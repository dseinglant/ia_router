# ia_router

Flutter package: **provider-blind LLM + TTS** behind stable ports.
Release builds never hold a vendor API key. Each app deploys `relay/`
to its own Firebase project and calls `configureRelay` with that app's
ID token. Debug builds may still pass vendor keys to `configure`.

## Consumers

Depend on a pinned tag (not a path dependency):

```yaml
ia_router:
  git:
    url: https://github.com/dseinglant/ia_router.git
    ref: v0.8.0
```

## Usage

```dart
import 'package:ia_router/ia_router.dart';

Future<void> main() async {
  IaRouter.requestTimeout = const Duration(seconds: 90);

  // Release. [readAccessToken] is a Firebase ID token, refreshed per request.
  // Base URIs are THIS app's deployed aiRelay, not a shared host.
  await IaRouter.configureRelay(
    readAccessToken: () => FirebaseAuth.instance.currentUser?.getIdToken(),
    llmBaseUri: 'https://<region>-<project>.cloudfunctions.net/aiRelay/client/v4',
    ttsBaseUri: 'https://<region>-<project>.cloudfunctions.net/aiRelay/v1beta',
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
}
```

Set `IA_ROUTER_ACCOUNT_ID` to this app's Cloudflare account. The package
default is one account; another app that leaves it unchanged will ask for
the wrong account and its relay will reject the path.

Deploy `relay/` (`ia-router-relay`) in this app's Firebase project. Put
`LLM_TOKEN` and `TTS_TOKEN` in that project's Secret Manager. Do not pass
those values with `--dart-define` on a release build.

### Debug

```dart
await IaRouter.configure(
  llmToken: 'YOUR_LLM_TOKEN',
  ttsToken: 'YOUR_TTS_TOKEN',
);
// After a cold start with persisted keys:
// await IaRouter.ensureReady();
```

`configure` and `ensureReady` throw in release.

Feature code never imports a vendor, account id, or model id.

## Layout

- `contract/` — ports + DTOs + errors
- `ia_router_facade.dart` — `configure` / `configureRelay` / `llm` / `tts`
- `relay/` — Node package each host deploys to its own Firebase project
- `providers/` — internal adapters (not part of the public barrel)
