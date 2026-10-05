# Runbook — observation-policy regression replay

> SLAWS v2 §3, D2, D6, ISC-55. Owner: Signal Loom platform.
> Code: `d2-signalloom/apps/signal-ingest/policy/replay.go`.

## What this is for

`signal-ingest replay` re-evaluates observations already in the signal store
through **the same stage 1 and stage 2 code the live sink runs**, with the clock
replaced by observation timestamps, and writes the canonical finding and
decision projection to a file.

Three questions it answers:

1. **Did a bundle change alter detection?** Replay the same window with the old
   bundle tree and the new one, and diff the two output files.
2. **What would a candidate rule have found?** Replay the backlog with a bundle
   tree that is not deployed.
3. **Is the pipeline still deterministic?** Replay twice and diff. Any
   difference is a defect, not a timing artefact.

It is **not** a backfill. Replay writes nothing to the store — findings go to the
output file only. Running it cannot change what the live pipeline has already
recorded, and cannot change the input of the next replay.

## The command

```bash
signal-ingest replay \
  --bundles /etc/policy-engine/bundles \
  --from 2026-10-02T00:00:00Z \
  --to   2026-10-03T00:00:00Z \
  --tenant kusari \
  --out /tmp/replay-kusari.txt
```

| Flag | Required | Meaning |
| :--- | :--- | :--- |
| `--bundles` | no | Bundle tree to replay **with**. Defaults to `/etc/policy-engine/bundles`, the ConfigMap mount. An empty or missing directory is zero bundles and an empty output, not an error. |
| `--from` | yes | Start of the observation range, RFC3339. Inclusive. |
| `--to` | yes | End of the range, RFC3339. Must be after `--from`. |
| `--tenant` | no | Restrict to one tenant. Omit to replay every tenant the store holds. |
| `--out` | yes | Output file. Overwritten. |

Exit codes: `0` success, `1` runtime failure (store, bundle load, write), `2`
bad arguments.

The store is whatever `SIGNAL_STORE` / `SIGNAL_STORE_DIR` select, the same as
for the server, so a replay reads the same data the service writes. Against a
FrostDB store on a PVC, run it in a pod with that PVC mounted.

## Output format

Sorted canonical finding lines, then sorted canonical decision lines, one per
line, pipe-delimited.

```
<finding id>|<timestamp>|<tenant>|<actor>|<rule id>|<bundle>@<version>|<severity>|<source obs id>|<k=v>...
<decision id>|<timestamp>|<tenant>|<actor>|<window id>|<rule id>|<bundle>@<version>|<severity>|<mode>|<count>|<finding ids>
```

The finding projection is `obscel.CanonicalFinding`; the decision projection is
`policy.CanonicalDecision`. Both are **allowlists**: store-assigned fields
(ingest time, segment offsets) never appear, which is what lets two runs be
compared byte for byte.

Output is sorted, so a difference in the store's read order cannot show up as a
difference in output. An ordering difference that genuinely mattered surfaces as
a different *decision* instead, because the sliding window is sensitive to
arrival order.

## Procedure: did a bundle change alter detection?

```bash
# 1. The deployed tree.
signal-ingest replay --bundles /etc/policy-engine/bundles \
  --from 2026-10-02T00:00:00Z --to 2026-10-03T00:00:00Z --out /tmp/before.txt

# 2. The candidate tree (a git checkout of policy/bundles at the new revision).
signal-ingest replay --bundles /tmp/candidate-bundles \
  --from 2026-10-02T00:00:00Z --to 2026-10-03T00:00:00Z --out /tmp/after.txt

# 3. The answer.
diff /tmp/before.txt /tmp/after.txt
```

Reading the diff:

- **No output** — the change is detection-neutral over that window. Promote it.
- **Lines only in `after.txt`** — new detections. Confirm each is intended.
- **Lines only in `before.txt`** — detections **lost**. This is the dangerous
  direction and needs an explicit justification on the commit.
- **A finding ID changed but nothing else did** — the bundle `version` was
  bumped. `Finding.ID` hashes the bundle version by design, so every finding
  gets a new identity on a version bump. Expected, and the reason a version
  bump and a rule change should be separate commits where possible.

## Procedure: prove the pipeline is deterministic

```bash
signal-ingest replay --bundles /etc/policy-engine/bundles \
  --from 2026-10-02T00:00:00Z --to 2026-10-03T00:00:00Z --out /tmp/a.txt
signal-ingest replay --bundles /etc/policy-engine/bundles \
  --from 2026-10-02T00:00:00Z --to 2026-10-03T00:00:00Z --out /tmp/b.txt
cmp /tmp/a.txt /tmp/b.txt && echo DETERMINISTIC
```

Any difference is a defect. The usual causes, in order of likelihood: a
`time.Now()` that reached a finding or a decision; a map iterated without
sorting; a rule whose evaluation depends on something outside the observation.

## Replay equals live

`policy/replay_test.go` asserts byte equality between a live ingest of the AWS
fixture corpus and a replay over the same store, including decisions, and
separately over a store that holds the corpus in reverse timestamp order.

One honest limit on that oracle, because it shapes how much the green bar is
worth: the equality test compares the **same** canonical projection on both
sides, so it is sensitive to live-versus-replay differences and *not* to a bug
in the shared projection itself — such a bug cancels. The line-count and
finding/decision-count assertions in the same file are what cover that case.

## Warm-up versus replay

Two different readers of the store, and they are not interchangeable:

| | Warm-up | Replay |
| :--- | :--- | :--- |
| When | Once at boot | On demand |
| Reads | Findings, over the longest declared window | Raw observations, over the given range |
| Emits | Nothing — rebuilds counters only | Canonical lines to a file |
| Writes to the store | No | No |

Warm-up exists so a restart mid-burst does not lose a counter. It deliberately
does **not** re-alert history: the edge-trigger latch is set, not fired.

A stored finding carries the closed policy label set plus the label values every
window over its rule keys on. So a window keyed on a `labels.<key>` dimension
rebuilds faithfully.

This was not always true, and the old failure was worse than it looked. Every
warmed finding read an empty value for that dimension. They then landed in a
counter keyed on the empty string, which no live finding can ever join. Warm-up
contributed nothing and a restart **missed** the burst it was warmed to catch.

One row-level case remains. A finding written by an older binary, or read from a
v1 segment, carries no such label. Warm-up counts those rows and names the count
in its completion log rather than passing over them.

## Troubleshooting

| Symptom | Cause |
| :--- | :--- |
| Empty output file, exit 0 | Zero bundles loaded (check the log for the warning naming the directory), or no observations in the range, or `--tenant` does not match the `tenant_id` label. |
| `non-conformant bundle` | A rule does not compile. Fail-closed by design: a half-loaded policy set is indistinguishable from one that chose not to detect. Fix the rule named in the error. |
| `--from ... is not RFC3339` | Use `2026-10-02T00:00:00Z`, not `2026-10-02`. |
| Findings but no decisions | Expected unless the corpus crosses a declared threshold inside a declared window. Check the window's `threshold` and `window` against the data. |
| Replay differs from live | Check the actor first, then investigate as a determinism defect. See "the actor is a pseudonym". |
| Allowlisted identity produces findings on every record | A bundle var holding actor identities is missing from `actor_vars`. The list stayed cleartext and can never match the pseudonym. Live and replay agree, so replay will not catch this. |

## The actor is a pseudonym

`obs.actor` is the keyed pseudonym of the actor, on the live path and on replay
alike. A segment-schema-v2 segment stores no cleartext actor column, so a replay
has nothing else to read.

This matters when a replay disagrees with live, because the actor is the first
thing to check and it used to be the cause. Replay read those rows, saw an empty
actor, and every allowlist inverted. Allowlists are written as negative tests, so
an empty actor satisfies them. Exempted identities fired and true positives were
lost. On the Kusari corpus live produced 62 findings and 3 decisions, replay
produced 64 and 2.

Two rules follow for anyone writing a bundle.

1. Name every var holding actor identities under `actor_vars`. Those lists are
   rewritten into the pseudonym space at load. Omitting one leaves it cleartext,
   so a negative allowlist test becomes always true. `Conform` refuses a rule
   comparing `obs.actor` against an undeclared var, so this fails at load.
2. Compare `obs.actor` with equality or membership only. It has no internal
   structure. A rule needing part of an identifier reads a projected label, as
   `cross-account-assume-role` reads `actor_account_id`.

## Related

- Bundle governance and the shipped bundle: `policy/bundles/kusari/iam-change.yaml`
- Vocabulary and determinism contract: `d2-signalloom/pkg/obscel/doc.go`
- Pipeline shape and what it may not do: `d2-signalloom/apps/signal-ingest/policy/doc.go`
- Proposal: `docs/Proposal — Signal Loom AWS Telemetry Ingest & Multilayer Policy Engine Beta (2026-Q3).md` §3, §4, D2, D5, D6
