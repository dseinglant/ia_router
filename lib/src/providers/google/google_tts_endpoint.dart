/// Hardened Google Cloud TTS base URI validation.
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

/// Builds `…/text:synthesize` under [baseUri], optionally with API [key].
Uri buildGoogleSynthesizeUri({
  required String baseUri,
  String? key,
}) {
  final base = Uri.parse(baseUri);
  var basePath = base.path;
  if (basePath.endsWith('/')) {
    basePath = basePath.substring(0, basePath.length - 1);
  }

  return Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: '$basePath/text:synthesize',
    queryParameters: {
      if (key != null && key.isNotEmpty) 'key': key,
    },
  );
}
