# nis2 v1.0 — agent and request context

This pack is a placeholder (`status: placeholder` at both the framework and the
check level). Its single check is the literal `false`, it reads no input, and
it is never evaluated — the engine reports `not_evaluated` for it and excludes
it from the failed, errored and exposure totals.

**No `agent`, `object` or `request` path is defined, and none may be added
without a real check to read it.** There is therefore nothing here to freeze
and nothing to guard.

If this pack is ever built out, the conventions it must adopt are in
`../../cra/v1.0/AGENT-CONTEXT.md`: `has()` before every read, `type(x) == map`
before every container read, all four wrong container shapes pinned by
fixtures, and a calibrated `freqTriple` or an explicit row in
`../../cra/catalogue/unpriced.tsv`.

One specific warning for whoever does it. The only Article 21(2) measure with a
real technical surface is point (j), "the use of multi-factor authentication or
continuous authentication solutions". The `nist-800-53` pack already contains
the mistake to avoid: its `mfa-spiffe-svid-required` check evaluates
`svid_presented == true` — a single credential — and its id claims multifactor.
A check named for MFA must evidence two factors or be named for what it reads.

Why there is nothing to read yet, and why a NIS2 finding is a claim about
27 national transposing regimes rather than about the Directive:
`../README.md`.
