# cra v1.0 — agent context

Every check in this pack reads `agent` only. No check reads `object` or
`request`, so the pack is out of scope for the Pod Security Admission oracle.
Shipped paths are frozen: extend, never rename.

Every path is `has()`-guarded **and** every container read is
`type(x) == map`-guarded. An absent path fails the check instead of erroring,
and so does a wrongly-typed one. See "Container types" below for why that
second guard is not decoration.

| Path | Type | Check | Required value |
|------|------|-------|----------------|
| `agent.security_profile` | map | `default-secure-configuration` | must be a map |
| `agent.security_profile.secure_by_default` | bool | `default-secure-configuration` | `true` |
| `agent.sbom` | map | `sbom-verified-provenance` | must be a map |
| `agent.sbom.format` | string | `sbom-verified-provenance` | exactly `CycloneDX` or `SPDX` |
| `agent.sbom.verified` | bool | `sbom-verified-provenance` | `true` |
| `agent.provenance` | map | `signed-cryptographic-updates` | must be a map |
| `agent.provenance.slsa_level` | string | `signed-cryptographic-updates` | exactly `SLSA_LEVEL_3` |

## Absent-field semantics

An absent `agent` entirely, an absent container, or an absent leaf all produce
`fail`, never `error`. Here `celBindings` binds a missing input to an empty map,
and each expression leads with `has()`. Fixtures pin all three positions
(`--no-agent-context`, `--flag-absent` / `--format-absent` / `--verified-absent`
/ `--level-absent`).

## Container types

The three container reads are each guarded with `type(x) == map`, matching the
`finos-aigf` pack. This closed a real defect rather than pre-empting a
hypothetical one.

Before the guard, a container supplied as a JSON **list** produced

```
CEL evaluation error: unsupported index type 'string' in list
```

which the engine reports as `error`. An errored check is neither passed nor
failed and carries no exposure. Thus `agent.sbom: [{"format": "CycloneDX",
"verified": true}]` made a critical-severity control vanish from the result
rather than fail it. The asymmetry hid it. A string, a number and `null` in the
same slot all failed gracefully. Three of the four wrong shapes behaved
correctly, and only the list did not.

All four shapes are now pinned for all three containers
(`--<container>-is-a-list`, `--is-a-string`, `--is-a-number`, `--is-null`), so
the asymmetry cannot return silently. Mutation-proved: removing the three
guards turns exactly the three `-is-a-list` fixtures red.

## Scalar types

Scalars are not `type()`-guarded because they do not need to be — a scalar of
the wrong type already fails. Pinned so that remains true:

| Fixture | Input | Verdict |
|---------|-------|---------|
| `default-secure-configuration--flag-not-bool` | `secure_by_default: "true"` | fail |
| `sbom-verified-provenance--verified-not-bool` | `verified: "true"` | fail |
| `sbom-verified-provenance--format-numeric` | `format: 1` | fail |
| `signed-cryptographic-updates--slsa-level-numeric` | `slsa_level: 3` | fail |

## Comparison semantics worth knowing

Both are pinned by fixtures and both are deliberate. Changing either changes
what the pack claims to an auditor, so neither was "fixed".

- **`format` is case-sensitive.** `cyclonedx` fails where `CycloneDX` passes
  (`--format-lowercase`). The CRA itself mandates no format at all — see
  `../README.md` — so the allow-list and its spelling are this pack's choice.
- **`slsa_level` is equality, not a threshold.** `SLSA_LEVEL_4` **fails** a
  control it exceeds (`--slsa-level-4`).

## What these values are

All seven paths are assertions the assessed subject makes about itself. No
check parses an SBOM, verifies a signature, or inspects provenance material.
Instead, `sbom.verified` and `provenance.slsa_level` are self-asserted labels. The
difference between that and evidence, per check and against the cited CRA
obligation, is set out in `../README.md` under "Evidence or proxy".
