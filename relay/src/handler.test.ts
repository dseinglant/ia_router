import assert from "node:assert/strict";
import test from "node:test";
import { handleAiRelay, type AiRelayRequest, type AiRelayResponse } from "./handler";

const account = "9c2eb959ccafdd0f563b1ea6adf1472b";
const model = "@cf/google/gemma-4-26b-a4b-it";
const llmPath = `/client/v4/accounts/${account}/ai/run/${model}`;

function mockReq(headers: Record<string, string>): AiRelayRequest {
  return {
    path: llmPath,
    method: "POST",
    header(name: string) {
      return headers[name.toLowerCase()];
    },
    rawBody: Buffer.from("{}"),
  };
}

function mockRes(): AiRelayResponse & { statusCode: number } {
  const res: AiRelayResponse & { statusCode: number } = {
    statusCode: 0,
    headersSent: false,
    status(code: number) {
      this.statusCode = code;
      return this;
    },
    json() {
      this.headersSent = true;
    },
    setHeader() {},
    end() {
      this.headersSent = true;
    },
  };
  return res;
}

test("missing token is 401 and does not call upstream", async () => {
  let called = false;
  const res = mockRes();
  await handleAiRelay(mockReq({}), res, {
    llmToken: "llm-secret",
    ttsToken: "tts-secret",
    cloudflareAccountId: account,
    paywallEnabled: false,
    verifyIdToken: async () => ({ uid: "u" }),
    fetchImpl: async () => {
      called = true;
      return new Response("no");
    },
  });
  assert.equal(res.statusCode, 401);
  assert.equal(called, false);
});

test("valid token forwards to Cloudflare with the vendor secret", async () => {
  let seenUrl = "";
  let seenAuth = "";
  const res = mockRes();
  await handleAiRelay(mockReq({ authorization: "Bearer firebase-id-token" }), res, {
    llmToken: "llm-secret",
    ttsToken: "tts-secret",
    cloudflareAccountId: account,
    paywallEnabled: false,
    verifyIdToken: async () => ({ uid: "u" }),
    fetchImpl: async (url, init) => {
      seenUrl = String(url);
      const headers = init?.headers as Record<string, string>;
      seenAuth = headers.authorization;
      return new Response(null, { status: 200 });
    },
  });
  assert.equal(
    seenUrl,
    `https://api.cloudflare.com/client/v4/accounts/${account}/ai/run/${model}`,
  );
  assert.equal(seenAuth, "Bearer llm-secret");
  assert.equal(res.statusCode, 200);
});
