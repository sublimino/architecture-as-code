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

IMAGE="nginxinc/nginx-unprivileged:1.27-alpine"
STUB_IMAGE="python:3.12-alpine"
DASHBOARD_KEY="dashboard-fleet-key-0123456789abcdef0123"

setup_file() {
  export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/sldc-docker}"
  mkdir -p "${DOCKER_CONFIG}"
  APP="$(cd "${BATS_TEST_DIRNAME}/../apps/dashboard-signalloom" && pwd)"
  WORK="${BATS_FILE_TMPDIR}"
  NET="dashboard-fleet-gate-$$"
  export APP WORK NET
  command -v docker >/dev/null || { echo "docker is required to run the dashboard nginx" >&2; return 1; }
  local img
  for img in "${IMAGE}" "${STUB_IMAGE}"; do
    docker image inspect "${img}" >/dev/null 2>&1 \
      || { echo "${img} is not present locally (docker pull ${img})" >&2; return 1; }
  done
  chmod 0777 "${WORK}"
  cat >"${WORK}/stub.py" <<'PY'
import http.server, sys, json
role, log, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
class H(http.server.BaseHTTPRequestHandler):
    def _any(self):
        auth = self.headers.get_all("Authorization") or []
        with open(log, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path, "auth": auth}) + "\n")
        if role == "gate":
            code = {"Bearer operator-token": 204, "Bearer viewer-token": 403}.get(auth[0] if len(auth) == 1 else "", 401)
        else:
            code = 200
        self.send_response(code); self.send_header("Content-Length", "0"); self.end_headers()
    do_GET = do_POST = do_HEAD = _any
    def log_message(self, *a): pass
http.server.HTTPServer(("0.0.0.0", port), H).serve_forever()
PY
  # Created here, world-writable, so root in the stubs appends and this
  # (non-root) suite can truncate between tests.
  : >"${WORK}/gate.log"; : >"${WORK}/fleet.log"; chmod 0666 "${WORK}/gate.log" "${WORK}/fleet.log"
  docker network create "${NET}" >/dev/null
  docker run -d --rm --network "${NET}" --network-alias fe-signalloom-api.fe-signalloom.svc.cluster.local \
    -v "${WORK}:/w" "${STUB_IMAGE}" python3 /w/stub.py gate /w/gate.log 8000 >"${WORK}/gate.cid"
  docker run -d --rm --network "${NET}" --network-alias fleet-manager.fe-signalloom.svc.cluster.local \
    -v "${WORK}:/w" "${STUB_IMAGE}" python3 /w/stub.py fleet /w/fleet.log 8082 >"${WORK}/fleet.cid"

  local filter
  filter="$(sed -n 's/^ENV NGINX_ENVSUBST_FILTER="\(.*\)"$/\1/p' "${APP}/Dockerfile")"
  [ -n "${filter}" ] || { echo "Dockerfile sets no NGINX_ENVSUBST_FILTER" >&2; return 1; }
  grep -qx 'ENV NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1' "${APP}/Dockerfile" \
    || { echo "Dockerfile does not enable NGINX_ENTRYPOINT_LOCAL_RESOLVERS" >&2; return 1; }
  # --read-only and the two tmpfs mounts mirror the Deployment: a read-only
  # root with emptyDirs at /tmp and /etc/nginx/conf.d (the rendered config).
  docker run -d --rm --network "${NET}" -p 127.0.0.1::8080 \
    --read-only --tmpfs /tmp:mode=1777 --tmpfs /etc/nginx/conf.d:mode=1777 -u 101:101 \
    -e NGINX_ENVSUBST_FILTER="${filter}" -e NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1 \
    -e FLEET_DASHBOARD_KEY="${DASHBOARD_KEY}" \
    -v "${APP}/nginx.conf:/etc/nginx/templates/default.conf.template:ro" \
    -v "${APP}/16-fleet-gate.envsh:/docker-entrypoint.d/16-fleet-gate.envsh:ro" \
    "${IMAGE}" >"${WORK}/cid"
  PORT="$(docker port "$(cat "${WORK}/cid")" 8080/tcp | sed 's/.*://' | head -1)"
  echo "${PORT}" >"${WORK}/nginx.port"
  local i
  for i in $(seq 1 50); do curl -s --max-time 2 -o /dev/null "http://127.0.0.1:${PORT}/readyz" && break; sleep 0.2; done
  # Both stubs answer through nginx's own resolver before any test runs.
  for i in $(seq 1 15); do
    [ "$(curl -s --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/fleet-api/v1/fleet/topology")" = "200" ] && break
    sleep 0.2
  done
}

teardown_file() {
  local f
  for f in cid gate.cid fleet.cid; do
    [ -s "${WORK}/${f}" ] && docker rm -f "$(cat "${WORK}/${f}")" >/dev/null 2>&1
  done
  docker network rm "${NET}" >/dev/null 2>&1
  return 0
}

setup() {
  PORT="$(cat "${WORK}/nginx.port")"
  : >"${WORK}/gate.log"; : >"${WORK}/fleet.log"
}

# fleet_log / gate_log: the stubs' request records, written into the shared
# bind mount by root inside the stub containers.
fleet_log() { cat "${WORK}/fleet.log" 2>/dev/null; }

# fleet <method> <path> [token] -> HTTP status from the dashboard nginx
fleet() {
  local hdr=()
  [ -n "${3:-}" ] && hdr=(-H "Authorization: Bearer $3")
  curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X "$1" "${hdr[@]}" "http://127.0.0.1:${PORT}$2"
}

fleet_requests() { fleet_log | grep -c . || true; }

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
