import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import '../../contract/chat_models.dart';
import '../../contract/exceptions.dart';
import '../../contract/llm_client.dart';
import '../../credentials/credential_store.dart';
import '../../http/ai_http_client.dart';
import '../../internal/router_defaults.dart';
import 'cloudflare_endpoint.dart';

/// Cloudflare Workers AI adapter for [LlmClient].
///
/// Endpoint: `POST /accounts/{accountId}/ai/run/{model}`
final class CloudflareLlmAdapter implements LlmClient {
  CloudflareLlmAdapter({
    required this.accountId,
    required CredentialStore credentials,
    AiHttpClient? httpClient,
    this.baseUri = RouterDefaults.baseUri,
    this.credentialSlot = RouterDefaults.llmCredentialSlot,
    this.runModel = RouterDefaults.llmModel,
    this.fallbackModel,
    bool allowInsecureBaseUri = false,
    /// Gemma 4+ / reasoning models burn max_tokens on CoT unless false.
    this.enableThinking = false,
  })  : _credentials = credentials,
        _http = httpClient ?? AiHttpClient() {
    validateCloudflareBaseUri(baseUri, allowInsecure: allowInsecureBaseUri);
    validateCloudflareAccountId(accountId);
    if (fallbackModel != null) {
      validateCloudflareModelId(fallbackModel!);
    }
  }

  final String accountId;
  final CredentialStore _credentials;
  final AiHttpClient _http;
  final String baseUri;
  final String credentialSlot;
  final String runModel;

  /// Fallback model used when primary returns model-not-found or deprecated.
  final String? fallbackModel;
  final bool enableThinking;

  Uri _runUri([String? modelOverride]) {
    return buildCloudflareRunUri(
      baseUri: baseUri,
      accountId: accountId,
      model: modelOverride ?? runModel,
    );
  }

  Future<String> _token() async {
    final token = await _credentials.read(credentialSlot);
    if (token == null || token.isEmpty) {
      throw const AiAuthException('Missing API token');
    }
    return token;
  }

  Map<String, dynamic> _body(ChatRequest request, {required bool stream}) {
    final body = <String, dynamic>{
      'messages': [
        for (final m in request.messages) m.toJson(),
      ],
      if (stream) 'stream': true,
      if (request.temperature != null) 'temperature': request.temperature,
      if (request.maxTokens != null) ...{
        'max_tokens': request.maxTokens,
        // Gemma 4+ on Workers AI prefers max_completion_tokens.
        'max_completion_tokens': request.maxTokens,
      },
      // Without this, Gemma 4 fills reasoning_content and leaves content "".
      'chat_template_kwargs': {'enable_thinking': enableThinking},
      if (!enableThinking) 'reasoning_effort': null,
    };
    return body;
  }

  @override
  Future<ChatResponse> complete(ChatRequest request) async {
    final token = await _token();
    final response = await _http.postJson(
      uri: _runUri(),
      bearerToken: token,
      body: _body(request, stream: false),
    );
    if (_shouldFallback(response.statusCode, response.body)) {
      return _completeWithFallback(request, token);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throwForStatus(response);
    }
    return _parseComplete(response.body);
  }

  Future<ChatResponse> _completeWithFallback(
    ChatRequest request,
    String token,
  ) async {
    if (fallbackModel == null) {
      throw const AiProviderException(
        'Model deprecated or not found, no fallback configured',
      );
    }
    developer.log(
      'primary model $runModel unavailable, falling back to $fallbackModel',
      name: 'CloudflareLlm',
      level: 800,
    );
    final response = await _http.postJson(
      uri: _runUri(fallbackModel),
      bearerToken: token,
      body: _body(request, stream: false),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throwForStatus(response);
    }
    return _parseComplete(response.body);
  }

  bool _shouldFallback(int statusCode, String body) {
    if (statusCode == 404) return true;
    if (statusCode == 400 || statusCode == 410) {
      final lower = body.toLowerCase();
      if (lower.contains('deprecated') ||
          lower.contains('not found') ||
          lower.contains('model not available') ||
          lower.contains('unknown model')) {
        return true;
      }
    }
    return false;
  }

  ChatResponse _parseComplete(String raw) {
    late final Map<String, dynamic> json;
    try {
      json = jsonDecode(raw) as Map<String, dynamic>;
    } on FormatException catch (e) {
      throw AiProviderException('Invalid JSON from provider', cause: e);
    }

    if (json['success'] == false) {
      throw AiProviderException(
        'Provider reported failure',
        cause: json['errors'],
      );
    }

    final result = json['result'];
    final content = _extractContent(result, envelope: json);
    final usage = _extractUsage(result is Map ? result : json);

    return ChatResponse(
      id: json['result'] is Map && (json['result'] as Map)['id'] != null
          ? '${(json['result'] as Map)['id']}'
          : 'chat-${DateTime.now().millisecondsSinceEpoch}',
      model: RouterDefaults.publicModelId,
      content: content,
      usage: usage,
    );
  }

  String _extractContent(
    Object? result, {
    Map<String, dynamic>? envelope,
  }) {
    final text = _textFromResult(result);
    if (text != null && text.isNotEmpty) return text;
    final shape = _describeResultShape(result);
    final dump = _diagnosticDump(result, envelope: envelope);
    developer.log(
      'no usable LLM text (often max_tokens exhausted on reasoning); $shape; dump=$dump',
      name: 'CloudflareLlm',
      level: 1000,
      error: dump,
    );
    throw AiProviderException(
      'Unexpected LLM result shape ($shape); dump=$dump',
      cause: result,
    );
  }

  /// Compact payload for logs when content extraction fails.
  /// Truncates prompt/body fields so we see *why*, not the whole article.
  String _diagnosticDump(
    Object? result, {
    Map<String, dynamic>? envelope,
  }) {
    final out = <String, dynamic>{};
    if (envelope != null) {
      out['success'] = envelope['success'];
      if (envelope.containsKey('errors')) out['errors'] = envelope['errors'];
      if (envelope.containsKey('messages')) {
        out['envelopeMessages'] = envelope['messages'];
      }
    }
    if (result is! Map) {
      out['resultType'] = '${result.runtimeType}';
      out['result'] = result;
      return jsonEncode(out);
    }
    final map = Map<String, dynamic>.from(result);
    out['keys'] = map.keys.map((k) => k.toString()).toList()..sort();
    for (final k in const [
      'id',
      'object',
      'model',
      'created',
      'service_tier',
    ]) {
      if (map.containsKey(k)) out[k] = map[k];
    }
    if (map.containsKey('usage')) out['usage'] = map['usage'];
    if (map.containsKey('metrics')) out['metrics'] = map['metrics'];
    final choices = map['choices'];
    out['choicesType'] = '${choices.runtimeType}';
    out['choicesLen'] = choices is List ? choices.length : null;
    out['choices'] = _jsonSafe(choices);
    if (choices is List && choices.isNotEmpty && choices.first is Map) {
      final c0 = Map<String, dynamic>.from(choices.first as Map);
      out['choice0Keys'] = c0.keys.map((k) => k.toString()).toList()..sort();
      if (c0.containsKey('finish_reason')) {
        out['finish_reason'] = c0['finish_reason'];
      }
      if (c0.containsKey('native_finish_reason')) {
        out['native_finish_reason'] = c0['native_finish_reason'];
      }
      final message = c0['message'];
      if (message is Map) {
        out['messageKeys'] =
            message.keys.map((k) => k.toString()).toList()..sort();
        out['contentType'] = '${message['content']?.runtimeType}';
        out['contentPreview'] = _clipPreview(message['content']);
        if (message.containsKey('reasoning_content')) {
          out['reasoningPreview'] = _clipPreview(message['reasoning_content']);
        }
        if (message.containsKey('refusal')) {
          out['refusal'] = message['refusal'];
        }
      }
    }
    if (map.containsKey('prompt_text')) {
      out['prompt_text_preview'] = _clipPreview(map['prompt_text']);
    }
    final promptIds = map['prompt_token_ids'];
    if (promptIds is List) {
      out['prompt_token_ids_len'] = promptIds.length;
    } else if (promptIds != null) {
      out['prompt_token_ids_type'] = '${promptIds.runtimeType}';
    }
    if (map.containsKey('prompt_logprobs')) {
      out['prompt_logprobs_type'] = '${map['prompt_logprobs']?.runtimeType}';
    }
    return jsonEncode(out);
  }

  Object? _jsonSafe(Object? value) {
    if (value == null || value is num || value is bool || value is String) {
      return value is String ? _clipPreview(value) : value;
    }
    if (value is List) {
      return [for (final e in value.take(3)) _jsonSafe(e)];
    }
    if (value is Map) {
      return <String, dynamic>{
        for (final e in value.entries) '${e.key}': _jsonSafe(e.value),
      };
    }
    return '${value.runtimeType}';
  }

  String? _clipPreview(Object? value, {int max = 240}) {
    if (value == null) return null;
    final s = value is String ? value : jsonEncode(_jsonSafe(value));
    if (s.length <= max) return s;
    return '${s.substring(0, max)}…(len=${s.length})';
  }

  String _describeResultShape(Object? result) {
    if (result is! Map) return 'type=${result.runtimeType}';
    final keys = result.keys.toList();
    final choices = result['choices'];
    if (choices is! List || choices.isEmpty) {
      return 'keys=$keys';
    }
    final first = choices.first;
    if (first is! Map) {
      return 'keys=$keys, choice0=${first.runtimeType}';
    }
    final message = first['message'];
    final content = message is Map ? message['content'] : null;
    return 'keys=$keys, choice0Keys=${first.keys.toList()}, '
        'contentType=${content?.runtimeType ?? (message is Map ? 'null' : 'no-message')}';
  }

  /// Workers AI: classic `{response}` / `{text}` or OpenAI-style `{choices}`.
  String? _textFromResult(Object? result) {
    if (result is String) {
      return result.trim().isEmpty ? null : result;
    }
    if (result is! Map) return null;
    final map = Map<String, dynamic>.from(result);
    for (final key in const [
      'response',
      'text',
      'content',
      'summary',
      'description',
    ]) {
      final extracted = _coerceContent(map[key]);
      if (extracted != null) return extracted;
    }
    return _textFromOpenAiChoices(map['choices']);
  }

  String? _textFromOpenAiChoices(Object? choices) {
    if (choices is! List || choices.isEmpty) return null;
    for (final item in choices) {
      if (item is! Map) continue;
      final message = item['message'];
      if (message is Map) {
        final fromContent = _coerceContent(message['content']);
        if (fromContent != null) return fromContent;
        // Reasoning models may exhaust max_tokens on CoT only.
        final fromReasoning = _coerceContent(message['reasoning_content']);
        if (fromReasoning != null) {
          developer.log(
            'using reasoning_content fallback (content empty)',
            name: 'CloudflareLlm',
            level: 500,
          );
          return fromReasoning;
        }
      }
      final fromDelta = item['delta'];
      if (fromDelta is Map) {
        final d = _coerceContent(
          fromDelta['content'] ?? fromDelta['reasoning_content'],
        );
        if (d != null) return d;
      }
      final fromText = _coerceContent(item['text']);
      if (fromText != null) return fromText;
    }
    return null;
  }

  /// OpenAI/Workers AI may return a string or a list of content parts.
  String? _coerceContent(Object? content) {
    if (content is String) {
      final t = content.trim();
      return t.isEmpty ? null : content;
    }
    if (content is Map) {
      final nested = _coerceContent(content['text'] ?? content['content']);
      if (nested != null) return nested;
    }
    if (content is List) {
      final buf = StringBuffer();
      for (final part in content) {
        final piece = _coerceContent(part);
        if (piece != null) buf.write(piece);
      }
      final joined = buf.toString().trim();
      return joined.isEmpty ? null : joined;
    }
    return null;
  }

  Usage? _extractUsage(Object? source) {
    if (source is! Map) return null;
    final usage = source['usage'];
    if (usage is! Map) return null;
    return Usage(
      promptTokens: _asInt(usage['prompt_tokens'] ?? usage['promptTokens']),
      completionTokens:
          _asInt(usage['completion_tokens'] ?? usage['completionTokens']),
      totalTokens: _asInt(usage['total_tokens'] ?? usage['totalTokens']),
    );
  }

  int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return null;
  }

  @override
  Stream<ChatStreamChunk> completeStream(ChatRequest request) async* {
    final token = await _token();
    final streamed = await _http.postJsonStream(
      uri: _runUri(),
      bearerToken: token,
      body: _body(request, stream: true),
    );

    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      final errBody = await streamed.stream.bytesToString();
      if (_shouldFallback(streamed.statusCode, errBody)) {
        yield* _completeStreamWithFallback(request, token);
        return;
      }
      throwForStreamStatus(streamed, errBody);
    }

    yield* _parseStreamResponse(streamed.stream);
  }

  Stream<ChatStreamChunk> _completeStreamWithFallback(
    ChatRequest request,
    String token,
  ) async* {
    if (fallbackModel == null) {
      throw const AiProviderException(
        'Model deprecated or not found, no fallback configured',
      );
    }
    developer.log(
      'primary model $runModel unavailable, falling back to $fallbackModel',
      name: 'CloudflareLlm',
      level: 800,
    );
    final streamed = await _http.postJsonStream(
      uri: _runUri(fallbackModel),
      bearerToken: token,
      body: _body(request, stream: true),
    );
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      final errBody = await streamed.stream.bytesToString();
      throwForStreamStatus(streamed, errBody);
    }
    yield* _parseStreamResponse(streamed.stream);
  }

  Stream<ChatStreamChunk> _parseStreamResponse(
    Stream<List<int>> responseStream,
  ) async* {
    final lines = responseStream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      // SSE: "data: {...}" or raw JSON lines.
      final payload = trimmed.startsWith('data:')
          ? trimmed.substring(5).trim()
          : trimmed;
      if (payload == '[DONE]') {
        yield const ChatStreamChunk(done: true);
        return;
      }

      Map<String, dynamic> json;
      try {
        json = jsonDecode(payload) as Map<String, dynamic>;
      } on FormatException {
        continue;
      }

      if (json['success'] == false) {
        throw AiProviderException(
          'Provider stream reported failure',
          cause: json['errors'],
        );
      }

      final delta = _streamDelta(json);
      if (delta != null && delta.isNotEmpty) {
        yield ChatStreamChunk(delta: delta);
      }
      if (json['done'] == true) {
        yield const ChatStreamChunk(done: true);
        return;
      }
    }

    yield const ChatStreamChunk(done: true);
  }

  String? _streamDelta(Map<String, dynamic> json) {
    // Workers AI OpenAI-compat: digits/quotes often land only in
    // choices[].delta.content. Top-level "response" can omit them — concatenating
    // that field yields broken JSON (ponytail: prefer choices; response fallback).
    final fromChoices = _textFromOpenAiChoices(json['choices']);
    if (fromChoices != null) return fromChoices;

    final result = json['response'] ?? json['result'];
    if (result is String) {
      return result.isEmpty ? null : result;
    }
    if (result is Map) {
      final nestedChoices = _textFromOpenAiChoices(result['choices']);
      if (nestedChoices != null) return nestedChoices;
      final r = result['response'];
      if (r is String && r.isNotEmpty) return r;
      final d = result['delta'];
      if (d is String && d.isNotEmpty) return d;
    }
    return null;
  }
}
