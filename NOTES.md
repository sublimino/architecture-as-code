# NOTES — I2-v2-acceptance

Working notes for the branch `feat/gcp-tf-v2-acceptance`. Two things belong
here: which acceptance checks cannot reach a real verdict without a live estate,
and every v1 assumption in the tree that will need attention when v1 migrates.

Base commit: `cd68dea`. Revised after review by I1 (schema + access_mode enum)
and the team lead (egress direction, OS Login gap).

---

## 1. Checks that can only be UNKNOWN without a live estate

The bats suite drives every branch of every check below with a stubbed `gcloud`,
so the *classification logic* is fully exercised offline. What follows is a
different claim: which checks cannot produce a real-world verdict — `PASS` or
`FAIL` about the actual estate — without a deployed environment to point at.

### Everything, if the handoff is absent

`deploy/gcp/<env>.handoff.json` does not exist on this branch's base commit
(`cd68dea`); `make gcp-tf-handoff` and the emitter live on I1's branch
(`8ba9e98`). Until those merge, `acceptance-v2.sh` exits `5` and checks nothing.
That is deliberate: the alternative is reconstructing resource names from a
naming convention, which grades resources that may not exist and reports their
absence as a clean estate.

**Schema converged with I1 — no rename needed on either side.** The emitter's
exact shape is committed as a fixture at
`test/fixtures/gcp-tf-v2/handoff/emitter-shape.handoff.json`, and a test asserts
it produces 14 PASS with zero UNKNOWN. Nine of eleven fields already matched a
spelling I accept; I1 added `env` and `schema` as additive aliases, and I added
`.environment_key` to my fallback chain so either spelling resolves.

`schema` is now checked. An unrecognised value is **announced but not fatal** —
the field reader already degrades to UNKNOWN on anything it cannot resolve, so a
newer schema produces an honest report rather than a refusal or a wrong answer.
Fixture: `future-schema.handoff.json`.

`state_prefix`, `schema_version` and `generated_at` are emitted and ignored;
extra fields are never fatal, so the emitter can add freely.

**I1's note on degradation is worth recording:** the generator never writes a
hand-off with a blank required field — it exits non-zero naming the field. So in
practice I get the *missing file* path, not the *missing key* path. The UNKNOWN
degradation stays anyway, because it is what protects against a hand-off written
by an older or newer schema, but it is not the normal signal.

The handoff schema I read, with the fallback spellings also accepted:

| Field | Also accepted | Used by |
|---|---|---|
| `env` | `environment_key`, `env_key`, `environment` | reporting; disagreement with `--env` is announced |
| `project` | `project_id` | every cloud call |
| `region` | — | reporting |
| `zone` | — | instance describe, tunnel probe |
| `instance` | `instance_name`, `vm` | instance checks, tunnel probe |
| `internal_ip` | `ip` | staleness check |
| `app_port` | `port` | tunnel probe, app-port check |
| `state_bucket` | `bucket` | bucket protection, deploy-SA roles |
| `deploy_sa` | `deploy_service_account` | deploy-SA roles |
| `access_mode` | — | the IAP-vs-allowlist check |
| `hostname` | — | reporting; `""` is valid |

A field absent under every spelling yields `UNKNOWN` for the checks that need it,
never a guess. Extra fields are ignored, so the emitter can add freely.

### Checks whose verdict is inherently live-only

| Check | Why it cannot be settled offline |
|---|---|
| **IAP tunnel authorises** | The three-way outcome is a property of the running IAP service and the caller's IAM at that moment. The stub proves the *classifier* handles all four cases (`listening`, `denied`, `no-listener`, silence); only a real probe says which one the estate is in. |
| **app port responds** | Requires something listening inside the VM. The live `demo-1` has nothing listening today, so this is expected to `FAIL` with "nothing is listening on 8080" until the application is deployed — which is a deploy problem, not an access one, and the report says so explicitly. |
| **handoff describes this estate** | Compares the recorded internal IP against the live one. Meaningless without both. |
| **deploy SA: objectAdmin only** | Needs `storage.buckets.getIamPolicy` on the real bucket. Reports `UNKNOWN` if the identity lacks it — which is itself a finding worth acting on, since it means nobody can verify the least-privilege claim. |
| **state bucket protection** | Same shape: real bucket, real permission. |
| **SSH path via IAP tunnel** | Same shape as the app port, on tcp/22. Offline the stub proves the classifier; only a live probe says which state the estate is in. The lead has verified this returns `SSH-2.0-OpenSSH_9.2p1` against the live estate. |

### The check that is deliberately *not* live

**`access mode authenticates`** is graded from the handoff, not from the edge. It
asserts what the estate was *declared* to be; the tunnel probe asserts what it
*does*. Both matter, and a disagreement between them is worth seeing rather than
silently resolving in favour of one.

### Two things that cannot be checked from here at all

- **The OS Login external-user grant.** `roles/compute.osLoginExternalUser` is
  **org-scoped**, and this suite has no org-level read. So the report names the
  condition rather than grading it: when the tunnel to tcp/22 is `PASS` and
  `gcloud compute ssh` still fails, the note says explicitly that the difference
  is that grant and not the estate. Converting an unexplained failure into a
  named condition is the most this can honestly do without org read.
- **Whether `iap_members` is non-empty.** Terraform validates it at plan time
  (IAP with no authorised principal is a locked door with no key), and
  `conformance.sh` already grades the live IAP IAM policy. Not duplicated here.

### One judgement call worth surfacing

`acceptance-v2.sh` carries the same read-only allowlist as `preflight.sh` and
`conformance.sh` — `describe` / `list` / `version`, plus `get-iam-policy`, which
`conformance.sh` already established.

It adds **one** verb those two do not have: `compute start-iap-tunnel`.

I put it in a **separate gate** (`gcloud_tunnel_probe`) rather than widening
`gcloud_ro`, so it cannot be reached accidentally from any other check, and so
that adding a second verb there is a decision someone has to make in the open.
The justification: `start-iap-tunnel` opens a local listener and a tunnel
session. It creates no cloud resource, modifies no configuration and deletes
nothing — the same class of operation as curling an endpoint. Its genuinely
mutating neighbours in the same command group (`ssh`, `scp`, `reset`, `delete`)
are refused by that gate, and there is a test asserting so.

It is nonetheless a widening, and the brief said `describe`/`list`/`version`. If
that is judged too broad, the alternative is dropping the tunnel check entirely
and with it the single most useful distinction the report draws — so I would
rather flag the call than quietly make it.

---

## 2. Three defects the suite found while it was being written

Recorded because each is a class, not a one-off.

1. **A jq `//` fired on an empty stream.** `[ .networkInterfaces[]?
   .accessConfigs[]? .natIP // "assigned" ]` parses the `//` as an alternative to
   the *whole* preceding expression. An instance with no `accessConfigs` — the
   passing case — produces an empty stream, which is falsy, so the alternative
   fired and the array became `["assigned"]`. **Every compliant instance was
   reported as having an external IP.** Caught by the compliant positive on the
   first run; a suite of negatives alone would have shipped it.

2. **A total cloud blackout was classified as an IAP denial.** `gcloud` answers
   `PERMISSION_DENIED` to everything when a token has expired, so the tunnel
   probe's text classifier read it as "IAP refuses you". Now a denial is only
   evidence about IAP if some other read in the same run succeeded; otherwise
   `UNKNOWN`. Same discrimination `teardown-verify.sh` draws around a missing
   state bucket: the identical failed call means opposite things depending on
   whether anything else answered.

3. **Teardown killed only the backgrounded wrapper.** The tunnel's child process
   survived every run. In the suite that cost 2m40s of wall clock (down to 46s
   once fixed); in production it leaks a **live IAP tunnel per invocation**. Now
   torn down by walking children by parent PID — never by pattern, because a
   `pkill -f start-iap-tunnel` can match the script's own shell, whose
   `/proc/*/cmdline` contains the entire program text under `bash -c`.

---

### 2a. Two more, found in review rather than by the suite

4. **`access_mode` was treated as a boolean.** It is a three-valued enum —
   `iap | allowlist | iap_and_allowlist` — and the combined mode is, per the
   variable's own description, the strongest posture. My first revision FAILED
   it. The failure mode is the worst possible shape: the *best-configured*
   estate is the one that fails, and `iap_and_allowlist` is exactly what a demo
   estate that is both IAP-gated and IP-restricted would run. Caught by I1, who
   owns the emitter, not by my suite — the fixtures only carried the two values
   I had imagined. Now graded as an enum against the Terraform validation, with
   an unrecognised value reporting UNKNOWN rather than guessing in either
   direction.
5. **The pidfile in the leak-regression test was overwritten, not appended.**
   Once a run opened two tunnels (app port and tcp/22), the test only ever
   checked the second one. A leak of the first would have gone unnoticed by the
   very test written to catch leaks.

## 3. Blockers and open decisions

**Blocker — outside both my chunk and I1's, needs the orchestrator.**
`terraform/environments/outputs.tf` does not re-export the compute module's
`instance_name` and `internal_ip`. The module publishes both; the root does not.
So `make gcp-tf-handoff` fails against the live estate today, deliberately,
naming those two fields — which means the end-to-end path (`make gcp-tf-handoff`
then `acceptance-v2.sh`) cannot be exercised against the real estate yet. I hit
the "missing file, run `make gcp-tf-handoff`" path, and running it does not fix
it. The exact output blocks needed are in `NOTES.md` on I1's branch.

**Open decision — CI lanes have no instance.** There is no compute module for
`kind = "ci"`, so `instance_name` and `internal_ip` have no meaning for
`ENV=ci-1`. Somebody needs to decide whether the hand-off is demo-only or
whether those fields become empty-allowed for CI. Neither I1 nor I have assumed
one. **My side degrades safely either way**: absent instance fields report
UNKNOWN with "handoff carries no project and/or instance name" and the run exits
0 (or 3 under `--strict`), so a CI-lane hand-off produces an honest partial
report rather than a false pass or a crash.

## 4. v1 assumption inventory

Everything in the tree that encodes a ControlPlane assumption. Split by whether
it needs to change when v1 migrates, or is correct as it stands.

### 4a. In the **v2** Terraform — latent, not breaking today

These are the ones worth acting on first, because they are v1 defaults sitting in
the estate v2 actually applies.

| Location | Assumption | Impact |
|---|---|---|
| `terraform/environments/variables.tf:54` | `default_region = "europe-west2"` | Feeds the provider block in `providers.tf`, so it is the fallback for any resource that does not set a region explicitly. `demo-1` sets `region = "us-east4"` in its own entry, so nothing is misplaced **today** — a resource added without an explicit region would land in the v1 region. |
| `terraform/platform/variables.tf:75` | `log_bucket_location = "europe-west2"` | The audit log bucket. Nothing in `deploy/` overrides it, so a `us-east4` estate writes its audit trail to the v1 region. Cross-region egress, and a data-residency question that should be answered deliberately. SECURITY.md #9 treats the audit trail as security-relevant, which makes its location a security-relevant default. |
| `terraform/modules/observability/variables.tf:123` | `log_bucket_location = "europe-west2"` | The module-level twin of the above. |
| `terraform/environments/variables.tf:62-63` | `europe-west2` in the doc comments for `region` / `zone` | Cosmetic, but it is the example a reader copies. |

### 4b. v1 by design — leave alone until the migration is deliberate

| Location | What it is |
|---|---|
| `scripts/ci/gcp-ci.sh` | The imperative v1 pipeline. Named `cp-dev-ajm`, `europe-west2`, `signalloom-ci` / `signalloom-ci-2` throughout. **Out of scope for this branch and untouched.** |
| `scripts/ci/vm-pipeline.sh`, `scripts/ci/ci-lock.sh` | Its machinery. Untouched. |
| `.github/workflows/signalloom-ci.yaml` | `GCP_PROJECT: cp-dev-ajm`, `GCP_ZONE: europe-west2-a`, `VM_NAME: signalloom-ci`, concurrency group `signalloom-ci`. The whole v1 entry point. |
| `Makefile` | `ci-gcp` / `ci-gcp-2` targets and the `signalloom-ci` VM names. |
| `scripts/ci/README.md` | Documents v1. Correct as it stands. |

### 4c. Straddles both — will need a decision

| Location | Issue |
|---|---|
| `scripts/ci/gcp-tf-ci.sh:54` | `ZONE="${GCP_TF_CI_ZONE:-europe-west2-a}"`. This is a **Terraform** CI script defaulting to the v1 zone. Overridable by env var, so not breaking, but the default points at the wrong estate. |
| `scripts/ci/gcp-tf-reaper.sh:57-58` | Denylists `signalloom-ci` and `signalloom-ci-2` so the reaper cannot delete the v1 runners. **Correct and load-bearing while v1 exists** — and it becomes dead configuration the day v1 is retired, so it should be removed as part of that change rather than left to rot into a list that pre-approves nothing. |
| `terraform/ISA.md` | Names `cp-dev-ajm` and `andy@control-plane.io` in its problem statement. Historical context; worth a note that v2 superseded it rather than an edit. |
| `test/fixtures/gcp-tf-ci/instances.tsv.template` | v1 instance names and zone. Test fixture, correct for what it tests. |
| `test/gcp-ci-ssh-diagnosis.bats`, `test/gcp-ci-vm-status.bats`, `test/ci-terminal-state.bats`, `test/ci-state-locality.bats`, `test/terraform-ci-lifecycle.bats`, `test/kind-load-verified.bats` | Assert against v1 names. They test v1 and should keep doing so. |
| `d2-signalloom/apps/dashboard-signalloom/src/pages/NetworkTestsPage.tsx` | Mentions `signalloom-ci`. Application-side, unrelated to either estate's provisioning. |

### 4d. Deliberate v1 references in my own files

`scripts/gcp-tf/acceptance-v2.sh` and `test/terraform-v2-acceptance.bats` both
name every v1 marker. That is the refusal guard and its test — the script has to
name v1 in order to refuse it. `test/fixtures/gcp-tf-v2/handoff/v1-*.json` are
the fixtures that drive it.

No real v2 project id, account or address appears anywhere in the script; there
is a test asserting that (`no real project id, account or address is hardcoded in
the script`). Everything identifying comes from the handoff. The real values are
documented in `docs/policy-as-versioned-code/V2-CICD.md`, where documentation
belongs.

---

## 5. Suite facts

- `bats test/terraform-v2-acceptance.bats` — **44 tests, all passing, ~46s**,
  offline: no network, no cloud credentials, no terraform.
- `shellcheck` clean: the script and both stubs.
- Five mutation checks, each refusing to run unless its `sed` actually changed
  the file — a mutation that silently no-ops runs against unmutated code and
  passes, which is a mutation check that can never fail.
- The compliant fixture carries four decoys — a wide-open *neighbouring* VPC, a
  DISABLED world-open rule, a DENY rule sourced from `0.0.0.0/0`, and
  `storage.admin` held by someone who is not the deploy identity — so four
  separate over-broad implementations turn it red. One has already earned its
  keep (defect 1 above).
- The suite is picked up automatically by `make gcp-tf-validate`: `GCP_TF_BATS`
  globs `test/terraform-*.bats`. `test/terraform-suite-registration.bats` passes
  (14/14) with this file present, so it is genuinely registered rather than
  merely on disk.
