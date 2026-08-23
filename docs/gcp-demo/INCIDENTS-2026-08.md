# Incidents — August 2026

> **HISTORICAL RECORD.** These five defects are fixed. This page is kept for
> the reasoning, not as a description of the tree today. Each entry names the
> measurement that found the cause, because in every case the first symptom
> pointed at the wrong subsystem.

Five blockers stopped the four-lane estate in August 2026. They share one
shape: **a component succeeded at the wrong thing, and the failure surfaced
later, somewhere else.** None of them reported its own cause.

For the operational rules that came out of these, see
[`OPERATIONS.md`](OPERATIONS.md).

## 1 · The Zot blob store lived where a re-delivery destroys it

**Symptom.** `pushing artifact failed: 500 Internal Server Error` on
`localhost:5001`. All four lanes aborted at `create-cluster`.

**Cause.** The blob store directory sat inside the tree that the delivery
wipes. A rebuild therefore left the registry holding metadata whose blobs were
gone. The registry answered, and it answered wrongly.

**Why it took two passes to find.** The first occurrence was labelled
"transient infrastructure" on a single observation. It then recurred on 4 of 4
lanes, and twice on one lane. One observation is not a class.

**The class.** This is the same defect as the cosign keypair one layer up. That
fix persisted the keypair outside the tree the delivery wipes. Any state that
must outlive a delivery has to live outside the delivered tree.

Fixed in `49b5cf5e`.

## 2 · The `docker.io` registry fallback was the marketing site

**Symptom.** `unexpected media type text/html for sha256:fc4f0cf0...` during
CRI adoption. It read as a corrupt local image.

**Cause.** `scripts/registry-cache.sh` carried `https://docker.io` in the
`server` field, as containerd's last-resort host. That URL is not a registry.
It redirects to the Docker marketing site, which answers 200 `text/html` to any
path, including `/v2/<name>/manifests/<ref>`.

Measured from inside `sl-demo-1-vm`'s kind node:

| Host | Status | Content type | Verdict |
| :--- | :--- | :--- | :--- |
| mirror | 404 | `application/json` | correct: repo not on the Hub, falls through |
| fallback | 200 | `text/html` | final URL `https://www.docker.com/` |
| `registry-1` | 401 | `application/json` | what the correct host returns |

**Why it hid.** containerd derives a descriptor's mediaType from the response
`Content-Type`. The fallback did not fail — it **succeeded**, and wrote an HTML
page in as the image record's target. Nothing complained at pull time. The
damage surfaced minutes later, one subsystem away.

All 76 poisoning events across the estate carried one identical digest on
independent VMs. That is a deterministically served page, not per-host
corruption.

**The trigger.** `netassert-controller` has `imagePullPolicy: IfNotPresent` on
a local-only tag that exists on no registry, so kubelet pulls forever with
textbook exponential backoff. The loader's purge-before-import did run, and
kubelet re-poisoned the record during the 334-second adopt wait. Raising the
adopt budget from 20 to 300 seconds made it strictly worse: it gave kubelet
more chances to rewrite the record.

**Why review missed it for four months.** `docker.io` reads as obviously
correct. It was the only one of five mappings where field 2 (the upstream
remote) and field 4 (the server) named different hosts. The other four were
already self-consistent.

Fixed in `adca5639`.

## 3 · One AFM archive path shared by four lanes

**Symptom.** `the delivered AFM image hashes 3a64f0694fa3 and f91275f4fd69 was
sent. The archive is corrupt in transit`.

**Cause.** Four lanes run `make gcp-tf-demo-up` concurrently from one checkout.
`LOCAL_AFM_ARCHIVE` defaulted to `${REPO_ROOT}/.afm-image/kubesec-afm.tar.gz`,
which is the same path for all four lanes. Each lane rebuilds the archive
before it delivers it. So lane B's `k8s-afm.sh save` truncates and rewrites the
244 MB file that lane A is part-way through copying.

Measured on an in-place four-lane redeploy:

| Lane | Built and hashed | Delivered bytes hashed |
| :--- | :--- | :--- |
| ci-1 | `f91275f4fd69` | `3a64f0694fa3` |
| demo-1 | | `3a64f0694fa3` |
| demo-2 | | `3a64f0694fa3` |
| ci-2 | | `3a64f0694fa3` |

ci-1 sent the archive it built. The other three had rewritten the file
underneath it.

**Why the message misleads.** That error is true from the receiving end and
misleading everywhere else. It sends you to `scp`, to MTU, to the tunnel.
Nothing was wrong with the network. The file changed under the sender.

**The class.** This is the second instance. The first was `REPORT_DIR`, which
surfaced as `mv: cannot stat '.../demo-reports'`. Neither was visible in
review, because a bare path under `REPO_ROOT` is exactly what a single-lane
script should use. It becomes wrong only given a caller that runs four at once.
That is a fact about the Makefile, not about the line you are reading.

NOTE: The remote path is deliberately **not** keyed on `ENV_KEY`, and the test
suite asserts that. It derives from `REMOTE_WORK_DIR`, which is already
per-VM, and both sides of the SSH boundary compute it independently from the
same rule. Keying it "for symmetry" would break that.

Fixed in `829109bd`.

## 4 · Only one of four fleet publishers filtered the observability tenants

**Symptom.** Three of four lanes aborted at stage 5 of 8 on `context deadline
exceeded`. The estate never converged.

**Cause.** `ENABLE_OBSERVABILITY=false` is the intended state, and
`push_foundation` honoured it correctly. Three other paths publish the same
`acme/fleet` artifact, and none of them filtered:

- `scripts/ci/vm-pipeline.sh` → `retry 3 make push-local-fleet`
- `Makefile` → `demo-agent-trust-up` → `$(MAKE) push-local-fleet`
- `Makefile` → `demo-signalloom-up` → `$(MAKE) push-local-fleet`

All three reach `push-local.sh fleet` → `push_fleet`, whose default argument
was the raw unfiltered fleet. So every bring-up published a correct two-tenant
fleet at bootstrap, then overwrote it with a four-tenant one an hour later.

**The evidence is the age gap.** Measured on `sl-demo-1-vm` before the fix:

| Kustomization | Age | Ready | Status |
| :--- | :--- | :--- | :--- |
| `cert-manager/infra-controllers` | 12h | True | Applied |
| `ingress/infra-controllers` | 12h | True | Applied |
| `monitoring/infra-controllers` | 9h | False | Source artifact not found |
| `trivy-system/infra-controllers` | 9h | False | Source artifact not found |

Those four Kustomizations retry forever.

**The lesson.** A filter that lives in one publisher is not a filter. It is a
property of that publisher. The fix moved the filter into
`scripts/lib/fleet-source.sh` as a library that every publisher calls.

Fixed in `814824a8`.

## 5 · A `DEMO_*` environment leak let a test stub overwrite the real run

**Symptom.** Nine assertions in `gcp-demo-pipeline.bats` looked for a file that
was never created. The lane read FAIL 24/29 with five stages red.

**Cause.** The suite ran the driver with the **outer** run's `DEMO_*`
environment live, because `demo-up.sh` exports its configuration into every
stage. `demo-pipeline.sh:141` reads
`${DEMO_SUMMARY_FILE:-${REPORT_DIR}/summary.json}` in preference to
`DEMO_REPORT_DIR`, so an override of the report directory did not redirect the
verdict. The stub wrote its `summary.json` into the real run's
`/opt/signalloom/reports/summary.json`.

WARNING: ANY MID-RUN POLL OF THAT FILE READ A STUB'S VERDICT, NOT THE RUN'S.
A test process silently overwrote the artefact that decides whether the real
run passed.

**The fix, and why it is wider than the bug.** `setup()` now clears the whole
`DEMO_*` namespace, not the one variable, because the leak is structural.
Exporting `DEMO_SUMMARY_FILE` reproduces all nine failures by number on any
machine. The new `ENVLEAK` test asserts the neutralisation, and asserts that
the neutralisation is load-bearing.

**What the same investigation found.** Five stages were red and only three
were genuinely VM-only. Two had been reported as VM-only for two sessions:

- Two vacuous assertions used `[ "$status" -ne 0 ]` as the **only** assertion,
  which passes when the file cannot be read at all.
- `guard-falsification-proof.sh` asked "does a runner name this file?" with a
  basename grep. Two runners glob instead, so 34 suites and 21 proof scripts
  counted as invoked by nothing, at baseline, on every machine. The counts were
  identical locally. It was never a VM condition.

Fixed in `f788590f`.

## What the five have in common

1. **Each one succeeded.** The registry served, the fallback returned 200, the
   archive copied, the fleet published, the stub wrote its summary. Success at
   the wrong thing produces no error to read.
2. **Each surfaced away from its cause.** A pull-time defect surfaced in CRI
   adoption. A sender-side race surfaced as a transit-corruption message.
3. **Two were the second instance of a class already fixed once.** Shared
   mutable state under `REPO_ROOT`, and state inside a tree the delivery wipes.
   Fix the class, not the line.
4. **A single observation is not a class.** Blocker 1 was mislabelled
   "transient" on one data point, and then recurred on every lane.
