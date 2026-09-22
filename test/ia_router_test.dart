import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ia_router/ia_router.dart';
import 'package:ia_router/src/credentials/memory_credential_store.dart';
import 'package:ia_router/src/http/ai_http_client.dart';
import 'package:ia_router/src/internal/router_defaults.dart';
import 'package:ia_router/src/providers/cloudflare/cloudflare_clients.dart';
import 'package:ia_router/src/providers/cloudflare/cloudflare_llm_adapter.dart';
import 'package:ia_router/src/providers/google/google_tts_adapter.dart';

void main() {
  tearDown(IaRouter.debugReset);

  group('MemoryCredentialStore', () {
    test('round-trips secrets by slot', () async {
      final store = MemoryCredentialStore();
      expect(await store.read(RouterDefaults.llmCredentialSlot), isNull);

      await store.write(RouterDefaults.llmCredentialSlot, 'tok');
      expect(await store.read(RouterDefaults.llmCredentialSlot), 'tok');

      await store.delete(RouterDefaults.llmCredentialSlot);
      expect(await store.read(RouterDefaults.llmCredentialSlot), isNull);
    });
  });

  group('IaRouter', () {
    test('configure wires llm/tts without exposing vendor', () async {
      final mock = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer secret-key');
        expect(
          request.url.path,
          contains('/ai/run/${RouterDefaults.llmModel}'),
        );
        return http.Response(
          jsonEncode({
            'success': true,
            'result': {'response': 'hola'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      IaRouter.debugBind(
        credentials: MemoryCredentialStore(),
        httpClient: AiHttpClient(client: mock),
        accountId: 'acc',
      );
      await IaRouter.configure(llmToken: 'secret-key', ttsToken: 'tts-key');

      final result = await IaRouter.llm.complete(
        const ChatRequest(
          messages: [ChatMessage(role: ChatRole.user, content: 'hi')],
        ),
      );

      expect(result.content, 'hola');
      expect(result.model, RouterDefaults.publicModelId);
    });

    test('llm throws AiAuthException before configure', () {
      expect(() => IaRouter.llm, throwsA(isA<AiAuthException>()));
    });

    test('ensureReady rehydrates from persisted keys', () async {
      final store = MemoryCredentialStore();
      await store.write(RouterDefaults.llmCredentialSlot, 'persisted');
      await store.write(RouterDefaults.ttsCredentialSlot, 'tts-persisted');

      final mock = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer persisted');
        return http.Response(
          jsonEncode({
            'success': true,
            'result': {'response': 'ok'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      IaRouter.debugBind(
        credentials: store,
        httpClient: AiHttpClient(client: mock),
        accountId: 'acc',
      );
      await IaRouter.ensureReady();

      final result = await IaRouter.llm.complete(
        const ChatRequest(
          messages: [ChatMessage(role: ChatRole.user, content: 'hi')],
        ),
      );
      expect(result.content, 'ok');
    });

    test('clear drops clients and both credentials', () async {
      final store = MemoryCredentialStore();
      IaRouter.debugBind(credentials: store, accountId: 'acc');
      await IaRouter.configure(llmToken: 'tok', ttsToken: 'tts');
      await IaRouter.clear();

      expect(await store.read(RouterDefaults.llmCredentialSlot), isNull);
      expect(await store.read(RouterDefaults.ttsCredentialSlot), isNull);
      expect(() => IaRouter.llm, throwsA(isA<AiAuthException>()));
    });
  });

  group('CloudflareLlmAdapter', () {
    test('complete maps Workers AI JSON to ChatResponse', () async {
      final store = MemoryCredentialStore();
      await store.write(RouterDefaults.llmCredentialSlot, 'secret');

      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(
          request.url.path,
          contains('/ai/run/@cf/meta/llama-3.1-8b-instruct'),
        );
        expect(request.headers['Authorization'], 'Bearer secret');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['messages'], isA<List>());
        expect(body['temperature'], 0.2);

        return http.Response(
          jsonEncode({
            'success': true,
            'result': {'response': 'hola mundo'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final llm = CloudflareLlmAdapter(
        accountId: 'acc',
        credentials: store,
        httpClient: AiHttpClient(client: mock),
      );

      final result = await llm.complete(
        const ChatRequest(
          messages: [ChatMessage(role: ChatRole.user, content: 'hi')],
          temperature: 0.2,
        ),
      );

      expect(result.content, 'hola mundo');
      expect(result.model, 'default');
    });

    test('complete parses OpenAI-style result.choices', () async {
      final store = MemoryCredentialStore();
      await store.write(RouterDefaults.llmCredentialSlot, 'secret');

      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'success': true,
            'result': {
              'choices': [
                {
                  'message': {
                    'role': 'assistant',
                    'content': 'choices summary',
                  },
                },
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final llm = CloudflareLlmAdapter(
        accountId: 'acc',
        credentials: store,
        httpClient: AiHttpClient(client: mock),
        runModel: '@cf/google/gemma-3-12b-it',
      );

      final result = await llm.complete(
        const ChatRequest(
          messages: [ChatMessage(role: ChatRole.user, content: 'hi')],
        ),
      );

      expect(result.content, 'choices summary');
    });

    test('complete parses content parts list in choices', () async {
      final store = MemoryCredentialStore();
      await store.write(RouterDefaults.llmCredentialSlot, 'secret');

      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'success': true,
            'result': {
              'id': 'cf-1',
              'object': 'chat.completion',
              'created': 1,
              'model': '@cf/google/gemma-4-26b-a4b-it',
              'choices': [
                {
                  'message': {
                    'role': 'assistant',
                    'content': [
                      {'type': 'text', 'text': 'part-a '},
                      {'type': 'text', 'text': 'part-b'},
                    ],
                  },
                },
              ],
              'usage': {
                'prompt_tokens': 1,
                'completion_tokens': 2,
                'total_tokens': 3,
              },
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final llm = CloudflareLlmAdapter(
        accountId: 'acc',
        credentials: store,
        httpClient: AiHttpClient(client: mock),
        runModel: '@cf/google/gemma-4-26b-a4b-it',
      );

      final result = await llm.complete(
        const ChatRequest(
          messages: [ChatMessage(role: ChatRole.user, content: 'hi')],
        ),
      );

      expect(result.content, 'part-a part-b');
      expect(result.usage?.totalTokens, 3);
    });

    test('complete dump includes choices/usage when shape is empty', () async {
      final store = MemoryCredentialStore();
      await store.write(RouterDefaults.llmCredentialSlot, 'secret');

      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'success': true,
            'errors': [],
            'result': {
              'id': 'cf-empty',
              'object': 'chat.completion',
              'created': 1,
              'model': '@cf/test',
              'choices': <dynamic>[],
              'usage': {
                'prompt_tokens': 12,
                'completion_tokens': 0,
                'total_tokens': 12,
              },
              'metrics': {'latency_ms': 42},
              'prompt_text': 'hello prompt',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final llm = CloudflareLlmAdapter(
        accountId: 'acc',
        credentials: store,
        httpClient: AiHttpClient(client: mock),
        runModel: '@cf/test',
      );

      await expectLater(
        () => llm.complete(
          const ChatRequest(
            messages: [ChatMessage(role: ChatRole.user, content: 'hi')],
          ),
        ),
        throwsA(
          isA<AiProviderException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('dump='),
              contains('"choicesLen":0'),
              contains('"completion_tokens":0'),
              contains('"metrics"'),
              contains('"prompt_text_preview":"hello prompt"'),
            ),
          ),
        ),
      );
    });

    test('complete sends max_tokens and max_completion_tokens', () async {
      final store = MemoryCredentialStore();
      await store.write(RouterDefaults.llmCredentialSlot, 'secret');

      Map<String, dynamic>? sent;
      final mock = MockClient((request) async {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'success': true,
            'result': {'response': 'ok'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final llm = CloudflareLlmAdapter(
        accountId: 'acc',
        credentials: store,
        httpClient: AiHttpClient(client: mock),
        runModel: '@cf/google/gemma-4-26b-a4b-it',
      );

      await llm.complete(
        const ChatRequest(
          messages: [ChatMessage(role: ChatRole.user, content: 'hi')],
          maxTokens: 4096,
        ),
      );

      expect(sent?['max_tokens'], 4096);
      expect(sent?['max_completion_tokens'], 4096);
      expect(sent?['chat_template_kwargs'], {'enable_thinking': false});
      expect(sent?.containsKey('reasoning_effort'), isTrue);
      expect(sent?['reasoning_effort'], isNull);
    });

    test('complete falls back to reasoning_content when content empty',
        () async {
      final store = MemoryCredentialStore();
      await store.write(RouterDefaults.llmCredentialSlot, 'secret');

      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'success': true,
            'result': {
              'choices': [
                {
                  'finish_reason': 'length',
                  'message': {
                    'role': 'assistant',
                    'content': '',
                    'reasoning_content': 'usable summary from CoT',
                  },
                },
              ],
              'usage': {'completion_tokens': 4096},
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final llm = CloudflareLlmAdapter(
        accountId: 'acc',
        credentials: store,
        httpClient: AiHttpClient(client: mock),
        runModel: '@cf/google/gemma-4-26b-a4b-it',
      );

      final result = await llm.complete(
        const ChatRequest(
          messages: [ChatMessage(role: ChatRole.user, content: 'hi')],
        ),
      );

      expect(result.content, 'usable summary from CoT');
    });

    test('complete throws AiAuthException when token missing', () async {
      final llm = CloudflareLlmAdapter(
        accountId: 'acc',
        credentials: MemoryCredentialStore(),
        httpClient: AiHttpClient(client: MockClient((_) async {
          fail('must not call network without token');
        })),
      );

      expect(
        () => llm.complete(
          const ChatRequest(
            messages: [ChatMessage(role: ChatRole.user, content: 'x')],
          ),
        ),
        throwsA(isA<AiAuthException>()),
      );
    });

    test('completeStream yields deltas from SSE lines', () async {
      final store = MemoryCredentialStore();
      await store.write(RouterDefaults.llmCredentialSlot, 'secret');

      final streamClient = _StreamMockClient([
        'data: {"response":"hel"}\n',
        'data: {"response":"lo"}\n',
        'data: [DONE]\n',
      ]);

      final llm = CloudflareLlmAdapter(
        accountId: 'acc',
        credentials: store,
        httpClient: AiHttpClient(client: streamClient),
      );

      final chunks = await llm
          .completeStream(
            const ChatRequest(
              messages: [ChatMessage(role: ChatRole.user, content: 'hi')],
            ),
          )
          .toList();

      expect(
        chunks.where((c) => c.delta != null).map((c) => c.delta).toList(),
        ['hel', 'lo'],
      );
      expect(chunks.last.done, isTrue);
    });

    test('completeStream prefers choices.delta when response omits digits',
        () async {
      final store = MemoryCredentialStore();
      await store.write(RouterDefaults.llmCredentialSlot, 'secret');

      // Mirrors Workers AI llama-3.1: response drops "0" tokens; choices keep them.
      final streamClient = _StreamMockClient([
        'data: {"choices":[{"delta":{"content":"{\\"n\\":"}}],"response":"{\\"n\\":"}\n',
        'data: {"choices":[{"delta":{"content":"0"}}],"response":null}\n',
        'data: {"choices":[{"delta":{"content":"}"}}],"response":"}"}\n',
        'data: [DONE]\n',
      ]);

      final llm = CloudflareLlmAdapter(
        accountId: 'acc',
        credentials: store,
        httpClient: AiHttpClient(client: streamClient),
      );

      final text = (await llm
              .completeStream(
                const ChatRequest(
                  messages: [ChatMessage(role: ChatRole.user, content: 'hi')],
                ),
              )
              .where((c) => c.delta != null)
              .map((c) => c.delta!)
              .toList())
          .join();

      expect(text, '{"n":0}');
    });
  });

  group('GoogleTtsAdapter', () {
    test('listVoices returns Neural2 EN+ES catalog for UI', () async {
      final tts = GoogleTtsAdapter(credentials: MemoryCredentialStore());

      final voices = await tts.listVoices();
      expect(voices, hasLength(2));
      expect(
        voices.map((v) => v.id),
        containsAll([
          RouterDefaults.ttsVoiceEn,
          RouterDefaults.ttsVoiceEs,
        ]),
      );
      expect(
        voices.where((v) => v.language == 'es').map((v) => v.id),
        contains(RouterDefaults.ttsVoiceEs),
      );
      expect(
        voices.where((v) => v.language == 'en').map((v) => v.id),
        contains(RouterDefaults.ttsVoiceEn),
      );
    });

    test('synthesize posts Google Neural2 payload with API key', () async {
      final store = MemoryCredentialStore();
      await store.write(RouterDefaults.ttsCredentialSlot, 'g-tts-key');

      final audio = Uint8List.fromList([9, 8, 7]);
      final mock = MockClient((request) async {
        expect(request.url.path, endsWith('/text:synthesize'));
        expect(request.url.queryParameters['key'], 'g-tts-key');
        expect(request.headers['x-goog-api-key'], 'g-tts-key');
        expect(request.headers.containsKey('Authorization'), isFalse);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['input'], {'text': 'hola'});
        expect(body['voice'], {
          'languageCode': 'es-US',
          'name': RouterDefaults.ttsVoiceEs,
        });
        expect(body['audioConfig'], {'audioEncoding': 'MP3'});
        return http.Response(
          jsonEncode({'audioContent': base64Encode(audio)}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final tts = GoogleTtsAdapter(
        credentials: store,
        httpClient: AiHttpClient(client: mock),
      );

      final result = await tts.synthesize(
        const TtsRequest(text: 'hola', voice: 'aquila'),
      );
      expect(result.audioBytes, audio);
      expect(result.contentType, 'audio/mpeg');
    });

    test('synthesize defaults Spanish language to es-US-Neural2-A', () async {
      final store = MemoryCredentialStore();
      await store.write(RouterDefaults.ttsCredentialSlot, 'g-tts-key');

      final audio = Uint8List.fromList([1, 2, 3, 4]);
      final mock = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['voice'], {
          'languageCode': 'es-US',
          'name': 'es-US-Neural2-A',
        });
        return http.Response(
          jsonEncode({'audioContent': base64Encode(audio)}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final tts = GoogleTtsAdapter(
        credentials: store,
        httpClient: AiHttpClient(client: mock),
      );

      final result = await tts.synthesize(
        const TtsRequest(text: 'hola', language: 'es'),
      );

      expect(result.audioBytes, audio);
      expect(result.contentType, 'audio/mpeg');
    });

    test('synthesize defaults English language to en-US-Neural2-A', () async {
      final store = MemoryCredentialStore();
      await store.write(RouterDefaults.ttsCredentialSlot, 'g-tts-key');

      final audio = Uint8List.fromList([5, 6, 7]);
      final mock = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['voice'], {
          'languageCode': 'en-US',
          'name': 'en-US-Neural2-A',
        });
        return http.Response(
          jsonEncode({'audioContent': base64Encode(audio)}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final tts = GoogleTtsAdapter(
        credentials: store,
        httpClient: AiHttpClient(client: mock),
      );

      final result = await tts.synthesize(
        const TtsRequest(text: 'hello', language: 'en'),
      );

      expect(result.audioBytes, audio);
      expect(result.contentType, 'audio/mpeg');
    });

    test('legacy es-MX-Neural2-A aliases to es-US-Neural2-A', () async {
      final store = MemoryCredentialStore();
      await store.write(RouterDefaults.ttsCredentialSlot, 'g-tts-key');

      final audio = Uint8List.fromList([8, 9]);
      final mock = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect((body['voice'] as Map)['name'], 'es-US-Neural2-A');
        expect((body['voice'] as Map)['languageCode'], 'es-US');
        return http.Response(
          jsonEncode({'audioContent': base64Encode(audio)}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final tts = GoogleTtsAdapter(
        credentials: store,
        httpClient: AiHttpClient(client: mock),
      );

      final result = await tts.synthesize(
        const TtsRequest(text: 'hola', voice: 'es-MX-Neural2-A'),
      );
      expect(result.audioBytes, audio);
    });

    test('decodeGoogleTtsJsonResponse rejects missing audioContent', () {
      expect(
        () => decodeGoogleTtsJsonResponse(
          Uint8List.fromList(
            utf8.encode(jsonEncode({'error': {'message': 'boom'}})),
          ),
        ),
        throwsA(isA<AiProviderException>()),
      );
    });
  });

  group('AiClients', () {
    test('create factory returns independent ports', () {
      final pair = AiClients.create(
        accountId: 'acc',
        credentials: MemoryCredentialStore(),
        httpClient: AiHttpClient(client: MockClient((_) async {
          return http.Response('{}', 500);
        })),
      );
      expect(pair.llm, isA<CloudflareLlmAdapter>());
      expect(pair.tts, isA<GoogleTtsAdapter>());
    });
  });
}

/// Minimal [http.Client] that supports [send] for SSE tests.
final class _StreamMockClient extends http.BaseClient {
  _StreamMockClient(this.chunks);

  final List<String> chunks;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final controller = StreamController<List<int>>();
    scheduleMicrotask(() async {
      for (final c in chunks) {
        controller.add(utf8.encode(c));
      }
      await controller.close();
    });
    return http.StreamedResponse(controller.stream, 200);
  }
}
