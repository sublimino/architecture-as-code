# shellcheck shell=bash
#
# dashboard-nginx.bash - run the dashboard's REAL nginx image with the REAL
# nginx.conf (rendered by the image's own envsubst entrypoint, read-only root
# like the Deployment) against stub upstreams on a throwaway docker network.
# Each stub is aliased to a REAL service FQDN, so nginx resolves it through the
# network's DNS exactly as it resolves the service through kube-dns in the pod.
#
# Used by dashboard-fleet-gate.bats and dashboard-afm-gate.bats. No cluster.
#
# A stub records every request (method, path, Authorization values) as one JSON
# line in ${WORK}/<name>.log. GET /api/v1/auth/check answers like
# fe-signalloom's superadmin gate: 204 for "Bearer operator-token", 403 for
# "Bearer viewer-token", 401 otherwise. Every other path answers <code>.

DN_IMAGE="nginxinc/nginx-unprivileged:1.27-alpine"
DN_STUB_IMAGE="python:3.12-alpine"
DN_DASHBOARD_KEY="dashboard-fleet-key-0123456789abcdef0123"

# dn_up <name>=<fqdn>:<port>[:<code>] ...  -> exports WORK, APP, NET; writes
# ${WORK}/nginx.port. Call from setup_file.
dn_up() {
  export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/sldc-docker}"
  mkdir -p "${DOCKER_CONFIG}"
  APP="$(cd "${BATS_TEST_DIRNAME}/../apps/dashboard-signalloom" && pwd)"
  WORK="${BATS_FILE_TMPDIR}"
  NET="dashboard-nginx-$$-${RANDOM}"
  export APP WORK NET
  command -v docker >/dev/null || { echo "docker is required to run the dashboard nginx" >&2; return 1; }
  local img
  for img in "${DN_IMAGE}" "${DN_STUB_IMAGE}"; do
    docker image inspect "${img}" >/dev/null 2>&1 \
      || { echo "${img} is not present locally (docker pull ${img})" >&2; return 1; }
  done
  chmod 0777 "${WORK}"
  cat >"${WORK}/stub.py" <<'PY'
import http.server, sys, json
log, port, code = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
class H(http.server.BaseHTTPRequestHandler):
    def _any(self):
        auth = self.headers.get_all("Authorization") or []
        with open(log, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path, "auth": auth}) + "\n")
        c = code
        if self.path == "/api/v1/auth/check":
            c = {"Bearer operator-token": 204, "Bearer viewer-token": 403}.get(auth[0] if len(auth) == 1 else "", 401)
        self.send_response(c); self.send_header("Content-Length", "0"); self.end_headers()
    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = _any
    def send_error(self, code, message=None, explain=None):
        self.send_response(code, message)
        self.send_header("Content-Type", "application/json")
        self.send_header("Connection", "close")
        body = b"{}" if self.command != "HEAD" else b""
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)
    def log_message(self, *a): pass
class Server(http.server.HTTPServer):
    allow_reuse_address = True
Server(("0.0.0.0", port), H).serve_forever()
PY
  docker network create "${NET}" >/dev/null
  local spec name rest fqdn port code
  for spec in "$@"; do
    name="${spec%%=*}"; rest="${spec#*=}"
    IFS=: read -r fqdn port code <<<"${rest}"
    : >"${WORK}/${name}.log"; chmod 0666 "${WORK}/${name}.log"
    docker run -d --rm --network "${NET}" --network-alias "${fqdn}" \
      -v "${WORK}:/w" "${DN_STUB_IMAGE}" python3 /w/stub.py "/w/${name}.log" "${port}" "${code:-200}" \
      >>"${WORK}/stubs.cid"
  done

  local filter
  filter="$(sed -n 's/^ENV NGINX_ENVSUBST_FILTER="\(.*\)"$/\1/p' "${APP}/Dockerfile")"
  [ -n "${filter}" ] || { echo "Dockerfile sets no NGINX_ENVSUBST_FILTER" >&2; return 1; }
  grep -qx 'ENV NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1' "${APP}/Dockerfile" \
    || { echo "Dockerfile does not enable NGINX_ENTRYPOINT_LOCAL_RESOLVERS" >&2; return 1; }
  docker run -d --rm --network "${NET}" -p 127.0.0.1::8080 \
    --read-only --tmpfs /tmp:mode=1777 --tmpfs /etc/nginx/conf.d:mode=1777 -u 101:101 \
    -e NGINX_ENVSUBST_FILTER="${filter}" -e NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1 \
    -e FLEET_DASHBOARD_KEY="${DN_DASHBOARD_KEY}" \
    -v "${APP}/nginx.conf:/etc/nginx/templates/default.conf.template:ro" \
    -v "${APP}/16-fleet-gate.envsh:/docker-entrypoint.d/16-fleet-gate.envsh:ro" \
    "${DN_IMAGE}" >"${WORK}/cid"
  local p i
  p="$(docker port "$(cat "${WORK}/cid")" 8080/tcp | sed 's/.*://' | head -1)"
  echo "${p}" >"${WORK}/nginx.port"
  for i in $(seq 1 50); do curl -s --max-time 2 -o /dev/null "http://127.0.0.1:${p}/readyz" && break; sleep 0.2; done
}

# dn_wait_upstream <path>: poll until nginx reaches an upstream through <path>
# (a GET that a stub answers 200), so the resolver is warm before tests run.
dn_wait_upstream() {
  local p i; p="$(cat "${WORK}/nginx.port")"
  for i in $(seq 1 15); do
    [ "$(curl -s --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${p}$1")" = "200" ] && return 0
    sleep 0.2
  done
  return 1
}

dn_down() {
  local c
  [ -s "${WORK}/cid" ] && docker rm -f "$(cat "${WORK}/cid")" >/dev/null 2>&1
  if [ -s "${WORK}/stubs.cid" ]; then
    while read -r c; do docker rm -f "${c}" >/dev/null 2>&1; done <"${WORK}/stubs.cid"
  fi
  docker network rm "${NET}" >/dev/null 2>&1
  return 0
}

# dn_reset_logs <name>...: truncate the named stubs' request logs.
dn_reset_logs() { local n; for n in "$@"; do : >"${WORK}/${n}.log"; done; }

# dn_req <method> <path> [token] -> HTTP status from the dashboard nginx.
dn_req() {
  local hdr=() p; p="$(cat "${WORK}/nginx.port")"
  [ -n "${3:-}" ] && hdr=(-H "Authorization: Bearer $3")
  curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X "$1" "${hdr[@]}" "http://127.0.0.1:${p}$2"
}

# dn_count <name>: requests that stub has seen since the last reset.
dn_count() { grep -c . "${WORK}/$1.log" || true; }
