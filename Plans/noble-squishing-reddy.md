# Plan: GCP Ephemeral CI VM for Signalloom D2 E2E Tests

## Context

The Signalloom D2 platform baseline has an 8-stage test suite (`signalloom-test-1.sh`) covering static contracts, API contracts, fake integrations, dashboard API, harness, Flux convergence, runtime negatives, and Playwright browser journeys. Currently this only runs locally — there's no CI that exercises the full Kind cluster + Flux + Dex + Gateway + browser stack. We need confidence that the integrated system works on a clean machine, every time.

The approach: an ephemeral GCP VM (n2-standard-16, europe-west2) that provisions itself, runs the full pipeline, produces a SARIF report, and self-destructs. Security-first: no ingress, IAP tunnel only, deploy key via Secret Manager, no data leaves the region.

## Files to Create

| File | Purpose |
|------|---------|
| `scripts/ci/gcp-ci.sh` | Local orchestrator — creates GCP infra, launches VM, polls for completion, collects reports, destroys everything |
| `scripts/ci/vm-startup.sh` | VM startup script — installs Docker, fetches deploy key, clones repo, runs full pipeline, emits SARIF, signals completion |
| `scripts/ci/sarif-convert.sh` | Converts JUnit XML + TAP + Go JSON test output to SARIF 2.1.0 |
| `scripts/ci/README.md` | One-time setup steps + usage |

## Files to Modify

| File | Change |
|------|--------|
| `Makefile` | Add `ci-gcp` and `ci-report` targets |

## Architecture

```
Local machine                         GCP europe-west2
┌──────────────┐                      ┌─────────────────────────────────┐
│ gcp-ci.sh    │──gcloud create──►    │ n2-standard-16 (no external IP) │
│              │                      │                                 │
│              │                      │ vm-startup.sh:                  │
│              │                      │  1. Install Docker CE + Node    │
│              │                      │  2. Fetch deploy key (SecretMgr)│
│              │                      │  3. Clone osramp-demo           │
│              │                      │  4. setup.sh --tools-only       │
│              │                      │  5. make up (Kind+Zot+Flux)     │
│              │                      │  6. Container builds → Zot      │
│              │                      │  7. signalloom-local.sh up      │
│              │                      │  8. 8-stage test suite          │
│              │                      │  9. SARIF conversion            │
│              │◄──serial port────    │ 10. Signal CI_COMPLETE_PASS/FAIL│
│ SCP reports  │◄──IAP tunnel───      │                                 │
│ Destroy all  │──gcloud delete──►    └─────────────────────────────────┘
└──────────────┘
```

## Security Model

- **VPC:** Dedicated `signalloom-ci` with single subnet in europe-west2
- **Firewall:** Default deny all ingress → allow IAP SSH only (35.235.240.0/20 TCP:22) → allow all egress
- **Cloud NAT:** Outbound-only internet (Docker Hub pulls, tool downloads) — no external IP on VM
- **VM SA:** `signalloom-ci-vm@cpdev-ajm` — only `secretmanager.secretAccessor` (scoped to deploy key via IAM condition) + `logging.logWriter`. No compute admin, no storage
- **Shielded VM:** Secure boot + vTPM + integrity monitoring
- **Deploy key:** Read-only GitHub SSH key, stored in Secret Manager with europe-west2-only replication
- **No data egress:** All containers built/pushed to Zot inside Kind. Reports SCP'd back via IAP tunnel. Nothing leaves the region

## GCP Resource Lifecycle

All resources created per-run and destroyed after:

1. **Create** (idempotent service account, then per-run VPC + NAT + firewall + VM)
2. **Poll** serial port for `CI_COMPLETE_PASS` / `CI_COMPLETE_FAIL` / `CI_COMPLETE_ERROR` (30s interval, 90min timeout)
3. **Collect** reports via `gcloud compute scp --tunnel-through-iap`
4. **Destroy** VM → NAT → router → firewall rules → subnet → VPC (EXIT trap, all `|| true`)

Collision prevention: if VPC already exists at start, abort with message (another run is active or stale). `--cleanup-only` flag for manual recovery.

## Test Output Capture → SARIF

Each stage captured individually (not via signalloom-test-1.sh, which only produces console output):

| Stage | Test | Output Format | SARIF Conversion |
|-------|------|---------------|------------------|
| 1 | `make -C d2-signalloom test` | TAP (BATS) | Parse `ok`/`not ok` lines |
| 2 | pytest API contracts | JUnit XML (`--junit-xml`) | Parse `<testcase>` elements |
| 3 | pytest fake integrations | JUnit XML (`--junit-xml`) | Parse `<testcase>` elements |
| 4 | `go test -json ./...` | Go test JSON | Parse `pass`/`fail` events |
| 5 | `bats --tap` harness | TAP | Parse `ok`/`not ok` lines |
| 6 | `make demo-signalloom-test` | TAP (BATS) | Parse `ok`/`not ok` lines |
| 7 | `bats --tap` runtime | TAP | Parse `ok`/`not ok` lines |
| 8 | Playwright browser | JUnit XML (`PLAYWRIGHT_JUNIT_OUTPUT_FILE`) | Parse `<testcase>` elements |

Output: `signalloom-test-1.sarif` (SARIF 2.1.0, one run per stage) + `summary.json` (pass/fail per stage + overall).

SARIF converter is an inline Node.js script — zero npm deps, handles all three formats (TAP, JUnit XML, Go JSON).

## Makefile Targets

```makefile
ci-gcp:  ## Run Signalloom D2 e2e on ephemeral GCP VM
ci-report:  ## View last ci-gcp SARIF report
```

## Error Handling

| Failure | Detection | Response |
|---------|-----------|----------|
| VM create fails | gcloud non-zero | EXIT trap cleans VPC/firewall |
| Docker/tools install fails | ERR trap in vm-startup.sh | Serial port `CI_COMPLETE_ERROR` |
| Docker Hub rate limit | docker build fails | `retry 3` wrapper |
| Pipeline hangs | 90min timeout in polling loop | Cleanup + exit 2 |
| VM crashes | Status TERMINATED/STOPPED | Detected in poll, cleanup + exit 2 |
| SCP fails | gcloud scp non-zero | Warning only, exit code reflects pipeline |
| Concurrent runs | VPC already exists | Abort with message |

## One-Time Setup (in README)

```bash
gcloud services enable compute.googleapis.com secretmanager.googleapis.com iap.googleapis.com --project=cpdev-ajm
gcloud secrets create signalloom-deploy-key --project=cpdev-ajm --replication-policy=user-managed --locations=europe-west2
gcloud secrets versions add signalloom-deploy-key --project=cpdev-ajm --data-file=path/to/deploy-key
```

## Verification

1. `make ci-gcp` completes with exit 0 or 1 (not 2/error)
2. `ci-reports/signalloom-test-1.sarif` is valid SARIF 2.1.0
3. `ci-reports/summary.json` has all 8 stages with status
4. No GCP resources remain after run: `gcloud compute instances list --project=cpdev-ajm | grep signalloom-ci` returns empty
5. `gcloud compute networks list --project=cpdev-ajm | grep signalloom-ci` returns empty
6. VM had no external IP: verified in create command (`--no-address`)
7. IAP SSH works during run: `gcloud compute ssh --tunnel-through-iap $VM_NAME` connects
