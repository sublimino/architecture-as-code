# From-scratch test plan: four lanes, both surfaces

> Written 2026-08-21 after a session that rebuilt the estate twice and never got a
> lane past `create-cluster`. This plan exists so the next run starts from what
> that session learned rather than rediscovering it.
>
> **Read § 0 before running anything.** It is the list of things that have
> already cost hours, and every one of them presents as a different problem than
> it is.

---

## 0. Known traps — read first

Each of these was diagnosed the hard way. The left column is what you will see;
the right is what it actually means.

| Symptom | Actual cause |
| :--- | :--- |
| `✗ pushing artifact failed: … 500 Internal Server Error` on `localhost:5001` | The zot blob store lived where a re-delivery wipes it, so the registry kept metadata whose blobs were gone. **Fixed** (same defect as the cosign keypair, one layer down) — but the fix is **unproven end to end**, so this is the first thing to watch in § 5. It aborted 4/4 lanes at `create-cluster` and I mislabelled it "transient" on a single observation before it recurred twice on one lane. |
| `mv: cannot stat '.../demo-reports'` | Two lanes racing one report directory. Fixed — `REPORT_DIR` now carries `${ENV_KEY}`. If it returns, the lane key has left the *default* in `scripts/gcp-tf/demo-up.sh`. |
| `Error: error asking for approval: EOF` on destroy | `terraform destroy` is interactive by design. Feed it `yes yes \|` — **`yes` alone emits "y"**, which terraform rejects with "Destroy cancelled". |
| `4047: Failed to lookup instance` | IAP tunnel racing a just-replaced VM. Wait and retry. |
| `agent refused operation` on any `gcloud compute ssh` | Local ssh-agent, not the VM. **`unset SSH_AUTH_SOCK` first, always.** |
| `Quota 'CPUS_ALL_REGIONS' exceeded` mid-apply | Four lanes at the validated 8-vCPU floor need exactly 32 of a 32 cap. **Teardown must fully complete before any create.** `scripts/gcp-tf/preflight.sh` refuses up front. |
| `FATAL: refusing to push. This checkout's signing key is not the key the cluster trusts` | `.keys/` is gitignored so the payload never carries it. Fixed by persisting the keypair on the VM outside the delivered tree — **unproven end to end**. |
| gate reports `0 ok, 0 not ok` and exits non-zero | tflint or `terraform test` failed *before* bats ran. **Read the ok/not-ok counts, never the exit code alone.** Three different upstream causes have produced this identical presentation. |
| A test passes standalone and fails in the full run | Shared state. Give the suite a private `TF_DATA_DIR`; see `test/terraform-observability-dormant.bats`. |
| A guard goes green after a change that should break it | Check the fixture, not the code. **Five separate failures this session were fixtures short of a newly-required field** — a mock missing a key, a fixture copying one file from a library, stub outputs predating a required field (twice). Every one named the wrong subject. |
| `git status` shows a modified file nobody edited | **A mutation harness killed mid-run leaves the tree mutated.** Seen twice: `DefaultDependencies=no` left in `demo-vm.sh`, and `far-side identity UNVERIFIED` rewritten to `CONFIRMED` in `demo-up.sh` — the second would have turned "we do not know" into "we have confirmed". Both were caught only because a merge refused on a dirty tree. **`git diff` before any merge, and read what it says rather than assuming it is yours.** |

**The meta-lesson, which cost the most time:** three confident causal stories were
built on correct observations and were wrong — the mechanism was *reasoned* when
it should have been *run*. In each case one command settled it. Prefer measuring.

---

## 0b. Where this actually stands (2026-08-22)

**Why this has taken days, stated plainly.** Every cycle fixed a real defect and
uncovered the next one behind it. That is progress, but it is *serial* progress
against a stack of independent faults, and each one costs a ~40-minute lane run
to observe. The blockers, in the order they were hit:

| # | Blocker | Status | Commit |
| :--- | :--- | :--- | :--- |
| 1 | Zot 500 — blob store inside the tree a re-delivery wipes | FIXED, proven | `57771c46` |
| 2 | `netassert-controller` corrupt blob — docker.io fallback was the *marketing site*, serving 200 text/html that containerd recorded as the image mediaType | FIXED, proven | `adca5639` |
| 3 | AFM archive — one local path shared by four concurrent lanes; one lane truncated the file another was mid-scp | FIXED, proven | `829109bd` |
| 4 | `infra-controllers` never Ready — observability tenants were re-published by three unfiltered paths, so source-controller thrashed `NAME_UNKNOWN` forever and starved real reconciles (12h21m vs a 600s deadline) | FIXED, proven | `814824a8` |
| 5 | 5-6 test stages still failing | IN PROGRESS | — |

**The measurable trajectory**, which is the honest answer to "are we getting
anywhere":

```
run 1   4/4 lanes ABORT at push-local        (Zot)
run 2   3/4 lanes ABORT at create-cluster    (netassert)
run 3   3/4 lanes ABORT at [5/8]             (Flux starvation)
run 4   4/4 lanes REACH REPORT, 24/29        <- current
```

`ABORTED` and `FAIL` are not the same verdict and the distinction is the whole
story: ABORTED means the estate never converged, FAIL means it converged and ran
its tests. **As of run 4 every lane converges.** What remains is test failures,
not infrastructure collapse.

### The remaining 6, and a correction that matters

They are IDENTICAL on all four lanes, which is itself the signal — the lanes no
longer diverge on timing or luck.

| Stage | Exit | Status |
| :--- | :--- | :--- |
| `Vacuous-assertion lint` | 1 | ROOT-CAUSED — 3 real hollow assertions |
| `Vacuous-assertion lint falsification` | 1 | same cause; tests 38/39 just run the checker |
| `Static guards previously invoked by nothing` | 1 | open |
| `Guard falsification proof` | 3 | open — exit 3 is UNKNOWN>0, cases the harness *could not run* |
| `Demo pipeline control flow` | 1 | open |
| `CI build parity with demo-signalloom-up` | 1 | open, found late — was missing from every earlier list |

**Correction, recorded because the wrong version was believed for a day:** these
were called "VM-only failures" in § 8 below. That is FALSE for at least the
vacuous-assertion pair, which fail in a clean local worktree at base:

```
$ git status --porcelain          # empty
$ ./scripts/check-vacuous-assertions.sh
exit 1, 3 findings
```

The three findings are real hollow assertions that arrived from sibling lanes —
and **one of them came from a commit merged the same day** (`814824a8`, the
observability fix). It was merged after its own suite passed 13/13.

That is the process lesson worth more than the fix: **a green suite is not
evidence the suite asserts anything.** `check-vacuous-assertions.sh` is the tool
that distinguishes those two, and it was not being run before merging. It is now
the gate for anything landing on this branch.

---

## 1. Preconditions

```bash
cd /home/andy/src/cp/osramp-demo
unset SSH_AUTH_SOCK                      # every session, before anything
export TF_STATE_BUCKET=sl-port-over-sandbox-osramp-tfstate
export GCP_TF_VAR_FILE=../../deploy/gcp/sl-port-over-sandbox.tfvars
gcloud config get-value project          # expect sl-port-over-sandbox
```

Project `sl-port-over-sandbox`, zone `us-east4-a`. Four lanes: `demo-1`, `demo-2`
(kind=demo), `ci-1`, `ci-2` (kind=ci), all `n2-standard-8` / 100GB per
`deploy/gcp/sl-port-over-sandbox.tfvars`.

**Capacity is exact, not comfortable.** `CPUS_ALL_REGIONS` is 32 and four lanes
need 32. `SSD_TOTAL_GB` is 500 in us-east4 and four lanes need 400.
`COMPUTE-RULE-01` in `terraform/modules/compute/variables.tf` floors
`machine_type` at 8 vCPU, so **no configuration of four lanes uses less CPU**.

---

## 2. Offline gate — before touching the cloud

```bash
make gcp-tf-validate 2>&1 | tee /tmp/gate.log
grep -c '^ok ' /tmp/gate.log; grep -c '^not ok' /tmp/gate.log
```

Takes >10 minutes; run it detached. **Judge it on the counts, not the exit
code.** Expect ~880 ok. Any `not ok` is a real regression — the tree was green
when this plan was written.

Also expect `NOT PROVEN: 0` from the mutation proofs. A `NOT PROVEN` means a
guard could not be shown to fail, which is worse than a red test.

---

## 3. Teardown

```bash
for e in demo-1 demo-2 ci-1 ci-2; do
  ( yes yes | make gcp-tf-destroy ENV=$e CONFIRM=$e > /tmp/destroy-$e.log 2>&1
    echo "$e exit=$?" >> /tmp/destroy-results.txt ) &
done; wait
```

Parallel is safe — destroys only free capacity. Verify **before** creating:

```bash
gcloud compute instances list --project sl-port-over-sandbox      # expect empty
gcloud compute project-info describe --project sl-port-over-sandbox --format=json \
  | jq -r '.quotas[]|select(.metric=="CPUS_ALL_REGIONS")|"\(.usage)/\(.limit)"'   # expect 0.0/32.0
```

`gcp-tf-destroy` runs `ts-logout --force` first, releasing the MagicDNS name so
the rebuild reclaims it instead of drifting to `sl-demo-1-1`.

---

## 4. Infrastructure

```bash
for e in demo-1 demo-2 ci-1 ci-2; do
  ( make gcp-tf-up ENV=$e > /tmp/up-$e.log 2>&1; echo "$e exit=$?" >> /tmp/up-results.txt ) &
done; wait
```

Four parallel applies are safe and were proven so: per-lane `TF_DATA_DIR`, GCS
state prefix, plan file and hand-off. Expect **18 resources added per lane**.

### Checkpoint A — three things that must be true on fresh disks

```bash
for n in sl-demo-1 sl-demo-2 sl-ci-1 sl-ci-2; do
  echo "$n $(curl -s -o /dev/null -w '%{http_code}' https://$n.taild4da3.ts.net/)"
done
for e in demo-1 demo-2 ci-1 ci-2; do
  jq -r '"\(.env) \(.operator_sa) \(.access_mode)"' deploy/gcp/$e.handoff.json
done
```

- **HTTP 502 on all four.** 502 is the *pass* condition here — the boot unit
  records the serve config before the estate exists. **000 means the boot install
  failed** (`terraform/modules/compute/startup/demo-vm.sh`), and
  `systemctl is-enabled signalloom-tailscale-serve.service` distinguishes them
  without waiting for the estate.
- `operator_sa` present in every hand-off. If absent, every `gcp-tf-ts-*` call
  will refuse with an error blaming GCP OS Login IAM; the real cause is the
  missing field.
- `access_mode` = `iap_tunnel`, not `iap` — the path in force, not the one the
  tfvars wished for.

---

## 5. Estates — THIS IS WHERE IT CURRENTLY FAILS

```bash
for e in demo-1 demo-2 ci-1 ci-2; do
  ( GCP_TF_DEMO_ALLOW_DIRTY=1 nohup make gcp-tf-demo-up ENV=$e \
      > /tmp/estate-$e.log 2>&1; echo "$e exit=$?" >> /tmp/estate-results.txt ) &
done; disown -a
```

~40 minutes per lane. `GCP_TF_DEMO_ALLOW_DIRTY=1` only suppresses the
dirty-tree refusal — delivery is `git archive HEAD`, so **uncommitted work is
never in the run** regardless.

> **Expect this to abort at `create-cluster` on the Zot 500 until that is
> fixed.** Do not interpret it as a regression in anything else. Check
> `demo-reports/<env>/summary.json` → `.phase` and `.exit_code` first; the
> driver leaves the VM RUNNING for inspection.

### Checkpoint B — what this phase proves for the first time

None of these has ever completed end to end. Watch for each explicitly:

| Mechanism | Where | Evidence to look for |
| :--- | :--- | :--- |
| `deliver_afm_image` | `scripts/gcp-tf/demo-up.sh` | `building the AFM image archive` |
| `push_afm_image` | `scripts/gcp-tf/demo-up.sh` | archive lands, digest matches |
| Cosign key reuse | `scripts/lib/keys.sh`, `scripts/push-local.sh` | a **second** `gcp-tf-demo-up` on a bootstrapped cluster getting past `push-local-foundation` |
| CRI adoption | `scripts/kind-load-verified.sh` | no `has not adopted … after N checks` |

---

## 6. Both surfaces, all four lanes

```bash
for e in demo-1 demo-2 ci-1 ci-2; do make gcp-tf-ts-test ENV=$e; done   # remote, no credentials
for e in demo-1 demo-2 ci-1 ci-2; do make gcp-tf-test-surfaces ENV=$e; done
make gcp-tf-surfaces-report
```

- `gcp-tf-ts-test` — the tailnet surface from this machine. Needs no cloud
  credentials by design. Distinguishes *not on the tailnet* (exit 2) from *on it
  and serving nothing* (exit 1) from *serving with a dead backend* (502).
- `gcp-tf-test-surfaces` — asserts **both** surfaces ran and passed for a lane.
- `gcp-tf-surfaces-report` — every lane, both surfaces, one table.
  **STALE is not a pass and MISSING is not silence**; a receipt from another
  commit fails.

### Checkpoint C — AFM, which is the point of the exercise

```bash
for n in sl-demo-1 sl-demo-2 sl-ci-1 sl-ci-2; do
  echo "$n $(curl -s -o /dev/null -w '%{http_code}' https://$n.taild4da3.ts.net/afm/health)"
done
make check-backends
```

`/afm/health` must be **200 on all four**. A 502 means no AFM backend —
`nginx.conf` points seven locations at `afm-platform.fe-k8s-afm.svc.cluster.local:8000`.

**200 is necessary and not sufficient.** The cluster-import CronJob is `*/30` and
does not run at creation, so a fresh lane can sit at `/afm/health` 200 with
**zero clusters** — green dot, empty dashboard, nothing reporting it. Worse than
the 502. `test/acceptance/smoke.spec.ts` asserts `cluster-count` is not
`0 clusters` for exactly this reason.

---

## 7. Files this plan depends on

| File | Why |
| :--- | :--- |
| `terraform/notes/j-lane-parallelism.md` | The clash audit — verdicts per shared resource, the gate's uniform failure mode, the nginx lane-header costing |
| `terraform/notes/i1-make-handoff.md` | Hand-off contract; records `GCP_TF_VAR_FILE`'s wrong default |
| `terraform/notes/g-iap-private-edge.md` | Why TCP IAP stays and web IAP does not |
| `docs/gcp-demo/RUNBOOK.md` | The operator path this plan automates |
| `scripts/gcp-tf/preflight.sh` | Quota gate; refuses an apply that cannot fit, CPU and SSD separately |
| `scripts/gcp-tf/surfaces-report.sh` | The four-lane report |
| `scripts/kind-load-verified.sh` | Image load + CRI adoption, and its header explains the whole failure class |
| `test/terraform-observability-dormant.bats` | Why observability is off, and the private-`TF_DATA_DIR` pattern |
| `deploy/gcp/sl-port-over-sandbox.tfvars` | Lane definitions. **Gitignored** — the only copy is local |

---

## 8. Undone, and honestly so

- **The Zot 500 has a fix that has never run.** The blob store now persists
  outside the tree a re-delivery wipes — the same defect as the cosign keypair,
  one layer down. Until § 5 completes on at least one lane, treat it as
  plausible rather than proven.
- **Four static-gate stages fail only on the VM** — `Static guards previously
  invoked by nothing`, `Guard falsification proof`, `Vacuous-assertion lint`,
  `Demo pipeline control flow`. All pass locally at HEAD *and* at the base
  commit, so they are not regressions, but a guard that can only be triaged
  where it fails is a guard nobody will keep.
- **`scripts/k8s-afm.sh` still hardcodes a developer home path.** It does not
  trip the conventions guard because that guard's globs do not reach it. Out of
  a guard's reach is not the same as correct.
- **`wait_reachable` hardcodes `curl`** while `demo-up.sh` maintains an
  injectable `CURL_BIN`. Worked around locally via `_wait_retry`; the generic fix
  is a `WAIT_CURL` override in the vendored `scripts/lib/wait.sh`, whose source
  of truth is outside this repo.
- **The reaper has no scheduler and `ci_idle_suspend_minutes` has no reader.** A
  cost control that is documented, validated, mutation-proven and entirely inert.
