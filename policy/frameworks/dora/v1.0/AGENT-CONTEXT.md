# dora v1.0 — agent and request context

This pack is a placeholder (`status: placeholder` at both the framework and the
check level). Its single check is the literal `false`, it reads no input, and
it is never evaluated. The engine reports `not_evaluated` for it and excludes
it from the failed, errored and exposure totals.

**No `agent`, `object` or `request` path is defined, and none may be added
without a real check to read it.** There is therefore nothing here to freeze
and nothing to guard.

If this pack is ever built out, the conventions it must adopt are in
`../../cra/v1.0/AGENT-CONTEXT.md`. Use `has()` before every read and
`type(x) == map` before every container read. Pin all four wrong container
shapes by fixtures. Also provide a calibrated `freqTriple` or an explicit row in
`../../cra/catalogue/unpriced.tsv`.

Why there is nothing to read yet, and which DORA articles could be evidenced
honestly: `../README.md`.
