import { describe, expect, it } from "vitest";
import { assertTestDatabaseUrl } from "./helpers";

describe("assertTestDatabaseUrl", () => {
  it("DB 名が _test で終わる URL だけを通す", () => {
    expect(assertTestDatabaseUrl("postgres://u:p@h:5432/feeeed_test")).toBe("postgres://u:p@h:5432/feeeed_test");
    expect(assertTestDatabaseUrl("postgres://u:p@h:5432/feeeed_test?sslmode=disable")).toBe(
      "postgres://u:p@h:5432/feeeed_test?sslmode=disable",
    );
  });

  it("未設定や _test で終わらない DB 名なら投げる", () => {
    expect(() => assertTestDatabaseUrl(undefined)).toThrow(/TEST_DATABASE_URL/);
    expect(() => assertTestDatabaseUrl("")).toThrow(/TEST_DATABASE_URL/);
    expect(() => assertTestDatabaseUrl("postgres://u:p@h:5432/feeeed_development")).toThrow(/_test/);
    expect(() => assertTestDatabaseUrl("postgres://u:p@h:5432/feeeed_test_backup")).toThrow(/_test/);
    expect(() => assertTestDatabaseUrl("not a url")).toThrow();
  });
});
