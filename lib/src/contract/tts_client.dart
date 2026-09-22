import 'tts_models.dart';

/// Port for text-to-speech. No domain logic.
abstract interface class TtsClient {
  /// Voices available for the active TTS backend (for host UI pickers).
  Future<List<TtsVoice>> listVoices();

  Future<TtsResponse> synthesize(TtsRequest request);
}
