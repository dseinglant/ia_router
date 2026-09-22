# ia_router — Design

**Date:** 2026-09-08  
**Updated:** 2026-09-09  
**Status:** Approved; provider-blind facade

## Goal

Flutter package that securely talks to LLM/TTS inference providers behind stable ports.
Host apps never learn which vendor is serving them. No domain logic.

## Decisions

| Topic | Choice |
|---|---|
| Public entry | `IaRouter.configure(apiKey)` + `llm` / `tts` |
| Credentials | Persist apiKey in secure storage (opaque slot); no OAuth |
| Host inputs | API key only — no account id, no model ids, no `CredentialStore` |
| Models | Package defaults (`RouterDefaults`); DTOs have no `model` field |
| Providers MVP | Cloudflare Workers AI (internal only) |
| LLM API | OpenAI-like `messages`; unused params ignored by adapters |
| LLM I/O | `complete` + `completeStream` |

## Architecture

```
Host → IaRouter.configure / llm / tts / DTOs / AiException
     → (internal) CredentialStore + Cloudflare adapters + AiHttpClient
```

## Out of scope

Backend proxy, STT, embeddings, domain helpers, public vendor barrels.
