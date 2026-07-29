# AGENTS.md — d2-infra (shared infrastructure)

Platform team's infrastructure components. Cluster-wide resources reconciled
by Flux as cluster admin. All D2 slices depend on this.

## Components

| Component | Contents | Path |
|-----------|----------|------|
| cert-manager | Controller + self-signed cluster issuer + wildcard cert | `components/cert-manager/` |
| ingress | Envoy Gateway + cluster Gateway (HTTP→HTTPS redirect, TLS) | `components/ingress/` |
| monitoring | kube-prometheus-stack (Prometheus + Grafana + Flux dashboards) + metrics-server | `components/monitoring/` |
| registry | Zot OCI registry (in-cluster, persistent cache) | `components/registry/` |

## Access Control

This directory defines **cluster-wide** resources: CRDs, ClusterRoles,
Namespaces, Gateway classes. Changes here affect every slice. Treat edits
with the same caution as production infrastructure.

## Monitoring Opt-in

Services opt into Prometheus scraping with the label:
```yaml
osramp.acme.co/scrape: Enabled
```

## Pitfalls

- Grafana may independently require its `admin` login and reject iframe embedding
- cert-manager uses a self-signed issuer; production would swap to ACME with DNS01
- Envoy Gateway HTTPRoutes from `All` namespaces are accepted on the `https` listener — any slice can add routes
- `LICENSE` is Apache 2.0
