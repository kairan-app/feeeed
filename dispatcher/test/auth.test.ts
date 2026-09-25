import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { authenticate, constantTimeEqual, sha256Hex } from "../src/auth";
import { app, request, TOKEN } from "./helpers";

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

describe("WORKER_TOKENS が壊れている場合", () => {
  const requestWithWorkerTokens = (workerTokens: string) => {
    const headers = new Headers({ Authorization: `Bearer ${TOKEN}` });
    return app.request(
      "/shadow/channels",
      { headers },
      { HYPERDRIVE: { connectionString: process.env.TEST_DATABASE_URL! }, WORKER_TOKENS: workerTokens },
    );
  };

  // 想定どおりの console.error まで出力してテストのノイズにしないよう、都度抑制する
  let errorSpy: ReturnType<typeof vi.spyOn>;
  beforeEach(() => {
    errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
  });
  afterEach(() => {
    errorSpy.mockRestore();
  });

  it("不正な JSON なら 500 server misconfigured を返す", async () => {
    const res = await requestWithWorkerTokens("not json");
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: "server misconfigured" });
    expect(errorSpy).toHaveBeenCalled();
  });

  it("JSON だが配列なら 500 server misconfigured を返す", async () => {
    const res = await requestWithWorkerTokens(JSON.stringify([]));
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: "server misconfigured" });
    expect(errorSpy).toHaveBeenCalled();
  });

  it("JSON だが値が文字列でないオブジェクトなら 500 server misconfigured を返す", async () => {
    const res = await requestWithWorkerTokens(JSON.stringify({ a: 1 }));
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: "server misconfigured" });
    expect(errorSpy).toHaveBeenCalled();
  });

  it("エラーログにトークンの値そのものを含めない", async () => {
    const secretLookingValue = "not json but contains a SECRET_TOKEN_VALUE_12345";
    await requestWithWorkerTokens(secretLookingValue);
    for (const call of errorSpy.mock.calls) {
      for (const arg of call) {
        expect(String(arg)).not.toContain(secretLookingValue);
        expect(String(arg)).not.toContain("SECRET_TOKEN_VALUE_12345");
      }
    }
    expect(errorSpy).toHaveBeenCalled();
  });
});
