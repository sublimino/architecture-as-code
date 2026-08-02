/**
 * Cryptographic key-exchange lifecycle reference data — versioned and sourced.
 *
 * Backs the "End of Life" column on the Cipher Discovery (PQC) table in
 * CryptographyPage.tsx. Every entry cites the standards-body guidance its
 * `eolDate` is derived from — do not hand-edit a date without updating
 * `source` to match, and bump this file's version comment when NIST/NSA
 * guidance changes.
 *
 * v1 — 2026-08-02.
 */

export interface CipherLifecycleEntry {
  /** Matches CipherEndpoint.kex in CryptographyPage.tsx exactly. */
  kex: string
  /** Human-readable standard/timeline this cipher is tracked against. */
  standard: string
  /** Scheduled end-of-life / disallowed-after date, or null if none scheduled. */
  eolDate: string | null
  /** Citation for eolDate — the authoritative guidance document. */
  source: string
}

export const CIPHER_LIFECYCLE: CipherLifecycleEntry[] = [
  {
    kex: 'X25519MLKEM768',
    standard: 'FIPS 203 (ML-KEM) hybrid key establishment',
    eolDate: null,
    source: 'NIST FIPS 203 (Aug 2024) — ML-KEM standardised; X25519MLKEM768 hybrid group has no scheduled deprecation',
  },
  {
    kex: 'X25519 + ML-KEM-768',
    standard: 'FIPS 203 (ML-KEM) hybrid key establishment',
    eolDate: null,
    source: 'NIST FIPS 203 (Aug 2024) — ML-KEM standardised; X25519 + ML-KEM-768 hybrid group has no scheduled deprecation',
  },
  {
    kex: 'ECDHE P-256',
    standard: 'NIST SP 800-131A Rev. 2 / NSA CNSA 2.0',
    eolDate: '2030',
    source:
      'NIST SP 800-131A Rev. 2 (Mar 2019), Table 8 — 128-bit-security-strength classical curves (incl. P-256 key establishment) disallowed after 2030; NSA CNSA 2.0 Advisory (Sept 2022, rev. 2024) requires PQC-only key establishment for National Security Systems by 2033',
  },
]

/** Look up lifecycle data for a cipher's key-exchange string. Returns undefined for unknown ciphers. */
export function cipherLifecycle(kex: string): CipherLifecycleEntry | undefined {
  return CIPHER_LIFECYCLE.find((entry) => entry.kex === kex)
}
