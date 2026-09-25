export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** WORKER_TOKENS の形 (JSON の string -> string) が壊れているときに投げる */
export class WorkerTokensConfigError extends Error {
  constructor() {
    super("WORKER_TOKENS is not a valid JSON object of string -> string");
    this.name = "WorkerTokensConfigError";
  }
}

/** `{ workerName: sha256Hex }` 形の JSON をパースする。壊れていれば null (値そのものは呼び出し側でログに出さないこと) */
export function parseWorkerTokens(json: string): Record<string, string> | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return null;
  for (const value of Object.values(parsed as Record<string, unknown>)) {
    if (typeof value !== "string") return null;
  }
  return parsed as Record<string, string>;
}

export async function authenticate(authorization: string | undefined, workerTokensJson: string): Promise<string | null> {
  const tokens = parseWorkerTokens(workerTokensJson);
  if (!tokens) {
    // 値そのもの (workerTokensJson) はログに出さない。壊れている旨だけを残す。
    console.error("[dispatcher] WORKER_TOKENS is not a valid JSON object of string -> string");
    throw new WorkerTokensConfigError();
  }

  const match = authorization?.match(/^Bearer (.+)$/);
  if (!match) return null;

  const hashed = await sha256Hex(match[1]);
  let found: string | null = null;
  // 早期 return はせず全エントリを一定時間で比較しつつ、複数一致時は最初の一致を採用する
  for (const [name, expected] of Object.entries(tokens)) {
    if (found === null && constantTimeEqual(hashed, expected)) found = name;
  }
  return found;
}
