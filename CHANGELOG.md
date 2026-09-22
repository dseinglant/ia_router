## 0.6.0

- Breaking: TTS backend switched from Deepgram Aura-2 to Google Cloud
  Text-to-Speech Neural2 (`en-US-Neural2-A` / `es-US-Neural2-A`).
  Note: Google has no `es-MX-Neural2-*`; LatAm Spanish uses `es-US`.
- Breaking: `IaRouter.configure` now takes independent `llmToken` and
  `ttsToken` (separate credential slots). Hosts seed via `--dart-define=LLM_TOKEN`
  / `--dart-define=TTS_TOKEN`.
- `listVoices()` returns the two Neural2 voices (`language`: `en` / `es`).
- Legacy Aura speaker ids `luna` / `aquila` still map to Neural2 defaults.

## 0.5.0

- (internal) Deepgram Aura-2 TTS on Cloudflare Workers AI.

## 0.4.0

- Breaking: TTS backend switched from MeloTTS to Deepgram Aura-2
  (`aura-2-en` / `aura-2-es`). Voice ids are Aura speakers (`luna`, `aquila`, …).
- `listVoices()` returns the Aura-2 EN + ES speaker catalog.
- Spanish requests route to `aura-2-es`; everything else to `aura-2-en`.

## 0.3.1

- TTS: `TtsClient.listVoices()` + `TtsVoice` for host UI pickers.
- Cloudflare MeloTTS adapter returns a fixed speaker/language catalog.

## 0.3.0

- Breaking: provider-blind public API via `IaRouter.configure(apiKey)`.
- Hosts no longer pass account id, vendor model ids, `CredentialStore`, or
  `ProviderIds`. `ChatRequest` / `TtsRequest` no longer require `model`.
- Removed public `cloudflare.dart` barrel; adapters stay package-private.
- `ensureReady()` rehydrates from secure storage after cold start; `clear()`
  deletes the stored key.
- Default `IA_ROUTER_ACCOUNT_ID` points at the InfoFeed Workers AI account
  (override via dart-define when needed).

## 0.2.0

- Package version bump (prior Cloudflare composition-root API).

## 0.1.1

- Harden Cloudflare endpoint URLs: reject path/query/fragment injection in
  `accountId` / `model`; require `https` `baseUri` unless `allowInsecureBaseUri`.
- HTTP client default 60s timeout; map provider errors without attaching raw bodies.
- `SecureCredentialStore` defaults: Android EncryptedSharedPreferences + iOS
  `first_unlock_this_device` keychain accessibility.
- Security regression tests under `test/security_regression_test.dart`.

## 0.1.0

- Initial ports: `LlmClient` (`complete` / `completeStream`) and `TtsClient`.
- `CredentialStore` + secure / memory implementations.
- Cloudflare Workers AI adapters and `AiClients.cloudflare` factory.
