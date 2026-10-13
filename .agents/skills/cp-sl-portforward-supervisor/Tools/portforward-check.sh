#!/usr/bin/env bash
# portforward-check.sh — Probe and heal Signal Loom port-forward connections
set -eo pipefail

echo "=== Signal Loom Port-Forward Supervisor ==="
DATE_STR=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Check Timestamp: ${DATE_STR}"
FAIL_COUNT=0

# 1. Probe local port 5173
RAW_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://localhost:5173/ 2>/dev/null || true)
HTTP_CODE="${RAW_CODE: -3}"
[ -z "$HTTP_CODE" ] && HTTP_CODE="000"
echo "PORT_5173_HTTP_STATUS=${HTTP_CODE}"

if [ "$HTTP_CODE" != "200" ]; then
  echo "PORT_5173_ALERT=DOWN (status: ${HTTP_CODE})"
  
  # Check if cluster is reachable before trying to heal
  if kubectl get ns fe-signalloom >/dev/null 2>&1; then
    echo "Attempting to restore port 5173..."
    if systemctl --user is-active signalloom-portforward.service >/dev/null 2>&1; then
      systemctl --user restart signalloom-portforward.service
    else
      # Safe kill avoiding current script process
      pgrep -f 'kubectl.*port-forward.*dashboard-signalloom' | grep -v "$$" | xargs -r kill 2>/dev/null || true
      
      # Spawn session-detached port-forward with all 3 fds redirected
      setsid kubectl port-forward -n fe-signalloom svc/dashboard-signalloom 5173:8080 </dev/null >/tmp/sl-portforward.log 2>&1 & disown
    fi
    
    # Bounded polling loop instead of arbitrary sleep
    RETRY_CODE="000"
    for _ in {1..8}; do
      RAW_RETRY=$(curl -s -o /dev/null -w "%{http_code}" --max-time 1 http://localhost:5173/ 2>/dev/null || true)
      RETRY_CODE="${RAW_RETRY: -3}"
      if [ "$RETRY_CODE" = "200" ]; then
        break
      fi
      sleep 0.5
    done
    echo "PORT_5173_RETRY_STATUS=${RETRY_CODE}"
    if [ "$RETRY_CODE" != "200" ]; then
      echo "  [REMEDIATION] Port 5173 recovery attempt failed (HTTP ${RETRY_CODE})."
      echo "  1. Check for socket collision on port 5173: 'lsof -i :5173' or 'ss -lntp | grep 5173'."
      echo "  2. Review port-forward log: 'cat /tmp/sl-portforward.log'."
      echo "  3. Verify dashboard pod is Running: 'kubectl get pods -n fe-signalloom -l app=dashboard-signalloom'."
      echo "  4. Inspect service unit: 'systemctl --user status signalloom-portforward.service' or 'journalctl --user -u signalloom-portforward.service -n 50'."
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  else
    echo "CLUSTER_STATUS=OFFLINE (Cluster unreachable, cannot restart port-forward)"
    echo "  [ADVISORY (Cluster offline)] To start Signal Loom dashboard and ingress:"
    echo "  1. Start the cluster: 'make up'"
    echo "  2. Deploy Signal Loom slice: 'make demo-signalloom-up'"
    echo "  3. Start port-forward: 'systemctl --user restart signalloom-portforward.service' or 'make demo-signalloom-up'"
  fi
else
  echo "PORT_5173_ALERT=HEALTHY"
fi

# 2. Probe in-pod backend routes if cluster is alive
if kubectl get deploy dashboard-signalloom -n fe-signalloom >/dev/null 2>&1; then
  POD_NAME=$(kubectl -n fe-signalloom get pods -l app=dashboard-signalloom -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -n "$POD_NAME" ]; then
    echo "Running in-pod backend probe on pod: ${POD_NAME}..."
    FLEET_PROBE=$(kubectl -n fe-signalloom exec "$POD_NAME" -- curl -sS -o /dev/null -w '%{http_code}' http://localhost:8080/fleet-api/v1/fleet/topology 2>/dev/null || echo "FAILED")
    echo "IN_POD_FLEET_TOPOLOGY_STATUS=${FLEET_PROBE}"
    if [ "$FLEET_PROBE" != "200" ]; then
      echo "  [REMEDIATION] In-pod fleet topology probe returned ${FLEET_PROBE}:"
      echo "  - If 502: Fleet Manager backend pod is down or unregistered: 'kubectl get pods -n inf-signalloom -l app=fleet-manager'."
      echo "  - If 504: NetworkPolicy blocking traffic between fe-signalloom and inf-signalloom."
      echo "  - If text/html: Nginx proxy block missing in d2-signalloom/apps/fe-signalloom/docker/nginx.conf."
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    
    API_PROBE=$(kubectl -n fe-signalloom exec "$POD_NAME" -- curl -sS -o /dev/null -w '%{http_code}' http://localhost:8080/api/v1/health 2>/dev/null || echo "FAILED")
    echo "IN_POD_API_HEALTH_STATUS=${API_PROBE}"
    if [ "$API_PROBE" != "200" ]; then
      echo "  [REMEDIATION] In-pod API health probe returned ${API_PROBE}:"
      echo "  Check API backend pod status: 'kubectl get pods -n fe-signalloom -l app=api-signalloom'."
      echo "  Check API logs: 'kubectl logs -n fe-signalloom -l app=api-signalloom --tail=50'."
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  fi
fi

echo "=== Supervisor Check Completed ==="
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "RESULT: ${FAIL_COUNT} PORT-FORWARD / PROBE FAILURES DETECTED"
  exit 1
else
  echo "RESULT: ALL PORT-FORWARD CHECKS PASS"
  exit 0
fi
