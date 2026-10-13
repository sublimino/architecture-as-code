# Workflow: Signal Loom Ingress & Port-Forward Supervision

Automated workflow to detect and recover broken port-forward connections and backend proxies for Signal Loom.

## Steps

### Step 1: Check Pod Health
Before touching ports, confirm that the frontend pod is actually running:
```bash
POD_STATUS=$(kubectl -n fe-signalloom get pods -l app=dashboard-signalloom -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NOT_FOUND")
if [ "$POD_STATUS" != "Running" ]; then
  echo "FRONTEND_POD_NOT_RUNNING: Pod is ${POD_STATUS}. Skipping local forward check."
  exit 0
fi
```

### Step 2: Probe Local Port 5173
```bash
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://localhost:5173/ || echo "000")
echo "PORT_5173_HTTP_CODE=${HTTP_CODE}"
```

### Step 3: Self-Healing on Dropped Connection
If `HTTP_CODE` is `000` (Connection Refused / Timeout):
1. Check if `signalloom-portforward.service` is defined:
   ```bash
   if systemctl --user list-unit-files signalloom-portforward.service >/dev/null 2>&1; then
     echo "Restarting signalloom-portforward.service..."
     systemctl --user restart signalloom-portforward.service
     sleep 2
   else
     echo "Ad-hoc port-forward restart..."
     pkill -f 'kubectl port-forward -n fe-signalloom svc/dashboard-signalloom 5173:8080' || true
     nohup kubectl port-forward -n fe-signalloom svc/dashboard-signalloom 5173:8080 >/tmp/sl-portforward.log 2>&1 &
     sleep 2
   fi
   ```
2. Re-probe `http://localhost:5173/`. If it returns 200, state is HEALED.

### Step 4: In-Pod Route Diagnostic
If local port 5173 returns 200, probe backend service connectivity from inside the pod:
```bash
PROBE_RESULT=$(kubectl -n fe-signalloom exec deploy/dashboard-signalloom -- \
  curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' \
  http://localhost:8080/fleet-api/v1/fleet/topology 2>/dev/null || echo "EXEC_FAILED")
echo "IN_POD_BACKEND_PROBE=${PROBE_RESULT}"
```

### Step 5: Triage Diagnostic
- If `200 application/json`: All layers healthy.
- If `200 text/html`: Nginx proxy rule missing in `nginx.conf`.
- If `504`: NetworkPolicy blocking dashboard to fleet-manager.
- If `502`: Fleet Manager pod down or not registered in DNS.
