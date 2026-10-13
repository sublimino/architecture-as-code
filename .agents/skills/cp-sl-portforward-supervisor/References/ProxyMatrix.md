# Reference: In-Pod Backend Proxy Triage Matrix

When a frontend page in the Signal Loom dashboard displays an error, spins indefinitely, or fails to fetch data, execute the in-pod query from `d2-signalloom/AGENTS.md`:

```bash
kubectl -n fe-signalloom exec deploy/dashboard-signalloom -- \
  curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' \
  http://localhost:8080/fleet-api/v1/fleet/topology
```

## The Four Diagnostic Signatures

| Result | Cause | Exact Remedy |
|---|---|---|
| `200 application/json` | The service is completely healthy. Frontend issue is client-side JS or CORS. | Check browser DevTools console errors; check React Query cache. |
| `200 text/html` | The nginx proxy rule is missing. The SPA catch-all returned `index.html`. | Add the missing `location` block to `apps/dashboard-signalloom/nginx.conf`. Rebuild with `make signalloom-dashboard-image`. |
| `504 Gateway Timeout` | A Kubernetes NetworkPolicy blocked the connection between the dashboard pod and backend service. | Inspect NetworkPolicy in `fe-signalloom` or target namespace. Add required ingress/egress CIDR/label rules. |
| `502 Bad Gateway` (log: `could not be resolved`) | Cluster CoreDNS has no record for the service. Service is not deployed. | Run `make demo-signalloom-up`. For AFM routes, run `make demo-k8s-afm-up`. |

---

## Port Assignment Authority

| Port | Service | Protocol | Binding Rule |
|---|---|---|---|
| `5173` | `fe-signalloom/dashboard-signalloom:8080` | HTTP | Required for Dex callback: `http://localhost:5173/callback` |
| `18443` | `ingress/envoy-gateway:443` | HTTPS (TLS) | Envoy Gateway ingress port-forward |
| `8000` | `fe-signalloom/api-signalloom:8000` | HTTP | Direct FastAPI backend port-forward (optional debug) |
| `5432` | `inf-signalloom/postgres:5432` | TCP | Direct PostgreSQL port-forward (optional debug) |
