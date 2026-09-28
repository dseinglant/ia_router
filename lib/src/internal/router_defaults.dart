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

  /// Google Cloud Text-to-Speech REST root.
  static const ttsBaseUri = 'https://texttospeech.googleapis.com/v1';

  static const llmModel = '@cf/google/gemma-4-26b-a4b-it';

  /// Default English Neural2 voice.
  static const ttsVoiceEn = 'en-US-Neural2-A';

  /// Default Spanish Neural2 voice.
  ///
  /// Google has no `es-MX-Neural2-*`; closest LatAm Neural2 is `es-US`.
  static const ttsVoiceEs = 'es-US-Neural2-A';
}
