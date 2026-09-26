# Signal Loom infrastructure components

`inf-bao` owns the OpenBao and SPIRE slice. `inf-signalloom` owns Dex,
dex-ui, the fake integration proxy, netassert-controller, PostgreSQL, Redis,
and MinIO. `inf-bao` has a controller/config split with local overlay entry
points. `inf-signalloom` has that split plus [`base/`](inf-signalloom/base/) and
[`overlays/connectors/`](inf-signalloom/overlays/connectors/). The `agent-swarm`,
`kagent`, and `knative` directories have no split.

| Path | Contents | Consumer |
| :--- | :--- | :--- |
| [`inf-bao/`](inf-bao/) | OpenBao and SPIRE | [`signalloom.yaml`](../../d2-osramp-fleet/tenants/local/signalloom.yaml) fleet tenant |
| [`inf-signalloom/`](inf-signalloom/) | Dex, dex-ui, the fake integration proxy, netassert-controller, PostgreSQL, Redis, and MinIO | [`signalloom.yaml`](../../d2-osramp-fleet/tenants/local/signalloom.yaml) fleet tenant |
| [`agent-swarm/`](agent-swarm/) | The `fe-signalloom-agents` namespace, shared RBAC, NetworkPolicies, and one subdirectory for each swarm agent | [`agent-swarm.yaml`](../../d2-osramp-fleet/tenants/base/agent-swarm.yaml) ResourceSet |
| [`kagent/`](kagent/) | Kagent base manifests, a local overlay, Helm values, and a smoke agent | `make swarm-kagent-up` |
| [`knative/`](knative/) | Knative Serving and Eventing manifests, a broker, and a GitHub source template | `make swarm-infra-up` |
| [`systemd/`](systemd/) | systemd user unit that keeps the dashboard port-forward (5173:8080) running | Operator. See [durable port forwarding](../../docs/signalloom/durable-port-forwarding.md). |
| [`audit-policy.yaml`](audit-policy.yaml) | Kubernetes API server audit policy at `Metadata` level for sensitive resources | [`cloudaudit-preflight.sh`](../../scripts/cloudaudit-preflight.sh) checks it |
