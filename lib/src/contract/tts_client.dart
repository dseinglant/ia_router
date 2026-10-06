import 'tts_models.dart';

/// Port for text-to-speech. No domain logic.
abstract interface class TtsClient {
  /// Voices available for the active TTS backend (for host UI pickers).
  Future<List<TtsVoice>> listVoices();

  /// Synthesize one utterance. Backends may fulfill this via a 1-item batch.
  Future<TtsResponse> synthesize(TtsRequest request);

  /// Synthesize many utterances in one provider batch job (order preserved).
  Future<List<TtsResponse>> synthesizeBatch(List<TtsRequest> requests);
}
