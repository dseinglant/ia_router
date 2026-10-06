import '../../ai_client_pair.dart';
import '../../credentials/credential_store.dart';
import '../../credentials/secure_credential_store.dart';
import '../../http/ai_http_client.dart';
import '../../internal/router_defaults.dart';
import '../google/google_tts_adapter.dart';
import 'cloudflare_endpoint.dart';
import 'cloudflare_llm_adapter.dart';

/// Internal composition factory (Cloudflare LLM + Gemini TTS Batch).
abstract final class AiClients {
  /// LLM on Cloudflare Workers AI, TTS on Gemini 3.8 Flash-Lite (Batch API).
  ///
  /// [baseUri] must be `https` unless [allowInsecureBaseUri] is true (tests).
  static AiClientPair create({
    required String accountId,
    CredentialStore? credentials,
    AiHttpClient? httpClient,
    String baseUri = RouterDefaults.baseUri,
    String ttsBaseUri = RouterDefaults.ttsBaseUri,
    bool allowInsecureBaseUri = false,
  }) {
    validateCloudflareBaseUri(baseUri, allowInsecure: allowInsecureBaseUri);
    validateCloudflareAccountId(accountId);
    final store = credentials ?? SecureCredentialStore();
    final http = httpClient ?? AiHttpClient();
    return AiClientPair(
      llm: CloudflareLlmAdapter(
        accountId: accountId,
        credentials: store,
        httpClient: http,
        baseUri: baseUri,
        credentialSlot: RouterDefaults.llmCredentialSlot,
        allowInsecureBaseUri: allowInsecureBaseUri,
      ),
      tts: GoogleTtsAdapter(
        credentials: store,
        httpClient: http,
        baseUri: ttsBaseUri,
        credentialSlot: RouterDefaults.ttsCredentialSlot,
        allowInsecureBaseUri: allowInsecureBaseUri,
      ),
    );
  }
}
