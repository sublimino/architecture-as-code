# Durable Systemd User Port-Forwarding for Signal Loom Dashboard

## 1. Overview & Architecture

Local web browser dashboards and developer tooling communicate with the in-cluster Signal Loom frontend (`fe-signalloom/dashboard-signalloom:8080`) over `localhost:5173`. 

In traditional development workflows, running manual background `kubectl port-forward` commands leads to fragile developer experiences:
1. **Pod Rollouts**: Any `kubectl rollout restart`, deployment upgrade, or pod replacement abruptly severs the SPDY stream, leaving orphaned sockets or dead ports.
2. **Cluster Restarts**: Host restarts, Kind cluster pauses, or API server drops kill foreground or unmanaged background port-forwards without notification.
3. **Stale Port Collisions**: Orphaned port-forward processes holding port 5173 prevent new forwards from binding.

To eliminate broken developer and browser connections, Signal Loom provides a persistent, supervised **systemd user service unit**: `signalloom-portforward.service`.

```
┌──────────────────────────────────────────────────────────┐
│                      Host User Session                   │
│                                                          │
│  Browser / CLI                                           │
│  http://localhost:5173 ──► [ signalloom-portforward ]    │
│                            systemd user service          │
│                            Restart=always, RestartSec=3s │
│                                    │                     │
└────────────────────────────────────┼─────────────────────┘
                                     │ kubectl port-forward
                                     ▼
┌──────────────────────────────────────────────────────────┐
│                      Kind Cluster                        │
│                                                          │
│  Namespace: fe-signalloom                                │
│  Service: dashboard-signalloom:8080                      │
│                                                          │
│  ┌───────────────────────┐   (on rollout / restart)      │
│  │ Pod: dashboard-...-a  │ ──► Terminated                │
│  └───────────────────────┘                               │
│  ┌───────────────────────┐                               │
│  │ Pod: dashboard-...-b  │ ◄── Auto-reconnected in ~4s   │
│  └───────────────────────┘                               │
└──────────────────────────────────────────────────────────┘
```

---

## 2. Unit Configuration

The canonical service unit definition is tracked in the repository at [`d2-signalloom/infra/systemd/signalloom-portforward.service`](file:///home/andy/src/.worktrees/38c06/osramp-demo/d2-signalloom/infra/systemd/signalloom-portforward.service) and installed into `~/.config/systemd/user/signalloom-portforward.service`:

```ini
[Unit]
Description=Signal Loom Dashboard Local Port-Forward (5173:8080)
Documentation=https://github.com/controlplaneio-in-toto/osramp-demo docs/signalloom/durable-port-forwarding.md
After=network.target

[Service]
Type=simple
Environment=KUBECONFIG=%h/.kube/config
Environment=PATH=/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin:%h/bin:%h/.local/bin
Environment=LOCAL_PORT=5173
Environment=REMOTE_PORT=8080
Environment=NAMESPACE=fe-signalloom
Environment=SERVICE=svc/dashboard-signalloom
Environment=LISTEN_ADDRESS=127.0.0.1
ExecStart=/usr/bin/env kubectl --address ${LISTEN_ADDRESS} -n ${NAMESPACE} port-forward ${SERVICE} ${LOCAL_PORT}:${REMOTE_PORT}
Restart=always
RestartSec=3s
KillMode=process
TimeoutStopSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
```

### Key Properties
- **`Restart=always` & `RestartSec=3s`**: Automatically restarts `kubectl port-forward` when the stream is dropped due to pod deletion or network reconnection.
- **`KillMode=process`**: Ensures clean process termination when the service stops without killing unrelated subprocesses.
- **`Environment=KUBECONFIG=%h/.kube/config`**: Explicitly passes user kubeconfig context across systemd user session invocations.
- **`WantedBy=default.target`**: Enables automatic startup upon user login without requiring root privileges or sudo.

---

## 3. Lifecycle Management

The [`scripts/manage-portforward-service.sh`](file:///home/andy/src/.worktrees/38c06/osramp-demo/scripts/manage-portforward-service.sh) script provides comprehensive lifecycle control:

| Command | Action |
|---|---|
| `./scripts/manage-portforward-service.sh install` | Installs unit to `~/.config/systemd/user/`, reloads daemon, enables & starts service |
| `./scripts/manage-portforward-service.sh uninstall` | Stops and disables service, removes unit file, and reloads daemon |
| `./scripts/manage-portforward-service.sh start` | Cleans stale listeners and starts the service |
| `./scripts/manage-portforward-service.sh stop` | Stops the running port-forward service |
| `./scripts/manage-portforward-service.sh restart` | Restarts the port-forward service |
| `./scripts/manage-portforward-service.sh status` | Displays systemd service state and verifies HTTP 200 on `http://localhost:5173` |
| `./scripts/manage-portforward-service.sh logs [N]` | Tails the last N journalctl log lines (default: 30) |
| `./scripts/manage-portforward-service.sh enable` | Enables service autostart on user login |
| `./scripts/manage-portforward-service.sh disable` | Disables service autostart |
| `./scripts/manage-portforward-service.sh override-port <PORT>` | Configures a systemd drop-in override for a custom local port |
| `./scripts/manage-portforward-service.sh clean-stale` | Scans for and terminates orphaned, non-systemd listeners on port 5173 |

### Native `systemctl --user` Commands
Operators can also manage the unit directly using standard `systemctl`:

```bash
# Reload definitions
systemctl --user daemon-reload

# Check status
systemctl --user status signalloom-portforward.service

# View live logs
journalctl --user -u signalloom-portforward.service -f
```

---

## 4. Drop-In Port Overrides

To customize the local listening port (e.g. if port 5173 is required by another local service), create a systemd drop-in configuration under `~/.config/systemd/user/signalloom-portforward.service.d/10-port-override.conf`:

```ini
[Service]
Environment=LOCAL_PORT=5174
```

Apply the override with:
```bash
./scripts/manage-portforward-service.sh override-port 5174
# OR:
systemctl --user daemon-reload && systemctl --user restart signalloom-portforward.service
```

---

## 5. Automated Verification & Resilience Testing

The automated test suite [`scripts/verify-portforward-service.sh`](file:///home/andy/src/.worktrees/38c06/osramp-demo/scripts/verify-portforward-service.sh) validates the service against simulated failures:

1. **Active State Verification**: Asserts `systemctl --user is-active signalloom-portforward.service` is `active (running)`.
2. **HTTP Baseline Probe**: Validates `curl -I http://localhost:5173` returns `HTTP 200 OK`.
3. **Pod Deletion Chaos Test**: Simulates pod failure by forcefully deleting the active `dashboard-signalloom` pod.
4. **Auto-Recovery Measurement**: Tracks recovery latency until the new pod is running and `http://localhost:5173` resumes returning HTTP 200 (typical latency: ~3.5–4.5s).
5. **Evidence Artifact Generation**: Writes structured JSON proof to [`docs/signalloom/evidence/portforward-service-proof.json`](file:///home/andy/src/.worktrees/38c06/osramp-demo/docs/signalloom/evidence/portforward-service-proof.json).

Run verification with:
```bash
./scripts/verify-portforward-service.sh
```

---

## 6. Troubleshooting

### Port Already in Use (`address already in use`)
If a manual `kubectl port-forward` or orphaned process is bound to port 5173:
```bash
./scripts/manage-portforward-service.sh clean-stale
./scripts/manage-portforward-service.sh restart
```

### Kubernetes API Server Unreachable
If the service exits with API connection errors, ensure the Kind cluster is up:
```bash
kubectl cluster-info
make healthcheck
```

### Sandboxed / Landlocked Environments
In sandboxed execution environments where writing directly to `~/.config/systemd/user` is restricted, operations should be dispatched via `systemd-run`:
```bash
systemd-run --user --wait --collect --pipe systemctl --user status signalloom-portforward.service
```
`scripts/manage-portforward-service.sh` automatically detects sandbox constraints and dispatches via `systemd-run` as needed.
