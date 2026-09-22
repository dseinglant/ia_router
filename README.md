# ia_router

Flutter package: **provider-blind LLM + TTS** behind stable ports.
Hosts pass independent API keys; vendor wiring stays inside the package.

## Consumers

Depend on a pinned tag (not a path dependency):

```yaml
ia_router:
  git:
    url: https://github.com/dseinglant/ia_router.git
    ref: v0.6.0
```

## Usage

```dart
import 'package:ia_router/ia_router.dart';

Future<void> main() async {
  await IaRouter.configure(
    llmToken: 'YOUR_LLM_TOKEN',
    ttsToken: 'YOUR_TTS_TOKEN',
  );

  final chat = await IaRouter.llm.complete(
    const ChatRequest(
      messages: [
        ChatMessage(role: ChatRole.system, content: 'Be brief.'),
        ChatMessage(role: ChatRole.user, content: 'Summarize: ...'),
      ],
    ),
  );
  print(chat.content);

  final voices = await IaRouter.tts.listVoices();
  final spanish = voices.firstWhere((v) => v.language == 'es');

  final speech = await IaRouter.tts.synthesize(
    TtsRequest(text: chat.content, voice: spanish.id, language: spanish.language),
  );
  // speech.audioBytes → play / save

  // After cold start with persisted keys:
  // await IaRouter.ensureReady();

  // await IaRouter.clear();
}
```

Feature code never imports a vendor, account id, or model id.

## Layout

- `contract/` — ports + DTOs + errors
- `ia_router_facade.dart` — `IaRouter.configure` / `llm` / `tts`
- `providers/` — internal adapters (not part of the public barrel)
