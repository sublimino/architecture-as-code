# SLSI-P0 — Acceptance Baseline

The Signal Loom Design Partner Appliance Self-Initialisation Pipeline (SLSI) mission starts from the commit recorded here. Every downstream SLSI card (P1-PRE through P3-GOV) diffs against this note instead of re-deriving the baseline.

## Baseline commit

| Field | Value |
| :--- | :--- |
| Commit SHA | `504405b9e7e91efdf5c97bcd701b6511f712f6db` |
| Authored | `2026-10-10T16:11:32+01:00` |
| Subject | `chore: record baseline at 504405b9` |
| Integration branch | `refs/heads/integration/slsi-v0.1.1` → `504405b9e7e91efdf5c97bcd701b6511f712f6db` |
| Task branch | `P0-w1` branched from `504405b9e7e91efdf5c97bcd701b6511f712f6db` |
| Working tree at capture | clean (`git status --porcelain` → 0 lines) |
| Worktree root | `/home/andy/src/.worktrees/32e03/osramp-demo` (1 of 561+ worktrees) |

**Baseline-of-record vs current tip — two distinct hashes, stated explicitly.**
At capture time `integration/slsi-v0.1.1` and the task worktree HEAD were the same object, `504405b9`. P0 commits its baseline evidence onto `P0-w1`; **the `refs/heads/integration/slsi-v0.1.1` ref itself has not moved** — the phase Governor advances it upon certification.

`git merge-base --is-ancestor 504405b9 HEAD` exits 0.

## Environment & Toolchain

### Toolchain Versions

| Tool | Exact Version String |
| :--- | :--- |
| `go` | `go version go1.26.2 linux/amd64` |
| `kubectl` | `Client Version: v1.36.0` |
| `kind` | `kind v0.32.0 go1.26.2 linux/amd64` |
| `flux` | `flux version 2.9.3` |
| `cosign` | `cosign version 3.0.6` |
| `openssl` | `OpenSSL 3.6.2 3 Feb 2026 (Library: OpenSSL 3.6.2 3 Feb 2026)` |
| `jq` | `jq-1.8.1` |
| `envsubst` | `envsubst (GNU gettext-runtime) 0.23.1` |
| `bats` | `Bats 1.13.0` |
| `make` | `GNU Make 4.4.1` |
| `git` | `git version 2.54.0` |
| `docker` | `Docker version 29.9.0, build f415da8` |

### Kubeconfig & Cluster Contexts

- **KUBECONFIG Path:** `/tmp/osramp-kubeconfig.yaml` (`Makefile:15,28` pin)
- **KUBECONFIG SHA256:** `c3186c480f7e91cf5f2d82f1e30a06ea6f3e60c876245f10143b5c47503ff831` (11,152 bytes)
- **Active Contexts:** `kind-osramp` (workload plane) and `kind-signalloom-hub` (control plane)
- **Control Plane Reachability:** Both control planes answer `/readyz` with HTTP 200 `ok`.
- **Node Images:** `kindest/node:v1.36.1` on both clusters.
- **Image Pin Alignment:** `signal-ingest` in `fe-signalloom` runs `zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/signal-ingest:src-e2763e591d984701`, matching `scripts/signal-ingest-image-tag.sh` (`src-e2763e591d984701`).

## Suite Acceptance Results

All suites were executed individually. Totals were deterministically parsed from raw logs and cross-checked against `.status` and `.seconds` sidecars.

| Suite | Exact Command | Pass | Fail | Skip | Duration | Verdict | Attribution |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `test-obscel` | `make test-obscel` | 42 | 0 | 0 | 0.36s | **GREEN** | Base |
| `test-signal-ingest` | `make test-signal-ingest` | 1354 | 0 | 44 | 25.22s | **GREEN** | Base (44 stated skips: DB URLs unset) |
| `cel-conformance` | `cd d2-signalloom/apps/policy-engine && GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache GOPATH=/tmp/gopath CGO_ENABLED=0 go test -run TestConformance -v .` | 776 | 0 | 0 | 0.19s | **GREEN** | Base |
| `test-kusari-e2e` | `make test-kusari-e2e` | 41 | 0 | 0 | 4.30s | **GREEN** | Base (18 plain + 23 frostdb) |
| `docs-lint` | `make docs-lint` | 0 | 21 | 0 | 7.25s | **RED_INHERITED** | Foreign (`cb0a6d0e` `integration/cel-frameworks`) |
| `test-all-offline` | `make test-all-offline` | 1417 | 1 | 0 | 47.11s | **RED_INHERITED** | Base (Offline 2/5 bun install EACCES sandbox symlink) |
| `test-all-cluster` | `make test-all-cluster` | 0 | 1 | 8 | 0.50s | **RED_INHERITED** | Base (assert-bats aborted: namespace/frontend not deployed) |
| `test-all-browser` | `make test-all-browser` | 0 | 1 | 0 | 0.02s | **RED_INHERITED** | Base (test/acceptance/node_modules EACCES sandbox symlink) |
| `test-all-estate` | `make test-all-estate` | 1417 | 1 | 0 | 26.77s | **RED_INHERITED** | Composite (aborted at leg 1 Offline 2/5 bun install) |
| `doctor` | `make doctor` | 1 | 0 | 0 | 0.79s | **GREEN** | Base (`scripts/cluster-debug.sh`) |
| `dual-cluster-containment` | `make test-e2e-dual-cluster-containment` | 4 | 2 | 0 | 196.92s | **RED_INHERITED** | Base (Steps 2, 3, 5, 6 pass; Step 1 rollout timeout, Step 4 actor_id null) |

### Non-Vacuity Proof & Reproducibility

- **Non-Vacuity:** Every green suite executed real assertions (42 in obscel, 1354 in signal-ingest, 776 in CEL conformance, 41 in kusari-e2e). `scripts/check-vacuous-assertions.sh` reported 1 FINDING (VAC007/VAC008 dead allowlist entries), confirming no uninspected passes.
- **Reproducibility (Phase G):** Back-to-back re-run of `test-obscel` and `cel-conformance` with `-count=1` yielded identical totals (obscel: 42 pass; cel-conformance: 776 sub-tests pass). Sorted diff in `docs/slsi-p0-baseline/run2-diff.txt` is **0 bytes**.

## Dual-Cluster Containment Score

`make test-e2e-dual-cluster-containment` executed 6 steps across `kind-osramp` and `kind-signalloom-hub`:

- **Step 1 (FAIL):** Kusari deployment rollout timed out after 180s (`wait_rollout` failure). Cause: Flux has not reconciled the Kusari workload onto the cluster.
- **Step 2 (PASS):** Tenant registration and database claim for tenant `kusari` succeeded in PostgreSQL.
- **Step 3 (PASS):** Provocation endpoint `/act/read-passwd` successfully called on agent pod.
- **Step 4 (FAIL):** Sentinel eBPF probe intercepted syscall, but assertion `[ "$(printf '%s' "$obs" | jq -r '.actor_id')" != "null" ]` failed (actor_id resolved null).
- **Step 5 (PASS):** Pod frozen verified in kernel (`cgroup.events` frozen 1), Flux reconciliation suppressed (`reconcile: disabled`), 0 restarts, and cAdvisor CPU flatlined.
- **Step 6 (PASS):** Authorised recovery via `fleet-manager` on `kind-osramp` processed `/api/v1/fleet/recover` (HTTP 200), retired old pod, and deployed unstunned clean replacement pod.
- **Overall Score:** 4/6 passed (66.7%). Evidence directory: `/tmp/kusari-e2e/20261011-162450`. Detailed in `docs/slsi-p0-baseline/dual-cluster-containment.json`.
- **Note on Brief Expectation (3/6 vs 4/6):** The brief anticipated 3/6 assuming Step 6 would fail due to missing hub fleet-manager. In reality, the test harness targets `fleet-manager` on `kind-osramp` via port-forward (`${K_WORKLOAD}`), where fleet-manager is healthy and successfully executes the authorized recovery.

## Foreign Failures (docs-lint 21 findings)

All 21 failures in `make docs-lint` are pre-existing and foreign to the SLSI board. Every finding originates in commit `cb0a6d0e4a3d6130bf37c101542d0d4a382e16b0` (`merge: integration/cel-frameworks`). Every path begins with `policy/frameworks/`. A 22nd finding or any finding outside `policy/frameworks/**` is an SLSI regression.

| # | File | Line | Rule | Text | Attribution |
| :- | :--- | :--- | :--- | :--- | :--- |
| 1 | `policy/frameworks/CONFORMANCE.md` | 3 | long | 31 words (max 25): A check is "correct" when a fixture that should fail it fails, a fixtu | `cb0a6d0e` |
| 2 | `policy/frameworks/CONFORMANCE.md` | 28 | semicolon | use two sentences: Write numeric comparisons that hold for both int and double (CODE is f | `cb0a6d0e` |
| 3 | `policy/frameworks/CONFORMANCE.md` | 41 | long | 27 words (max 25): A check that errors on an ordinary, valid input is a defect in the che | `cb0a6d0e` |
| 4 | `policy/frameworks/CONFORMANCE.md` | 95 | semicolon | use two sentences:  **mutation**: the change made to the CEL (or fixture) and the failing | `cb0a6d0e` |
| 5 | `policy/frameworks/README.md` | 76 | semicolon | use two sentences:  Every shipped pack is a single CODE; no pack carries a CODE | `cb0a6d0e` |
| 6 | `policy/frameworks/README.md` | 100 | long | 32 words (max 25):  A per-container security control (privileged, privilege escalation, c | `cb0a6d0e` |
| 7 | `policy/frameworks/cis-kubernetes/v1.8/README.md` | 18 | semicolon | use two sentences: "All containers" means CODE, CODE and CODE together; every per-contain | `cb0a6d0e` |
| 8 | `policy/frameworks/cis-kubernetes/v1.8/README.md` | 44 | semicolon | use two sentences: The exemption keys on CODE only; a Windows pod that relies on a CODE n | `cb0a6d0e` |
| 9 | `policy/frameworks/cis-kubernetes/v1.8/README.md` | 51 | semicolon | use two sentences: Per-container checks pass vacuously because nothing runs; pod-level ch | `cb0a6d0e` |
| 10 | `policy/frameworks/cis-kubernetes/v1.8/README.md` | 76 | semicolon | use two sentences: Fixture CODE (4 init + 5 main + 1 ephemeral container, each with 25 en | `cb0a6d0e` |
| 11 | `policy/frameworks/cis-kubernetes/v1.8/README.md` | 76 | long | 38 words (max 25): Fixture CODE (4 init + 5 main + 1 ephemeral container, each with 25 en | `cb0a6d0e` |
| 12 | `policy/frameworks/cis-kubernetes/v1.8/README.md` | 84 | long | 35 words (max 25):  CODE: each fixture is the Linux or Windows baseline with one fact   c | `cb0a6d0e` |
| 13 | `policy/frameworks/eu-ai-act/v2.1/AGENT-CONTEXT.md` | 19 | semicolon | use two sentences:  Only the boolean CODE passes a bool path; the string CODE fails. | `cb0a6d0e` |
| 14 | `policy/frameworks/finos-aigf/v1.0/AGENT-CONTEXT.md` | 17 | semicolon | use two sentences: A container of the wrong type, such as a string or a list, makes its   | `cb0a6d0e` |
| 15 | `policy/frameworks/finos-aigf/v1.0/AGENT-CONTEXT.md` | 17 | long | 32 words (max 25): A container of the wrong type, such as a string or a list, makes its   | `cb0a6d0e` |
| 16 | `policy/frameworks/finos-aigf/v1.0/AGENT-CONTEXT.md` | 61 | semicolon | use two sentences: Extend this document; never rename a field in it. | `cb0a6d0e` |
| 17 | `policy/frameworks/finos-aigf/v1.0/README.md` | 34 | path | no such path in the tree: docs/_config.yml | `cb0a6d0e` |
| 18 | `policy/frameworks/finos-aigf/v1.0/README.md` | 36 | path | no such path in the tree: docs/_includes/mitigation-id.html | `cb0a6d0e` |
| 19 | `policy/frameworks/finos-aigf/v1.0/README.md` | 67 | long | 46 words (max 25): Re-checked against all   25 mitigations at a149dd1e after the cross-ve | `cb0a6d0e` |
| 20 | `policy/frameworks/finos-aigf/v1.0/README.md` | 81 | semicolon | use two sentences: When the key is absent the check now fails; before, it raised an error | `cb0a6d0e` |
| 21 | `policy/frameworks/finos-aigf/v1.0/README.md` | 87 | semicolon | use two sentences: They are left out on purpose; this pack does not approximate them. | `cb0a6d0e` |

## Pre-existing Doctor Exceptions

Running `kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLSI` raises exactly two exceptions. Neither is an SLSI defect. Both are pre-existing across the 561+ worktrees. Do not rescue, prune, or gc.

### DOC-5: 26 Orphan Worktrees

Exactly 26 worktrees not attached to an active card:
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-a0d026d0b4ed958d8`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-a103f2110ccbcbf67`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-a206bb89509db9d38`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-a2472486ef498f427`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-a31df8e279ed860a2`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-a4011c4e018d3f4e4`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-a45cfc6397491fcf8`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-a5aebeb7d802d664e`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-a6a3470364eb507a5`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-a73720c2c3997fc47`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-a7bbecb95a0078ce6`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-a7c5c5d852ad025ea`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-a7def60753c53986b`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-a8038c34c7d724ccc`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-a81c75fe4b2f3cae5`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-a84235ab4d22c3d4d`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-a8d0365f37110ff3b`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-aa65f01fbd3ce3fdb`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-aad674bdbf90b128f`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-ab3518f8434910c70`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-ad1ed812f25748d15`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-ad6ddbe471af82603`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-ad9aafd5218743fc2`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-adff68218fbbbeaaa`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-ae64e41befa26c777`
- `/home/andy/src/cp/osramp-demo/.claude/worktrees/agent-afae5e4c52d79379f`

### DOC-7: 7 Dangling Commits

All 7 commits are rebase/amend leftovers whose content is already integrated at HEAD:
1. `72e4d8bc` (2026-09-11 09:16:33 +0100, Andrew Martin): `feat(signalloom): certify SFAS Phase 4 Governor and record final Programme sign-off` [SHA: `72e4d8bcc075e676f5c5f2d323b4ab12f2ef77bf`]. Forensic verdict: Rebase/amend leftover from SFAS Programme certification; content already integrated at HEAD.
2. `8a229448` (2026-09-10 22:28:09 +0100, Andrew Martin): `feat(signalloom): implement real-time temporal delegation edge revocation on stun containment` [SHA: `8a22944847fde0fe51bcb40d40729f6ce0bf098c`]. Forensic verdict: Prior iteration of temporal edge revocation commit; integrated via subsequent merge commit at HEAD.
3. `3c7ca874` (2026-09-10 21:59:35 +0100, Andrew Martin): `feat(signalloom): wire Tab 5 timeline audit events to interactive cryptographic authorization proof drawer` [SHA: `3c7ca8744710409f07290e8a1c9c74df045c26d2`]. Forensic verdict: Prior amend iteration of timeline audit drawer wiring; integrated at HEAD.
4. `82e70cea` (2026-09-10 21:45:42 +0100, Andrew Martin): `feat(signalloom): embed 7-hop attested authorization chain into Agent Dossier Tab 2` [SHA: `82e70cea98368b78205d7fe360a57c8491cba662`]. Forensic verdict: Draft commit superseded by subsequent amended commit in SLAC mission; changes present at HEAD.
5. `fab8555a` (2026-09-10 21:45:00 +0100, Andrew Martin): `feat(signalloom): embed 7-hop attested authorization chain into Agent Dossier Tab 2` [SHA: `fab8555a21c896f18f0d8d9ce5af437dde14f90d`]. Forensic verdict: Pre-amend parent of `82e70cea`; superseded during authoring and integrated at HEAD.
6. `5209a692` (2026-09-09 15:58:34 +0100, Andrew Martin): `fix(signalloom): preserve previous pod logs on step 2 failure and broaden 40x regex` [SHA: `5209a692b7bb5f24d0b7036fe5b062fe47cf31b0`]. Forensic verdict: Bugfix rebased into main line during SLAC Phase 2; changes integrated at HEAD.
7. `82781937` (2026-09-09 01:36:41 +0100, Andrew Martin): `docs(signalloom): record Phase 3 discovery preflight proof (SLAC-P3-PRE)` [SHA: `827819374fe8827df0f9b1f61baecc7f2ea56efa`]. Forensic verdict: Preflight proof document commit amended into subsequent release; proof content present at HEAD.

## Collision Map: Future Appliance Scripts

All 4 future appliance scripts are confirmed **ABSENT** at commit `504405b9`:

| Script | Intended Path | Authoring Card | Current Status |
| :--- | :--- | :--- | :--- |
| Core Packaging Toolchain | `scripts/package-tenant-bundle.sh` | **P1-1** | `ABSENT_VERIFIED` |
| Cryptographic Bootstrap & Kind Persistent Host Engine | `scripts/init-tenant.sh` | **P2-1** | `ABSENT_VERIFIED` |
| In-Place Day-2 Upgrade Engine | `scripts/upgrade-tenant.sh` | **P3-2** | `ABSENT_VERIFIED` |
| Local Audit Bundler & Telemetry Diagnostics | `scripts/export-diagnostics.sh` | **P3-3** | `ABSENT_VERIFIED` |

No card prior to the designated authoring card may create or stub these scripts.

## Settled Decision Guards

- **Decision 8 (Settled):** Relationship to ADR-12 — the appliance is a superset, and `remote-tenant` is one of its modes. `APPLIANCE_MODE=hub|attached` selects mode. `hub` runs local issuers/ingest; `attached` renders `signalloom-warden-overlays/remote-tenant` and consumes central issuer secrets. ADR-12 is not superseded; no separate product line is permitted.
- **Decision 9 (Settled):** Release trust by digest pin plus bundle-time signing. Third-party platform images are pinned by immutable digest and signed at bundle time with the SLSI release key; no separate release signing pipeline is built. The release private key stays in OpenBao transit KMS; the appliance ships only the public key. Tag-only image references anywhere in the bundle are a defect.

## Handoff Contract for Downstream Cards

1. All downstream cards (P1-PRE through P3-GOV) diff their test outcomes against `docs/slsi-p0-baseline/baseline.json`.
2. A delta is permitted only if owned by that card's scope.
3. Any new `docs-lint` finding outside `policy/frameworks/**`, or any count exceeding 21, is a defect.
4. Any change to cluster manifests or functional platform code in preflight cards is forbidden.
