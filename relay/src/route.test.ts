import assert from "node:assert/strict";
import test from "node:test";
import { resolveUpstream } from "./route";

const account = "9c2eb959ccafdd0f563b1ea6adf1472b";
const model = "@cf/google/gemma-4-26b-a4b-it";

test("cloudflare run of the host account is forwarded", () => {
  const got = resolveUpstream(
    `/aiRelay/client/v4/accounts/${account}/ai/run/${model}`,
    "POST",
    account,
  );
  assert.deepEqual(got, {
    origin: "https://api.cloudflare.com",
    path: `/client/v4/accounts/${account}/ai/run/${model}`,
  });
});

test("a different Cloudflare account is rejected", () => {
  assert.equal(
    resolveUpstream(
      `/client/v4/accounts/${account}/ai/run/${model}`,
      "POST",
      "another-account",
    ),
    null,
  );
});

test("gemini generate and batch of the pinned model are forwarded", () => {
  assert.equal(
    resolveUpstream(
      "/aiRelay/v1beta/models/gemini-3.8-flash-lite-tts:generateContent",
      "POST",
      account,
    )?.origin,
    "https://generativelanguage.googleapis.com",
  );
  assert.equal(
    resolveUpstream(
      "/v1beta/models/gemini-3.8-flash-lite-tts:batchGenerateContent",
      "POST",
      account,
    )?.path,
    "/v1beta/models/gemini-3.8-flash-lite-tts:batchGenerateContent",
  );
});

test("gemini batch poll GET is forwarded", () => {
  const got = resolveUpstream("/aiRelay/v1beta/batches/abc-123", "GET", account);
  assert.equal(got?.path, "/v1beta/batches/abc-123");
});

test("other hosts, methods, models, and traversal are rejected", () => {
  assert.equal(
    resolveUpstream(`/client/v4/accounts/other/ai/run/${model}`, "POST", account),
    null,
  );
  assert.equal(
    resolveUpstream(
      "/v1beta/models/gemini-2.0-flash:generateContent",
      "POST",
      account,
    ),
    null,
  );
  assert.equal(resolveUpstream("/v1beta/models/gemini-3.8-flash-lite-tts:generateContent", "PUT", account), null);
  assert.equal(resolveUpstream("/aiRelay/client/v4/accounts/../ai/run/x", "POST", account), null);
  assert.equal(resolveUpstream("https://evil.example/client/v4/accounts/x", "POST", account), null);
});
