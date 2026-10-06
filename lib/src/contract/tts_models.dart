import 'dart:typed_data';

/// A selectable TTS voice for host UI pickers.
///
/// [id] is opaque and package-owned — pass it as [TtsRequest.voice].
/// [language] is a BCP-47-ish hint (e.g. `es`, `en`) for filtering / request.
class TtsVoice {
  const TtsVoice({
    required this.id,
    required this.label,
    required this.language,
  });

  /// Opaque id to send as [TtsRequest.voice].
  final String id;

  /// Human-readable label for UI.
  final String label;

  /// Language code associated with this voice (e.g. `en`, `es`, `fr`).
  final String language;
}

/// Text-to-speech request. Adapters ignore unsupported fields (e.g. [voice]).
///
/// Model selection is owned by the package — hosts do not pass a model id.
/// Prefer [voice] ids from [TtsClient.listVoices].
class TtsRequest {
  const TtsRequest({
    required this.text,
    this.voice,
    this.format,
    this.language,
    this.style,
  });

  final String text;
  final String? voice;
  final String? format;
  final String? language;

  /// Turn-level delivery notes for Gemini 3.8+ (`speech_metadata.style`).
  /// Never concatenate into [text] — the model speaks the transcript verbatim.
  final String? style;
}

/// Raw audio payload from a TTS provider.
class TtsResponse {
  const TtsResponse({
    required this.audioBytes,
    required this.contentType,
  });

  final Uint8List audioBytes;
  final String contentType;
}
