---
name: cp-sl-portforward-supervisor
description: "Scheduled-run durable ingress and port-forward supervisor for the #partner-signal-loom platform. Supervises signalloom-portforward.service, detects severed SPDY streams after pod rollouts, verifies port 5173 (SPA/Dex) and port 18443 (Envoy Gateway), cleans up socket collisions, and executes in-pod proxy diagnostics. USE WHEN port forward down, signalloom dashboard down, dex login refused, port 5173 broken, restart portforward, cp-sl-portforward-supervisor, or on schedule '*/15 * * * *'."
---

# cp-sl-portforward-supervisor

Scheduled ingress, port-forward, and API proxy supervisor for the **Signal Loom** (`#partner-signal-loom`) platform.

## Loop Lens & Schedule Contract

- **Cadence**: `*/15 * * * *` (Every 15 minutes, or immediately after `rollout restart` / image rebuild).
- **Trigger**: Cron notification, `/cp-sl-portforward-supervisor`, or manual prompt "fix port forward".
- **Checkpoint**: Push right. Automatically probe ports, restart broken systemd user services, and clear zombie forwarders. Only notify human if host ports cannot bind or cluster is unreachable.
- **Brief**: Emit a 4-bullet executive status: (1) Service status (`signalloom-portforward.service`), (2) Local endpoint HTTP codes (5173, 18443), (3) In-pod proxy health (`/fleet-api/`, `/api/v1/`), (4) Auto-healing action taken.

---

## Mandate & Non-Negotiable Invariants

1. **Port 5173 Strictness**:
   - Port 5173 is the ONLY registered Dex redirect URI (`http://localhost:5173/callback`).
   - Any alternate port (e.g. 5174, 8080) breaks OIDC authentication. The forwarder MUST bind strictly to 5173.

2. **Rollout Resilience**:
   - Any `kubectl rollout restart` terminates Kubernetes SPDY streams. The supervisor detects dead streams even when the process looks alive in `ps`.

3. **In-Pod Triage (Never Guess Why Routes Fail)**:
   - When a frontend proxy fails, query the backend service from INSIDE the dashboard pod:
     - `200 application/json` -> Backend healthy.
     - `200 text/html` -> Nginx proxy location missing; SPA catch-all returned `index.html`.
     - `504 Gateway Timeout` -> NetworkPolicy blocking connection.
     - `502 Bad Gateway` -> DNS failure or backend service not deployed.

---

## Information Hierarchy

- **Primary Workflow**: [`Workflows/Supervise.md`](Workflows/Supervise.md)
- **Triage Matrix Reference**: [`References/ProxyMatrix.md`](References/ProxyMatrix.md)
- **Executable Checker**: [`Tools/portforward-check.sh`](Tools/portforward-check.sh)

---

## Execution Sequence

1. **Systemd Service Inspection**:
   - Query unit status: `systemctl --user is-active signalloom-portforward.service || true`.
   - If inactive or failed, attempt start: `systemctl --user restart signalloom-portforward.service`.

2. **Local Port & HTTP Probe**:
   - Probe `http://localhost:5173/`: must return HTTP 200 within 3 seconds.
   - If connection refused, check for zombie `kubectl port-forward` processes holding port 5173.

3. **Envoy Gateway TLS Probe**:
   - Discover gateway service name via `gateway.envoyproxy.io/owning-gateway-name=cluster`.
   - Probe `https://dashboard.osramp.acme.local:18443/` (TLS insecure check).

4. **In-Pod Backend Proxy Triage**:
   - Execute internal probe from `deploy/dashboard-signalloom`:
     ```bash
     kubectl -n fe-signalloom exec deploy/dashboard-signalloom -- \
       curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' \
       http://localhost:8080/fleet-api/v1/fleet/topology
     ```

5. **Self-Healing Action**:
   - If SPDY stream severed or pod rolled over, restart `signalloom-portforward.service` and verify recovery.

---

## Completion Criteria

- **Clarity**: Unambiguous status (`INGRESS_HEALTHY`, `HEALED`, or `BLOCKED` with triage diagnostic).
- **Demand**: Both local port 5173 and in-pod backend routes verified; zombie processes cleared.
