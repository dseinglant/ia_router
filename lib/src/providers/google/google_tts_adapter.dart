import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import '../../contract/exceptions.dart';
import '../../contract/tts_client.dart';
import '../../contract/tts_models.dart';
import '../../credentials/credential_store.dart';
import '../../http/ai_http_client.dart';
import '../../internal/router_defaults.dart';
import 'google_tts_endpoint.dart';

/// Delay injected so tests can skip real Batch poll waits.
typedef BatchPollSleeper = Future<void> Function(Duration delay);

String _primaryLang(String? language) {
  final code = (language ?? '').trim().toLowerCase();
  if (code.isEmpty) return 'en';
  return code.split(RegExp(r'[-_]')).first;
}

/// Extracts audio bytes from a completed Gemini Batch TTS job payload.
TtsResponse decodeGeminiBatchAudioResponse(
  Map<String, dynamic> batchJson, {
  required int index,
  String contentType = 'audio/wav',
}) {
  final inlined = _inlinedResponses(batchJson);
  if (index < 0 || index >= inlined.length) {
    throw AiProviderException(
      'Unexpected TTS batch result shape',
      cause: {
        'index': index,
        'count': inlined.length,
        'topKeys': batchJson.keys.toList(),
        'responseKeys': batchJson['response'] is Map
            ? (batchJson['response'] as Map).keys.toList()
            : null,
        'outputKeys': batchJson['output'] is Map
            ? (batchJson['output'] as Map).keys.toList()
            : null,
      },
    );
  }

  final entry = inlined[index];
  if (entry is! Map) {
    throw const AiProviderException('Unexpected TTS batch result shape');
  }

  final error = entry['error'];
  if (error != null) {
    final detail = formatProviderStatusMessage(error);
    throw AiProviderException(
      detail == null || detail.isEmpty
          ? 'TTS batch item failed'
          : 'TTS batch item failed: $detail',
      cause: error,
    );
  }

  final response = entry['response'];
  if (response is! Map) {
    throw const AiProviderException('Unexpected TTS batch result shape');
  }

  final b64 = _firstInlineAudio(response);
  if (b64 == null || b64.isEmpty) {
    throw AiProviderException(
      'Unexpected TTS result shape',
      cause: response,
    );
  }

  try {
    final decoded = base64Decode(b64);
    return TtsResponse(
      audioBytes: wrapGeminiPcmAsWav(decoded),
      contentType: contentType,
    );
  } on FormatException catch (e) {
    throw AiProviderException('Invalid TTS audio payload', cause: e);
  }
}

/// Gemini Batch REST nests the array as
/// `inlinedResponses: { inlinedResponses: [ ... ] }` (see InlinedResponses).
/// Older mocks / some wrappers use a bare list — accept both.
List<dynamic> _coerceInlinedList(dynamic node) {
  if (node is List) return node;
  if (node is Map) {
    final nested = node['inlinedResponses'] ?? node['inlined_responses'];
    if (nested is List) return nested;
  }
  return const [];
}

List<dynamic> _inlinedResponses(Map<String, dynamic> batchJson) {
  final containers = <Map>[];
  void addContainer(dynamic value) {
    if (value is Map) containers.add(value);
  }

  addContainer(batchJson['response']);
  addContainer(batchJson['output']);
  addContainer(batchJson['dest']);
  final response = batchJson['response'];
  if (response is Map) addContainer(response['output']);
  final metadata = batchJson['metadata'];
  if (metadata is Map) addContainer(metadata['output']);
  containers.add(batchJson);

  for (final container in containers) {
    final raw =
        container['inlinedResponses'] ?? container['inlined_responses'];
    final list = _coerceInlinedList(raw);
    if (list.isNotEmpty) return list;
  }
  return const [];
}

String? _firstInlineAudio(Map<dynamic, dynamic> response) {
  final candidates = response['candidates'];
  if (candidates is! List || candidates.isEmpty) return null;
  final first = candidates.first;
  if (first is! Map) return null;
  final content = first['content'];
  if (content is! Map) return null;
  final parts = content['parts'];
  if (parts is! List) return null;
  for (final part in parts) {
    if (part is! Map) continue;
    final inline = part['inlineData'] ?? part['inline_data'];
    if (inline is! Map) continue;
    final data = inline['data'];
    if (data is String && data.isNotEmpty) return data;
  }
  return null;
}

bool _isRiffWav(List<int> bytes) {
  return bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x41 &&
      bytes[10] == 0x56 &&
      bytes[11] == 0x45;
}

/// Gemini TTS returns raw 16-bit mono PCM @ 24 kHz; wrap as WAV for hosts.
Uint8List wrapGeminiPcmAsWav(
  List<int> pcm, {
  int sampleRate = 24000,
  int channels = 1,
  int bitsPerSample = 16,
}) {
  if (_isRiffWav(pcm)) return Uint8List.fromList(pcm);
  final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
  final blockAlign = channels * bitsPerSample ~/ 8;
  final dataSize = pcm.length;
  final header = ByteData(44);
  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      header.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + dataSize, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, bitsPerSample, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, dataSize, Endian.little);

  final out = BytesBuilder(copy: false)
    ..add(header.buffer.asUint8List())
    ..add(pcm);
  return out.toBytes();
}

String? batchJobState(Map<String, dynamic> batchJson) {
  final metadata = batchJson['metadata'];
  if (metadata is Map && metadata['state'] is String) {
    return metadata['state'] as String;
  }
  final state = batchJson['state'];
  if (state is String) return state;
  if (state is Map && state['name'] is String) return state['name'] as String;
  return null;
}

String? batchJobName(Map<String, dynamic> createJson) {
  final name = createJson['name'];
  if (name is String && name.trim().isNotEmpty) return name.trim();
  final metadata = createJson['metadata'];
  if (metadata is Map) {
    final metaName = metadata['name'];
    if (metaName is String && metaName.trim().isNotEmpty) {
      return metaName.trim();
    }
  }
  return null;
}

/// Pulls a readable message from a google.rpc.Status-shaped map / string.
String? formatProviderStatusMessage(dynamic error) {
  if (error is String) {
    final trimmed = error.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (error is! Map) return null;
  final message = error['message'];
  if (message is String && message.trim().isNotEmpty) {
    final trimmed = message.trim();
    return trimmed.length > 240 ? '${trimmed.substring(0, 240)}…' : trimmed;
  }
  final status = error['status'];
  if (status is String && status.trim().isNotEmpty) return status.trim();
  final code = error['code'];
  if (code != null) return 'code=$code';
  return null;
}

/// Decodes a unary `generateContent` TTS response into audio bytes.
TtsResponse decodeGeminiUnaryAudioResponse(
  Map<String, dynamic> json, {
  String contentType = 'audio/wav',
}) {
  final b64 = _firstInlineAudio(json);
  if (b64 == null || b64.isEmpty) {
    final promptFeedback = json['promptFeedback'] ?? json['prompt_feedback'];
    final detail = formatProviderStatusMessage(json['error']) ??
        (promptFeedback is Map
            ? formatProviderStatusMessage(promptFeedback)
            : null);
    throw AiProviderException(
      detail == null || detail.isEmpty
          ? 'Unexpected TTS result shape'
          : 'Unexpected TTS result shape: $detail',
      cause: {
        'topKeys': json.keys.toList(),
        if (promptFeedback != null) 'promptFeedback': promptFeedback,
      },
    );
  }

  try {
    return TtsResponse(
      audioBytes: wrapGeminiPcmAsWav(base64Decode(b64)),
      contentType: contentType,
    );
  } on FormatException catch (e) {
    throw AiProviderException('Invalid TTS audio payload', cause: e);
  }
}

/// Gemini 3.8 Flash-Lite TTS. Interactive calls use unary `generateContent`;
/// [synthesizeBatch] keeps the Batch API for bulk jobs.
final class GoogleTtsAdapter implements TtsClient {
  GoogleTtsAdapter({
    required CredentialStore credentials,
    AiHttpClient? httpClient,
    this.baseUri = RouterDefaults.ttsBaseUri,
    this.credentialSlot = RouterDefaults.ttsCredentialSlot,
    this.model = RouterDefaults.ttsModel,
    this.pollInterval = const Duration(seconds: 5),
    this.pollTimeout = const Duration(minutes: 10),
    BatchPollSleeper? sleeper,
    bool allowInsecureBaseUri = false,
  })  : _credentials = credentials,
        _http = httpClient ?? AiHttpClient(),
        _sleeper = sleeper ?? Future<void>.delayed {
    validateGoogleTtsBaseUri(baseUri, allowInsecure: allowInsecureBaseUri);
  }

  final CredentialStore _credentials;
  final AiHttpClient _http;
  final BatchPollSleeper _sleeper;
  final String baseUri;
  final String credentialSlot;
  final String model;
  final Duration pollInterval;
  final Duration pollTimeout;

  static const List<TtsVoice> _catalog = [
    TtsVoice(
      id: RouterDefaults.ttsVoiceEn,
      label: 'Kore (en)',
      language: 'en',
    ),
    TtsVoice(
      id: RouterDefaults.ttsVoiceEs,
      label: 'Aoede (es)',
      language: 'es',
    ),
  ];

  /// Previous package voice ids → Gemini prebuilt voice names.
  static const Map<String, String> _legacyVoiceAliases = {
    'luna': RouterDefaults.ttsVoiceEn,
    'aquila': RouterDefaults.ttsVoiceEs,
    'en-US-Neural2-A': RouterDefaults.ttsVoiceEn,
    'es-US-Neural2-A': RouterDefaults.ttsVoiceEs,
    'es-MX-Neural2-A': RouterDefaults.ttsVoiceEs,
  };

  // Gemini Developer API uses BATCH_STATE_*; some Vertex / older docs use
  // JOB_STATE_*. Accept both so a successful batch is not treated as failure.
  static const _succeededStates = {
    'JOB_STATE_SUCCEEDED',
    'BATCH_STATE_SUCCEEDED',
  };

  static const _terminalStates = {
    ..._succeededStates,
    'JOB_STATE_FAILED',
    'JOB_STATE_CANCELLED',
    'JOB_STATE_EXPIRED',
    'BATCH_STATE_FAILED',
    'BATCH_STATE_CANCELLED',
    'BATCH_STATE_EXPIRED',
  };

  Future<String> _token() async {
    final token = await _credentials.read(credentialSlot);
    if (token == null || token.isEmpty) {
      throw const AiAuthException('Missing API token');
    }
    return token;
  }

  TtsVoice? _voiceById(String? id) {
    if (id == null || id.isEmpty) return null;
    final resolved = _legacyVoiceAliases[id] ?? id;
    for (final voice in _catalog) {
      if (voice.id == resolved) return voice;
    }
    return null;
  }

  String _defaultVoiceForLang(String lang) =>
      lang == 'es' ? RouterDefaults.ttsVoiceEs : RouterDefaults.ttsVoiceEn;

  String _resolveVoice(TtsRequest request) {
    final catalogVoice = _voiceById(request.voice);
    if (catalogVoice != null) return catalogVoice.id;

    final raw = request.voice?.trim() ?? '';
    final aliased = _legacyVoiceAliases[raw];
    if (aliased != null) return aliased;

    final lang = _primaryLang(request.language);
    // Extended Voice Library / Voice replication ids only — never forward
    // stale host prefs (e.g. MeloTTS "Sarah") which 400 the API.
    if (raw.startsWith('voice_') || raw.startsWith('voicekey_')) {
      return raw;
    }
    return _defaultVoiceForLang(lang);
  }

  Map<String, dynamic> _generateContentRequest(TtsRequest request) {
    final voice = _resolveVoice(request);
    final style = request.style?.trim();
    // Gemini 3.8 GenerateContent: verbatim transcript + speech_metadata.style,
    // AUDIO modality, prebuiltVoiceConfig.voiceName.
    return {
      'contents': [
        {
          'role': 'user',
          'parts': [
            {
              'text': request.text,
              if (style != null && style.isNotEmpty)
                'speech_metadata': {'style': style},
            },
          ],
        },
      ],
      'generationConfig': {
        'responseModalities': ['AUDIO'],
        'speechConfig': {
          'voiceConfig': {
            'prebuiltVoiceConfig': {
              'voiceName': voice,
            },
          },
        },
      },
    };
  }

  @override
  Future<List<TtsVoice>> listVoices() async {
    return List<TtsVoice>.unmodifiable(_catalog);
  }

  @override
  Future<TtsResponse> synthesize(TtsRequest request) async {
    if (request.text.trim().isEmpty) {
      throw ArgumentError.value(request.text, 'text', 'must not be empty');
    }

    final token = await _token();
    const contentType = 'audio/wav';
    final response = await _http.postJson(
      uri: buildGeminiTtsGenerateUri(baseUri: baseUri, model: model),
      body: _generateContentRequest(request),
      headers: {'x-goog-api-key': token},
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throwForStatus(
        response,
        bodyHint: _providerErrorHint(response.bodyBytes),
      );
    }

    late final Map<String, dynamic> json;
    try {
      json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } on FormatException catch (e) {
      throw AiProviderException('Invalid JSON from provider TTS', cause: e);
    }

    return Isolate.run(
      () => decodeGeminiUnaryAudioResponse(json, contentType: contentType),
    );
  }

  @override
  Future<List<TtsResponse>> synthesizeBatch(List<TtsRequest> requests) async {
    if (requests.isEmpty) {
      throw ArgumentError.value(requests, 'requests', 'must not be empty');
    }
    for (final request in requests) {
      if (request.text.trim().isEmpty) {
        throw ArgumentError.value(request.text, 'text', 'must not be empty');
      }
    }

    final token = await _token();
    // Gemini TTS returns raw PCM; host players expect a WAV container label.
    // Bytes may still be PCM — callers that need a RIFF header wrap separately.
    const contentType = 'audio/wav';

    final batchBody = <String, dynamic>{
      'batch': {
        'display_name': 'ia-router-tts-${DateTime.now().millisecondsSinceEpoch}',
        'input_config': {
          'requests': {
            'requests': [
              for (var i = 0; i < requests.length; i++)
                {
                  'request': _generateContentRequest(requests[i]),
                  'metadata': {'key': 'tts-$i'},
                },
            ],
          },
        },
      },
    };

    final createResponse = await _http.postJson(
      uri: buildGeminiTtsBatchUri(baseUri: baseUri, model: model),
      body: batchBody,
      headers: {'x-goog-api-key': token},
    );

    if (createResponse.statusCode < 200 || createResponse.statusCode >= 300) {
      throwForStatus(
        createResponse,
        bodyHint: _providerErrorHint(createResponse.bodyBytes),
      );
    }

    late final Map<String, dynamic> createJson;
    try {
      createJson =
          jsonDecode(utf8.decode(createResponse.bodyBytes)) as Map<String, dynamic>;
    } on FormatException catch (e) {
      throw AiProviderException('Invalid JSON from provider TTS', cause: e);
    }

    final name = batchJobName(createJson);
    if (name == null) {
      throw AiProviderException(
        'Unexpected TTS batch create shape',
        cause: createJson.keys.toList(),
      );
    }

    final doneJson = await _pollUntilDone(name: name, token: token);
    final state = batchJobState(doneJson);
    if (!_succeededStates.contains(state)) {
      throw AiProviderException(
        'TTS batch ended with state ${state ?? 'unknown'}',
        cause: doneJson['error'],
      );
    }

    return Isolate.run(() {
      return [
        for (var i = 0; i < requests.length; i++)
          decodeGeminiBatchAudioResponse(
            doneJson,
            index: i,
            contentType: contentType,
          ),
      ];
    });
  }

  Future<Map<String, dynamic>> _pollUntilDone({
    required String name,
    required String token,
  }) async {
    final deadline = DateTime.now().add(pollTimeout);
    while (true) {
      final statusResponse = await _http.getJson(
        uri: buildGeminiBatchStatusUri(baseUri: baseUri, batchName: name),
        headers: {'x-goog-api-key': token},
      );

      if (statusResponse.statusCode < 200 || statusResponse.statusCode >= 300) {
        throwForStatus(
          statusResponse,
          bodyHint: _providerErrorHint(statusResponse.bodyBytes),
        );
      }

      late final Map<String, dynamic> json;
      try {
        json = jsonDecode(utf8.decode(statusResponse.bodyBytes))
            as Map<String, dynamic>;
      } on FormatException catch (e) {
        throw AiProviderException('Invalid JSON from provider TTS', cause: e);
      }

      final state = batchJobState(json);
      final done = json['done'] == true ||
          (state != null && _terminalStates.contains(state));
      if (done) return json;

      if (DateTime.now().isAfter(deadline)) {
        throw const AiProviderException('TTS batch poll timed out');
      }
      await _sleeper(pollInterval);
    }
  }

  String? _providerErrorHint(Uint8List bodyBytes) {
    try {
      final json = jsonDecode(utf8.decode(bodyBytes));
      if (json is! Map) return null;
      final error = json['error'];
      if (error is Map && error['message'] is String) {
        final msg = (error['message'] as String).trim();
        if (msg.isEmpty) return null;
        return msg.length > 160 ? '${msg.substring(0, 160)}…' : msg;
      }
    } catch (_) {
      return null;
    }
    return null;
  }
}
