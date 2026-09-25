import { beforeEach, describe, expect, it } from "vitest";
import { newFlags, pgTextArrayLiteral, proxyRequiredDomains, selectDueChannels, storedItems } from "../src/queries";
import { hoursAgo, insertChannel, insertItem, resetTables, sql } from "./helpers";

function tokyoNow() {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: "Asia/Tokyo", weekday: "short", hour: "numeric", hourCycle: "h23" })
    .formatToParts(new Date());
  const weekday = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].indexOf(parts.find((p) => p.type === "weekday")!.value);
  const hour = Number(parts.find((p) => p.type === "hour")!.value);
  return { weekday, hour };
}

beforeEach(resetTables);

describe("selectDueChannels", () => {
  it("未チェック・間隔切れ・固定スケジュールのものを選び、停止中と間隔内は選ばない", async () => {
    const never = await insertChannel({ feed_url: "https://a.example/feed" });
    const overdue = await insertChannel({ feed_url: "https://b.example/feed", check_interval_hours: 3, last_items_checked_at: hoursAgo(3) });
    await insertChannel({ feed_url: "https://c.example/feed", check_interval_hours: 3, last_items_checked_at: hoursAgo(1) });
    const scheduled = await insertChannel({ feed_url: "https://d.example/feed", check_interval_hours: 24, last_items_checked_at: hoursAgo(1) });
    const { weekday, hour } = tokyoNow();
    await sql`INSERT INTO channel_fixed_schedules (channel_id, day_of_week, hour, created_at, updated_at) VALUES (${scheduled}, ${weekday}, ${hour}, now(), now())`;
    const stopped = await insertChannel({ feed_url: "https://e.example/feed" });
    await sql`INSERT INTO channel_stoppers (channel_id, reason, created_at, updated_at) VALUES (${stopped}, 'x', now(), now())`;

    const ids = (await selectDueChannels(sql, { max: 10, order: "priority" })).map((c) => c.channel_id).sort();
    expect(ids).toEqual([never, overdue, scheduled].sort());
  });

  it("間隔の10分前から対象になる", async () => {
    const id = await insertChannel({ feed_url: "https://a.example/feed", check_interval_hours: 1, last_items_checked_at: hoursAgo(55 / 60) });
    expect((await selectDueChannels(sql, { max: 10, order: "priority" })).map((c) => c.channel_id)).toEqual([id]);
  });

  it("同じホストからは1件だけ、優先度順に選ぶ", async () => {
    const hourly = await insertChannel({ feed_url: "https://www.youtube.com/feeds/1", check_interval_hours: 1, last_items_checked_at: hoursAgo(5) });
    await insertChannel({ feed_url: "https://www.youtube.com/feeds/2", check_interval_hours: 24, last_items_checked_at: hoursAgo(48) });
    await insertChannel({ feed_url: "https://WWW.YOUTUBE.COM/feeds/3", check_interval_hours: 3, last_items_checked_at: hoursAgo(10) });
    const other = await insertChannel({ feed_url: "https://note.com/x/rss", check_interval_hours: 12, last_items_checked_at: hoursAgo(13) });

    const rows = await selectDueChannels(sql, { max: 10, order: "priority" });
    expect(rows.map((r) => r.channel_id)).toEqual([hourly, other]);
  });

  it("max で件数を絞り、use_proxy と保存済みの値を返す", async () => {
    await sql`INSERT INTO proxy_required_domains (domain, created_at, updated_at) VALUES ('blocked.example', now(), now())`;
    const id = await insertChannel({ feed_url: "https://blocked.example/feed", title: "T", site_url: "https://blocked.example/" });
    await insertChannel({ feed_url: "https://ok.example/feed" });
    const rows = await selectDueChannels(sql, { max: 1, order: "priority" });
    expect(rows).toHaveLength(1);
    const all = await selectDueChannels(sql, { max: 10, order: "priority" });
    const blocked = all.find((r) => r.channel_id === id)!;
    expect(blocked.use_proxy).toBe(true);
    expect(blocked.stored).toEqual({ title: "T", description: null, site_url: "https://blocked.example/", image_url: null });
    expect(await proxyRequiredDomains(sql)).toEqual(["blocked.example"]);
  });
});

describe("newFlags", () => {
  it("entry_id とも url とも一致しないものだけ true", async () => {
    const id = await insertChannel({ feed_url: "https://a.example/feed" });
    await insertItem(id, "g1");
    await insertItem(id, "https://a.example/2");
    const flags = await newFlags(sql, id, [
      { entry_id: "g1", url: "https://a.example/1" },
      { entry_id: "g2", url: "https://a.example/2" },
      { entry_id: "g3", url: null },
      { entry_id: null, url: null },
    ]);
    expect(flags).toEqual([false, false, true, true]);
  });

  it("別のチャンネルの item は見ない", async () => {
    const a = await insertChannel({ feed_url: "https://a.example/feed" });
    const b = await insertChannel({ feed_url: "https://b.example/feed" });
    await insertItem(b, "g1");
    expect(await newFlags(sql, a, [{ entry_id: "g1", url: null }])).toEqual([true]);
  });
});

describe("storedItems", () => {
  it("guid で保存済みの item を返す", async () => {
    const id = await insertChannel({ feed_url: "https://a.example/feed" });
    await insertItem(id, "g1", { title: "one", created_at: new Date("2026-09-20T12:34:56Z"), data: { summary: "s", enclosure_url: "https://a.example/1.mp3", other: "x" } });
    const items = await storedItems(sql, id, ["g1", "missing"]);
    expect(items).toEqual([
      {
        guid: "g1", title: "one", url: "https://example.com/g1", image_url: null,
        published_at: "2026-09-24T00:00:00Z",
        created_at: "2026-09-20T12:34:56Z",
        data: { summary: "s", itunes_subtitle: null, enclosure_url: "https://a.example/1.mp3", enclosure_type: null },
      },
    ]);
  });
});

describe("pgTextArrayLiteral", () => {
  it("PostgreSQL の text[] として元の値に戻る", async () => {
    const values = ['a"b', "c\\d", "{x,y}", "NULL", "", null, "日本語🍣", '\\"', "line1\nline2", " spaced "];
    const rows = await sql`
      SELECT v, v IS NULL AS is_null FROM unnest(${pgTextArrayLiteral(values)}::text[]) WITH ORDINALITY AS t(v, ord) ORDER BY ord`;
    expect(rows.map((r) => (r.is_null ? null : r.v))).toEqual(values);
  });

  it("空配列は空の text[]", async () => {
    const [row] = await sql`SELECT cardinality(${pgTextArrayLiteral([])}::text[]) AS n`;
    expect(Number(row.n)).toBe(0);
  });
});
