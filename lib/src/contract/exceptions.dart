/// Base type for provider / transport failures exposed to hosts.
sealed class AiException implements Exception {
  const AiException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => '$runtimeType: $message';
}

final class AiAuthException extends AiException {
  const AiAuthException(super.message, {super.cause});
}

final class AiRateLimitException extends AiException {
  const AiRateLimitException(super.message, {super.cause, this.retryAfter});

  final Duration? retryAfter;
}

final class AiProviderException extends AiException {
  const AiProviderException(
    super.message, {
    super.cause,
    this.statusCode,
  });

  final int? statusCode;
}

final class AiNetworkException extends AiException {
  const AiNetworkException(super.message, {super.cause});
}
