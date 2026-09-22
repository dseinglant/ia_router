/// Chat roles aligned with OpenAI-compatible APIs.
enum ChatRole {
  system,
  user,
  assistant;

  String get wireName => name;
}

/// One turn in a chat completion request.
class ChatMessage {
  const ChatMessage({required this.role, required this.content});

  final ChatRole role;
  final String content;

  Map<String, dynamic> toJson() => {
        'role': role.wireName,
        'content': content,
      };
}

/// OpenAI-like completion request. Adapters ignore unsupported fields.
///
/// Model selection is owned by the package — hosts do not pass a model id.
class ChatRequest {
  const ChatRequest({
    required this.messages,
    this.temperature,
    this.maxTokens,
  });

  final List<ChatMessage> messages;
  final double? temperature;
  final int? maxTokens;
}

/// Token usage when the provider reports it.
class Usage {
  const Usage({
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
  });

  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
}

/// Full (non-stream) completion result.
class ChatResponse {
  const ChatResponse({
    required this.id,
    required this.content,
    this.model = 'default',
    this.usage,
  });

  final String id;
  /// Opaque label — never a vendor model id.
  final String model;
  final String content;
  final Usage? usage;
}

/// One piece of a streamed completion.
class ChatStreamChunk {
  const ChatStreamChunk({this.delta, this.done = false});

  final String? delta;
  final bool done;
}
