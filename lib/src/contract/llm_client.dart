import 'chat_models.dart';

/// Port for chat / text completion. No domain logic.
abstract interface class LlmClient {
  Future<ChatResponse> complete(ChatRequest request);

  Stream<ChatStreamChunk> completeStream(ChatRequest request);
}
