# SLAC-P3-PRE — Phase 3 Cluster Discovery Preflight Proof

## Metadata

- **Card:** `SLAC-P3-PRE`
- **Phase:** 3 — in-cluster discovery and auto-claim demonstration
- **Captured:** `2026-09-09T00:16:47Z` through `2026-09-09T00:33:18Z`
- **Evidence timezone:** UTC (`Z`)
- **Runtime worktree:** `/home/andy/.cline/worktrees/a99e1/osramp-demo`
- **Integration ref:** `refs/heads/integration/slac-v0.1.0`
- **Integration SHA:** `d16d25ffae70abbb2269eee09ea513bf98e3af4e`
- **Evidence-source HEAD:** `09f570f0c353ae612baf38070264e963b9873e76`
- **Verdict:** **PASS, qualified** — cluster discovery is ready for `SLAC-P3-1`.

The qualification is repository-wide lint debt, not a Phase 3 discovery defect.
The root Makefile defines no lint target and TypeScript typechecking passes. A
supplemental `bun run lint` from
`d2-signalloom/apps/dashboard-signalloom` exited 1 with 72 problems (66 errors,
6 warnings). `git diff d16d25ffae70abbb2269eee09ea513bf98e3af4e..09f570f0c353ae612baf38070264e963b9873e76`
contains only the NATS BATS correction, so none of those dashboard findings was
introduced by this card.

## 1. Worktree and baseline gates

The Kanban runtime resolved outside the principal checkout and started clean:

```text
PWD=/home/andy/.cline/worktrees/a99e1/osramp-demo
principal_checkout_guard_exit=0
branch=HEAD
head=d16d25ffae70abbb2269eee09ea513bf98e3af4e
integration_ref=d16d25ffae70abbb2269eee09ea513bf98e3af4e
clean=true
ancestry_exit=0
```

The approved board checker reported `HEALTH: ✓ healthy`; `P3-PRE` was the only
in-progress card, `P2-GOV` was done, and `P3-1`, `P3-2`, and `P3-GOV` remained
in backlog. No sibling scope collision was active.

The first full baseline run exposed a stale NATS test assumption: DETIK searched
the `frontend` namespace although NATS runs in `backend`, and a substring count
matched both `nats` Services. Commit `09f570f0c353ae612baf38070264e963b9873e76`
repairs only that baseline test by selecting `backend` and querying the exact
`service/nats`. The focused test and mandated full target then passed:

```text
$ bats --filter "uptime check: NATS" d2-osramp-apps/test/osramp.bats
1..1
ok 1 uptime check: NATS
exit_code=0

$ make test
1..8
ok 1 reset the debug file
ok 2 example test with setup/retry and pipes
ok 3 uptime check: NATS
ok 4 end-to-end NATS listener and processor integration
ok 5 PURL processing with cache behavior
ok 6 PURL processing with nocache option
ok 7 archiver task result storage and retrieval
ok 8 SBOM generation and archival integration end-to-end
exit_code=0

$ bun run typecheck
$ tsc --noEmit
exit_code=0

$ bun run lint
$ eslint src/ --max-warnings 0
✖ 72 problems (66 errors, 6 warnings)
error: script "lint" exited with code 1
```

## 2. Cluster node and namespace readiness

Captured at `2026-09-09T00:16:47Z`:

```text
docker_server=29.7.1
docker_exit=0
kind_clusters:
osramp
kind_exit=0
kubectl_context=kind-osramp

NAME                   STATUS   ROLES           AGE   VERSION
osramp-control-plane   Ready    control-plane   9d    v1.36.1
kubectl_nodes_exit=0

fe-signalloom-agents   Active
namespace_exit=0
```

Neither hard blocker applied: Docker and Kind were reachable, and the required
namespace existed in `Active` state.

## 3. Agent workload enumeration

`kubectl get pods -n fe-signalloom-agents` exited `0`. The full namespace state
captured at `2026-09-09T00:25:19Z` was:

```text
agent-sir-lancelot                                  Running   true
kagent-chaos-prober-85c4766966-zprp4                Running   true
kagent-commit-summariser-5956c9b945-v6nmd           Running   true
kagent-compliance-checker-85cf6b4f78-rcsnx          Running   true
kagent-finops-optimizer-567d96db46-2zhxp            Running   true
kagent-incident-responder-f8b7b8b69-l8nhj           Running   true
kagent-k8s-reader-64b77b54cf-7z6vt                  Running   true
kagent-network-auditor-8c7c955df-snmbb              Running   true
kagent-security-analyst-944d6fb4d-pmr7n             Running   true
netassert-cardvault-agent-fixture-7cc598476-srgz7   Running   true
netassert-generic-agent-fixture-545f77f844-cfjss    Running   true
stun-quarantine-target-984603                       Failed    false
pods_exit=0
```

The nine contract-relevant autonomous workloads (`agent-sir-lancelot` and the
eight `kagent-*` pods) were all `Running` and ready. The historical
`stun-quarantine-target` fixture was `Failed`; it is not a Kagent or autonomous
discovery workload and does not block this card.

## 4. Proxy readiness and port 8080 reachability

The proxy deployment, Service, Endpoint, and selected pod were ready:

```text
deployment.apps/fake-integration-proxy   1/1   1   1   8d
service/fake-integration-proxy   ClusterIP   10.96.241.226   8080/TCP
endpoints/fake-integration-proxy   10.0.0.41:8080
proxy_objects_exit=0

fake-integration-proxy-5bc6df5554-4z5xh   1/1   Running   0   17h
proxy_pods_exit=0
```

The network probe ran from `deploy/dashboard-signalloom` in `fe-signalloom`,
not from the host, and reached the cross-namespace ClusterIP Service on port
8080:

```bash
kubectl -n fe-signalloom exec deploy/dashboard-signalloom -- \
  curl -fsS \
  http://fake-integration-proxy.inf-signalloom.svc.cluster.local:8080/agents
```

```text
captured_utc=2026-09-09T00:24:10Z
source_namespace=fe-signalloom
target=http://fake-integration-proxy.inf-signalloom.svc.cluster.local:8080/agents
curl_exit=0
json_parse=true
agent_count=19
response_namespace=fe-signalloom-agents,fe-signalloom
```

Representative raw discovery records matched the running pod enumeration:

```json
{"framework":"kagent","id":"agent-sir-lancelot","name":"Sir Lancelot","namespace":"fe-signalloom-agents","phase":"Running","service_account":"default"}
{"framework":"kagent","id":"kagent-incident-responder-f8b7b8b69-l8nhj","name":"kagent-incident-responder-f8b7b8b69-l8nhj","namespace":"fe-signalloom-agents","phase":"Running","service_account":"kagent-incident-responder"}
{"framework":"kagent","id":"kagent-k8s-reader-64b77b54cf-7z6vt","name":"kagent-k8s-reader-64b77b54cf-7z6vt","namespace":"fe-signalloom-agents","phase":"Running","service_account":"kagent-k8s-reader"}
```

## 5. Enriched API and pre-claim state

A real Dex password-grant ID token was minted through a temporary local
port-forward, then used against the deployed `fe-signalloom` API. The token was
kept in process memory and was not logged. Both forwards were terminated after
the probe.

```text
captured_utc=2026-09-09T00:33:18Z
dex_token_curl_exit=0
api_url=http://127.0.0.1:28080/api/agents?limit=100
api_curl_exit=0
json_parse=true
response_keys=agents,data,meta,pagination,source_health,source_health_detail,total
agent_count=24
expected_running_agent_count=9
source_health="healthy"
source_health_detail={"crypto_proofs":{"last_good":"2026-09-09T00:33:18Z","message":null,"status":"healthy"},"k8s_discovery":{"last_good":"2026-09-09T00:33:18Z","message":null,"status":"healthy"},"postgres_registry":{"last_good":"2026-09-09T00:33:18Z","message":null,"status":"healthy"}}
```

The evidence script derived the expected set directly from live pods, indexed
the API response by `runtime.pod_name`, and evaluated this exact predicate:

```python
expected = sorted(
    pod["metadata"]["name"]
    for pod in pods
    if pod["status"]["phase"] == "Running"
    and (
        pod["metadata"]["name"] == "agent-sir-lancelot"
        or pod["metadata"]["name"].startswith("kagent-")
    )
)
by_pod = {agent["runtime"]["pod_name"]: agent for agent in agents}
for pod_name in expected:
    agent = by_pod[pod_name]
    assert agent["record_class"] == "discovered"
    assert agent["is_registry_linked"] is False
    assert agent["runtime"]["namespace"] == "fe-signalloom-agents"
```

The enriched response proves all nine expected workloads are not linked before
claim:

```json
{"assertion":"PASS","is_registry_linked":false,"namespace":"fe-signalloom-agents","phase":"Running","pod_name":"agent-sir-lancelot","present":true,"record_class":"discovered"}
{"assertion":"PASS","is_registry_linked":false,"namespace":"fe-signalloom-agents","phase":"Running","pod_name":"kagent-chaos-prober-85c4766966-zprp4","present":true,"record_class":"discovered"}
{"assertion":"PASS","is_registry_linked":false,"namespace":"fe-signalloom-agents","phase":"Running","pod_name":"kagent-commit-summariser-5956c9b945-v6nmd","present":true,"record_class":"discovered"}
{"assertion":"PASS","is_registry_linked":false,"namespace":"fe-signalloom-agents","phase":"Running","pod_name":"kagent-compliance-checker-85cf6b4f78-rcsnx","present":true,"record_class":"discovered"}
{"assertion":"PASS","is_registry_linked":false,"namespace":"fe-signalloom-agents","phase":"Running","pod_name":"kagent-finops-optimizer-567d96db46-2zhxp","present":true,"record_class":"discovered"}
{"assertion":"PASS","is_registry_linked":false,"namespace":"fe-signalloom-agents","phase":"Running","pod_name":"kagent-incident-responder-f8b7b8b69-l8nhj","present":true,"record_class":"discovered"}
{"assertion":"PASS","is_registry_linked":false,"namespace":"fe-signalloom-agents","phase":"Running","pod_name":"kagent-k8s-reader-64b77b54cf-7z6vt","present":true,"record_class":"discovered"}
{"assertion":"PASS","is_registry_linked":false,"namespace":"fe-signalloom-agents","phase":"Running","pod_name":"kagent-network-auditor-8c7c955df-snmbb","present":true,"record_class":"discovered"}
{"assertion":"PASS","is_registry_linked":false,"namespace":"fe-signalloom-agents","phase":"Running","pod_name":"kagent-security-analyst-944d6fb4d-pmr7n","present":true,"record_class":"discovered"}
all_expected_unclaimed_assertion=PASS
```

This is the required pre-claim baseline. Raw `/agents` proves Kubernetes
discovery; authenticated `/api/agents` adds the registry reconciliation field.

## 6. CLI and RBAC audit

Captured at `2026-09-09T00:16:48Z`:

```text
Bats 1.13.0
bats_exit=0
curl 8.20.0 (x86_64-pc-linux-gnu) libcurl/8.20.0 OpenSSL/3.6.2
curl_exit=0
jq-1.8.1
jq_exit=0
kubectl_client=v1.36.0
kind v0.32.0 go1.26.3 linux/amd64
```

The discovery RBAC suite also passed without skips:

```text
$ bats d2-signalloom/test/agent-discovery-rbac.bats
1..6
ok 1 the proxy declares at least the two demo namespaces
ok 2 every discovery namespace grants the proxy SA a pod-reading Role
ok 3 a discovery namespace with no grant is reported, not tolerated
ok 4 no discovery grant gives the proxy a cluster-scoped identity
ok 5 every discovery grant covers the two agent carriers and nothing more
ok 6 the RoleBinding ships alongside the Role it references
```

## 7. Scope and hand-off

- Discovery-specific Kubernetes activity was read-only: `get`, `exec` plus
  `curl`, and temporary `port-forward` processes only.
- The separately mandated `make test` baseline used `kubectl exec` to publish
  test messages to NATS, producing application test-data writes. The prompt
  mandates that full baseline command while separately requiring read-only
  discovery probes; this interaction is retained as a scope qualification. The
  run did not mutate Kubernetes objects.
- No pod was deleted, restarted, relabelled, or terminated.
- No manifest, Kustomization, or NetworkPolicy was changed.
- No Kanban runtime state or sibling worktree was changed.
- The running Kagent and Sir Lancelot workloads are visible through discovery.
- Their enriched records are demonstrably unclaimed.

**Determination:** `SLAC-P3-PRE` **passes with the documented qualifications**.
`SLAC-P3-1` may consume this artifact as its discovery and unclaimed-state
baseline while preserving those qualifications.
