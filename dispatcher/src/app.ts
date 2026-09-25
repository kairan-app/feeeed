import { Hono } from "hono";
import { authenticate } from "./auth";
import type { Sql } from "./db";

export type Env = { HYPERDRIVE: { connectionString: string }; WORKER_TOKENS: string };
export type Deps = { openSql: (env: Env) => { sql: Sql; close: () => Promise<void> } };
export type Vars = { sql: Sql; workerName: string };

export function createApp(deps: Deps) {
  const app = new Hono<{ Bindings: Env; Variables: Vars }>();

  app.use("*", async (c, next) => {
    const workerName = await authenticate(c.req.header("Authorization"), c.env.WORKER_TOKENS);
    if (!workerName) return c.json({ error: "unauthorized" }, 401);
    c.set("workerName", workerName);

    const { sql, close } = deps.openSql(c.env);
    c.set("sql", sql);
    try {
      await next();
    } finally {
      const closing = close();
      try {
        c.executionCtx.waitUntil(closing);
      } catch {
        await closing;
      }
    }
  });

  return app;
}
