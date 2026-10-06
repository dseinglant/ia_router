import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ia_router/ia_router.dart';
import 'package:ia_router/src/credentials/memory_credential_store.dart';
import 'package:ia_router/src/credentials/secure_credential_store.dart';
import 'package:ia_router/src/http/ai_http_client.dart';
import 'package:ia_router/src/internal/router_defaults.dart';
import 'package:ia_router/src/providers/cloudflare/cloudflare_clients.dart';
import 'package:ia_router/src/providers/cloudflare/cloudflare_endpoint.dart';
import 'package:ia_router/src/providers/cloudflare/cloudflare_llm_adapter.dart';
import 'package:ia_router/src/providers/google/google_tts_adapter.dart';
import 'package:ia_router/src/providers/google/google_tts_endpoint.dart';

void main() {
  group('cloudflare endpoint URI hardening', () {
    test('accepts legitimate Workers AI model ids', () {
      final uri = buildCloudflareRunUri(
        baseUri: 'https://api.cloudflare.com/client/v4',
        accountId: 'acc123',
        model: '@cf/meta/llama-3.1-8b-instruct',
      );
      expect(uri.scheme, 'https');
      expect(uri.host, 'api.cloudflare.com');
      expect(
        uri.path,
        '/client/v4/accounts/acc123/ai/run/@cf/meta/llama-3.1-8b-instruct',
      );
      expect(uri.hasQuery, isFalse);
      expect(uri.fragment, isEmpty);
    });

    test('rejects path traversal in accountId', () {
      expect(
        () => buildCloudflareRunUri(
          baseUri: 'https://api.cloudflare.com/client/v4',
          accountId: '../evil',
          model: 'm',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects path traversal in model', () {
      expect(
        () => buildCloudflareRunUri(
          baseUri: 'https://api.cloudflare.com/client/v4',
          accountId: 'acc',
          model: '../../../admin',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects query injection in model', () {
      expect(
        () => buildCloudflareRunUri(
          baseUri: 'https://api.cloudflare.com/client/v4',
          accountId: 'acc',
          model: 'm?x=1',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects fragment injection in accountId', () {
      expect(
        () => buildCloudflareRunUri(
          baseUri: 'https://api.cloudflare.com/client/v4',
          accountId: 'acc#frag',
          model: 'm',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects absolute URL smuggling in model', () {
      expect(
        () => buildCloudflareRunUri(
          baseUri: 'https://api.cloudflare.com/client/v4',
          accountId: 'acc',
          model: 'https://evil.example/x',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects cleartext baseUri by default', () {
      expect(
        () => validateCloudflareBaseUri('http://api.cloudflare.com/client/v4'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('allows cleartext baseUri only when opted in', () {
      expect(
        () => validateCloudflareBaseUri(
          'http://127.0.0.1:8787',
          allowInsecure: true,
        ),
        returnsNormally,
      );
    });
  });

  group('adapter construction guards', () {
    test('CloudflareLlmAdapter rejects insecure baseUri', () {
      expect(
        () => CloudflareLlmAdapter(
          accountId: 'acc',
          credentials: MemoryCredentialStore(),
          baseUri: 'http://evil.example',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('GoogleTtsAdapter rejects insecure baseUri', () {
      expect(
        () => GoogleTtsAdapter(
          credentials: MemoryCredentialStore(),
          baseUri: 'http://evil.example',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('AiClients.create rejects insecure baseUri', () {
      expect(
        () => AiClients.create(
          accountId: 'acc',
          credentials: MemoryCredentialStore(),
          baseUri: 'http://evil.example',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('malicious runModel never hits the network', () async {
      var networkHits = 0;
      final store = MemoryCredentialStore();
      await store.write(RouterDefaults.llmCredentialSlot, 'tok');

      final llm = CloudflareLlmAdapter(
        accountId: 'acc',
        credentials: store,
        runModel: '../admin',
        httpClient: AiHttpClient(
          client: MockClient((_) async {
            networkHits++;
            return http.Response('{}', 200);
          }),
        ),
      );

      await expectLater(
        llm.complete(
          const ChatRequest(
            messages: [ChatMessage(role: ChatRole.user, content: 'x')],
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(networkHits, 0);
    });

    test('buildGeminiTtsGenerateUri embeds model path only', () {
      final uri = buildGeminiTtsGenerateUri(
        baseUri: 'https://generativelanguage.googleapis.com/v1beta',
        model: 'gemini-3.8-flash-lite-tts',
      );
      expect(
        uri.path,
        '/v1beta/models/gemini-3.8-flash-lite-tts:generateContent',
      );
      expect(uri.hasQuery, isFalse);
      expect(uri.fragment, isEmpty);
    });

    test('buildGeminiTtsBatchUri embeds model path only', () {
      final uri = buildGeminiTtsBatchUri(
        baseUri: 'https://generativelanguage.googleapis.com/v1beta',
        model: 'gemini-3.8-flash-lite-tts',
      );
      expect(
        uri.path,
        '/v1beta/models/gemini-3.8-flash-lite-tts:batchGenerateContent',
      );
      expect(uri.hasQuery, isFalse);
      expect(uri.fragment, isEmpty);
    });

    test('buildGeminiBatchStatusUri rejects path traversal', () {
      expect(
        () => buildGeminiBatchStatusUri(
          baseUri: 'https://generativelanguage.googleapis.com/v1beta',
          batchName: '../evil',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('error body redaction', () {
    test('throwForStatus does not attach raw provider body as cause', () {
      expect(
        () => throwForStatus(
          http.Response('SECRET_LEAK_TOKEN_xyz raw dump', 401),
        ),
        throwsA(
          isA<AiAuthException>()
              .having((e) => e.message, 'message', contains('401'))
              .having(
                (e) => e.message,
                'message',
                isNot(contains('SECRET_LEAK')),
              )
              .having(
                (e) => '${e.cause ?? ''}',
                'cause',
                isNot(contains('SECRET_LEAK')),
              ),
        ),
      );
    });

    test('throwForStatus includes sanitized bodyHint on 401', () {
      expect(
        () => throwForStatus(
          http.Response('{}', 401),
          bodyHint: 'API key not valid. Please pass a valid API key.',
        ),
        throwsA(
          isA<AiAuthException>().having(
            (e) => e.message,
            'message',
            contains('API key not valid'),
          ),
        ),
      );
    });

    test('throwForStatus on 500 does not attach raw body as cause', () {
      expect(
        () => throwForStatus(
          http.Response('internal stack with SECRET_LEAK_TOKEN_xyz', 500),
        ),
        throwsA(
          isA<AiProviderException>().having(
            (e) => '${e.cause ?? ''}',
            'cause',
            isNot(contains('SECRET_LEAK')),
          ),
        ),
      );
    });
  });

  group('HTTP timeouts', () {
    test('postJson times out hanging connections', () async {
      final client = AiHttpClient(
        client: _HangClient(),
        timeout: const Duration(milliseconds: 40),
      );

      await expectLater(
        client.postJson(
          uri: Uri.parse('https://example.com/x'),
          bearerToken: 't',
          body: const {},
        ),
        throwsA(isA<AiNetworkException>()),
      );
    });

    test('postJsonStream times out hanging connections', () async {
      final client = AiHttpClient(
        client: _HangClient(),
        timeout: const Duration(milliseconds: 40),
      );

      await expectLater(
        client.postJsonStream(
          uri: Uri.parse('https://example.com/x'),
          bearerToken: 't',
          body: const {},
        ),
        throwsA(isA<AiNetworkException>()),
      );
    });
  });

  group('SecureCredentialStore defaults', () {
    test('exposes hardened Android encryptedSharedPreferences flag', () {
      expect(SecureCredentialStore.encryptedSharedPreferences, isTrue);
    });

    test('exposes non-migrating iOS keychain accessibility contract', () {
      expect(
        SecureCredentialStore.iosKeychainAccessibility,
        'first_unlock_this_device',
      );
    });
  });
}

/// [http.Client] whose [send] never completes — forces timeout paths.
final class _HangClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return Completer<http.StreamedResponse>().future;
  }
}
