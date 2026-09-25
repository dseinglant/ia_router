import 'package:flutter/foundation.dart';

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

/// Provider-blind entrypoint. Host passes independent LLM and TTS API keys.
///
/// ```dart
/// await IaRouter.configure(llmToken: llmKey, ttsToken: ttsKey);
/// final chat = await IaRouter.llm.complete(ChatRequest(messages: [...]));
/// await IaRouter.clear();
/// ```
///
/// After a cold start with persisted keys, call [ensureReady] once before
/// using [llm] / [tts].
abstract final class IaRouter {
  static CredentialStore _credentials = SecureCredentialStore();
  static AiHttpClient? _http;
  static String? _accountIdOverride;
  static String? _baseUriOverride;
  static String? _ttsBaseUriOverride;
  static bool _allowInsecureBaseUri = false;
  static AiClientPair? _clients;
  static String? _llmModelOverride;

  /// Persists [llmToken] and [ttsToken] in secure storage and wires clients.
  ///
  /// [llmModel] overrides the default Workers AI model (Gemma 4 26B).
  /// Leave null to use the compile-time default or `--dart-define=IA_MODEL`.
  static Future<void> configure({
    required String llmToken,
    required String ttsToken,
    String? llmModel,
  }) async {
    final llm = llmToken.trim();
    final tts = ttsToken.trim();
    if (llm.isEmpty) {
      throw ArgumentError.value(llmToken, 'llmToken', 'must not be empty');
    }
    if (tts.isEmpty) {
      throw ArgumentError.value(ttsToken, 'ttsToken', 'must not be empty');
    }
    _llmModelOverride = llmModel;
    await _credentials.write(RouterDefaults.llmCredentialSlot, llm);
    await _credentials.write(RouterDefaults.ttsCredentialSlot, tts);
    _clients = _wire();
  }

  /// Rehydrates clients from secure storage if [configure] already ran before.
  static Future<void> ensureReady() async {
    if (_clients != null) return;
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
      httpClient: _http,
      baseUri: _baseUriOverride ?? RouterDefaults.baseUri,
      ttsBaseUri: _ttsBaseUriOverride ?? RouterDefaults.ttsBaseUri,
      llmModel: _llmModelOverride ?? RouterDefaults.llmModel,
      llmFallbackModel: RouterDefaults.llmFallbackModel,
      allowInsecureBaseUri: _allowInsecureBaseUri,
    );
  }

  /// Test-only: swap storage/HTTP before [configure] / [ensureReady].
  @visibleForTesting
  static void debugBind({
    CredentialStore? credentials,
    AiHttpClient? httpClient,
    String? accountId,
    String? baseUri,
    String? ttsBaseUri,
    String? llmModel,
    bool allowInsecureBaseUri = false,
  }) {
    _credentials = credentials ?? MemoryCredentialStore();
    _http = httpClient;
    _accountIdOverride = accountId;
    _baseUriOverride = baseUri;
    _ttsBaseUriOverride = ttsBaseUri;
    _llmModelOverride = llmModel;
    _allowInsecureBaseUri = allowInsecureBaseUri;
    _clients = null;
  }

  /// Test-only: restore production defaults between tests.
  @visibleForTesting
  static void debugReset() {
    _credentials = SecureCredentialStore();
    _http = null;
    _accountIdOverride = null;
    _baseUriOverride = null;
    _ttsBaseUriOverride = null;
    _llmModelOverride = null;
    _allowInsecureBaseUri = false;
    _clients = null;
  }
}
