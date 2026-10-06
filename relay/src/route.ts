/** Paths the mobile client is allowed to spend THIS app's credentials on. */
const kLlmModel = "@cf/google/gemma-4-26b-a4b-it";
const kTtsModel = "gemini-3.8-flash-lite-tts";

const kCloudflareOrigin = "https://api.cloudflare.com";
const kGeminiOrigin = "https://generativelanguage.googleapis.com";

export type UpstreamTarget = { origin: string; path: string };

/**
 * Maps a function request path to a fixed upstream.
 * Returns null for anything that is not the pinned LLM run or the pinned TTS model.
 * [accountId] is the Cloudflare account this deployment pays. Another
 * project's account id must not match.
 */
export function resolveUpstream(
  rawPath: string,
  method: string,
  accountId: string,
): UpstreamTarget | null {
  const verb = method.toUpperCase();
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(accountId)) return null;
  if (verb !== "GET" && verb !== "POST") return null;
  if (rawPath.includes("://") || rawPath.includes("..") || rawPath.includes("//")) {
    return null;
  }
  let path = rawPath.split("?")[0] ?? "";
  if (!path.startsWith("/")) path = `/${path}`;
  path = path.replace(/^\/aiRelay(?=\/|$)/, "");
  if (path.length === 0) path = "/";

  if (verb === "POST") {
    const llm = `/client/v4/accounts/${accountId}/ai/run/${kLlmModel}`;
    if (path === llm) return { origin: kCloudflareOrigin, path };
    const gen = `/v1beta/models/${kTtsModel}:generateContent`;
    const batch = `/v1beta/models/${kTtsModel}:batchGenerateContent`;
    if (path === gen || path === batch) return { origin: kGeminiOrigin, path };
    return null;
  }

  if (/^\/v1beta\/batches\/[A-Za-z0-9_-]+$/.test(path)) {
    return { origin: kGeminiOrigin, path };
  }
  const modelBatch =
    /^\/v1beta\/models\/gemini-3\.8-flash-lite-tts\/batches\/[A-Za-z0-9_-]+$/;
  if (modelBatch.test(path)) return { origin: kGeminiOrigin, path };
  return null;
}
