import { Hono } from "hono";
import { authenticate, WorkerTokensConfigError } from "./auth";
import type { Db, Sql } from "./db";
import { newFlags, proxyRequiredDomains, selectDueChannels, storedItems } from "./queries";

export type Env = { HYPERDRIVE: { connectionString: string }; WORKER_TOKENS: string };
export type Deps = { openSql: (env: Env) => { sql: Sql; close: () => Promise<void> } };
export type Vars = { sql: Db; workerName: string };

export function createApp(deps: Deps) {
  const app = new Hono<{ Bindings: Env; Variables: Vars }>();

  // 1リクエスト1行のアクセスログ (Workers Logs で見る)。トークンやクエリ文字列は出さない
  app.use("*", async (c, next) => {
    await next();
    console.log(
      JSON.stringify({ worker: c.get("workerName") ?? null, method: c.req.method, path: c.req.path, status: c.res.status }),
    );
  });

  app.use("*", async (c, next) => {
    let workerName: string | null;
    try {
      workerName = await authenticate(c.req.header("Authorization"), c.env.WORKER_TOKENS);
    } catch (err) {
      if (err instanceof WorkerTokensConfigError) {
        return c.json({ error: "server misconfigured" }, 500);
      }
      throw err;
    }
    if (!workerName) return c.json({ error: "unauthorized" }, 401);
    c.set("workerName", workerName);
    await next();
  });

  // dispatcher は本番 DB に書き込まない。コードの約束だけに頼らず、すべてのルートを
  // READ ONLY トランザクションの中で動かし、書き込みを DB 側で拒否させる。
  // ルートは c.get("sql") (= このトランザクション) だけを使うこと。
  app.use("*", async (c, next) => {
    const { sql, close } = deps.openSql(c.env);
    try {
      await sql.begin("read only", async (tx) => {
        c.set("sql", tx);
        await next();
      });
    } finally {
      const closing = close();
      try {
        c.executionCtx.waitUntil(closing);
      } catch {
        await closing;
      }
    }
  });

  const MAX_BATCH = 1000;

  const channelIdParam = (raw: string) => {
    const id = Number(raw);
    return Number.isSafeInteger(id) && id > 0 ? id : null;
  };

  app.get("/shadow/channels", async (c) => {
    const max = Number(c.req.query("max") ?? "20");
    const order = c.req.query("order") ?? "priority";
    if (!Number.isInteger(max) || max < 1 || max > 100) return c.json({ error: "max must be 1..100" }, 400);
    if (order !== "priority" && order !== "random") return c.json({ error: "order must be priority or random" }, 400);
    const sql = c.get("sql");
    const [channels, domains] = await Promise.all([
      selectDueChannels(sql, { max, order }),
      proxyRequiredDomains(sql),
    ]);
    return c.json({ channels, proxy_required_domains: domains });
  });

  app.post("/channels/:channel_id/new-guids", async (c) => {
    const channelId = channelIdParam(c.req.param("channel_id"));
    const body = await c.req.json().catch(() => null);
    const entries = body?.entries;
    const valid =
      Array.isArray(entries) &&
      entries.length <= MAX_BATCH &&
      entries.every(
        (e: any) =>
          e && (e.entry_id === null || typeof e.entry_id === "string") && (e.url === null || typeof e.url === "string"),
      );
    if (!channelId || !valid) return c.json({ error: "expected { entries: [{ entry_id, url }] }" }, 400);
    return c.json({ new: await newFlags(c.get("sql"), channelId, entries) });
  });

  app.post("/shadow/channels/:channel_id/items", async (c) => {
    const channelId = channelIdParam(c.req.param("channel_id"));
    const body = await c.req.json().catch(() => null);
    const guids = body?.guids;
    const valid = Array.isArray(guids) && guids.length <= MAX_BATCH && guids.every((g: any) => typeof g === "string");
    if (!channelId || !valid) return c.json({ error: "expected { guids: string[] }" }, 400);
    return c.json({ items: await storedItems(c.get("sql"), channelId, guids) });
  });

  return app;
}
