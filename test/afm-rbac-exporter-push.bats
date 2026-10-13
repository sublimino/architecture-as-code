#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      afm-rbac-exporter-push
# @target  d2-signalloom/infra/agent-swarm/signalloom-warden/rbac-exporter/export.py
# @doc     docs/Proposal — Signal Loom Spireless Token-Based Agent Identity Migration (2026-Q4).md
# @spec    SLTM Phase 1, D2/D3/ADR-06 (P1-2)
#
# Offline push validation: extracts export.py from the rendered ConfigMap,
# runs it against local stub servers on 127.0.0.1 ephemeral ports, and verifies
# authentication, payload shape, pagination, fail-closed behavior, and process hygiene.

bats_require_minimum_version 1.5.0

setup_file() {
  export REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export KUBECONFIG=/dev/null
  local T="${BATS_FILE_TMPDIR}"

  mkdir -p "${T}/config"

  # Extract export.py directly from the rendered ConfigMap
  kubectl kustomize "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-warden" 2>/dev/null \
    | yq -r 'select(.kind == "ConfigMap" and .metadata.name == "signalloom-rbac-exporter-script*") | .data["export.py"]' > "${T}/export.py" || true

  # Python stub server script
  cat <<'PYEOF' > "${T}/fake_servers.py"
import http.server
import socketserver
import threading
import json
import os
import time
import sys

DIR = sys.argv[1]
CFG_DIR = os.path.join(DIR, "config")
KUBE_LOG = os.path.join(DIR, "kube_requests.jsonl")
AFM_LOG = os.path.join(DIR, "afm_requests.jsonl")

class KubeHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def send_error(self, code, message=None, explain=None):
        if code == 501:
            body = b"method not allowed"
            self.send_response(405)
            self.send_header("Allow", "GET, HEAD")
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
            return
        err_msg = message or (http.server.BaseHTTPRequestHandler.responses.get(code, ("error",))[0])
        self._send_json(code, {"error": err_msg, "code": code})

    def do_GET(self):
        req_entry = {
            "method": "GET",
            "path": self.path,
            "headers": dict(self.headers),
        }
        with open(KUBE_LOG, "a") as f:
            f.write(json.dumps(req_entry) + "\n")

        # Check for error injection
        err_file = os.path.join(CFG_DIR, "kube_error.json")
        if os.path.exists(err_file):
            try:
                with open(err_file) as f:
                    cfg = json.load(f)
                if cfg.get("path_match") in self.path:
                    status = cfg.get("status", 403)
                    self._send_json(status, {"kind": "Status", "status": "Failure", "code": status})
                    return
            except Exception:
                pass

        # Check for pagination test on clusterroles
        paged_file = os.path.join(CFG_DIR, "kube_paged.json")
        if os.path.exists(paged_file) and "/apis/rbac.authorization.k8s.io/v1/clusterroles" in self.path:
            if "continue=" in self.path:
                resp_data = {
                    "kind": "ClusterRoleList",
                    "apiVersion": "rbac.authorization.k8s.io/v1",
                    "metadata": {},
                    "items": [
                        {"metadata": {"name": "page2-role-1"}, "rules": [{"verbs": ["get"], "apiGroups": [""], "resources": ["pods"]}]},
                        {"metadata": {"name": "page2-role-2"}, "rules": [{"verbs": ["list"], "apiGroups": ["apps"], "resources": ["deployments"]}]},
                    ]
                }
            else:
                resp_data = {
                    "kind": "ClusterRoleList",
                    "apiVersion": "rbac.authorization.k8s.io/v1",
                    "metadata": {"continue": "tok-page2"},
                    "items": [
                        {"metadata": {"name": "page1-role-1"}, "rules": [{"verbs": ["get"], "apiGroups": [""], "resources": ["pods"]}]},
                        {"metadata": {"name": "page1-role-2"}, "rules": [{"verbs": ["watch"], "apiGroups": [""], "resources": ["services"]}]},
                    ]
                }
            self._send_json(200, resp_data)
            return

        # Default fixtures
        items = []
        kind = "List"
        if "clusterroles" in self.path:
            kind = "ClusterRoleList"
            items = [{"metadata": {"name": "admin-role"}, "rules": [{"verbs": ["*"], "apiGroups": ["*"], "resources": ["*"]}]}]
        elif "clusterrolebindings" in self.path:
            kind = "ClusterRoleBindingList"
            items = [{
                "metadata": {"name": "admin-binding"},
                "roleRef": {"name": "admin-role", "kind": "ClusterRole"},
                "subjects": [{"kind": "User", "name": "alice"}]
            }]
        elif "roles" in self.path:
            kind = "RoleList"
            items = [{"metadata": {"name": "pod-reader", "namespace": "default"}, "rules": [{"verbs": ["get", "list"], "apiGroups": [""], "resources": ["pods"]}]}]
        elif "rolebindings" in self.path:
            kind = "RoleBindingList"
            items = [{
                "metadata": {"name": "read-pods", "namespace": "default"},
                "roleRef": {"name": "pod-reader", "kind": "Role"},
                "subjects": [{"kind": "ServiceAccount", "name": "sa-reader", "namespace": "default"}]
            }]
        elif "namespaces" in self.path:
            kind = "NamespaceList"
            items = [
                {"metadata": {"name": "default"}},
                {"metadata": {"name": "fe-signalloom-agents"}}
            ]
        elif "serviceaccounts" in self.path:
            kind = "ServiceAccountList"
            items = [
                {"metadata": {"name": "default", "namespace": "default"}},
                {"metadata": {"name": "signalloom-rbac-exporter", "namespace": "fe-signalloom-agents"}}
            ]

        resp_data = {
            "kind": kind,
            "apiVersion": "v1",
            "metadata": {},
            "items": items
        }
        self._send_json(200, resp_data)

class AFMHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_error(self, code, message=None, explain=None):
        if code == 501:
            body = b"method not allowed"
            self.send_response(405)
            self.send_header("Allow", "POST")
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
            return
        err_msg = message or (http.server.BaseHTTPRequestHandler.responses.get(code, ("error",))[0])
        self._send_json(code, {"error": err_msg, "code": code})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body_raw = self.rfile.read(length).decode("utf-8")
        try:
            body_json = json.loads(body_raw)
        except Exception:
            body_json = body_raw

        req_entry = {
            "method": "POST",
            "path": self.path,
            "headers": dict(self.headers),
            "body": body_json
        }
        with open(AFM_LOG, "a") as f:
            f.write(json.dumps(req_entry) + "\n")

        # Delay support
        delay_file = os.path.join(CFG_DIR, "afm_delay.txt")
        if os.path.exists(delay_file):
            try:
                with open(delay_file) as f:
                    d = float(f.read().strip())
                time.sleep(d)
            except Exception:
                pass

        # Refusal status code support
        status_file = os.path.join(CFG_DIR, "afm_status.txt")
        if os.path.exists(status_file):
            try:
                with open(status_file) as f:
                    status = int(f.read().strip())
                self._send_json(status, {"error": "injected_status", "code": status})
                return
            except Exception:
                pass

        self._send_json(200, {"status": "imported", "cluster": "kind-osramp"})

class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True

kube_server = ThreadedTCPServer(("127.0.0.1", 0), KubeHandler)
afm_server = ThreadedTCPServer(("127.0.0.1", 0), AFMHandler)

kube_port = kube_server.server_address[1]
afm_port = afm_server.server_address[1]

with open(os.path.join(DIR, "ports.env"), "w") as f:
    f.write(f"FAKE_KUBE_PORT={kube_port}\n")
    f.write(f"FAKE_AFM_PORT={afm_port}\n")

t1 = threading.Thread(target=kube_server.serve_forever)
t2 = threading.Thread(target=afm_server.serve_forever)
t1.daemon = True
t2.daemon = True
t1.start()
t2.start()

while True:
    time.sleep(1)
PYEOF

  python3 "${T}/fake_servers.py" "${T}" >/dev/null 2>&1 &
  local server_pid=$!
  echo "${server_pid}" > "${T}/fake_servers.pid"

  # Wait for ports file to be written
  local waited=0
  while [ ! -f "${T}/ports.env" ] && [ "${waited}" -lt 20 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
}

teardown_file() {
  local T="${BATS_FILE_TMPDIR}"
  if [ -f "${T}/fake_servers.pid" ]; then
    local pid
    pid="$(cat "${T}/fake_servers.pid")"
    if [ -n "${pid}" ]; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
  fi
}

setup() {
  export REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export KUBECONFIG=/dev/null
  local T="${BATS_FILE_TMPDIR}"

  source "${T}/ports.env"

  # Reset config and logs per test
  rm -rf "${T}/config"
  mkdir -p "${T}/config"
  rm -f "${T}/kube_requests.jsonl" "${T}/afm_requests.jsonl"

  # Default test keys and tokens
  mkdir -p "${BATS_TEST_TMPDIR}"
  echo "valid-token-for-testing-12345678901234567890" > "${BATS_TEST_TMPDIR}/sa_token"
  echo "dummy-ca-data" > "${BATS_TEST_TMPDIR}/ca.crt"

  mkdir -p "${BATS_TEST_TMPDIR}/key"
  echo "afm-test-key-32-bytes-minimum-length-abcdef" > "${BATS_TEST_TMPDIR}/key/token"
}

@test "exporter push: full push with bearer key, bound cluster id, and valid body shape (T5)" {
  local T="${BATS_FILE_TMPDIR}"
  [ -f "${T}/export.py" ]

  run env \
    RBAC_EXPORTER_API_BASE="http://127.0.0.1:${FAKE_KUBE_PORT}" \
    RBAC_EXPORTER_TOKEN_FILE="${BATS_TEST_TMPDIR}/sa_token" \
    RBAC_EXPORTER_CA_FILE="${BATS_TEST_TMPDIR}/ca.crt" \
    RBAC_EXPORTER_KEY_FILE="${BATS_TEST_TMPDIR}/key/token" \
    AFM_IMPORT_URL="http://127.0.0.1:${FAKE_AFM_PORT}/api/v1/afm/clusters/import" \
    AFM_CLUSTER_ID="kind-osramp" \
    python3 "${T}/export.py"

  [ "$status" -eq 0 ]

  # Fake AFM received exactly one request
  [ -f "${T}/afm_requests.jsonl" ]
  [ "$(wc -l < "${T}/afm_requests.jsonl")" -eq 1 ]

  local afm_req
  afm_req="$(head -n 1 "${T}/afm_requests.jsonl")"

  # Check method, path, and Authorization header
  [ "$(echo "${afm_req}" | jq -r '.method')" = "POST" ]
  [ "$(echo "${afm_req}" | jq -r '.path')" = "/api/v1/afm/clusters/import" ]
  [ "$(echo "${afm_req}" | jq -r '.headers["Authorization"] // .headers["authorization"]')" = "Bearer afm-test-key-32-bytes-minimum-length-abcdef" ]
  [ "$(echo "${afm_req}" | jq -r '.headers["Content-Type"] // .headers["content-type"]')" = "application/json" ]

  # Check body contract
  local body
  body="$(echo "${afm_req}" | jq '.body')"
  [ "$(echo "${body}" | jq -r '.id')" = "kind-osramp" ]
  [ -n "$(echo "${body}" | jq -r '.name')" ]

  # Check rbac.subjects contains serviceaccounts
  local sa_sub
  sa_sub="$(echo "${body}" | jq -r '.rbac.subjects[] | select(.kind == "ServiceAccount" and .name == "signalloom-rbac-exporter") | .namespace')"
  [ "${sa_sub}" = "fe-signalloom-agents" ]

  # Check roles and bindings
  [ "$(echo "${body}" | jq -r '.rbac.roles | length')" -ge 2 ]
  [ "$(echo "${body}" | jq -r '.rbac.bindings | length')" -ge 2 ]

  # Fake Kube API saw only the 6 resource endpoints, and never /secrets
  local kube_paths
  kube_paths="$(jq -r '.path' "${T}/kube_requests.jsonl" | sort -u)"
  [[ "${kube_paths}" != *"secrets"* ]]
  [ "$(echo "${kube_paths}" | grep -Ec 'clusterroles|clusterrolebindings|roles|rolebindings|namespaces|serviceaccounts')" -ge 6 ]
}

@test "exporter push: pagination follows metadata.continue and includes all items (T5b-page)" {
  local T="${BATS_FILE_TMPDIR}"
  [ -f "${T}/export.py" ]

  # Enable pagination fixture
  echo '{"paged": true}' > "${T}/config/kube_paged.json"

  run env \
    RBAC_EXPORTER_API_BASE="http://127.0.0.1:${FAKE_KUBE_PORT}" \
    RBAC_EXPORTER_TOKEN_FILE="${BATS_TEST_TMPDIR}/sa_token" \
    RBAC_EXPORTER_CA_FILE="${BATS_TEST_TMPDIR}/ca.crt" \
    RBAC_EXPORTER_KEY_FILE="${BATS_TEST_TMPDIR}/key/token" \
    AFM_IMPORT_URL="http://127.0.0.1:${FAKE_AFM_PORT}/api/v1/afm/clusters/import" \
    AFM_CLUSTER_ID="kind-osramp" \
    python3 "${T}/export.py"

  [ "$status" -eq 0 ]

  # Verify clusterroles from both page 1 and page 2 are present in payload
  local afm_req roles
  afm_req="$(head -n 1 "${T}/afm_requests.jsonl")"
  roles="$(echo "${afm_req}" | jq -r '.body.rbac.roles[].name')"

  [[ "${roles}" == *"page1-role-1"* ]]
  [[ "${roles}" == *"page1-role-2"* ]]
  [[ "${roles}" == *"page2-role-1"* ]]
  [[ "${roles}" == *"page2-role-2"* ]]
}

@test "exporter push: fail-closed on 403 list failure, posts nothing and exits 4 (T5b-failclosed)" {
  local T="${BATS_FILE_TMPDIR}"
  [ -f "${T}/export.py" ]

  # Inject 403 on roles endpoint
  echo '{"path_match": "roles", "status": 403}' > "${T}/config/kube_error.json"

  run env \
    RBAC_EXPORTER_API_BASE="http://127.0.0.1:${FAKE_KUBE_PORT}" \
    RBAC_EXPORTER_TOKEN_FILE="${BATS_TEST_TMPDIR}/sa_token" \
    RBAC_EXPORTER_CA_FILE="${BATS_TEST_TMPDIR}/ca.crt" \
    RBAC_EXPORTER_KEY_FILE="${BATS_TEST_TMPDIR}/key/token" \
    AFM_IMPORT_URL="http://127.0.0.1:${FAKE_AFM_PORT}/api/v1/afm/clusters/import" \
    AFM_CLUSTER_ID="kind-osramp" \
    python3 "${T}/export.py"

  [ "$status" -eq 4 ]

  # AFM receives zero requests
  [ ! -f "${T}/afm_requests.jsonl" ] || [ ! -s "${T}/afm_requests.jsonl" ]
}

@test "exporter push: missing, short or whitespace key exits 3 before any request (T5b-key)" {
  local T="${BATS_FILE_TMPDIR}"
  [ -f "${T}/export.py" ]

  # 1. Missing key file
  run env \
    RBAC_EXPORTER_API_BASE="http://127.0.0.1:${FAKE_KUBE_PORT}" \
    RBAC_EXPORTER_TOKEN_FILE="${BATS_TEST_TMPDIR}/sa_token" \
    RBAC_EXPORTER_CA_FILE="${BATS_TEST_TMPDIR}/ca.crt" \
    RBAC_EXPORTER_KEY_FILE="${BATS_TEST_TMPDIR}/nonexistent_key" \
    AFM_IMPORT_URL="http://127.0.0.1:${FAKE_AFM_PORT}/api/v1/afm/clusters/import" \
    AFM_CLUSTER_ID="kind-osramp" \
    python3 "${T}/export.py"

  [ "$status" -eq 3 ]
  [ ! -f "${T}/kube_requests.jsonl" ] || [ ! -s "${T}/kube_requests.jsonl" ]
  [ ! -f "${T}/afm_requests.jsonl" ] || [ ! -s "${T}/afm_requests.jsonl" ]

  # 2. Short key (< 32 bytes)
  echo "short-key-12345" > "${BATS_TEST_TMPDIR}/short_key"
  run env \
    RBAC_EXPORTER_API_BASE="http://127.0.0.1:${FAKE_KUBE_PORT}" \
    RBAC_EXPORTER_TOKEN_FILE="${BATS_TEST_TMPDIR}/sa_token" \
    RBAC_EXPORTER_CA_FILE="${BATS_TEST_TMPDIR}/ca.crt" \
    RBAC_EXPORTER_KEY_FILE="${BATS_TEST_TMPDIR}/short_key" \
    AFM_IMPORT_URL="http://127.0.0.1:${FAKE_AFM_PORT}/api/v1/afm/clusters/import" \
    AFM_CLUSTER_ID="kind-osramp" \
    python3 "${T}/export.py"

  [ "$status" -eq 3 ]
  [ ! -f "${T}/kube_requests.jsonl" ] || [ ! -s "${T}/kube_requests.jsonl" ]

  # 3. Whitespace-only key
  echo "   " > "${BATS_TEST_TMPDIR}/ws_key"
  run env \
    RBAC_EXPORTER_API_BASE="http://127.0.0.1:${FAKE_KUBE_PORT}" \
    RBAC_EXPORTER_TOKEN_FILE="${BATS_TEST_TMPDIR}/sa_token" \
    RBAC_EXPORTER_CA_FILE="${BATS_TEST_TMPDIR}/ca.crt" \
    RBAC_EXPORTER_KEY_FILE="${BATS_TEST_TMPDIR}/ws_key" \
    AFM_IMPORT_URL="http://127.0.0.1:${FAKE_AFM_PORT}/api/v1/afm/clusters/import" \
    AFM_CLUSTER_ID="kind-osramp" \
    python3 "${T}/export.py"

  [ "$status" -eq 3 ]
  [ ! -f "${T}/kube_requests.jsonl" ] || [ ! -s "${T}/kube_requests.jsonl" ]
}

@test "exporter push: gateway 401, 403, 413, 500 exits 5 without retry loop (T5b-refusal)" {
  local T="${BATS_FILE_TMPDIR}"
  [ -f "${T}/export.py" ]

  for err_code in 401 403 413 500; do
    rm -f "${T}/afm_requests.jsonl"
    echo "${err_code}" > "${T}/config/afm_status.txt"

    run env \
      RBAC_EXPORTER_API_BASE="http://127.0.0.1:${FAKE_KUBE_PORT}" \
      RBAC_EXPORTER_TOKEN_FILE="${BATS_TEST_TMPDIR}/sa_token" \
      RBAC_EXPORTER_CA_FILE="${BATS_TEST_TMPDIR}/ca.crt" \
      RBAC_EXPORTER_KEY_FILE="${BATS_TEST_TMPDIR}/key/token" \
      AFM_IMPORT_URL="http://127.0.0.1:${FAKE_AFM_PORT}/api/v1/afm/clusters/import" \
      AFM_CLUSTER_ID="kind-osramp" \
      python3 "${T}/export.py"

    [ "$status" -eq 5 ]

    # Log does not expose raw key
    [[ "$output" != *"afm-test-key-32-bytes-minimum-length-abcdef"* ]]

    # Exactly one POST was made (no retry loop)
    [ "$(wc -l < "${T}/afm_requests.jsonl")" -eq 1 ]
  done
}

@test "exporter push: config error on missing AFM_CLUSTER_ID or non-local http API (T5b-config)" {
  local T="${BATS_FILE_TMPDIR}"
  [ -f "${T}/export.py" ]

  # Missing AFM_CLUSTER_ID
  run env \
    RBAC_EXPORTER_API_BASE="http://127.0.0.1:${FAKE_KUBE_PORT}" \
    RBAC_EXPORTER_TOKEN_FILE="${BATS_TEST_TMPDIR}/sa_token" \
    RBAC_EXPORTER_CA_FILE="${BATS_TEST_TMPDIR}/ca.crt" \
    RBAC_EXPORTER_KEY_FILE="${BATS_TEST_TMPDIR}/key/token" \
    AFM_IMPORT_URL="http://127.0.0.1:${FAKE_AFM_PORT}/api/v1/afm/clusters/import" \
    python3 "${T}/export.py"

  [ "$status" -eq 2 ]

  # Non-127.0.0.1 http API base URL
  run env \
    RBAC_EXPORTER_API_BASE="http://192.168.1.50:6443" \
    RBAC_EXPORTER_TOKEN_FILE="${BATS_TEST_TMPDIR}/sa_token" \
    RBAC_EXPORTER_CA_FILE="${BATS_TEST_TMPDIR}/ca.crt" \
    RBAC_EXPORTER_KEY_FILE="${BATS_TEST_TMPDIR}/key/token" \
    AFM_IMPORT_URL="http://127.0.0.1:${FAKE_AFM_PORT}/api/v1/afm/clusters/import" \
    AFM_CLUSTER_ID="kind-osramp" \
    python3 "${T}/export.py"

  [ "$status" -eq 2 ]
}

@test "exporter push: process cmdline and output never expose key or token (T5b-hygiene)" {
  local T="${BATS_FILE_TMPDIR}"
  [ -f "${T}/export.py" ]

  # Add 0.5s delay to AFM response so we can inspect cmdline while process runs
  echo "0.5" > "${T}/config/afm_delay.txt"

  local test_key="secret-key-32-bytes-hygiene-probe-9988776655"
  local test_token="secret-sa-token-hygiene-probe-1122334455"

  echo "${test_key}" > "${BATS_TEST_TMPDIR}/key/hygiene_key"
  echo "${test_token}" > "${BATS_TEST_TMPDIR}/hygiene_sa_token"

  env \
    RBAC_EXPORTER_API_BASE="http://127.0.0.1:${FAKE_KUBE_PORT}" \
    RBAC_EXPORTER_TOKEN_FILE="${BATS_TEST_TMPDIR}/hygiene_sa_token" \
    RBAC_EXPORTER_CA_FILE="${BATS_TEST_TMPDIR}/ca.crt" \
    RBAC_EXPORTER_KEY_FILE="${BATS_TEST_TMPDIR}/key/hygiene_key" \
    AFM_IMPORT_URL="http://127.0.0.1:${FAKE_AFM_PORT}/api/v1/afm/clusters/import" \
    AFM_CLUSTER_ID="kind-osramp" \
    python3 "${T}/export.py" > "${BATS_TEST_TMPDIR}/out.log" 2>&1 &
  local py_pid=$!

  # Check /proc/<pid>/cmdline while running
  sleep 0.1
  if [ -d "/proc/${py_pid}" ]; then
    local cmdline
    cmdline="$(tr '\0' ' ' < "/proc/${py_pid}/cmdline" 2>/dev/null || true)"
    [[ "${cmdline}" != *"${test_key}"* ]]
    [[ "${cmdline}" != *"${test_token}"* ]]
  fi

  wait "${py_pid}"
  local exit_code=$?
  [ "${exit_code}" -eq 0 ]

  # Check captured output log
  local out_log
  out_log="$(cat "${BATS_TEST_TMPDIR}/out.log")"
  [[ "${out_log}" != *"${test_key}"* ]]
  [[ "${out_log}" != *"${test_token}"* ]]
}
