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

## Reports

| File | Format | Content |
|------|--------|---------|
| `summary.json` | JSON | Overall pass/fail, per-stage results, commit SHA |
| `signalloom-ci-report.yaml` | OpenReports v1alpha1 | All tests as ReportResult entries |
| `stage1-static.tap` | TAP | BATS static contract results |
| `stage2-api.xml` | JUnit XML | pytest API contract results |
| `stage3-fakes.xml` | JUnit XML | pytest fake integration results |
| `stage4-dashboard.json` | Go test JSON | Dashboard API ownership results |
| `stage5-harness.tap` | TAP | BATS harness contract results |
| `stage6-flux.tap` | TAP | Flux convergence results |
| `stage7-runtime.tap` | TAP | BATS runtime negative results |
| `stage8-browser.xml` | JUnit XML | Playwright browser journey results |

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
