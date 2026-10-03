#!/usr/bin/env bats
#
# @id      dashboard-afm-gate
# @target  d2-signalloom/apps/dashboard-signalloom/nginx.conf
# @doc     d2-signalloom/apps/fe-signalloom/src/auth_check.py
#
# The dashboard's KubeSec-AFM proxies, run in the REAL nginx image with the
# REAL nginx.conf (see helpers/dashboard-nginx.bash). Reads pass as before; a
# mutating method on any prefix that reaches afm-platform, or on the
# fe-signalloom scan trigger, needs a superadmin's Dex token
# (GET /api/v1/auth/check) and otherwise never reaches the upstream.
#
#   fe   fe-signalloom-api.fe-signalloom.svc.cluster.local:8000  (gate + scan trigger, 202)
#   afm  afm-platform.fe-k8s-afm.svc.cluster.local:8000          (200)

load helpers/dashboard-nginx

# Every location that proxies to afm-platform, as the browser addresses it.
AFM_PATHS=(/afm/clusters /clusters /jobs /webhooks/github /metrics/x /health /dashboard/x)

setup_file() {
  dn_up fe=fe-signalloom-api.fe-signalloom.svc.cluster.local:8000:202 \
        afm=afm-platform.fe-k8s-afm.svc.cluster.local:8000:200
  dn_wait_upstream /clusters
}

teardown_file() { dn_down; }

setup() { dn_reset_logs fe afm; }

gate_calls() { grep -c '"path": "/api/v1/auth/check"' "${WORK}/fe.log" || true; }

@test "afm gate: reads on every AFM prefix pass untouched and never ask the gate" {
  local p
  for p in "${AFM_PATHS[@]}"; do
    [ "$(dn_req GET "$p")" = "200" ] || { echo "GET $p"; return 1; }
  done
  [ "$(dn_req HEAD /clusters)" = "200" ]
  [ "$(dn_count afm)" -eq $(( ${#AFM_PATHS[@]} + 1 )) ]
  [ "$(gate_calls)" -eq 0 ]
}

@test "afm gate: a mutation with no token is 401 on every AFM prefix and afm-platform sees none" {
  local p m
  for p in "${AFM_PATHS[@]}"; do
    for m in POST PUT PATCH DELETE; do
      [ "$(dn_req "$m" "$p")" = "401" ] || { echo "$m $p"; return 1; }
    done
  done
  [ "$(dn_count afm)" -eq 0 ]
}

@test "afm gate: a non-superadmin's mutation is 403 and afm-platform sees none" {
  [ "$(dn_req POST /clusters viewer-token)" = "403" ]
  [ "$(dn_req DELETE /afm/clusters/local viewer-token)" = "403" ]
  [ "$(dn_req POST /webhooks/github viewer-token)" = "403" ]
  [ "$(dn_count afm)" -eq 0 ]
}

@test "afm gate: a superadmin's mutation reaches afm-platform once, after one gate check" {
  [ "$(dn_req POST /clusters operator-token)" = "200" ]
  [ "$(dn_count afm)" -eq 1 ]
  grep -q '"method": "POST", "path": "/clusters"' "${WORK}/afm.log"
  [ "$(gate_calls)" -eq 1 ]
  grep -q '"method": "GET", "path": "/api/v1/auth/check", "auth": \["Bearer operator-token"\]' "${WORK}/fe.log"
}

@test "afm gate: scan triggers need a superadmin; the superadmin's token reaches fe-signalloom" {
  [ "$(dn_req POST /afm/clusters/local/jobs)" = "401" ]
  [ "$(dn_req POST /afm/clusters/local/jobs viewer-token)" = "403" ]
  run grep -c '"path": "/afm/clusters/local/jobs"' "${WORK}/fe.log"
  [ "$output" = "0" ]
  [ "$(dn_req POST /afm/clusters/local/jobs operator-token)" = "202" ]
  grep -q '"method": "POST", "path": "/afm/clusters/local/jobs", "auth": \["Bearer operator-token"\]' "${WORK}/fe.log"
  [ "$(dn_count afm)" -eq 0 ]
}

@test "afm gate: the gate subrequest is internal and cannot be called directly" {
  [ "$(dn_req POST /_afm_gate operator-token)" = "404" ]
}
