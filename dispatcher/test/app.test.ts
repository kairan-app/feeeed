import { beforeEach, describe, expect, it } from "vitest";
import { insertChannel, insertItem, request, resetTables } from "./helpers";

beforeEach(resetTables);

describe("routes", () => {
  it("GET /shadow/channels", async () => {
    const id = await insertChannel({ feed_url: "https://a.example/feed" });
    const res = await request("/shadow/channels?max=5");
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.channels.map((c: any) => c.channel_id)).toEqual([id]);
    expect(body.proxy_required_domains).toEqual([]);
  });

  it("GET /shadow/channels は max が範囲外なら 400", async () => {
    expect((await request("/shadow/channels?max=0")).status).toBe(400);
    expect((await request("/shadow/channels?max=101")).status).toBe(400);
    expect((await request("/shadow/channels?order=oldest")).status).toBe(400);
  });

  it("POST /channels/:id/new-guids", async () => {
    const id = await insertChannel({ feed_url: "https://a.example/feed" });
    await insertItem(id, "g1");
    const res = await request(`/channels/${id}/new-guids`, {
      method: "POST",
      body: JSON.stringify({ entries: [{ entry_id: "g1", url: null }, { entry_id: "g2", url: null }] }),
    });
    expect(await res.json()).toEqual({ new: [false, true] });
  });

  it("POST /channels/:id/new-guids は形が違えば 400", async () => {
    const res = await request("/channels/1/new-guids", { method: "POST", body: JSON.stringify({ guids: [] }) });
    expect(res.status).toBe(400);
  });

  it("POST /shadow/channels/:id/items", async () => {
    const id = await insertChannel({ feed_url: "https://a.example/feed" });
    await insertItem(id, "g1");
    const res = await request(`/shadow/channels/${id}/items`, { method: "POST", body: JSON.stringify({ guids: ["g1"] }) });
    const body = (await res.json()) as any;
    expect(body.items.map((i: any) => i.guid)).toEqual(["g1"]);
  });
});
