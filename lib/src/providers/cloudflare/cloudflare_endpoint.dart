/// Hardened Cloudflare Workers AI endpoint URL construction.
///
/// [accountId] and [model] are treated as untrusted until validated: path
/// traversal, query/fragment injection, and absolute-URL smuggling are rejected.
library;

/// Validates an absolute provider [baseUri].
///
/// By default only `https` is allowed. Set [allowInsecure] for local/test
/// cleartext endpoints (`http://127.0.0.1:...`).
void validateCloudflareBaseUri(
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

/// Cloudflare account ids are opaque path segments — no separators or dots.
void validateCloudflareAccountId(String accountId) {
  if (!_accountIdPattern.hasMatch(accountId)) {
    throw ArgumentError.value(
      accountId,
      'accountId',
      'must match $_accountIdPattern',
    );
  }
}

/// Workers AI model ids may contain `/` (e.g. `@cf/meta/llama-…`) but must not
/// alter the URL shape beyond extra path segments.
void validateCloudflareModelId(String model) {
  if (model.contains('://') ||
      model.contains('..') ||
      model.contains('//') ||
      model.contains('?') ||
      model.contains('#') ||
      model.startsWith('/') ||
      model.endsWith('/')) {
    throw ArgumentError.value(
      model,
      'model',
      'contains forbidden path/query/fragment characters',
    );
  }
  if (!_modelIdPattern.hasMatch(model)) {
    throw ArgumentError.value(
      model,
      'model',
      'must match $_modelIdPattern',
    );
  }
}

/// Builds `…/accounts/{accountId}/ai/run/{model}` under [baseUri].
Uri buildCloudflareRunUri({
  required String baseUri,
  required String accountId,
  required String model,
}) {
  validateCloudflareAccountId(accountId);
  validateCloudflareModelId(model);

  final base = Uri.parse(baseUri);
  var basePath = base.path;
  if (basePath.endsWith('/')) {
    basePath = basePath.substring(0, basePath.length - 1);
  }

  return Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: '$basePath/accounts/$accountId/ai/run/$model',
  );
}

final RegExp _accountIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

/// Allows Cloudflare-style ids: `@cf/org/model.name-v1`.
final RegExp _modelIdPattern = RegExp(
  r'^@?[A-Za-z0-9][A-Za-z0-9._/-]*$',
);
