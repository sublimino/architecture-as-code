# SLED-P3 — Network Teardown Runbook (Stages 1 and 2)

Stages 1 and 2 of the EAP teardown pipeline remove every network path to a
reaped environment: they unbind its ingress routes, then release its Tailscale
node. Stages 3 and 4 (key shredding and namespace deletion) are SLED-P3-2's.

| Stage | Recorded as | Code | Removes |
|---|---|---|---|
| 1 | `ingress_severed` | `sever_ingress_routes()` in `d2-signalloom/apps/fe-signalloom/src/environment_teardown.py` | Every `HTTPRoute` in the route namespace labelled `signalloom.io/eap-hash=<hash>` **or** whose `spec.hostnames` contains `sl-eap-<hash>.tailscale` / `sl-eap-<hash>.ts.net` |
| 2 | `tailscale_evicted` | `evict_tailscale_node()`, same file | Serve and funnel bindings and the node itself, via `scripts/eap/tailscale-eap-env.sh teardown --hash <hash>` |

Completed stages are appended to `LifecycleRecord.teardown_stages_completed`
through `LifecycleManager.record_teardown_stage()`, which is idempotent.

## Ordering and the fail-forward contract

- Stage 1 runs first. The pipeline **stops at the first failed stage**, so
  Stage 2 never releases the node while a route might still send traffic to it.
- A stage is recorded only after its helper returns. By then every subprocess
  it started has exited and the pipes are drained and closed.
- On a re-run, stages already listed in `teardown_stages_completed` are
  skipped, so a retry resumes at the stage that failed. Nothing rolls back to
  `ACTIVE`.
- "Nothing to remove" counts as success (`already_absent`). A missing route or
  an absent node is the desired end state, not an error.

## Bounded execution

- Each stage gets one **5-second** deadline (`STAGE_TIMEOUT_SECONDS`) that all
  of its external calls share. The phase-wide ceiling is 10s per deallocation
  call.
- Every call runs in its own session (`start_new_session=True`), and the whole
  process group gets `SIGKILL` on overrun. A grandchild holding the pipe open
  cannot hang the stage. The tests prove this with a fake `kubectl` that forks
  `sleep 30`.
- stdin is `/dev/null`, so a script that prompts reads EOF instead of blocking.

## Running it

**Via the API.** This only works for an environment in `draining` or
`terminated`. Any other state returns `409`, because severing ingress on a live
environment is an outage.

```bash
curl -sX POST http://localhost:8080/api/v1/eap/lifecycle/environments/6f82ad81/teardown/network | jq
```

The stages shell out, so the endpoint runs them in the threadpool rather than on
the event loop.

**Via the CLI**, run from `d2-signalloom/apps/fe-signalloom/src`:

```bash
python environment_teardown.py teardown --hash 6f82ad81 --json
python environment_teardown.py teardown --company kurasi --stages ingress \
    --namespace fe-signalloom --probe-url https://sl-eap-6f82ad81.ts.net/ --timeout 5
```

| Exit | Meaning |
|---|---|
| 0 | Every requested stage completed or was already absent |
| 1 | A stage failed; see the report and the `eap.teardown.stage_failed` event |
| 2 | Usage error: malformed hash, `--hash` together with `--company`, unknown stage, or a timeout ≤ 0 |

| Variable | Default | Effect |
|---|---|---|
| `SIGNALLOOM_KUBECTL` | `kubectl` | kubectl binary for Stage 1 |
| `SIGNALLOOM_EAP_ROUTE_NAMESPACE` | `fe-signalloom` | Namespace searched for routes (matches the template's `EAP_NAMESPACE` default). `--namespace` overrides it |
| `SIGNALLOOM_TAILSCALE_EAP_SCRIPT` | `<repo>/scripts/eap/tailscale-eap-env.sh` | Stage 2 script |
| `TAILSCALE_MOCK_DIR` | `/tmp/tailscale-eap-mock` | Mock node state. Stage 2 verifies `sl-eap-<hash>/` is gone afterwards |
| `SIGNALLOOM_EAP_TAILSCALE_LIVE` | unset, meaning mock | `1` runs the script live. See the hazard below |

### Hazard: live Tailscale eviction affects the whole node

In live mode, `tailscale-eap-env.sh teardown` runs `tailscale serve reset`,
`tailscale funnel reset` and `tailscale logout`. **None of these is scoped to
one customer.** They reset every serve and funnel binding on the host and log
the host out of the tailnet. On a shared node, evicting one customer takes down
every customer, along with the operator's own tailnet access.

For that reason Stage 2 **defaults to mock**, even on hosts where the
`tailscale` binary exists. The script would otherwise go live there, because it
only auto-mocks when the binary is missing. Live mode needs
`SIGNALLOOM_EAP_TAILSCALE_LIVE=1`, and every result and audit event records
`mode`. Enable live mode only when the node is dedicated to the one environment
being evicted.

## Audit events

Every stage emits one event to the sink (by default the
`signalloom.audit.teardown` logger, as one JSON line per event; the CLI also
returns them under `audit_events`).

| Field | Notes |
|---|---|
| `event_id` | UUID4 |
| `event_type` | `eap.teardown.ingress_severed`, `eap.teardown.tailscale_evicted`, `eap.teardown.stage_failed`, or `eap.teardown.alert` |
| `timestamp` | ISO 8601 UTC |
| `customer_hash`, `company_name` | From the lifecycle record. `company_name` is empty when running unmanaged by hash |
| `previous_state`, `current_state` | Lifecycle state. Teardown does not change it, so both are the same (`draining`/`terminated`, or `unmanaged` from the CLI) |
| `trigger_reason` | `reaper`, `api_request`, or `operator_cli` (overridable with `--reason`) |
| `operator_or_system_id` | `system:sled-teardown`, or `operator:$USER` from the CLI |
| `stage`, `stage_outcome`, `stage_detail`, `duration_ms`, `removed`, `mode` | Stage-specific fields |

**Alerting.** After **3 consecutive failures** of the same stage for the same
customer, an extra `eap.teardown.alert` event fires, carrying
`consecutive_failures`. A success resets the count. The count is held in the
process (`FailureTracker`), so it resets when the process restarts.

## Failure remediation

| Symptom (`stage_detail`) | Cause | Action |
|---|---|---|
| `kubectl binary not found` | No kubectl in the pod or on the PATH | Set `SIGNALLOOM_KUBECTL`, then retry |
| `kubectl get httproute failed … forbidden` | The service account cannot list or delete `httproutes.gateway.networking.k8s.io` in the route namespace | Grant `get,list,delete` on httproutes in that namespace, then retry |
| `routes still present after delete` | A finalizer, or a controller (Flux) re-creating the route | `kubectl get httproute -n <ns> -l signalloom.io/eap-hash=<hash> -o yaml`. If Flux owns it, suspend or remove the Kustomization source before retrying |
| `still answers HTTP 200 after unbind` (with `--probe-url`) | Traffic reaches the environment by another path: a stale gateway config, another route, or Tailscale serve still up | Check the Gateway's attached routes and run Stage 2. Do not mark the stage complete by hand |
| `timeout: …` | The API server or script is unresponsive | Retry. Repeated timeouts raise `eap.teardown.alert`, so check API server health |
| `teardown script not found` | Script missing from the container image | Set `SIGNALLOOM_TAILSCALE_EAP_SCRIPT`, or ship `scripts/eap/` in the image |
| `mock node state survived teardown` | `TAILSCALE_MOCK_DIR` differs between provision and teardown | Align `TAILSCALE_MOCK_DIR`, then retry |

Remediation always means a **retry**. Recorded stages are skipped, and nothing
is ever marked complete by hand. Doing so would leave an orphan route or proxy
slot that nothing re-checks.

## Not covered by Stages 1-2

- **DNS cache invalidation.** Gateway hostnames are not DNS records we own.
  MagicDNS entries go away when the node logs out (Stage 2, live). Nothing here
  flushes resolver caches. `--probe-url` is the closest check that the change
  took effect.
- **veth / virtual interface cleanup.** Pod interfaces belong to the
  namespace's workloads and are reclaimed at Stage 4 (SLED-P3-2).
- **Orchestration.** Calling the pipeline from the ReaperDaemon
  (DRAINING→TERMINATED) belongs to SLED-P2-1/P3-GOV. `run_network_teardown()`
  is the entry point to call, from a worker thread and never on the event loop.
