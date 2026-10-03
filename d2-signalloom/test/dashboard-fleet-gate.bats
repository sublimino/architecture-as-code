#!/usr/bin/env bats
#
# @id      dashboard-fleet-gate
# @target  d2-signalloom/apps/dashboard-signalloom/nginx.conf,
#          d2-signalloom/apps/dashboard-signalloom/16-fleet-gate.envsh
# @doc     d2-signalloom/apps/fe-signalloom/src/auth_check.py
#
# The dashboard's /fleet-api/ gate, run in the dashboard's REAL nginx image
# with the REAL nginx.conf rendered by the image's own envsubst entrypoint,
# with the Deployment's read-only root. The upstreams are the REAL service
# FQDNs, answered on a private docker network by stub containers aliased to
# those names (nginx resolves them through the network's DNS, exactly as it
# resolves them through kube-dns in the pod):
#
#   fe-signalloom-api.fe-signalloom.svc.cluster.local:8000
#       GET /api/v1/auth/check: 204 for "Bearer operator-token",
#       403 for "Bearer viewer-token", 401 otherwise
#   fleet-manager.fe-signalloom.svc.cluster.local:8082
#       200, recording every request's method, path and Authorization
#
# No cluster: everything runs on a throwaway local docker network.

load helpers/dashboard-nginx

DASHBOARD_KEY="${DN_DASHBOARD_KEY}"

setup_file() {
  dn_up gate=fe-signalloom-api.fe-signalloom.svc.cluster.local:8000:202 \
        fleet=fleet-manager.fe-signalloom.svc.cluster.local:8082:200
  dn_wait_upstream /fleet-api/v1/fleet/topology
}

teardown_file() { dn_down; }

setup() {
  PORT="$(cat "${WORK}/nginx.port")"
  dn_reset_logs gate fleet
}

# fleet <method> <path> [token] -> HTTP status from the dashboard nginx
fleet() { dn_req "$@"; }

fleet_requests() { dn_count fleet; }

@test "dashboard fleet gate: nginx renders the template and serves" {
  run docker logs "$(cat "${WORK}/cid")"
  [[ "$output" != *"emerg"* ]] || { echo "$output"; return 1; }
  [ "$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/readyz")" = "200" ]
}

@test "dashboard fleet gate: no browser token is 401 and fleet-manager sees nothing" {
  [ "$(fleet POST /fleet-api/v1/fleet/stun/agent-kusari)" = "401" ]
  [ "$(fleet_requests)" -eq 0 ]
  grep -q '"path": "/api/v1/auth/check"' "${WORK}/gate.log"
}

@test "dashboard fleet gate: a non-operator token is 403 and fleet-manager sees nothing" {
  [ "$(fleet POST /fleet-api/v1/fleet/stun/agent-kusari viewer-token)" = "403" ]
  [ "$(fleet POST /fleet-api/v1/fleet/recover viewer-token)" = "403" ]
  [ "$(fleet_requests)" -eq 0 ]
}

@test "dashboard fleet gate: an operator's call reaches fleet-manager with the dashboard key, never the browser token" {
  [ "$(fleet POST /fleet-api/v1/fleet/stun/agent-kusari operator-token)" = "200" ]
  [ "$(fleet_requests)" -eq 1 ]
  run cat "${WORK}/fleet.log"
  [[ "$output" == *'"path": "/api/v1/fleet/stun/agent-kusari"'* ]]
  [[ "$output" == *"\"auth\": [\"Bearer ${DASHBOARD_KEY}\"]"* ]]
  [[ "$output" != *"operator-token"* ]]
  # The gate saw the browser's token, as a GET with no body.
  grep -q '"method": "GET", "path": "/api/v1/auth/check", "auth": \["Bearer operator-token"\]' "${WORK}/gate.log"
}

@test "dashboard fleet gate: topology stays an unauthenticated read and forwards no credential" {
  [ "$(fleet GET /fleet-api/v1/fleet/topology viewer-token)" = "200" ]
  run cat "${WORK}/fleet.log"
  [[ "$output" == *'"path": "/api/v1/fleet/topology", "auth": []'* ]]
  [ "$(fleet POST /fleet-api/v1/fleet/topology operator-token)" = "403" ]
  [ ! -s "${WORK}/gate.log" ]
}

@test "dashboard fleet gate: the gate subrequest is internal and cannot be called directly" {
  [ "$(fleet GET /_fleet_gate operator-token)" = "404" ]
}
