/**
 * tenant-hash.test.ts - vectors for the TypeScript tenant hash (SLDC-P3-1).
 *
 * Run: bun test test/unit/tenant-hash.test.ts
 *
 * @id     tenant-hash-ts-test
 * @target scripts/derive_tenant_hash.ts
 * @task   SLDC-P3-1
 */
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  CANONICAL_HASH,
  PILOT_SALT,
  RetiredTenantError,
  SaltUnavailableError,
  TenantHashError,
  deriveTenantHash,
  resolveSalt,
} from "../../scripts/derive_tenant_hash.ts";

const bao = (body: unknown, status = 200) =>
  (async () => new Response(JSON.stringify(body), { status })) as unknown as typeof fetch;

describe("deriveTenantHash", () => {
  test("kusari is 4b53ab6b, not the unsalted d9d69501 or HMAC 4a89f30d", () => {
    const got = deriveTenantHash("kusari", PILOT_SALT);
    expect(got).toBe(CANONICAL_HASH);
    expect(got).not.toBe("d9d69501");
    expect(got).not.toBe("4a89f30d");
  });

  test("normalises case and whitespace", () => {
    expect(deriveTenantHash("  KUSARI ", PILOT_SALT)).toBe(CANONICAL_HASH);
  });

  test("rejects kurasi, empty, malformed and empty salt", () => {
    expect(() => deriveTenantHash("kurasi", PILOT_SALT)).toThrow(RetiredTenantError);
    expect(() => deriveTenantHash("  ", PILOT_SALT)).toThrow(TenantHashError);
    expect(() => deriveTenantHash("a.b", PILOT_SALT)).toThrow(TenantHashError);
    expect(() => deriveTenantHash("kusari", "")).toThrow(SaltUnavailableError);
  });
});

describe("resolveSalt", () => {
  const baoEnv = { BAO_ADDR: "http://bao.test", BAO_TOKEN: "t", SIGNAL_LOOM_EAP_SALT: "env" };

  test("prefers OpenBao", async () => {
    expect(await resolveSalt(baoEnv, bao({ data: { data: { salt: PILOT_SALT } } }))).toBe(PILOT_SALT);
  });

  test("falls back to env on 403 or network error", async () => {
    expect(await resolveSalt(baoEnv, bao({ errors: ["denied"] }, 403))).toBe("env");
    const boom = (async () => {
      throw new TypeError("fetch failed");
    }) as unknown as typeof fetch;
    expect(await resolveSalt(baoEnv, boom)).toBe("env");
  });

  test("fails closed with no salt anywhere", async () => {
    await expect(resolveSalt({}, bao({}))).rejects.toThrow(SaltUnavailableError);
  });
});

describe("shared cross-language vectors", () => {
  const table = JSON.parse(
    readFileSync(new URL("../fixtures/tenant/hash-vectors.json", import.meta.url), "utf8"),
  ) as {
    salt: string;
    vectors: { name: string; input: string; repeat?: number; salt?: string; want?: string; error?: string }[];
  };
  const errors: Record<string, new (...a: never[]) => Error> = {
    retired: RetiredTenantError,
    salt: SaltUnavailableError,
    empty: TenantHashError,
    invalid: TenantHashError,
  };
  for (const v of table.vectors) {
    test(v.name, () => {
      const tenant = v.input.repeat(v.repeat ?? 1);
      const salt = v.salt ?? table.salt;
      if (v.want) {
        expect(deriveTenantHash(tenant, salt)).toBe(v.want);
        return;
      }
      let caught: unknown;
      try {
        deriveTenantHash(tenant, salt);
      } catch (e) {
        caught = e;
      }
      expect(caught).toBeInstanceOf(errors[v.error!]);
      if (v.error === "empty" || v.error === "invalid") {
        expect(caught).not.toBeInstanceOf(RetiredTenantError);
        expect(String(caught).includes("cannot be empty")).toBe(v.error === "empty");
      }
    });
  }
});
