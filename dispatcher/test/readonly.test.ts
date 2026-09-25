import { beforeEach, describe, expect, it, onTestFinished, vi } from "vitest";
import { createApp } from "../src/app";
import { request, resetTables, sql, testEnv, TOKEN } from "./helpers";

beforeEach(resetTables);

describe("読み取り専用トランザクション", () => {
  it("ルートに渡される sql からの書き込みは read-only transaction のエラーで失敗する", async () => {
    // 書き込みを握りつぶしても sql.begin 自体が失敗し、Hono の既定のエラーハンドラが console.error に出すので抑制する
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    onTestFinished(() => errorSpy.mockRestore());
    const app = createApp({ openSql: () => ({ sql, close: async () => {} }) });
    let caught: unknown = null;
    app.post("/__write", async (c) => {
      try {
        await c.get("sql")`INSERT INTO proxy_required_domains (domain, created_at, updated_at) VALUES ('w.example', now(), now())`;
      } catch (err) {
        caught = err;
        return c.json({ error: "write failed" }, 500);
      }
      return c.json({ ok: true });
    });
    const res = await app.request("/__write", { method: "POST", headers: { Authorization: `Bearer ${TOKEN}` } }, await testEnv());
    expect(res.status).toBe(500);
    expect(String((caught as Error)?.message)).toMatch(/read-only transaction/);
    expect(await sql`SELECT 1 FROM proxy_required_domains`).toHaveLength(0);
  });
});

describe("リクエストのログ", () => {
  it("ワーカー名・メソッド・パス・ステータスを1行で出し、トークンは含めない", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    try {
      await request("/shadow/channels?max=5");
      await request("/shadow/channels", {}, "wrong");
      const lines = logSpy.mock.calls.map((call) => call.map(String).join(" "));
      expect(lines).toHaveLength(2);
      expect(JSON.parse(lines[0])).toMatchObject({ worker: "test-machine", method: "GET", path: "/shadow/channels", status: 200 });
      expect(JSON.parse(lines[1])).toMatchObject({ worker: null, method: "GET", path: "/shadow/channels", status: 401 });
      for (const line of lines) expect(line).not.toContain(TOKEN);
    } finally {
      logSpy.mockRestore();
    }
  });
});
