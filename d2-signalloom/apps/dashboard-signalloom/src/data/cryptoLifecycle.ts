/**
 * Cryptographic algorithm/cipher lifecycle reference data — versioned and sourced.
 *
 * Single source of truth for the "End of Life" columns on both the Cipher
 * Discovery (PQC) table and the Algorithm Inventory table in
 * CryptographyPage.tsx — one entry per underlying cryptographic primitive,
 * matched against every dashboard string (kex name or algorithm name) that
 * refers to it via `aliases`, so the two tables can never disagree about the
 * same fact. Every entry cites the standards-body guidance its `eolDate` is
 * derived from — do not hand-edit a date without updating `source` to match,
 * and bump this file's version comment when NIST/NSA guidance changes.
 *
 * v2 — 2026-08-02. Corrects v1: the 2030 "disallowed" date v1 cited to NIST
 * SP 800-131A Rev. 2 for RSA-2048 / P-256 / P-384 / X25519 does not exist in
 * that finalized (currently in-force, Mar 2019) document — no disallowance
 * date for these algorithms appears there at all. The 112-bit/128-bit,
 * 2030-cutoff framework v1 was actually describing lives only in the
 * still-draft SP 800-131A Rev. 3 (Initial Public Draft, Oct 2024, not yet
 * finalized as of Aug 2026). The correct authoritative source for a
 * quantum-migration EOL is NIST IR 8547 (Initial Public Draft, Nov 2024,
 * also still a draft but treated as an effective federal compliance
 * deadline under Executive Order 14412 and OMB M-26-15): it disallows all
 * quantum-vulnerable public-key algorithms (RSA, ECDSA, ECDH, DSA, FFDH)
 * after 2035, with an earlier 2030 "deprecated for new deployments"
 * milestone that applies only to sub-128-bit-strength algorithms (RSA-2048).
 * P-256/P-384/X25519 meet the 128-bit floor and so are not additionally
 * flagged at 2030 — they carry the same flat 2035 disallowance as RSA-2048,
 * not an earlier one. Net effect: every classical asymmetric entry in this
 * file moves from 2030 to 2035, and the standard cited moves from NIST SP
 * 800-131A to NIST IR 8547.
 */

export interface CryptoLifecycleEntry {
  /** Short canonical identifier for this primitive. */
  id: string
  /** Every kex string (CipherEndpoint.kex) or algorithm name (AlgorithmEntry.algorithm) that resolves to this entry. */
  aliases: string[]
  /** The construction/definition standard for this primitive (distinct from the lifecycle-timeline source below). */
  standard: string
  /** Scheduled disallowed-after date, or null if none scheduled. */
  eolDate: string | null
  /** Citation for eolDate — the authoritative guidance document, plus what it supersedes. */
  source: string
}

export const CRYPTO_LIFECYCLE: CryptoLifecycleEntry[] = [
  {
    id: 'ml-kem',
    aliases: ['ML-KEM (Kyber)', 'X25519MLKEM768', 'X25519 + ML-KEM-768'],
    standard: 'FIPS 203',
    eolDate: null,
    source:
      'NIST FIPS 203 (Aug 2024) — ML-KEM standardised as the PQC key-establishment replacement; no scheduled EOL. Hybrid groups combining it with classical X25519 are the recommended migration target and are expected to remain permitted even after classical-only key establishment is disallowed (NIST IR 8547 IPD, hybrid discussion).',
  },
  {
    id: 'ml-dsa',
    aliases: ['ML-DSA (Dilithium)'],
    standard: 'FIPS 204',
    eolDate: null,
    source: 'NIST FIPS 204 (Aug 2024) — ML-DSA standardised as the PQC signature replacement; no scheduled EOL.',
  },
  {
    id: 'slh-dsa',
    aliases: ['SLH-DSA (SPHINCS+)'],
    standard: 'FIPS 205',
    eolDate: null,
    source: 'NIST FIPS 205 (Aug 2024) — SLH-DSA standardised as the hash-based PQC signature backup; no scheduled EOL.',
  },
  {
    id: 'rsa-2048',
    aliases: ['RSA-2048'],
    standard: 'NIST IR 8547 (Initial Public Draft, Nov 2024)',
    eolDate: '2035',
    source:
      "NIST IR 8547 IPD — RSA at 112-bit security strength (RSA-2048) is deprecated for new deployments after 2030 and disallowed after 2035; Executive Order 14412 and OMB M-26-15 (2026) treat this as an effective compliance deadline for federal systems. Supersedes this dashboard's earlier citation of NIST SP 800-131A for a 2030 disallowance: the finalized Rev. 2 (Mar 2019, currently in force) sets no disallowance date for RSA-2048 at all — that framework is only proposed in the still-draft SP 800-131A Rev. 3 (IPD, Oct 2024).",
  },
  {
    id: 'ecdsa-ecdh-p256',
    aliases: ['ECDSA P-256', 'ECDH P-256', 'ECDHE P-256'],
    standard: 'NIST IR 8547 (Initial Public Draft, Nov 2024)',
    eolDate: '2035',
    source:
      "NIST IR 8547 IPD — ECDSA/ECDH are quantum-vulnerable (broken by Shor's algorithm) regardless of curve size, so P-256 (128-bit classical strength) is disallowed after 2035 alongside 112-bit RSA; it carries no earlier 2030 'deprecated' milestone, since that applies only to sub-128-bit strength. Supersedes this dashboard's earlier citation of NIST SP 800-131A for a 2030 disallowance: the finalized Rev. 2 places 128-bit-strength curves in its 'acceptable, no scheduled disallowance' category, and the still-draft Rev. 3 explicitly keeps them out of its 2030 cutoff too.",
  },
  {
    id: 'ecdsa-p384',
    aliases: ['ECDSA P-384'],
    standard: 'NIST IR 8547 (Initial Public Draft, Nov 2024)',
    eolDate: '2035',
    source:
      "NIST IR 8547 IPD — ECDSA is quantum-vulnerable regardless of curve size; P-384 (192-bit classical strength) is disallowed after 2035 along with every other ECDSA curve. Supersedes this dashboard's earlier citation of NIST SP 800-131A for a 2030 disallowance: the finalized Rev. 2 schedules no disallowance for 192-bit-strength algorithms.",
  },
  {
    id: 'x25519',
    aliases: ['X25519'],
    standard: 'RFC 7748 / NIST SP 800-186',
    eolDate: '2035',
    source:
      "NIST IR 8547 IPD groups elliptic-curve Diffie-Hellman (ECDH) as quantum-vulnerable regardless of curve; X25519 (RFC 7748, NIST-recognised since SP 800-186, 2023) is an ECDH construction and is disallowed after 2035 on the same basis as NIST-curve ECDH. Supersedes this dashboard's earlier citation of NIST SP 800-131A for a 2030 disallowance: the finalized Rev. 2 sets no disallowance for 128-bit-strength key establishment.",
  },
  {
    id: 'aes-256',
    aliases: ['AES-256'],
    standard: 'FIPS 197',
    eolDate: null,
    source:
      "NIST FIPS 197 — symmetric-key algorithm, not subject to Shor's algorithm. Grover's algorithm only halves its effective strength (to ~128-bit-equivalent), which remains adequate; AES-256 is outside NIST IR 8547's quantum-vulnerable public-key algorithm list (RSA, ECDSA, ECDH, DSA, FFDH).",
  },
]

/** Look up lifecycle data by any known kex string or algorithm name. Returns undefined if not tracked. */
export function cryptoLifecycle(name: string): CryptoLifecycleEntry | undefined {
  return CRYPTO_LIFECYCLE.find((entry) => entry.aliases.includes(name))
}
