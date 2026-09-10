---
title: Quick start
description: Start Signal Loom locally and open the dashboard or documentation site.
---

## Prerequisites

Install Docker. The setup script installs the other repository tools.

## Start the platform

1. Clone the repository.
2. Run the setup script.

   ```bash
   ./scripts/setup.sh
   ```

3. Start the shared foundation.

   ```bash
   make up
   ```

4. Start Signal Loom.

   ```bash
   make demo-signalloom-up
   ```

5. Check the foundation.

   ```bash
   make healthcheck
   ```

6. Check the Signal Loom slice.

   ```bash
   make demo-signalloom-test
   ```

## Open the dashboard directly

Use port `5173`. Dex requires this port for local redirects.

```bash
kubectl port-forward -n fe-signalloom svc/dashboard-signalloom 5173:8080
```

Open `http://localhost:5173`. Use one of these demonstration accounts:

| Account | Password | Current authorization |
| :--- | :--- | :--- |
| `demo-user@signalloom.local` | `demo-user` | Superadmin allowlist member |
| `viewer@signalloom.local` | `viewer` | Authenticated operator, not view-only |

## Open the documentation route

The direct dashboard port-forward bypasses the Gateway. It cannot route `/docs`.
Forward the Gateway instead.

```bash
kubectl -n ingress port-forward svc/envoy-ingress-cluster-* 18443:443
```

Open this URL:

```text
https://dashboard.osramp.acme.local:18443/docs/
```

Map `dashboard.osramp.acme.local` to `127.0.0.1` for your browser or use the
repository acceptance-test host resolver.

## Stop the slice

```bash
make demo-signalloom-down
```

This command keeps the shared foundation.
