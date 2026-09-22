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

/// Top-level so [Isolate.run] can decode JSON TTS off the UI isolate.
TtsResponse decodeGoogleTtsJsonResponse(
  Uint8List bodyBytes, {
  String contentType = 'audio/mpeg',
}) {
  late final Map<String, dynamic> json;
  try {
    json = jsonDecode(utf8.decode(bodyBytes)) as Map<String, dynamic>;
  } on FormatException catch (e) {
    throw AiProviderException('Invalid JSON from provider TTS', cause: e);
  }

  final audio = json['audioContent'];
  if (audio is! String || audio.isEmpty) {
    throw AiProviderException(
      'Unexpected TTS result shape',
      cause: json,
    );
  }

  return TtsResponse(
    audioBytes: base64Decode(audio),
    contentType: contentType,
  );
}

String _primaryLang(String? language) {
  final code = (language ?? '').trim().toLowerCase();
  if (code.isEmpty) return 'en';
  return code.split(RegExp(r'[-_]')).first;
}

/// Language code Google expects (`es-US` / `en-US`) from a Neural2 voice name.
String languageCodeForGoogleVoice(String voiceName) {
  final parts = voiceName.split('-');
  if (parts.length >= 2) return '${parts[0]}-${parts[1]}';
  return voiceName;
}

/// Google Cloud Text-to-Speech adapter (Neural2).
final class GoogleTtsAdapter implements TtsClient {
  GoogleTtsAdapter({
    required CredentialStore credentials,
    AiHttpClient? httpClient,
    this.baseUri = RouterDefaults.ttsBaseUri,
    this.credentialSlot = RouterDefaults.ttsCredentialSlot,
    bool allowInsecureBaseUri = false,
  })  : _credentials = credentials,
        _http = httpClient ?? AiHttpClient() {
    validateGoogleTtsBaseUri(baseUri, allowInsecure: allowInsecureBaseUri);
  }

  final CredentialStore _credentials;
  final AiHttpClient _http;
  final String baseUri;
  final String credentialSlot;

  static const List<TtsVoice> _catalog = [
    TtsVoice(
      id: RouterDefaults.ttsVoiceEn,
      label: 'Neural2 A (en-US)',
      language: 'en',
    ),
    TtsVoice(
      id: RouterDefaults.ttsVoiceEs,
      label: 'Neural2 A (es-US)',
      language: 'es',
    ),
  ];

  /// Legacy / misspelled ids → real Neural2 names.
  static const Map<String, String> _legacyVoiceAliases = {
    'luna': RouterDefaults.ttsVoiceEn,
    'aquila': RouterDefaults.ttsVoiceEs,
    // Google never shipped es-MX Neural2; map the old package id.
    'es-MX-Neural2-A': RouterDefaults.ttsVoiceEs,
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

  @override
  Future<List<TtsVoice>> listVoices() async {
    return List<TtsVoice>.unmodifiable(_catalog);
  }

  @override
  Future<TtsResponse> synthesize(TtsRequest request) async {
    final token = await _token();
    final catalogVoice = _voiceById(request.voice);
    final lang = _primaryLang(request.language ?? catalogVoice?.language);
    final voiceName = catalogVoice?.id ??
        _legacyVoiceAliases[request.voice ?? ''] ??
        (request.voice != null &&
                request.voice!.isNotEmpty &&
                request.voice!.contains('-')
            ? request.voice!
            : _defaultVoiceForLang(lang));
    final languageCode = languageCodeForGoogleVoice(voiceName);
    final encoding = _encodingFor(request.format);
    final contentType = _contentTypeFor(encoding);

    final body = <String, dynamic>{
      'input': {'text': request.text},
      'voice': {
        'languageCode': languageCode,
        'name': voiceName,
      },
      'audioConfig': {
        'audioEncoding': encoding,
      },
    };

    // Google accepts API keys via `x-goog-api-key` (preferred) or `?key=`.
    // Send both so either style of GCP key works; never put Bearer on API keys
    // (AIza…) — that yields 401.
    final response = await _http.postJson(
      uri: buildGoogleSynthesizeUri(baseUri: baseUri, key: token),
      body: body,
      headers: {'x-goog-api-key': token},
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throwForStatus(
        response,
        bodyHint: _providerErrorHint(response.bodyBytes),
      );
    }

    return Isolate.run(
      () => decodeGoogleTtsJsonResponse(
        response.bodyBytes,
        contentType: contentType,
      ),
    );
  }

  String _encodingFor(String? format) {
    switch ((format ?? 'mp3').toLowerCase()) {
      case 'mp3':
      case 'mpeg':
        return 'MP3';
      case 'wav':
      case 'linear16':
        return 'LINEAR16';
      case 'ogg':
      case 'opus':
        return 'OGG_OPUS';
      default:
        return 'MP3';
    }
  }

  String _contentTypeFor(String encoding) {
    switch (encoding) {
      case 'LINEAR16':
        return 'audio/wav';
      case 'OGG_OPUS':
        return 'audio/ogg';
      case 'MP3':
      default:
        return 'audio/mpeg';
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
