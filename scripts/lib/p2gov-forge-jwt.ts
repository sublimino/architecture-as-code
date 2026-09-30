#!/usr/bin/env bun
// @id scripts/lib/p2gov-forge-jwt.ts
// @target scripts/test-phase2-governor.sh (negative trust-domain probes)
// @tests test/phase2-governor-verification.bats
//
// SLDC-P2-GOV: mint an ES256 JWT that looks like a JWT-SVID but is signed by a
// throwaway P-256 key that no SPIRE server has ever published. Used only as
// the attacker's token in fail-closed probes: a rogue trust domain
// (spiffe://rogue.local/...) or a correctly-named osramp.local subject whose
// signature no federated key can verify.
//
// Usage: bun scripts/lib/p2gov-forge-jwt.ts <sub> <aud> [ttlSeconds]
// Prints the compact JWS on stdout. The private key never leaves memory.

const [sub, aud, ttlArg] = process.argv.slice(2);
if (!sub || !aud) {
  console.error("usage: p2gov-forge-jwt.ts <sub> <aud> [ttlSeconds]");
  process.exit(2);
}
const ttl = Number(ttlArg ?? "300");
if (!Number.isInteger(ttl) || ttl <= 0) {
  console.error(`ttlSeconds must be a positive integer, got ${ttlArg}`);
  process.exit(2);
}

const b64url = (buf: ArrayBuffer | Uint8Array) =>
  Buffer.from(buf instanceof Uint8Array ? buf : new Uint8Array(buf)).toString("base64url");

const { privateKey } = await crypto.subtle.generateKey(
  { name: "ECDSA", namedCurve: "P-256" },
  false,
  ["sign", "verify"],
);
const now = Math.floor(Date.now() / 1000);
const header = { alg: "ES256", typ: "JWT", kid: "sldc-p2-gov-rogue" };
const payload = { sub, aud: [aud], iat: now, exp: now + ttl };
const signingInput = `${b64url(new TextEncoder().encode(JSON.stringify(header)))}.${b64url(
  new TextEncoder().encode(JSON.stringify(payload)),
)}`;
// WebCrypto ECDSA emits IEEE P1363 (r||s), which is exactly the JWS ES256 form.
const sig = await crypto.subtle.sign(
  { name: "ECDSA", hash: "SHA-256" },
  privateKey,
  new TextEncoder().encode(signingInput),
);
process.stdout.write(`${signingInput}.${b64url(sig)}\n`);
