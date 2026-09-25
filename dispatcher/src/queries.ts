import type { Db } from "./db";

/**
 * postgres.js の `sql.array(...)` / 生の JS 配列 + `::text[]` キャストは、
 * このプロジェクトの接続設定 (`fetch_types: false`、db.ts 参照) の下では動かない。
 * `sql.array()` は型 OID を `options.shared.typeArrayMap` (fetch_types 有効時にサーバから
 * 取得するテーブル) 経由で解決しようとするが、fetch_types: false だとこのマップも
 * 配列用シリアライザ (`options.serializers[1009]` など) も一切登録されない。
 * その結果、配列パラメータが単なる `Array.prototype.toString()` (カンマ区切り、括弧無し)
 * にフォールバックしてしまい、`::text[]` キャストが `malformed array literal` で失敗する
 * (postgres.js 3.4.9 の src/index.js `array()` / src/types.js `handleValue()` /
 * src/connection.js `Bind()` で確認済み)。
 * そのため配列は自前で PostgreSQL のテキストリテラル形式 (`{"a","b",NULL}`) に組み立て、
 * ただの文字列パラメータとして渡して `::text[]` でキャストする。
 */
export function pgTextArrayLiteral(values: (string | null)[]): string {
  return "{" + values.map((v) => (v === null ? "NULL" : `"${v.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`)).join(",") + "}";
}

export type DueChannel = {
  channel_id: number;
  feed_url: string;
  site_url: string | null;
  use_proxy: boolean;
  stored: { title: string; description: string | null; site_url: string | null; image_url: string | null };
};

export type StoredItem = {
  guid: string;
  title: string;
  url: string;
  image_url: string | null;
  published_at: string;
  /** Rails がこの item を保存した時刻 (UTC、`...Z`)。フィード側の書き換えと parser の差を見分けるため */
  created_at: string;
  data: { summary: string | null; itunes_subtitle: string | null; enclosure_url: string | null; enclosure_type: string | null };
};

export async function selectDueChannels(
  sql: Db,
  opts: { max: number; order: "priority" | "random"; scope?: "due" | "all" },
): Promise<DueChannel[]> {
  const orderBy = opts.order === "random" ? sql`random()` : sql`check_interval_hours, last_items_checked_at`;
  // scope: "due" (既定) は Rails の needs_check_now と同じ「今取り込むべきか」の条件を足す。
  // "all" は本番の影モード検証用に、停止中を除く全チャンネルから (ホストごとに1件) サンプルするため、
  // この条件を丸ごと外す。SQL 全体を複製しないよう、postgres.js のフラグメントで条件だけ差し替える
  const dueFilter =
    (opts.scope ?? "due") === "all"
      ? sql``
      : sql`
        AND (
          c.last_items_checked_at IS NULL
          OR c.last_items_checked_at < (now() AT TIME ZONE 'UTC')
               - ((c.check_interval_hours || ' hours')::interval - interval '10 minutes')
          OR EXISTS (
            SELECT 1 FROM channel_fixed_schedules fs
            WHERE fs.channel_id = c.id
              AND fs.day_of_week = EXTRACT(DOW FROM now() AT TIME ZONE 'Asia/Tokyo')
              AND fs.hour = EXTRACT(HOUR FROM now() AT TIME ZONE 'Asia/Tokyo')
          )
        )`;
  const rows = await sql`
    WITH due AS (
      SELECT c.id, c.feed_url, c.site_url, c.title, c.description, c.image_url,
             c.check_interval_hours, c.last_items_checked_at,
             lower(substring(c.feed_url from '^[a-zA-Z][a-zA-Z0-9+.-]*://([^/:?#]+)')) AS host
      FROM channels c
      WHERE NOT EXISTS (SELECT 1 FROM channel_stoppers s WHERE s.channel_id = c.id)
        ${dueFilter}
    ),
    per_host AS (
      SELECT DISTINCT ON (host) * FROM due
      ORDER BY host, check_interval_hours, last_items_checked_at
    )
    SELECT p.id, p.feed_url, p.site_url, p.title, p.description, p.image_url,
           EXISTS (SELECT 1 FROM proxy_required_domains d WHERE lower(d.domain) = p.host) AS use_proxy
    FROM per_host p
    ORDER BY ${orderBy}
    LIMIT ${opts.max}`;

  return rows.map((r) => ({
    channel_id: Number(r.id),
    feed_url: r.feed_url,
    site_url: r.site_url,
    use_proxy: r.use_proxy,
    stored: { title: r.title, description: r.description, site_url: r.site_url, image_url: r.image_url },
  }));
}

export async function newFlags(
  sql: Db,
  channelId: number,
  entries: { entry_id: string | null; url: string | null }[],
): Promise<boolean[]> {
  if (entries.length === 0) return [];
  const rows = await sql`
    SELECT e.ord,
           NOT EXISTS (
             SELECT 1 FROM items i
             WHERE i.channel_id = ${channelId} AND (i.guid = e.entry_id OR i.guid = e.url)
           ) AS is_new
    FROM unnest(${pgTextArrayLiteral(entries.map((e) => e.entry_id))}::text[], ${pgTextArrayLiteral(entries.map((e) => e.url))}::text[])
         WITH ORDINALITY AS e(entry_id, url, ord)
    ORDER BY e.ord`;
  return rows.map((r) => r.is_new as boolean);
}

export async function storedItems(sql: Db, channelId: number, guids: string[]): Promise<StoredItem[]> {
  if (guids.length === 0) return [];
  const rows = await sql`
    SELECT guid, title, url, image_url,
           to_char(published_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS published_at,
           to_char(created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS created_at,
           data->>'summary' AS summary, data->>'itunes_subtitle' AS itunes_subtitle,
           data->>'enclosure_url' AS enclosure_url, data->>'enclosure_type' AS enclosure_type
    FROM items
    WHERE channel_id = ${channelId} AND guid = ANY(${pgTextArrayLiteral(guids)}::text[])
    ORDER BY id`;
  return rows.map((r) => ({
    guid: r.guid,
    title: r.title,
    url: r.url,
    image_url: r.image_url,
    published_at: r.published_at,
    created_at: r.created_at,
    data: {
      summary: r.summary,
      itunes_subtitle: r.itunes_subtitle,
      enclosure_url: r.enclosure_url,
      enclosure_type: r.enclosure_type,
    },
  }));
}

export async function proxyRequiredDomains(sql: Db): Promise<string[]> {
  const rows = await sql`SELECT lower(domain) AS domain FROM proxy_required_domains ORDER BY domain`;
  return rows.map((r) => r.domain as string);
}
