# AGENTS.md — d2-infra (shared infrastructure)

This slice holds the cluster add-ons of the platform team. Flux reconciles them
with the `cluster-admin` role
([`../d2-osramp-fleet/tenants/base/infra.yaml`](../d2-osramp-fleet/tenants/base/infra.yaml)).
All other slices depend on them. The human guide is [`README.md`](README.md).

## Components

| Component | Contents | Path |
|-----------|----------|------|
| cert-manager | Controller, self-signed cluster issuer, wildcard certificate | [`components/cert-manager/`](components/cert-manager/) |
| ingress | Envoy Gateway and the `cluster` Gateway (HTTP to HTTPS redirect, TLS) | [`components/ingress/`](components/ingress/) |
| monitoring | kube-prometheus-stack (Prometheus, Grafana, Flux dashboards) and metrics-server | [`components/monitoring/`](components/monitoring/) |
| trivy-system | Trivy Operator and its ServiceMonitor | [`components/trivy-system/`](components/trivy-system/) |

The Zot registry is not in this slice. It is in
[`../d2-osramp-fleet/local/zot.yaml`](../d2-osramp-fleet/local/zot.yaml).

## Access control

This slice defines cluster-wide resources: CRDs, ClusterRoles, Namespaces, and
Gateway classes. A change here affects every slice. Review it as you would
review production infrastructure.

## Monitoring opt-in

A Service opts in to Prometheus scraping with this label:

```yaml
osramp.acme.co/scrape: Enabled
```

## Pitfalls

- Grafana can ask for its own `admin` login and can refuse iframe embedding.
- cert-manager uses a self-signed issuer. A production cluster needs ACME with DNS01 instead.
- The `https` listener of the `cluster` Gateway accepts HTTPRoutes only from the
  namespaces in its selector: `ingress`, `fe-signalloom`, and `fe-k8s-afm`
  ([`cluster-gateway.yaml`](components/ingress/configs/base/cluster-gateway.yaml)).
  To publish a route from another namespace, add the namespace to that list.
- The licence is Apache 2.0.
