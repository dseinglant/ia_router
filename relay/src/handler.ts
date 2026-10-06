import { randomUUID } from "node:crypto";
import { Readable } from "node:stream";
import { getAuth } from "firebase-admin/auth";
import { getFirestore } from "firebase-admin/firestore";
import { resolveUpstream } from "./route";

const kMaxBodyBytes = 8_000_000;

export type AiRelayRequest = {
  path: string;
  method: string;
  header(name: string): string | undefined;
  rawBody?: Buffer;
};

export type AiRelayResponse = {
  headersSent: boolean;
  status(code: number): AiRelayResponse;
  json(body: unknown): void;
  setHeader(name: string, value: string): void;
  end(chunk?: string | Uint8Array): void;
};

export type AiRelayDeps = {
  llmToken: string;
  ttsToken: string;
  /** Cloudflare account billed by [llmToken]. Not InfoFeed's account. */
  cloudflareAccountId: string;
  paywallEnabled: boolean;
  verifyIdToken?: (token: string) => Promise<{ uid: string }>;
  fetchImpl?: typeof fetch;
};

function clientAccessToken(req: AiRelayRequest): string | null {
  const auth = req.header("authorization") ?? "";
  if (auth.toLowerCase().startsWith("bearer ")) {
    const token = auth.slice(7).trim();
    if (token.length > 0) return token;
  }
  const goog = req.header("x-goog-api-key")?.trim();
  if (goog) return goog;
  return null;
}

async function callerMaySpend(uid: string, paywallEnabled: boolean): Promise<boolean> {
  // ponytail: paywallEnabled false lets every Auth user of THIS app spend the quota.
  // The host flips it. This package does not know InfoFeed's kPaywallEnabled.
  if (!paywallEnabled) return true;
  const snap = await getFirestore().collection("users").doc(uid).get();
  const until = snap.get("entitledUntil");
  const date =
    until && typeof until.toDate === "function"
      ? (until.toDate() as Date)
      : null;
  return date != null && date.getTime() > Date.now();
}

export async function handleAiRelay(
  req: AiRelayRequest,
  res: AiRelayResponse,
  deps: AiRelayDeps,
): Promise<void> {
  const target = resolveUpstream(
    req.path || "/",
    req.method,
    deps.cloudflareAccountId,
  );
  if (!target) {
    res.status(404).json({ error: "not_found" });
    return;
  }
  const access = clientAccessToken(req);
  if (!access) {
    res.status(401).json({ error: "auth" });
    return;
  }
  const verify = deps.verifyIdToken ?? ((token) => getAuth().verifyIdToken(token));
  let uid: string;
  try {
    uid = (await verify(access)).uid;
  } catch {
    res.status(401).json({ error: "auth" });
    return;
  }
  if (!(await callerMaySpend(uid, deps.paywallEnabled))) {
    res.status(403).json({ error: "entitlement" });
    return;
  }

  const isLlm = target.origin === "https://api.cloudflare.com";
  const secret = isLlm ? deps.llmToken : deps.ttsToken;
  if (!secret) {
    res.status(500).json({ error: "unconfigured" });
    return;
  }

  const rawBody = req.rawBody;
  if (req.method !== "GET" && rawBody != null && rawBody.length > kMaxBodyBytes) {
    res.status(413).json({ error: "body" });
    return;
  }

  const url = `${target.origin}${target.path}`;
  const headers: Record<string, string> = {
    "content-type": req.header("content-type") ?? "application/json",
  };
  if (isLlm) headers.authorization = `Bearer ${secret}`;
  else headers["x-goog-api-key"] = secret;

  // Do not log req.body, rawBody, or the upstream body: both are article or script text.
  const fetchImpl = deps.fetchImpl ?? fetch;
  const upstream = await fetchImpl(url, {
    method: req.method,
    headers,
    body:
      req.method === "GET" || rawBody == null
        ? undefined
        : rawBody.toString("utf8"),
    redirect: "error",
    signal: AbortSignal.timeout(240_000),
  });

  res.status(upstream.status);
  const contentType = upstream.headers.get("content-type");
  if (contentType) res.setHeader("content-type", contentType);
  if (!upstream.body) {
    res.end();
    return;
  }
  const stream = Readable.fromWeb(
    upstream.body as import("node:stream/web").ReadableStream<Uint8Array>,
  );
  const writable = res as unknown as NodeJS.WritableStream;
  if (typeof writable.write === "function") {
    stream.pipe(writable);
    return;
  }
  const chunks: Buffer[] = [];
  for await (const chunk of stream) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  res.end(Buffer.concat(chunks));
}

export async function serveAiRelay(
  req: AiRelayRequest,
  res: AiRelayResponse,
  deps: AiRelayDeps,
): Promise<void> {
  try {
    await handleAiRelay(req, res, deps);
  } catch {
    if (!res.headersSent) {
      res.status(502).json({ error: "upstream", id: randomUUID() });
    }
  }
}
