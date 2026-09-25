import postgres from "postgres";

export type Sql = postgres.Sql;

export function openSql(connectionString: string): { sql: Sql; close: () => Promise<void> } {
  const sql = postgres(connectionString, {
    max: 5,
    fetch_types: false,
    connection: { TimeZone: "UTC" },
  });
  return { sql, close: () => sql.end() };
}
