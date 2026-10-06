/// Hardened Gemini API base URI validation (Google AI / Generative Language).
void validateGoogleTtsBaseUri(
  String baseUri, {
  bool allowInsecure = false,
}) {
  final uri = Uri.tryParse(baseUri);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw ArgumentError.value(
      baseUri,
      'baseUri',
      'must be an absolute URI with a host',
    );
  }
  if (allowInsecure) {
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw ArgumentError.value(
        baseUri,
        'baseUri',
        'unsupported URI scheme',
      );
    }
    return;
  }
  if (uri.scheme != 'https') {
    throw ArgumentError.value(
      baseUri,
      'baseUri',
      'must use https (pass allowInsecureBaseUri: true only for trusted tests)',
    );
  }
}

String _normalizedBasePath(String baseUri) {
  final base = Uri.parse(baseUri);
  var basePath = base.path;
  if (basePath.endsWith('/')) {
    basePath = basePath.substring(0, basePath.length - 1);
  }
  return basePath;
}

/// Builds `…/models/{model}:generateContent` under [baseUri].
Uri buildGeminiTtsGenerateUri({
  required String baseUri,
  required String model,
}) {
  if (model.contains('://') ||
      model.contains('..') ||
      model.contains('//') ||
      model.contains('?') ||
      model.contains('#') ||
      model.startsWith('/') ||
      model.endsWith('/') ||
      model.isEmpty) {
    throw ArgumentError.value(model, 'model', 'invalid TTS model id');
  }

  final base = Uri.parse(baseUri);
  final basePath = _normalizedBasePath(baseUri);
  return Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: '$basePath/models/$model:generateContent',
  );
}

/// Builds `…/models/{model}:batchGenerateContent` under [baseUri].
Uri buildGeminiTtsBatchUri({
  required String baseUri,
  required String model,
}) {
  if (model.contains('://') ||
      model.contains('..') ||
      model.contains('//') ||
      model.contains('?') ||
      model.contains('#') ||
      model.startsWith('/') ||
      model.endsWith('/') ||
      model.isEmpty) {
    throw ArgumentError.value(model, 'model', 'invalid TTS model id');
  }

  final base = Uri.parse(baseUri);
  final basePath = _normalizedBasePath(baseUri);
  return Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: '$basePath/models/$model:batchGenerateContent',
  );
}

/// Builds `…/{batchName}` for polling (`batches/{id}`).
Uri buildGeminiBatchStatusUri({
  required String baseUri,
  required String batchName,
}) {
  final trimmed = batchName.trim();
  if (trimmed.isEmpty ||
      trimmed.contains('://') ||
      trimmed.contains('..') ||
      trimmed.contains('?') ||
      trimmed.contains('#') ||
      trimmed.startsWith('/')) {
    throw ArgumentError.value(batchName, 'batchName', 'invalid batch name');
  }

  final base = Uri.parse(baseUri);
  final basePath = _normalizedBasePath(baseUri);
  return Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: '$basePath/$trimmed',
  );
}
