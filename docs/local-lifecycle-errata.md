# Local lifecycle errata

## `make up` foundation-only contract (2026-07-27)

Earlier UI, environment-template, and D2-BAO plan language could imply that
`make up` deployed demo workloads. That is incorrect. `make up` creates and
validates only the shared Kind, Zot, signing, Flux, and infrastructure
foundation. Demo ResourceSets remain inactive until an explicit
`make demo-*-up` command is run.

After `make up`, choose one demo command printed by `make demo-help`. In
particular, run `make demo-bao-up` for the OpenBao demo; it is not part of the
shared foundation.
