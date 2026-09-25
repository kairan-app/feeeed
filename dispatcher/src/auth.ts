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

export async function authenticate(authorization: string | undefined, workerTokensJson: string): Promise<string | null> {
  const match = authorization?.match(/^Bearer (.+)$/);
  if (!match) return null;
  const hashed = await sha256Hex(match[1]);
  const tokens = JSON.parse(workerTokensJson) as Record<string, string>;
  let found: string | null = null;
  for (const [name, expected] of Object.entries(tokens)) {
    if (constantTimeEqual(hashed, expected)) found = name;
  }
  return found;
}
