import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../contract/exceptions.dart';

/// Thin HTTP helper shared by provider adapters.
final class AiHttpClient {
  AiHttpClient({
    http.Client? client,
    this.timeout = const Duration(seconds: 60),
  }) : _client = client ?? http.Client();

  final http.Client _client;

  /// Per-request deadline. Prevents hung sockets from retaining resources.
  final Duration timeout;

  void close() => _client.close();

  Future<http.Response> postJson({
    required Uri uri,
    required Map<String, dynamic> body,
    String? bearerToken,
    Map<String, String>? headers,
  }) async {
    try {
      return await _client
          .post(
            uri,
            headers: {
              if (bearerToken != null && bearerToken.isNotEmpty)
                'Authorization': 'Bearer $bearerToken',
              'Content-Type': 'application/json',
              ...?headers,
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on TimeoutException catch (e) {
      throw AiNetworkException('HTTP request timed out', cause: e);
    } on http.ClientException catch (e) {
      throw AiNetworkException('HTTP request failed', cause: e);
    }
  }

  /// POST JSON and return the raw byte stream (for SSE / binary).
  Future<http.StreamedResponse> postJsonStream({
    required Uri uri,
    required Map<String, dynamic> body,
    String? bearerToken,
    Map<String, String>? headers,
  }) async {
    try {
      final request = http.Request('POST', uri)
        ..headers.addAll({
          if (bearerToken != null && bearerToken.isNotEmpty)
            'Authorization': 'Bearer $bearerToken',
          'Content-Type': 'application/json',
          ...?headers,
        })
        ..body = jsonEncode(body);
      return await _client.send(request).timeout(timeout);
    } on TimeoutException catch (e) {
      throw AiNetworkException('HTTP stream request timed out', cause: e);
    } on http.ClientException catch (e) {
      throw AiNetworkException('HTTP stream request failed', cause: e);
    }
  }
}

/// Maps HTTP status codes to typed [AiException]s without leaking raw bodies.
///
/// [bodyHint] is a short, already-sanitized snippet (e.g. Cloudflare error
/// message) — never pass tokens or full response bodies.
Never throwForStatus(http.Response response, {String? bodyHint}) {
  _throwForCode(response.statusCode, bodyHint: bodyHint);
}

Never throwForStreamStatus(http.StreamedResponse response, [String? _]) {
  _throwForCode(response.statusCode);
}

Never _throwForCode(int code, {String? bodyHint}) {
  final detail =
      (bodyHint != null && bodyHint.isNotEmpty) ? ': $bodyHint' : '';
  if (code == 401 || code == 403) {
    throw AiAuthException('Provider rejected credentials ($code)$detail');
  }
  if (code == 429) {
    throw const AiRateLimitException('Provider rate limited');
  }
  throw AiProviderException(
    'Provider error ($code)$detail',
    statusCode: code,
  );
}
