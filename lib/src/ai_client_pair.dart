import 'contract/llm_client.dart';
import 'contract/tts_client.dart';

/// Wired LLM + TTS clients (internal composition).
final class AiClientPair {
  const AiClientPair({required this.llm, required this.tts});

  final LlmClient llm;
  final TtsClient tts;
}
