import '../../ai_client_pair.dart';
import '../../credentials/credential_store.dart';
import '../../credentials/secure_credential_store.dart';
import '../../http/ai_http_client.dart';
import '../../internal/router_defaults.dart';
import '../google/google_tts_adapter.dart';
import 'cloudflare_endpoint.dart';
import 'cloudflare_llm_adapter.dart';

/// Internal composition factory (Cloudflare LLM + Google TTS).
abstract final class AiClients {
  /// LLM on Cloudflare Workers AI, TTS on Google Cloud Text-to-Speech.
  ///
  /// [baseUri] must be `https` unless [allowInsecureBaseUri] is true (tests).
  /// [llmModel] overrides the default Workers AI model.
  /// [llmFallbackModel] is used when the primary model returns a deprecated or
  /// model-not-found error.
  static AiClientPair create({
    required String accountId,
    CredentialStore? credentials,
    AiHttpClient? httpClient,
    String baseUri = RouterDefaults.baseUri,
    String ttsBaseUri = RouterDefaults.ttsBaseUri,
    String llmModel = RouterDefaults.llmModel,
    String? llmFallbackModel,
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
        runModel: llmModel,
        fallbackModel: llmFallbackModel,
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
