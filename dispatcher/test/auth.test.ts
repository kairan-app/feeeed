import { describe, expect, it } from "vitest";
import { authenticate, constantTimeEqual, sha256Hex } from "../src/auth";
import { request } from "./helpers";

describe("authenticate", () => {
  it("トークンのハッシュが一致したワーカー名を返す", async () => {
    const tokens = JSON.stringify({ alpha: await sha256Hex("a"), beta: await sha256Hex("b") });
    expect(await authenticate("Bearer b", tokens)).toBe("beta");
    expect(await authenticate("Bearer c", tokens)).toBeNull();
    expect(await authenticate(undefined, tokens)).toBeNull();
    expect(await authenticate("Basic b", tokens)).toBeNull();
  });

  it("constantTimeEqual は長さが違えば false", () => {
    expect(constantTimeEqual("abc", "abc")).toBe(true);
    expect(constantTimeEqual("abc", "abd")).toBe(false);
    expect(constantTimeEqual("abc", "abcd")).toBe(false);
  });

  it("認証に失敗したら 401", async () => {
    const res = await request("/shadow/channels", {}, "wrong");
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: "unauthorized" });
  });
});
