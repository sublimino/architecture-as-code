# AGENTS.md — osramp-demo

This document is the primary onboarding guide for agents. Read this document first.
Then read the per-slice `AGENTS.md` file for your target D2 installation.

For the complete documentation map, including GCP lanes and debugging guides, see
[`docs/README.md`](docs/README.md).

## Repository Purpose

This monorepo hosts the OSRAMP and Signal Loom demonstration platform. It hosts
independent D2 delivery slices that share a Kind cluster foundation, Flux GitOps
control plane, and Envoy Ingress Gateway.

## Shared Foundation Stack

| Layer | Technology | Location |
|-------|-----------|----------|
| Cluster | Kind (single-node `osramp`) | `make up` / `make cluster` |
| GitOps | Flux Operator + ResourceSets | `d2-osramp-fleet/` |
| Ingress | Envoy Gateway (Gateway API, TLS) | `d2-infra/components/ingress/` |
| Registry | Zot (in-cluster, persistent `.cache/zot`) | `d2-osramp-fleet/local/zot.yaml` (`make registry`) |
| Signing | cosign + witness | `.keys/` (made by `make signing-keys`) |
| Monitoring | kube-prometheus-stack + Grafana | `d2-infra/components/monitoring/` |
| Certs | cert-manager (self-signed cluster issuer) | `d2-infra/components/cert-manager/` |

## D2 Slices

Each slice is an independent deployment boundary. Slices share the cluster, but
each slice owns its namespaces, images, tests, and lifecycle.

| Slice | Purpose | Deploy | AGENTS.md |
|-------|---------|--------|-----------|
| `d2-signalloom/` | Signal Loom agent governance platform (dashboard, docs, API, identity, infra) | `make demo-signalloom-up` | `d2-signalloom/AGENTS.md` |
| `d2-osramp-apps/` | OSRAMP application services (archiver, listener, processor) | `make demo-osramp-up` | `d2-osramp-apps/AGENTS.md` |
| `d2-k8s-afm/` | KubeSec-AFM formal-methods RBAC analysis | `make demo-k8s-afm-up` | `d2-k8s-afm/AGENTS.md` |
| `d2-osramp-fleet/` | Flux fleet definitions (clusters, tenants, ResourceSets) | `make up` (foundation) | `d2-osramp-fleet/AGENTS.md` |
| `d2-infra/` | Shared infrastructure components | `make up` (foundation) | `d2-infra/AGENTS.md` |
| `d2-agent-trust/` | Contract-first SPIFFE agent trust hierarchy (A2A identity, OpenBao JWT roles, NetworkPolicies) | `make demo-agent-trust-up` | `d2-agent-trust/AGENTS.md` |
| `d2-cpai/` | CPAI runtime (aichat conversation demo) | `make demo-cpai-up` | `d2-cpai/README.md` |
| `olly-replica/` | Olly Sentinel AI SRE replica | `make demo-olly-up` | `olly-replica/README.md` |
| `d2-kagent` (D5) | CNCF Kagent AI Agent framework (CRDs, declarative swarm, SPIFFE/OpenBao) | `make swarm-kagent-up` && `make demo-kagent-up` | `docs/kagent-d5.md` |

One optional service deploys outside the Signal Loom `-up` target:

| Service | Deploy | Consumed by |
|---------|--------|-------------|
| `afm-platform` | `make demo-k8s-afm-up` (opt-in service) | `/rbac-analysis` and `/rbac-explorer`, plus nginx prefixes and API httpx call |

`make demo-signalloom-up` deploys Fleet Manager through Flux. The target
`make demo-signalloom-fleet-up` is a direct-apply test escape hatch. Do not use
that target as the normal deployment path.

The command `make demo-k8s-afm-up` builds its image from `$KUBESEC_AFM_ROOT`. The
default path is the sibling of the repository root, `<repo>/../kubesec-afm`
(`scripts/k8s-afm.sh:45`). If that checkout does not exist, `docker build` fails.

CAUTION: In a git worktree, that default path does not exist. A worktree lives
outside the source checkout. Set the variable before you build:

```bash
export KUBESEC_AFM_ROOT=/path/to/kubesec-afm
```

Run `make gcp-tf-worktree-check` to check this condition.
See [`docs/gcp-demo/OPERATIONS.md`](docs/gcp-demo/OPERATIONS.md) for more worktree details.

Before you add a backend service, read
[`docs/deploying-a-backend-service.md`](docs/deploying-a-backend-service.md). Four
independent layers can each break the page, and none reports "not deployed".

## Quick Start

```bash
# 1. Start foundation: Kind cluster, Zot registry, signing keys, Flux
make up

# 2. Start a demo slice (or combine them):
make demo-signalloom-up    # Signal Loom
make demo-osramp-up        # OSRAMP apps
make demo-k8s-afm-up       # KubeSec-AFM
make demo-olly-up           # Olly Sentinel
make demo-bao-up            # OpenBao and SPIRE only
make demo-agent-trust-up    # SPIFFE agent trust (requires inf-bao first)
make demo-cpai-up           # CPAI runtime
make swarm-kagent-up        # Kagent CRDs and Control Plane (D5)
make demo-kagent-up         # Kagent Declarative Agents (D5)
make demo-signalloom-fleet-up  # Fleet Manager direct-apply test escape hatch

# 3. Check health
make healthcheck            # check foundation readiness
make doctor                 # make comprehensive cluster diagnostic report
```

## Shared Lifecycle Commands

| Command | Action |
|---------|--------|
| `make up` | Start foundation: Kind, Zot, signing keys, Flux |
| `make down` | Delete Kind cluster (keeps persistent Zot cache) |
| `make teardown` | Full reset including keys and build state |
| `make teardown-all` | Full reset including tools installed by setup.sh |
| `make healthcheck` | Check foundation readiness for demos |
| `make doctor` | Make comprehensive cluster diagnostic report |
| `make cluster-debug` | Same as `make doctor` |
| `make help` | List all make targets |

## Shared Cluster Diagnostics

Run `make doctor` before you examine a cluster problem. The commands `make doctor`
and `make cluster-debug` are identical, read-only diagnostic entry points.
The diagnostic checks cluster connectivity, unhealthy pods, restart counts,
warning events, Flux state, node metrics, and image-pull failures. Read
[`TESTING.md`](TESTING.md#shared-cluster-diagnostics) for the step-by-step runbook.

### Per-Slice Lifecycle Pattern

Most demonstration slices follow this pattern:
```bash
make demo-<slice>-up        # Deploy
make demo-<slice>-test      # Static + readiness checks
make demo-<slice>-down      # Remove (keeps foundation)
```

Foundation slices and Kagent use the explicit commands in the slice table.

## Shared Testing Commands

| Command | Scope |
|---------|-------|
| `make test` | Run end-to-end BATS tests on running cluster |
| `make acceptance-test` | Run Playwright browser tests (Signal Loom and KubeSec-AFM) |
| `make demo-signalloom-api-test` | Run FastAPI contract and integration tests |
| `make attested-test` | Run test suite under witness attestation |

Do not write a manual test count for the acceptance suite. Written counts become
stale quickly. The file `test/acceptance/SPEC-REGISTRY.tsv` is the single source
of truth. It records where each spec runs.

The test `test/acceptance-spec-coverage.bats` (CI stage 1c) checks each row
against `playwright.config.ts`, the `Makefile`, and `scripts/ci/vm-pipeline.sh`.
If a row is incorrect or missing, CI fails.

CAUTION: Playwright ignores any spec that no project claims. It reports a
smaller test total and shows no warning. The spec registry marks an unreferenced
spec as `unwired` to make the omission visible.

## The GCP Estate — Four Lanes

The repository also runs on GCP across four independent lanes: `demo-1`,
`demo-2`, `ci-1`, and `ci-2`. Terraform provisions each lane. A separate step
builds the estate on the lane. Pass `ENV=<lane>` with each command.

```bash
make gcp-tf-up        ENV=demo-1              # plan, review, apply, and write hand-off
make gcp-tf-demo-up   ENV=demo-1              # send code, build estate, and run tests
make gcp-tf-ts-up     ENV=demo-1              # serve estate on Tailscale; prints URL
make gcp-tf-ssh       ENV=demo-1              # SSH into lane VM via IAP
make doctor-node      ENV=demo-1              # check node-level health for one lane
make doctor-node-all                          # check every lane with a hand-off file
make gcp-tf-destroy   ENV=demo-1 CONFIRM=demo-1
```

| Document | Purpose |
| :--- | :--- |
| [`docs/gcp-demo/RUNBOOK.md`](docs/gcp-demo/RUNBOOK.md) | Step-by-step instructions from start to browser dashboard |
| [`docs/gcp-demo/OPERATIONS.md`](docs/gcp-demo/OPERATIONS.md) | Lane details, health tooling, and error traps |
| [`docs/gcp-demo/INCIDENTS-2026-08.md`](docs/gcp-demo/INCIDENTS-2026-08.md) | Five incident analyses with diagnostic measurements |

Common traps in `OPERATIONS.md`:
- The `yes` tool outputs `y`. `terraform destroy` requires the exact word `yes`.
- Clear `SSH_AUTH_SOCK` (`unset SSH_AUTH_SOCK`) before any `gcloud compute ssh` command.
- The command `make -n` runs recipe lines that contain `$(MAKE)`.
- Let's Encrypt limits requests to five certificates per exact DNS name per 168 hours.

## The Older CI Lane — Two GCP VMs

This system is separate from the four GCP lanes above. It uses two persistent
VMs (`signalloom-ci` and `signalloom-ci-2`) and runs via `scripts/ci/gcp-ci.sh`.

It runs the end-to-end pipeline against a real cluster. VMs suspend between runs
to save cost. The pipeline `scripts/ci/vm-pipeline.sh` has 8 numbered stages.
See [`scripts/ci/README.md`](scripts/ci/README.md) for the complete guide.

| Command | Action |
|---------|--------|
| `make ci-gcp` | Warm run (reuses `signalloom-ci`) |
| `make ci-gcp-2` | Second lane run on `signalloom-ci-2` |
| `make ci-status` / `ci-status-2` | Show VM state |
| `make ci-ssh` / `ci-ssh-2` | SSH into VM for debugging |
| `make ci-report` / `ci-report-2` | Show last stage summary |

Key rules for CI VMs:
- `SUSPENDED` is the success state. The script suspends a VM on pass and leaves it running on failure.
- Run `unset SSH_AUTH_SOCK` before manual `gcloud compute ssh` commands.
- Never run `gcp-ci.sh destroy` against `signalloom-ci`. It deletes the shared VPC and NAT network.

## Observing Demonstrations

Query the cluster directly to get reliable facts:

| Command | Information Returned |
|---------|----------------------|
| `make doctor` | Full read-only cluster diagnostic |
| `make demo-signalloom-supercred-evidence` | Checks the credential chain across six probes |
| `make demo-agent-trust-network-test` | Checks SPIFFE trust boundaries |
| `make demo-k8s-afm-status` | Checks `afm-platform` status and `/health` |

Do not assume the cause of a page failure. Query the path from inside the dashboard pod:

```bash
kubectl -n fe-signalloom exec deploy/dashboard-signalloom -- \
  curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' \
  http://localhost:8080/fleet-api/v1/fleet/topology
# 200 application/json  → Service is healthy
# 200 text/html         → Missing nginx location; the SPA answered
# 504                   → NetworkPolicy blocked ingress or egress
# DNS failure           → Service is not deployed (run make demo-signalloom-fleet-up)
```

Read `docs/cluster-debugging.md` §8 for tests that can produce false answers.
See [`docs/deploying-a-backend-service.md`](docs/deploying-a-backend-service.md)
for the deployment checklist.

## Repository Layout

```
osramp-demo/
├── Makefile                 # Run `make help` to list documented targets
├── AGENTS.md                # This file (shared foundation)
├── docs/README.md           # Documentation index — start here for anything else
├── d2-signalloom/DESIGN.md   # Visual design guide (dashboard SPA)
├── scripts/                 # Lifecycle, build, and test scripts
├── .keys/                   # cosign + witness keys (gitignored, generated)
├── .cache/zot/              # Persistent Zot OCI cache (gitignored)
│
├── d2-signalloom/           # Signal Loom slice → d2-signalloom/AGENTS.md
│   └── apps/docs-signalloom/ # User documentation service at /docs
├── d2-osramp-apps/          # OSRAMP apps slice → d2-osramp-apps/AGENTS.md
├── d2-k8s-afm/              # KubeSec-AFM slice → d2-k8s-afm/AGENTS.md
├── d2-osramp-fleet/         # Flux fleet → d2-osramp-fleet/AGENTS.md
├── d2-infra/                # Shared infra → d2-infra/AGENTS.md
├── d2-agent-trust/          # SPIFFE agent trust → d2-agent-trust/AGENTS.md
├── d2-cpai/                 # CPAI runtime → d2-cpai/README.md
├── olly-replica/            # Olly Sentinel replica
│
├── tools/demo-console/      # Go: Estate 95 broker + API contract fixtures
├── test/acceptance/          # Playwright browser tests (cross-slice)
├── docs/                    # Per-slice documentation + evidence
└── .github/workflows/       # CI: e2e-local, push-artifacts/images, release
```

## Shared Pitfalls

### Port-forward stops on pod rollout

Every `kubectl rollout restart` command stops active port-forwards. Start
port-forwards again after each image rebuild and deploy cycle.

### Polling semantics — use shared helpers, never `sleep`

The library `scripts/lib/wait.sh` is the canonical polling library. Use it in all
scripts and BATS suites. It checks for object existence first, provides backoff
with jitter, and logs telemetry.

Source `scripts/lib/wait.sh`, then use the appropriate helper:

| Helper | Purpose |
|---|---|
| `wait_rollout <deploy> [-n ns] [deadline]` | **Deployments.** Wraps `kubectl rollout status`. |
| `wait_pods_ready <selector> [-n ns] [deadline]` | Pods by label. Requires at least one match. |
| `wait_k8s_ready <kind> <name> [-n ns] [--for cond] [deadline]` | Pods, Jobs, Flux objects. Waits for condition. |
| `wait_flux_ready <kind> <name> [-n ns] [deadline]` | Waits for Flux resource readiness. |
| `wait_reachable <url> [deadline]` | Waits for an HTTP endpoint response. |
| `wait_tcp <host> <port> [deadline]` | Waits for an open TCP port. |
| `_wait_retry <deadline> <label> <cmd>` | Generic retry with exponential backoff. |

CAUTION: `wait_k8s_ready` defaults to `--for=condition=ready`. Deployments have
no `Ready` condition. Deployments expose only `Available`, `Progressing`, and
`ReplicaFailure`. Because of this, `kubectl wait --for=condition=ready deployment/x`
times out on healthy Deployments. Always use `wait_rollout` for Deployments.

In **Playwright**, use web-first assertions such as
`await expect(locator).toBeVisible()`, `waitForResponse`, and `waitForLoadState`.
Do not use `page.waitForTimeout(n)`. Fixed timeouts cause flaky test runs.

### Mutable `:latest` tag with `imagePullPolicy: IfNotPresent`

After you run `kind load docker-image`, check the image ID in the pod:

```bash
kubectl get pod <name> -n <ns> -o jsonpath='{.status.containerStatuses[0].imageID}'
```

If the ID is stale, run `kubectl delete pod <name>` to force a new image resolve.

### Worktree location

Place worktrees in `~/src/.worktrees/<repo>/<branch>/`. Never create worktrees
inside the repository directory. In-repo worktree directories cause search tools
and test runners to scan duplicate files.

### Kanban and Worktree Runtime Paths

The Kanban runtime and detective telemetry sensors resolve paths via dynamic environment variables:
- `KANBAN_HOME`: Root directory for Kanban controller state, database, and telemetry (defaults to `$HOME/.cline/kanban`).
- `KANBAN_WORKTREES_HOME`: Base directory for Kanban worktrees (defaults to `$HOME/.cline/worktrees`, resolving canonically to `$HOME/src/.worktrees`).
All watchers and detectors must resolve these paths dynamically per call rather than capturing constants at import time.

### Zot cache persistence

The cache directory `.cache/zot/` persists after `make down`. Run
`make zot-cache-reset` if you need to clear the registry cache.

### Flux variable substitution

The setting `postBuild.substituteFrom` in a Flux Kustomization substitutes
variables across the entire manifest text. It affects `spec.inputs` and
`spec.resources`.

To prevent race conditions, add `dependsOn: [{name: flux-system}]` to
`clusters/<env>/tenants.yaml`. This ensures the ConfigMap `flux-runtime-info`
is ready before variable substitution occurs.

If a manifest contains unresolved `${VAR}` strings, run:

```bash
flux reconcile kustomization tenants -n flux-system --with-source
```

This command re-renders the manifests with current ConfigMap values.

**Annotation convention:** Add a `# FLUX ENVSUBST:` header to every
`kustomization.yaml` file containing `${VAR}`:
- `YES` — Reconciled by a Flux Kustomization with `postBuild.substituteFrom`.
- `NO` — Reconciled without `postBuild`. Workload expands variables at runtime.
- `N/A` — Applied outside Flux.
- `FLEET` — Processed by the fleet overlay Kustomization.

## Conventions

- **Commits**: Use Conventional Commits with a slice scope (for example, `feat(signalloom):`, `fix(osramp):`, `test(k8s-afm):`).
- **Image Signing**: Sign all images and OCI artifacts with Cosign. Flux rejects unsigned artifacts.
- **Commit Signing**: Check recent git log signatures before you commit. If the branch history is unsigned, use `git commit --no-gpg-sign`.
- **Supply Chain**: Include SBOMs (SPDX), SLSA provenance, and digest checks.
- **Tests**: Write unit, integration, and acceptance tests for all new features.
