import { createApp, type Env } from "./app";
import { openSql } from "./db";

const app = createApp({ openSql: (env: Env) => openSql(env.HYPERDRIVE.connectionString) });

export default app;
