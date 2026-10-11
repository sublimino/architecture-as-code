# nist-800-53

Three strictness tiers of a NIST SP 800-53 Rev 5 pack over Kubernetes workload
shape plus, in v2.1, agent and request context.

| Version | Checks | Priced | Control references | Anchored |
|---------|-------:|-------:|-------------------:|----------|
| v1.0    | 11     | 0      | 11                 | yes |
| v2.0    | 27     | 0      | 27                 | yes |
| v2.1    | 14     | 14     | 9                  | yes |

## Ground truth

Unlike CIS Kubernetes, whose §5 recommendations are prose only, SP 800-53 is
published by NIST as OSCAL JSON. Every control identifier and title in this
pack is therefore machine-anchored, not asserted.

- `catalogue/nist-sp-800-53-rev5-ids.tsv` — 1196 control IDs and titles from
  catalog uuid `ea7c7688-79c5-463b-a91b-0650f2d98623` (`metadata.version`
  5.2.0). Provenance and regeneration: `catalogue/PROVENANCE.md`.
- `catalogue/anchor-test.sh` — every reference resolves, every stated title
  matches exactly, every identifier's family matches its control set.
- `catalogue/pricing-test.sh` — every check is priced or explicitly declared
  unpriced in `catalogue/unpriced.tsv`.
- `catalogue/run-tests.sh` — both of the above.

Result: **no fabricated control identifiers.** All 47 references across the
three versions resolve. One title drift was found and fixed (v2.1 `IA-2`).

## Open findings

Two findings are structural, are not defects in any single check, and are not
this pack's to decide. Both are recorded here because the numbers a customer
reads depend on them.

### 1. v1.0 and v2.0 report zero exposure, always

All 11 checks in v1.0 and all 27 in v2.0 declare a loss-magnitude
`riskTriple` but **no `freqTriple`**. `fair.Simulate` multiplies magnitude by
a frequency drawn from that triple, so every one of those 38 checks prices at
exactly £0.00 and a scan of either version reports zero total exposure with
every control failing. That is 38 of the 66 silently-zero checks across the
whole estate — the largest single contribution, because this is the largest
pack.

v2.1 is unaffected: its 14 checks carry frequency triples and price at
£1,317,319.03 in the committed golden.

No frequency triples have been invented to close this. Calibrating how often a
NIST 800-53 control fails per year is a principal decision, and a number made
up to turn a zero into a non-zero would be worse than the zero because it
would look like evidence. What has changed is that the silence is no longer
possible: the 38 checks are now explicitly declared unpriced in
`catalogue/unpriced.tsv`, and `catalogue/pricing-test.sh` fails any check that
is neither priced nor declared, fails a declaration whose check has since been
calibrated, and fails a declaration naming a check that no longer exists.

**Decision needed:** calibrate frequency triples for v1.0 and v2.0, or accept
that those tiers are compliance-only and carry no monetary figure.

### 2. v2.1 is not a superset of v2.0 — it is a different pack

`policy/frameworks/README.md` describes the v2.1 tier as "workload checks plus
agent and request governance", which reads as v2.1 ⊇ v2.0. It is not.

- v2.0 ⊇ v1.0 holds. v2.0 adds 16 checks and loses none.
- **v2.1 drops 20 of v2.0's 27 checks** and adds 7. It keeps only
  `no-automount-sa-token`, `container-run-as-non-root`,
  `no-privilege-escalation`, `no-privileged-mode`, `read-only-rootfs`,
  `drop-all-capabilities`, `trusted-registry`.
- Dropped: `pod-security-context`, `no-host-network`, `no-host-pid`,
  `app-label`, `version-label`, `resource-limits-set`,
  `resource-requests-set`, `managed-by-label`, `env-label`,
  `tls-annotation`, `seccomp-profile`, `encryption-annotation`,
  `vuln-scan-annotation`, `liveness-probe-present`,
  `readiness-probe-present`, `audit-label`, `log-volume-mount`,
  `log-format-annotation`, `owner-label`.
- **v2.1 is not even a superset of v1.0**: it drops `app-label`,
  `version-label`, `resource-limits-set`, `audit-label`, and renames
  `image-digest-required` to `image-digest`.

The losses are not cosmetic. `seccomp-profile`, `no-host-network` and
`no-host-pid` are the pod-isolation checks; a workload that moves from the
v2.0 tier to the "Strict" v2.1 tier stops being checked for host namespace
sharing and seccomp entirely. The rename also means a consumer tracking
`image-digest-required` across versions silently loses the check at v2.1
rather than seeing it fail.

**Decision needed:** either v2.1 absorbs v2.0's workload checks (making the
tier doctrine true), or the tier table stops describing v2.1 as additive and
names it a differently-scoped agent-governance pack. This pack cannot fix the
doctrine line itself — `policy/frameworks/README.md` is outside it.

### 3. Identifiers that resolve but are the wrong control

Anchoring proves an identifier exists; it cannot prove it is the right one.
These mappings misdescribe what the check measures. None has been renumbered —
changing a control identifier changes what the pack claims to an auditor.

| Check | Mapped to | Catalogue title | Better fit |
|-------|-----------|-----------------|------------|
| `no-privilege-escalation` | AC-6(1) | Authorize Access to Security Functions | AC-6 or CM-7 |
| `no-privileged-mode` | AC-6(2) | Non-privileged Access for Nonsecurity Functions | SC-39 or AC-6 |
| `version-label` | CM-8(1) | Updates During Installation and Removal | CM-8 |
| `env-label` | CM-3(1) | Automated Documentation, Notification, Prohibition of Changes | CM-8 |
| `drop-all-capabilities` | SC-7 | Boundary Protection | CM-7 |
| `read-only-rootfs` (v1.0, v2.0) | SC-28 | Protection of Information at Rest | CM-7 — v2.1 already does this |
| `log-volume-mount` | AU-3 | Content of Audit Records | AU-4 |
| `mfa-spiffe-svid-required` | IA-2 | Identification and Authentication (Organizational Users) | IA-9 |

`AC-6(1)` and `AC-6(9)` are distinct controls with distinct statements and
neither is a synonym for `AC-6`; the anchor test keys them separately for that
reason.

Two naming defects, where the mapping is right and the check's own identity
overclaims:

- `immutable-audit-sink` evaluates `event_logging_enabled == true`. That is
  AU-2 (Event Logging) and the mapping is correct, but the id promises
  immutability, which is AU-9 (Protection of Audit Information). Nothing in the
  pack evidences AU-9. A report line reading `immutable-audit-sink: pass` will
  be read as AU-9 satisfied.
- `mfa-spiffe-svid-required` evaluates `svid_presented == true` — a single
  credential. Multifactor is IA-2(1) and is not evidenced.

### 4. Self-asserted flags are proxies, not evidence

Four of v2.1's new checks reduce to reading a boolean the assessed subject
supplies: `immutable-audit-sink`, `anomaly-detection-telemetry`,
`mfa-spiffe-svid-required`, `network-boundary-enforcement`. They cannot
distinguish a monitored workload from one that sets `monitoring_active: true`.
SI-4 requires detecting attacks; a flag saying monitoring is on is not that.
These become evidence only when the envelope is populated by an attesting
control plane rather than by the workload, and the pack does not record which
it is. `cross-namespace-egress-authorization` and `spiffe-peer-authorization`
compute over structured input instead and are materially stronger — the former
is the soundest check in v2.1.

### 5. Controls not evidenced anywhere

Stated so the gap is explicit: AU-9 (protection of audit information), AU-10
(non-repudiation), AU-4 (audit log storage capacity), IA-9 (service
identification), IA-2(1) (multifactor), and `spec.hostIPC` — v2.0 checks
`hostNetwork` and `hostPID` but not `hostIPC`, and v2.1 checks none of the
three.

### 6. Not fixed: `hostIPC` is unchecked in every version

PSS treats `hostNetwork`, `hostPID` and `hostIPC` as one Host Namespaces
control. v2.0 checks two of the three; **`hostIPC: true` alone passes every
version of this pack**, and v2.1 checks none of the three. Sharing the host IPC
namespace exposes host shared memory and semaphores, and PSS baseline forbids
it.

The fix is a `no-host-ipc` check with
`has(object.spec) && !(has(object.spec.hostIPC) && object.spec.hostIPC == true)`
mirroring `no-host-pid`, plus `--set-true` / `--set-false` / `--field-absent`
fixtures and an `unpriced.tsv` line. It was built and mutation-proved, then
**reverted**, because it cannot land from inside this pack alone:

- `frameworks/loader_test.go:705` asserts v2.0 has exactly 27 checks; a 28th
  fails it, and Go code is outside this pack.
- the PSA oracle's `hostNamespaces` group maps `no-host-network + no-host-pid`
  by name, so it would not consult a new check and the
  `apk-probe-host-ipc-only` divergence would persist regardless.

Both are one-line changes for whoever owns those files. Until then the gap is
real and recorded here rather than silently closed.

## Container-list scope

Security checks evaluate `containers + initContainers + ephemeralContainers`,
and fixtures cover all three positions. The resource and probe checks
deliberately do not: the Kubernetes API **forbids** `resources`,
`livenessProbe` and `readinessProbe` on ephemeral containers, and probes on
non-sidecar init containers. Requiring them there would produce a check no
admissible pod could pass — the mirror image of the admissibility error.
Per-version detail in each `AGENT-CONTEXT.md`.

## Pricing coverage

The table below is produced from `framework.json`. It is not typed by hand.
`make policy-pricing-counts` fails if it drifts from the packs.

A check is priced when its `freqTriple` has a non-zero `min`, `mode`, or `max`.
A check with no frequency triple, or an all-zero one, is unpriced. An unpriced
check contributes GBP 0.00 to every reported total however often it fails. That
state is allowed, because a loss magnitude with no calibrated frequency is not a
price. It is not a small-print detail, because a reader who adds up a scan gets
a total over the priced checks only.

### What these figures are a share of

A `riskTriple` mode here is the **attributable share of one loss event assigned
to one failed control**. It is not the cost of the loss event. Published
single-event loss medians sit one to two orders of magnitude above these modes
(IRIS 2022, <https://www.cyentia.com/iris-2022/>). The event-level figures are
the `SCN-*` magnitudes in [`risk/org/acme.yaml`](../../../risk/org/acme.yaml).

Every priced check carries a derivation entry in `v2.1/CALIBRATION.md`. It
names the anchor classes behind both triples, the scenario the check is a share
of, and a confidence letter. The registry is [ANCHORS.md](../ANCHORS.md).
Statutory ceilings are a `max` and never a `mode`, and they are in
[PENALTIES.md](../PENALTIES.md).

`no-automount-sa-token` is the estate's stated template. Credential exposure is
the only control family with strong published attribution, through
`AC-ATTRIB-CRED`. Its frequency triple of 0.5, 1.5 and 4.0 sits inside the
researched range for that family.

Read [the calibration statement](../README.md#the-calibration-statement) before you quote
any figure in this table or any figure the engine produces from this pack.

<!-- pricing-counts:begin -->
| Version | Checks | Priced | Unpriced | Placeholder |
| :--- | ---: | ---: | ---: | ---: |
| `v1.0.0` | 14 | 0 | 14 | 0 |
| `v2.0.0` | 28 | 0 | 28 | 0 |
| `v2.1.0` | 17 | 14 | 3 | 0 |
| **Pack total** | **59** | **14** | **45** | **0** |

An unpriced check contributes GBP 0.00 to every total however often it
fails. Of 59 check(s) on this page, 14 are priced and 45 are not.
Written by `policy/frameworks/pricing-counts-test.sh`. Do not edit by hand.
<!-- pricing-counts:end -->
