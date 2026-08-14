# Signalloom D2 E2E CI — Persistent GCP VM

Runs the full Signalloom D2 test suite on a persistent GCP VM that
**suspends after each successful run** (no cost while idle, ~10s resume).
On failure the VM stays running so you can SSH in and debug.

Kind cluster + Zot registry + Flux bootstrap + Dex auth + Gateway routing +
8-stage test suite + Playwright browser journeys. Produces an
[OpenReports](https://openreports.io/) format report (`openreports.io/v1alpha1 Report`).

## Security model

- **No inbound traffic.** The VM has no external IP. All access is via IAP tunnel.
- **Cloud NAT** provides outbound-only internet (Docker Hub pulls, tool downloads).
- **Deploy key** is a read-only GitHub SSH key stored in Secret Manager (europe-west2 only).
- **VM service account** has only `secretmanager.secretAccessor` (scoped to the deploy key)
  and `logging.logWriter`. No compute admin, no storage, no other APIs.
- **Shielded VM** with secure boot, vTPM, and integrity monitoring.
- **All data stays in europe-west2.** No external registries, no artifact push, no data egress.

## One-time setup

```bash
# 1. Enable required APIs
gcloud services enable \
  compute.googleapis.com \
  secretmanager.googleapis.com \
  iap.googleapis.com \
  --project=cp-dev-ajm

# 2. Create the deploy key secret (europe-west2 only)
gcloud secrets create signalloom-deploy-key \
  --project=cp-dev-ajm \
  --replication-policy=user-managed \
  --locations=europe-west2

# 3. Generate a read-only deploy key for osramp-demo
ssh-keygen -t ed25519 -C "signalloom-ci-deploy-key" -f /tmp/signalloom-ci-key -N ""

# 4. Add the public key to the osramp-demo repo on GitHub
#    Settings → Deploy keys → Add deploy key (read-only)
cat /tmp/signalloom-ci-key.pub

# 5. Store the private key in Secret Manager
gcloud secrets versions add signalloom-deploy-key \
  --project=cp-dev-ajm \
  --data-file=/tmp/signalloom-ci-key

# 6. Delete the local copy
rm /tmp/signalloom-ci-key /tmp/signalloom-ci-key.pub

# 7. Ensure your gcloud identity has the required roles
gcloud projects add-iam-policy-binding cp-dev-ajm \
  --member="user:andy@control-plane.io" \
  --role="roles/compute.admin"

gcloud projects add-iam-policy-binding cp-dev-ajm \
  --member="user:andy@control-plane.io" \
  --role="roles/iap.tunnelResourceAccessor"

# 8. Provision the VM (creates VPC, NAT, firewall, SA, VM — idempotent)
make ci-provision
```

### GitHub Actions setup

For the GHA workflow (`.github/workflows/signalloom-ci.yaml`):

```bash
# Option A: Workload Identity Federation (recommended)
# Create a pool + provider, grant the GHA SA the required roles:
#   - roles/compute.instanceAdmin.v1
#   - roles/iap.tunnelResourceAccessor
#   - roles/compute.osLogin
# Set repo secrets:
#   GCP_WORKLOAD_IDENTITY_PROVIDER
#   GCP_SA_EMAIL

# Option B: Service account key (simpler, less secure)
# Set repo secret GCP_SA_KEY with the JSON key
```

## Usage

### Local CLI

```bash
# Provision (one-time)
make ci-provision

# Run tests (resumes VM, runs pipeline, suspends on pass)
make ci-gcp

# What did the last run DO? Local, network-free, safe to run mid-run.
# Names the report file it read by absolute path, flags a report belonging to
# another commit or another checkout, and exits 0 only on PASS.
make ci-state
make ci-state-2

# View last report
make ci-report

# Check VM status
make ci-status

# Debug SSH (resumes if suspended)
make ci-ssh

# Custom timeout
CI_TIMEOUT_MINUTES=120 make ci-gcp

# Custom machine type
GCP_CI_MACHINE_TYPE=n2-standard-32 make ci-provision

# Isolated second CI worker: provision if needed, then run all stages
make ci-gcp-2

# Inspect the second worker and its isolated report directory
make ci-status-2
make ci-report-2

# Resume VM2 for evidence-led debugging after a failed run
make ci-ssh-2

# Destroy everything (decommission)
./scripts/ci/gcp-ci.sh destroy
```

### GitHub Actions

The workflow runs:
- **On demand** via `workflow_dispatch` (with configurable timeout and debug flag)
- **Nightly** at 02:00 UTC (03:00 BST)

On failure with `debug_on_failure: true` (default), the VM stays running.
SSH in to debug:

```bash
gcloud compute ssh --tunnel-through-iap signalloom-ci \
  --zone=europe-west2-a --project=cp-dev-ajm

# On the VM:
tail -f /var/log/ci-pipeline.log
kubectl get pods -A
docker ps

# When done:
gcloud compute instances suspend signalloom-ci \
  --zone=europe-west2-a --project=cp-dev-ajm
```

## VM lifecycle

```
 provision          run (pass)         run (fail)
     │                  │                  │
     ▼                  ▼                  ▼
 ┌────────┐       ┌──────────┐       ┌──────────┐
 │CREATING│──────►│ RUNNING  │──────►│ RUNNING  │ ← left up for debug
 └────────┘       └──────────┘       └──────────┘
     │                  │
     ▼                  ▼
 ┌──────────┐     ┌──────────┐
 │SUSPENDED │◄────│SUSPENDED │ ← ~£0.02/day (disk only)
 └──────────┘     └──────────┘
     │
     ▼ (next run)
 ┌──────────┐
 │ RUNNING  │ ← resumes in ~10s
 └──────────┘
```

## Operating the VMs — traps that cost real time

Every entry here was a live failure. They share a shape: the symptom names
something other than the cause, so the obvious diagnosis is the wrong one.

### `SUSPENDED` is the SUCCESS state, not evidence nothing ran

`gcp-ci.sh run` suspends on pass and deliberately **leaves the VM RUNNING on
failure** so you can SSH in and investigate. A suspended VM therefore means the
last run passed — *unless someone suspended a failed VM by hand to stop the
cost*, which is the normal thing to do and produces the identical state.

**The VM's state is not a verdict. Read `ci-reports*/summary.json`, which always
exists and always says which run it belongs to:**

| `outcome` | Means |
|-----------|-------|
| `PASS` | Every stage passed. Also carries `collected_at`. |
| `FAIL` | Stages ran and some failed. VM left running. |
| `ABORTED` | The run never reached a verdict. `phase` names how far it got. **Not a test failure.** |
| `RUNNING` | A run is in flight right now, or was killed without its trap running (compare `started_at` against the 180m fence). **Not a verdict.** |

`commit` and `branch` name the source under test; `written_at` / `collected_at`
date the claim. The directory is rotated to `ci-reports*.prev` at run **start**,
so the previous round's verdict is never readable as the current one's — and a
`summary.json` whose `commit` disagrees with the tree under test is rejected as
`ABORTED` rather than reported.

`gcp-ci.sh status` prints all of this together with the observation time and the
VM's `lastStartTimestamp`, so no state has to be dated by hand.

### Reports are per-checkout, so the obvious directory can hold a foreign answer

`REPORT_DIR` is `<checkout>/ci-reports`, and this repo routinely has a dozen
checkouts — the main one plus a worktree per agent. That locality is correct:
two lanes running concurrently must not share a report directory. It also means
**the obvious place to look is not necessarily the place that ran.** On
2026-08-14 the main checkout's `ci-reports-2/summary.json` said `d574d7d PASS
11/11` from the previous day while the run everyone cared about had finished an
hour earlier in a lane worktree. That artefact was honest — main did produce it —
and was still the wrong answer.

`make ci-state` is the answer to "what happened to the last run?". It is local,
touches neither gcloud nor the lock, and is safe to run while a lane is in
flight. It prints:

- the **absolute path** of the report file it read, and the checkout + HEAD it
  read it from — the data was never the problem, knowing which file was
  authoritative was;
- the verdict, from the same `classify_run_outcome` the run itself uses, so
  there is never a second opinion. `STALE` when the report names another commit;
- for a `RUNNING` marker, whether the process that wrote it is **still alive**,
  by checking the recorded `pid` and `host`. A marker whose process is gone is
  reported as `ABORTED`, and a live pid that started *after* the marker is
  reported as a recycled number, not as a run;
- `origin`, the checkout that produced the report, so a copied or inherited
  directory cannot pass as a local one;
- `NEWER ELSEWHERE`, naming any other checkout of this repo holding a fresher
  report — compared on the time the report *claims*, not file mtime, because
  mtime is re-dated by any copy.

It exits 0 only on `PASS`; `FAIL`, `ABORTED`, `STALE` and in-flight all exit
non-zero, so `make ci-state && <next step>` cannot proceed on a non-verdict.

#### Two separate ways a report lands in the wrong checkout

They look identical from the outside and neither one explains the other, so both
had to be fixed:

**Writing.** `CI_2_ENV` set `GCP_CI_REPORT_DIR=ci-reports-2` — a *relative*
value, where the warm lane used gcp-ci.sh's absolute script-anchored default.
A relative value resolves against the cwd of the process that reads it, so the
cold lane's reports followed the caller around while the warm lane's did not.
That asymmetry is how `/home/andy/src/cp/osramp-demo/ci-reports-2/` came to hold
a report from a run nobody made there. Fixed at both ends: `$(abspath …)` in
CI_2_ENV, and gcp-ci.sh anchors a relative override at `REPO_ROOT` so a
hand-typed `GCP_CI_REPORT_DIR=…` cannot reintroduce it. Guarded by
`test/ci-path-anchoring.bats`, which derives from the Makefile rather than from
a remembered list of paths — the third instance of this class in this repo, after
`../$(KEYS_DIR)` and `AUDIT_ANCHOR_KEYS`.

**Reading.** Independent of the above, and it bites agents hardest: a shell that
has not `cd`-ed anywhere starts in the *main checkout*, not in the worktree the
work is happening in. So `ls ci-reports/` or `jq . ci-reports/summary.json`
typed without an explicit path reads the main checkout's reports no matter which
worktree you believe you are in. This is why a lane agent could see a report its
own worktree had never produced under `ci-reports/` — the *absolute* one, which
the writing bug above provably cannot move. **Never read a report by relative
path.** `make ci-state` prints the absolute path it read for exactly this
reason.

#### A `RUNNING` marker can only be stranded by SIGKILL

`gcp-ci.sh run` arms `trap run_exit_trap EXIT` before it touches the VM, and
bash runs an EXIT trap on SIGTERM, SIGINT and SIGHUP as well as on a normal
exit — verified, not assumed. `timeout(1)` sends SIGTERM first, so even the
outer fence converts the marker to `ABORTED`. The one signal that bypasses it is
SIGKILL, which no handler can catch: `timeout -k` after its grace period, an
OOM kill, or `kill -9`. Such a run leaves `RUNNING` on disk forever.

Making that impossible is not available. Making it self-evident is: the marker
records `pid` and `host` as fields, and `ci-state` checks whether that process
is still alive. Gone means `ABORTED` and says so. Do not add a heartbeat to
`written_at` — a timestamp cannot separate a slow run from a dead one, and the
pid already can.

### `unset SSH_AUTH_SOCK` before any ad-hoc `gcloud compute ssh`

With an agent loaded, `gcloud compute ssh` fails with `agent refused operation`.
The wrapper scripts handle this; ad-hoc calls do not. The failure surfaces
during the provisioning wait, so it reads as **a VM that never came up** — you
will go looking at the serial console for a machine that is perfectly healthy.

```bash
unset SSH_AUTH_SOCK
gcloud compute ssh signalloom-ci-2 --zone europe-west2-a --project cp-dev-ajm --tunnel-through-iap
```

### NEVER run `gcp-ci.sh destroy` for `signalloom-ci`

`cmd_destroy` deletes the **shared VPC, Cloud NAT and firewall rules** that BOTH
VMs depend on, not just the instance. Destroying VM1 breaks VM2 mid-run and
costs ~15 minutes to rebuild. It early-returns to an instance-only delete for any
other VM name, so `signalloom-ci-2` is safe to destroy — that is exactly how you
get a genuine cold run, since `provision` is idempotent and will otherwise resume
a warm disk.

### The lock is PER-VM, and a stale one looks identical to a live one

`ci-lock` state lives at `/home/ci/.ci-lock` **on whichever VM is targeted** —
`ci-lock.sh` contains no VM name at all; `lock_shim` bakes `$VM_NAME` into the
SSH command. So the two lanes hold independent locks and **warm and cold can run
concurrently**. A refusal on one lane is that VM's own stale lock, never
contention with the other.

Before forcing, prove nothing is actually running:

```bash
unset SSH_AUTH_SOCK
gcloud compute ssh signalloom-ci-2 --zone europe-west2-a --project cp-dev-ajm --tunnel-through-iap \
  --command 'pgrep -af "vm-pipeline|bats|pytest"; sudo ls -l /home/ci/.ci-lock'
# nothing running? then:
GCP_CI_FORCE_LOCK=1 make ci-gcp-2
```

Locks older than 240m reclaim automatically. Historically the common cause of a
stale lock was release being scheduled AFTER the suspend, so the release SSH
could never land while `read_lock`'s `|| true` reported `already free` — that
combination leaves a clean-looking log and a lock file on disk. Fixed, but the
signature is worth recognising.

### Warm vs cold, and why cold earns its keep

`make ci-gcp` reuses `signalloom-ci`. `make ci-gcp-2` targets `signalloom-ci-2`;
because `provision` is idempotent, it only gives a **genuinely cold** run if you
destroy the instance first. Cold catches a whole defect class warm cannot:

- `bun.lock` vs `package-lock.json` drift — `bun add` writes the former, the
  dashboard Dockerfile runs `npm ci` against the latter, so a desync builds
  clean locally and fails only on a clean tree. Stage 1b now runs the guard.
- `kind load docker-image` exits 0 having transferred **nothing** on a Docker
  daemon using the containerd image store. Masked warm (the node cache
  survives), fatal cold. Use `scripts/kind-load-verified.sh`.

### A green run that reports failure

If 8/8 (now 9/9) stages pass and `make` still returns non-zero, suspect an EXIT
trap: under `set -e` an EXIT trap's **final command status replaces** the status
given to `exit`. This bit the lock-release path twice. Every path out of a trap
should `return 0` explicitly.

### Debugging shell traps inside the pipeline

- **Never `pgrep`/`pkill` a pattern that appears in your own command line.** The
  Bash tool wraps invocations in `bash -c 'eval ...'`, so the whole script text
  is that shell's `/proc/*/cmdline`. `pkill -f pinentry` kills the shell running
  it (silent exit 144). Filter: `pgrep -af PATTERN | grep -v 'claude\|grep'`.
- **Never `set -u`.** The shell snapshot's `grep`/`rg` wrappers reference
  `$ZSH_VERSION` unguarded; harmless in bash until nounset makes it fatal.
- **Commits are unsigned here.** 199 of the last 200 repo-wide report `N`. Use
  `git commit --no-gpg-sign`; a bare commit launches pinentry against a tty the
  agent cannot reach and blocks until timeout.

## Reports

| File | Format | Content |
|------|--------|---------|
| `summary.json` | JSON | `outcome` (PASS/FAIL/ABORTED/RUNNING), phase, per-stage results, commit SHA, timestamps. Written on every exit path — its absence is itself impossible, so it can be trusted as the verdict |
| `signalloom-ci-report.yaml` | OpenReports v1alpha1 | All tests as ReportResult entries |
| `stage1-static.tap` | TAP | BATS static contract results |
| `stage1b-dashboard-unit.xml` | JUnit XML | vitest dashboard unit + guard suite |
| `stage2-api.xml` | JUnit XML | pytest API contract results |
| `stage3-fakes.xml` | JUnit XML | pytest fake integration results |
| `stage4-dashboard.json` | Go test JSON | Dashboard API ownership results |
| `stage1e-node-images.tap` | TAP | BATS guard on doctor's node-image expectations |
| `stage1f-ci-terminal-state.tap` | TAP | BATS guard on this harness reporting honestly about itself |
| `stage5-harness.tap` | TAP | BATS harness contract results |
| `stage6-flux.tap` | TAP | Flux convergence results |
| `stage7-runtime.tap` | TAP | BATS runtime negative results |
| `stage8-browser.xml` | JUnit XML | Playwright browser journey results |

## Resuming an isolated VM2 investigation

`make ci-gcp-2` tests the current local working tree. Before every run it
archives the tree, replaces only VM2's `/home/ci/osramp-demo-ci-2` checkout,
and extracts the snapshot. This deliberately includes uncommitted changes and
removes paths deleted locally, so a rerun cannot silently test stale code. It
does not alter VM1 or a developer's local Kind cluster.

After a failure, start from the collected summary rather than rerunning:

```bash
make ci-report-2
make ci-ssh-2

# On VM2: inspect the isolated pipeline log and stage artifacts
tail -n 200 /home/ci/ci-pipeline-ci-2.log
ls -lah /home/ci/reports-signalloom-ci-2
```

Read the failing `stage*.{tap,txt}` artifact first, inspect the corresponding
workload or controller, apply one evidence-backed local fix, then rerun
`make ci-gcp-2`. A successful run suspends VM2 automatically; a failure leaves
it running for diagnosis.

## Cold-path failures on the kind node

Two failures that look like application bugs and are not. Both are invisible on
a **warm** VM — the kind node's state survives between runs — and both bite
reliably on a **cold** one, which is why they went unnoticed for so long. Both
were diagnosed on 2026-08-04 after two consecutive CI runs failed identically.

### `kind load docker-image` transfers nothing and exits 0

**Symptom, in the order you meet it:** stages 6, 7 and 8 fail together, ~443s
apart. `fe-signalloom` is empty. `inf-signalloom/infra-configs` is
`Ready=False`, waiting on `fake-integration-proxy` and `netassert-controller`.
Those two pods are in `ImagePullBackOff` with

```
failed to unpack image ... unexpected media type text/html for sha256:… : not found
```

**Nothing in that chain names an image.** The HTML is Docker Hub's 404 page:
kubelet could not find `fake-integration-proxy:dev` locally, so it went looking
for it on the internet.

**Cause.** On a Docker daemon using the containerd image store, `docker save`
emits an OCI index whose layers kind's importer does not always materialise.
`kind load` prints `loading...` and exits 0 having transferred nothing.

**The trap.** `ctr -n k8s.io images ls` *still lists* such an image, because the
content store holds the manifest. Any check built on it passes while the pod
cannot start. `crictl images` is the CRI's view — unpacked, labelled, runnable —
and is the only sound verification.

**Fixed** in `scripts/kind-load-verified.sh`, which every image load in
`make signalloom-images` now goes through: it loads, verifies against `crictl`,
recovers via an archive round-trip if the image is missing, and fails loudly
naming the downstream consequence if recovery does not work. Guarded by
`make test-kind-load-verified` (12 tests against fake docker/kind clients, no
cluster needed; 10 of the 12 fail against the pre-fix behaviour).

**Manual recovery**, if you meet this on an older checkout — the flags are not
interchangeable:

```bash
NODE=osramp-control-plane
# No --platform: the single-platform form imports into something ctr lists
# and crictl does not, which is the same dead end by another route.
docker save -o /tmp/img.tar fake-integration-proxy:dev
docker cp /tmp/img.tar "$NODE:/var/tmp/img.tar"
docker exec "$NODE" ctr -n k8s.io images import \
  --all-platforms --digests --snapshotter=overlayfs /var/tmp/img.tar
# Load-bearing. Without the label the CRI does not adopt the image and
# `crictl images` still will not list it.
docker exec "$NODE" ctr -n k8s.io images label \
  docker.io/library/fake-integration-proxy:dev io.cri-containerd.image=managed
docker exec "$NODE" crictl images | grep fake-integration   # must print a row
kubectl -n inf-signalloom delete pod -l app.kubernetes.io/name=fake-integration-proxy
```

### Zot's cache becomes a stale bind mount and 500s every push

**Symptom.** Every `make push-local-*` fails with

```
POST http://localhost:5001/v2/…/blobs/uploads/: unexpected status code 500 Internal Server Error
```

and every `OCIRepository` in the cluster reads `NAME_UNKNOWN: repository name
not known to registry` — the whole fleet source disappears at once. Zot's own
log says `readdirent /var/lib/zot: no such file or directory`.

**Cause.** Zot mounts `/var/local/osramp-zot-cache` from the node as a
hostPath. That path can survive as a *mount entry* whose backing directory is
gone, leaving a dentry with a link count of 0. `ls -ld` shows the directory;
`rm -rf` says `Device or resource busy`; a fresh pod's init container fails with
`error mounting … no such file or directory`. Recreating the cluster does not
clear it, because the stale mount is inside the node container.

**Recovery** — the `umount -l` is the part that is easy to miss:

```bash
NODE=osramp-control-plane
docker exec --privileged "$NODE" sh -c '
  umount -l /var/local/osramp-zot-cache 2>/dev/null
  rm -rf    /var/local/osramp-zot-cache
  mkdir -p  /var/local/osramp-zot-cache
  chown 65532:65532 /var/local/osramp-zot-cache
  chmod 0750        /var/local/osramp-zot-cache'
kubectl -n registry delete pod --all --force --grace-period=0
# Then re-push everything the registry lost:
make push-local-foundation && make push-local-signalloom && make bootstrap-local
```

### `signalloom-infra` inputs are reset by a fleet re-apply

Re-applying the fleet resets `spec.inputs` on the `signalloom-infra`
ResourceSet to `[]`, after which it fails to build with `map has no entry for
key "tenant"` and renders **none** of its resources — including the whole
`supercred-demo-runner` RBAC. The runner then deploys and passes both probes
with no permissions at all. Re-activate with `./scripts/signalloom-local.sh up`,
and confirm with:

```bash
kubectl auth can-i get pods -n fe-signalloom \
  --as=system:serviceaccount:fe-signalloom:supercred-demo-runner   # must be: yes
```

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | All 8 test stages passed (VM suspended) |
| 1 | One or more test stages failed (VM left running) |
| 2 | Infrastructure error (VM not found, SSH failure, etc.) |

## Cost

- **Suspended:** ~£0.02/day (disk storage only, no compute)
- **Running:** ~£0.75/hr (n2-standard-16 in europe-west2)
- **Typical run:** 40–60 minutes → ~£0.50–0.75 per run
- **Monthly (nightly runs, 30 days):** ~£20 compute + £0.60 disk = ~£21
