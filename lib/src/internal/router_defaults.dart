/// Package-owned defaults. Host apps never see or override these in public API.
abstract final class RouterDefaults {
  /// Credential slot for the LLM provider token.
  static const llmCredentialSlot = 'llm';

  /// Credential slot for the TTS provider token.
  static const ttsCredentialSlot = 'tts';

  /// Public model label on responses — never a vendor id.
  static const publicModelId = 'default';

  /// Workers AI account id. Override at build with
  /// `--dart-define=IA_ROUTER_ACCOUNT_ID=...`.
  static const accountId = String.fromEnvironment(
    'IA_ROUTER_ACCOUNT_ID',
    defaultValue: '9c2eb959ccafdd0f563b1ea6adf1472b',
  );

  static const baseUri = 'https://api.cloudflare.com/client/v4';

  /// Gemini API REST root (TTS Batch + Interactions share this host).
  static const ttsBaseUri = 'https://generativelanguage.googleapis.com/v1beta';

  static const llmModel = '@cf/google/gemma-4-26b-a4b-it';

  /// Gemini TTS model used for Batch speech generation.
  static const ttsModel = 'gemini-3.8-flash-lite-tts';

  /// Default English prebuilt voice.
  static const ttsVoiceEn = 'Kore';

  /// Default Spanish prebuilt voice.
  static const ttsVoiceEs = 'Aoede';
}
