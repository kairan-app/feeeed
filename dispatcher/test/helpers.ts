import postgres from "postgres";
import { createApp, type Env } from "../src/app";
import { sha256Hex } from "../src/auth";

/**
 * テストはテーブルを TRUNCATE するので、テスト用 DB (名前が `_test` で終わるもの) 以外では動かさない。
 * 開発用や本番の DB を指した URL を誤って渡したときに、何かを消す前に止める。
 */
export function assertTestDatabaseUrl(url: string | undefined): string {
  if (!url) throw new Error("TEST_DATABASE_URL is not set");
  let dbName: string;
  try {
    dbName = decodeURIComponent(new URL(url).pathname.replace(/^\//, ""));
  } catch {
    throw new Error("TEST_DATABASE_URL is not a valid URL");
  }
  if (!dbName.endsWith("_test")) {
    throw new Error(`TEST_DATABASE_URL must point to a database whose name ends with _test (got "${dbName}")`);
  }
  return url;
}

const TEST_DATABASE_URL = assertTestDatabaseUrl(process.env.TEST_DATABASE_URL);

export const sql = postgres(TEST_DATABASE_URL, {
  max: 2,
  fetch_types: false,
  connection: { TimeZone: "UTC" },
  onnotice: () => {},
});

export const TOKEN = "test-token";

export async function testEnv(): Promise<Env> {
  return {
    HYPERDRIVE: { connectionString: TEST_DATABASE_URL },
    WORKER_TOKENS: JSON.stringify({ "test-machine": await sha256Hex(TOKEN) }),
  };
}

export const app = createApp({ openSql: () => ({ sql, close: async () => {} }) });

export async function request(path: string, init: RequestInit = {}, token: string | null = TOKEN) {
  const headers = new Headers(init.headers);
  if (token) headers.set("Authorization", `Bearer ${token}`);
  if (init.body) headers.set("Content-Type", "application/json");
  return app.request(path, { ...init, headers }, await testEnv());
}

export async function resetTables() {
  await sql`TRUNCATE channels, items, channel_stoppers, channel_fixed_schedules, proxy_required_domains RESTART IDENTITY CASCADE`;
}

export async function insertChannel(attrs: {
  feed_url: string;
  title?: string;
  site_url?: string | null;
  description?: string | null;
  image_url?: string | null;
  check_interval_hours?: number;
  last_items_checked_at?: Date | null;
}) {
  const [row] = await sql`
    INSERT INTO channels (feed_url, title, site_url, description, image_url, check_interval_hours, last_items_checked_at, created_at, updated_at)
    VALUES (${attrs.feed_url}, ${attrs.title ?? "t"}, ${attrs.site_url ?? null}, ${attrs.description ?? null}, ${attrs.image_url ?? null},
            ${attrs.check_interval_hours ?? 1}, ${attrs.last_items_checked_at ?? null}, now(), now())
    RETURNING id`;
  return Number(row.id);
}

export async function insertItem(
  channelId: number,
  guid: string,
  attrs: { title?: string; url?: string; published_at?: Date; created_at?: Date; data?: object } = {},
) {
  await sql`
    INSERT INTO items (channel_id, guid, title, url, published_at, data, created_at, updated_at)
    VALUES (${channelId}, ${guid}, ${attrs.title ?? guid}, ${attrs.url ?? `https://example.com/${guid}`},
            ${attrs.published_at ?? new Date("2026-09-24T00:00:00Z")}, ${sql.json((attrs.data ?? {}) as any)},
            ${attrs.created_at ?? new Date()}, now())`;
}

export function hoursAgo(h: number) {
  return new Date(Date.now() - h * 3600 * 1000);
}
