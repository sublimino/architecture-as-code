# Plan: Fix GCP project ID in CI scripts

## Context

The GCP project ID was set to `cpdev-ajm` when it should be `cp-dev-ajm`. This is a straight find-and-replace across 3 files (9 occurrences).

## Files to Modify

| File | Occurrences | Change |
|------|-------------|--------|
| `scripts/ci/gcp-ci.sh` | 1 | Default project in `GCP_CI_PROJECT` |
| `scripts/ci/README.md` | 6 | All `--project=` and `add-iam-policy-binding` examples |
| `.github/workflows/signalloom-ci.yaml` | 1 | `GCP_PROJECT` env var |

Also fix the SA email reference in the Security Model comment within `gcp-ci.sh` (line 50 of the prior plan mentioned `signalloom-ci-vm@cpdev-ajm`).

## Change

```
cpdev-ajm  →  cp-dev-ajm
```

`replace_all: true` on each file.

## Verification

```bash
grep -r 'cpdev-ajm' scripts/ci/ .github/workflows/signalloom-ci.yaml
# Expected: no output (zero matches)

grep -r 'cp-dev-ajm' scripts/ci/ .github/workflows/signalloom-ci.yaml
# Expected: 9 matches
```
