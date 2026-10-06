import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'ai_client_pair.dart';
import 'contract/exceptions.dart';
import 'contract/llm_client.dart';
import 'contract/tts_client.dart';
import 'credentials/credential_store.dart';
import 'credentials/memory_credential_store.dart';
import 'credentials/secure_credential_store.dart';
import 'http/ai_http_client.dart';
import 'internal/router_defaults.dart';
import 'providers/cloudflare/cloudflare_clients.dart';

final class _CallbackCredentialStore implements CredentialStore {
  _CallbackCredentialStore(this._read);

  final Future<String?> Function() _read;

  @override
  Future<String?> read(String providerId) => _read();

  @override
  Future<void> write(String providerId, String secret) async {}

  @override
  Future<void> delete(String providerId) async {}
}

/// Provider-blind entrypoint.
///
/// Debug: [configure] with vendor keys. Release: [configureRelay] only.
/// [configure] and [ensureReady] throw in release builds.
abstract final class IaRouter {
  /// Default per-request HTTP deadline when the host does not set one.
  static const defaultRequestTimeout = Duration(seconds: 60);

  static CredentialStore _credentials = SecureCredentialStore();
  static AiHttpClient? _http;
  static http.Client? _debugTransport;
  static Duration _requestTimeout = defaultRequestTimeout;
  static String? _accountIdOverride;
  static String? _baseUriOverride;
  static String? _ttsBaseUriOverride;
  static bool _allowInsecureBaseUri = false;
  static AiClientPair? _clients;

  /// Per-request HTTP deadline for LLM and TTS.
  ///
  /// Set this before [configure] or [ensureReady]. A later change applies
  /// on the next [configure]. [ensureReady] keeps clients it already built.
  static Duration get requestTimeout => _requestTimeout;

  static set requestTimeout(Duration value) {
    if (value <= Duration.zero) {
      throw ArgumentError.value(value, 'requestTimeout', 'must be positive');
    }
    _requestTimeout = value;
  }

  /// Persists [llmToken] and [ttsToken] in secure storage and wires clients.
  ///
  /// Throws in release. Release hosts call [configureRelay].
  static Future<void> configure({
    required String llmToken,
    required String ttsToken,
  }) async {
    refuseVendorConfigure(releaseMode: kReleaseMode);
    final llm = llmToken.trim();
    final tts = ttsToken.trim();
    if (llm.isEmpty) {
      throw ArgumentError.value(llmToken, 'llmToken', 'must not be empty');
    }
    if (tts.isEmpty) {
      throw ArgumentError.value(ttsToken, 'ttsToken', 'must not be empty');
    }
    await _credentials.write(RouterDefaults.llmCredentialSlot, llm);
    await _credentials.write(RouterDefaults.ttsCredentialSlot, tts);
    _clients = _wire();
  }

  /// Release path. [readAccessToken] is called on every LLM/TTS request.
  /// It must return a Firebase ID token, never a vendor API key.
  ///
  /// [llmBaseUri] example: `https://<region>-<project>.cloudfunctions.net/aiRelay/client/v4`
  /// [ttsBaseUri] example: `https://<region>-<project>.cloudfunctions.net/aiRelay/v1beta`
  ///
  /// Deletes vendor keys left in the previous store by older versions.
  static Future<void> configureRelay({
    required Future<String?> Function() readAccessToken,
    required String llmBaseUri,
    required String ttsBaseUri,
  }) async {
    final llm = llmBaseUri.trim();
    final tts = ttsBaseUri.trim();
    if (llm.isEmpty || tts.isEmpty) {
      throw ArgumentError('relay base URIs must not be empty');
    }
    if (_credentials is! _CallbackCredentialStore) {
      await _credentials.delete(RouterDefaults.llmCredentialSlot);
      await _credentials.delete(RouterDefaults.ttsCredentialSlot);
    }
    _credentials = _CallbackCredentialStore(readAccessToken);
    _baseUriOverride = llm;
    _ttsBaseUriOverride = tts;
    _clients = _wire();
  }

  /// Rehydrates clients from secure storage if [configure] already ran before.
  ///
  /// Throws in release when clients are not already wired by [configureRelay].
  static Future<void> ensureReady() async {
    if (_clients != null) return;
    refuseVendorConfigure(releaseMode: kReleaseMode);
    final llm = await _credentials.read(RouterDefaults.llmCredentialSlot);
    final tts = await _credentials.read(RouterDefaults.ttsCredentialSlot);
    if (llm == null ||
        llm.isEmpty ||
        tts == null ||
        tts.isEmpty) {
      throw const AiAuthException(
        'Not configured; call IaRouter.configure(llmToken:, ttsToken:) first',
      );
    }
    _clients = _wire();
  }

  /// Deletes stored API keys and drops wired clients.
  static Future<void> clear() async {
    await _credentials.delete(RouterDefaults.llmCredentialSlot);
    await _credentials.delete(RouterDefaults.ttsCredentialSlot);
    _clients = null;
  }

  static LlmClient get llm => _requireClients().llm;

  static TtsClient get tts => _requireClients().tts;

  /// Release builds must not store a vendor key. Tests pass [releaseMode].
  @visibleForTesting
  static void refuseVendorConfigure({required bool releaseMode}) {
    if (releaseMode) {
      throw UnsupportedError(
        'Release builds must call IaRouter.configureRelay.',
      );
    }
  }

  static AiClientPair _requireClients() {
    final clients = _clients;
    if (clients == null) {
      throw const AiAuthException(
        'Not configured; call IaRouter.configure(llmToken:, ttsToken:) '
        'or ensureReady() first',
      );
    }
    return clients;
  }

  static AiClientPair _wire() {
    return AiClients.create(
      accountId: _accountIdOverride ?? RouterDefaults.accountId,
      credentials: _credentials,
      httpClient: _http ??
          AiHttpClient(
            client: _debugTransport,
            timeout: _requestTimeout,
          ),
      baseUri: _baseUriOverride ?? RouterDefaults.baseUri,
      ttsBaseUri: _ttsBaseUriOverride ?? RouterDefaults.ttsBaseUri,
      allowInsecureBaseUri: _allowInsecureBaseUri,
    );
  }

  /// Test-only: swap storage/HTTP before [configure] / [ensureReady].
  @visibleForTesting
  static void debugBind({
    CredentialStore? credentials,
    AiHttpClient? httpClient,
    http.Client? transport,
    String? accountId,
    String? baseUri,
    String? ttsBaseUri,
    bool allowInsecureBaseUri = false,
  }) {
    _credentials = credentials ?? MemoryCredentialStore();
    _http = httpClient;
    // Ignored when [httpClient] is set — that client owns its own timeout.
    _debugTransport = httpClient == null ? transport : null;
    _accountIdOverride = accountId;
    _baseUriOverride = baseUri;
    _ttsBaseUriOverride = ttsBaseUri;
    _allowInsecureBaseUri = allowInsecureBaseUri;
    _clients = null;
  }

  /// Test-only: restore production defaults between tests.
  @visibleForTesting
  static void debugReset() {
    _credentials = SecureCredentialStore();
    _http = null;
    _debugTransport = null;
    _requestTimeout = defaultRequestTimeout;
    _accountIdOverride = null;
    _baseUriOverride = null;
    _ttsBaseUriOverride = null;
    _allowInsecureBaseUri = false;
    _clients = null;
  }
}
