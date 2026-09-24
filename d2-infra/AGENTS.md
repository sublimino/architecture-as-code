# AGENTS.md — d2-infra (shared infrastructure)

This slice holds the cluster add-ons of the platform team. Flux reconciles them
with the `cluster-admin` role
([`../d2-osramp-fleet/tenants/base/infra.yaml`](../d2-osramp-fleet/tenants/base/infra.yaml)).
All other slices depend on them. The human guide is [`README.md`](README.md).

## Stack

The four components and their contents are listed once, in
[`README.md`](README.md#components). The Zot registry is not in this slice. It is in
[`../d2-osramp-fleet/local/zot.yaml`](../d2-osramp-fleet/local/zot.yaml).

## Namespaces

The `infra` ResourceSet declares one input per component. Each input becomes a
tenant namespace that holds the Flux objects and the add-on for that component
([`infra.yaml`](../d2-osramp-fleet/tenants/base/infra.yaml)).

| Namespace | Contents |
|---|---|
| `cert-manager` | cert-manager controller, the `cluster-issuer` ClusterIssuer, and the `cluster` Certificate that writes the `cluster-tls` Secret |
| `ingress` | Envoy Gateway and the `cluster` Gateway |
| `monitoring` | kube-prometheus-stack and metrics-server |
| `trivy-system` | Trivy Operator and its ServiceMonitor |

## Lifecycle

This slice has no `make` target of its own. Flux delivers it. For each tenant
namespace, the ResourceSet creates an OCIRepository `infra` and two
Kustomizations. `infra-controllers` applies `./controllers/<environment>` first.
`infra-configs` depends on it and applies `./configs/<environment>`. The
controllers are then ready before Flux applies their custom resources.

## Access control

This slice defines cluster-wide resources: CRDs, ClusterRoles, Namespaces, and
Gateway classes. A change here affects every slice. Review it as you would
review production infrastructure.

## Monitoring opt-in

A ServiceMonitor or PodMonitor opts in to Prometheus scraping with this label
([`kube-prometheus-stack.yaml`](components/monitoring/controllers/base/kube-prometheus-stack.yaml)):

```yaml
osramp.acme.co/scrape: Enabled
```

## Pitfalls

- Grafana can ask for its own `admin` login. Its `grafana.ini` does not set `allow_embedding`, so Grafana uses its default and refuses iframe embedding.
- cert-manager uses a self-signed issuer. A production cluster needs ACME with DNS01 instead.
- The `https` listener of the `cluster` Gateway accepts HTTPRoutes only from the
  namespaces in its selector: `ingress`, `fe-signalloom`, and `fe-k8s-afm`
  ([`cluster-gateway.yaml`](components/ingress/configs/base/cluster-gateway.yaml)).
  To publish a route from another namespace, add the namespace to that list.
- The licence is the GNU Affero General Public License, version 3 ([`LICENSE`](LICENSE)).
