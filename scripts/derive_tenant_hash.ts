/**
 * derive_tenant_hash.ts - TypeScript equivalent of scripts/derive_tenant_hash.py
 * (SLDC-P3-1) for bun services:
 *
 *   hash = sha256(salt + ":" + lower(trim(tenant))).hex[:8]
 *
 * Salted SHA-256 concatenation (Governor ruling G1), not HMAC. Salt lookup
 * order is OpenBao KV v2 secret/data/signalloom/eap (2 s timeout), then
 * SIGNAL_LOOM_EAP_SALT, else fail closed. No built-in default salt.
 *
 * @id     derive-tenant-hash-ts
 * @tests  test/unit/tenant-hash.test.ts
 */
import { createHash } from "node:crypto";

export const CANONICAL_TENANT = "kusari";
export const CANONICAL_HASH = "4b53ab6b";
export const PILOT_SALT = "signalloom-eap-salt-2026-q3";
const RETIRED_TENANTS = new Set(["kurasi"]);
const TENANT_RE = /^[a-z0-9][a-z0-9-]{0,62}$/;

export class TenantHashError extends Error {}
export class RetiredTenantError extends TenantHashError {}
export class SaltUnavailableError extends Error {}

export function normalizeTenant(name: string): string {
  // ASCII whitespace only, and non-ASCII refused before lowercasing, so
  // Unicode spaces, a BOM and case folds cannot reach an ASCII tenant.
  const trimmed = name.replace(/^[ \t\n\r\v\f]+|[ \t\n\r\v\f]+$/g, "");
  if (/[^\x00-\x7f]/.test(trimmed)) {
    throw new TenantHashError(`invalid tenant name ${JSON.stringify(trimmed)} (non-ASCII input)`);
  }
  const cleaned = trimmed.toLowerCase();
  if (!cleaned) throw new TenantHashError("tenant name cannot be empty");
  if (RETIRED_TENANTS.has(cleaned)) {
    throw new RetiredTenantError(
      `tenant '${cleaned}' is a retired legacy typo; the canonical tenant is '${CANONICAL_TENANT}'`,
    );
  }
  if (!TENANT_RE.test(cleaned)) {
    throw new TenantHashError(`invalid tenant name '${cleaned}'`);
  }
  return cleaned;
}

export function deriveTenantHash(tenant: string, salt: string): string {
  const cleaned = normalizeTenant(tenant);
  if (!salt) throw new SaltUnavailableError("EAP salt cannot be empty");
  return createHash("sha256").update(`${salt}:${cleaned}`, "utf8").digest("hex").slice(0, 8);
}

type Env = Record<string, string | undefined>;

export async function resolveSalt(
  env: Env = process.env,
  fetchImpl: typeof fetch = fetch,
): Promise<string> {
  const addr = env.BAO_ADDR || env.VAULT_ADDR || env.OPENBAO_ADDR;
  const token = env.BAO_TOKEN || env.VAULT_TOKEN;
  if (addr && token) {
    try {
      const res = await fetchImpl(`${addr.replace(/\/+$/, "")}/v1/secret/data/signalloom/eap`, {
        headers: { "X-Vault-Token": token },
        signal: AbortSignal.timeout(2000),
      });
      if (res.ok) {
        const salt = (await res.json())?.data?.data?.salt;
        if (typeof salt === "string" && salt) return salt;
      }
    } catch {
      // Unreachable or malformed: fall through to the env salt.
    }
  }
  if (env.SIGNAL_LOOM_EAP_SALT) return env.SIGNAL_LOOM_EAP_SALT;
  throw new SaltUnavailableError(
    "EAP salt unavailable: provision secret/signalloom/eap in OpenBao or set SIGNAL_LOOM_EAP_SALT",
  );
}
