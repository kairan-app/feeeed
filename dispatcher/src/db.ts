import postgres from "postgres";

export type Sql = postgres.Sql;
/** クエリ関数が受け取る接続。素の Sql でも、ルートに渡される読み取り専用トランザクションでもよい */
export type Db = postgres.ISql;

export function openSql(connectionString: string): { sql: Sql; close: () => Promise<void> } {
  const sql = postgres(connectionString, {
    max: 5,
    fetch_types: false,
    connection: { TimeZone: "UTC" },
  });
  return { sql, close: () => sql.end() };
}
