#!/usr/bin/env python3
"""netassert-controller: the ONLY process authorised to create/delete the
netassert-run Job.

Why this exists (see fake-integration-proxy/server.py's history): the Scan
Now button used to have fake-integration-proxy call the Kubernetes API
directly with its own ServiceAccount token, which meant granting that SA
`jobs: create` — equivalent to arbitrary code execution as the namespace's
identity, because a stolen or SSRF'd token with that verb can create ANY Job
manifest, not just the fixed one this feature intends. The Python-level
guarantee ("the request body is never inspected") only protects against a
malicious HTTP caller; it does nothing once the token itself is out of the
process's control.

This process is the fix: it holds the ONLY credential capable of
jobs:create/delete on the netassert-run Job, and it exposes exactly one
action — "(re)run the fixed scan" — over HTTP. Even a fully-compromised
fake-integration-proxy (which parses far more attacker-reachable input: JSON
bodies, headers, route params) cannot mint an arbitrary Job manifest through
this controller; the manifest here is the same non-negotiable constant
that used to live in fake-integration-proxy, now with nobody upstream of it
able to parameterise it.
"""

from __future__ import annotations

import json
import os
import ssl
import sys
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib import error, request
from urllib.parse import quote, urlparse

NETASSERT_JOB_NAME = "netassert-run"
NETASSERT_JOB_NAMESPACE = "fe-signalloom"
NETASSERT_RUNNER_SERVICE_ACCOUNT = "netassert-runner"
NETASSERT_RUNNER_IMAGE = os.environ.get("NETASSERT_RUNNER_IMAGE", "netassert-runner:local")
NETASSERT_CONFIGMAP_NAME = "netassert-signalloom-config"
NETASSERT_TAP_MARKER = "----NETASSERT-TAP-RESULTS----"

SERVICE_ACCOUNT_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
SERVICE_ACCOUNT_CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"


def _netassert_job_manifest() -> dict[str, object]:
    """The single, fixed netassert-run Job spec.

    This is the canonical copy — fake-integration-proxy no longer builds this
    manifest at all, so there is exactly one place in the codebase that can
    produce a netassert-run Job body. Every field here is a constant; no
    caller input reaches it (see the module docstring).
    """
    shell = (
        "/usr/local/bin/resolve-agent-pod.sh && "
        "/usr/local/bin/netassert run -f /work/netassert-run.yaml -t /work/results.tap -P 3 || true; "
        f"echo '{NETASSERT_TAP_MARKER}'; "
        "cat /work/results.tap || echo 'no tap output produced'"
    )
    return {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {
            "name": NETASSERT_JOB_NAME,
            "namespace": NETASSERT_JOB_NAMESPACE,
            "labels": {
                "app.kubernetes.io/part-of": "signalloom",
                "signalloom.ai/purpose": "network-test-run",
            },
        },
        "spec": {
            "backoffLimit": 0,
            "ttlSecondsAfterFinished": 600,
            "template": {
                "metadata": {"labels": {"signalloom.ai/purpose": "network-test-run"}},
                "spec": {
                    "restartPolicy": "Never",
                    "serviceAccountName": NETASSERT_RUNNER_SERVICE_ACCOUNT,
                    "securityContext": {
                        "runAsNonRoot": True,
                        "runAsUser": 65532,
                        "runAsGroup": 65532,
                        "seccompProfile": {"type": "RuntimeDefault"},
                    },
                    "containers": [{
                        "name": "netassert",
                        "image": NETASSERT_RUNNER_IMAGE,
                        "imagePullPolicy": "Never",
                        "command": ["/bin/sh", "-c", shell],
                        "securityContext": {
                            "allowPrivilegeEscalation": False,
                            "readOnlyRootFilesystem": True,
                            "capabilities": {"drop": ["ALL"]},
                        },
                        "volumeMounts": [
                            {"name": "config", "mountPath": "/config"},
                            {"name": "work", "mountPath": "/work"},
                        ],
                    }],
                    "volumes": [
                        {"name": "config", "configMap": {"name": NETASSERT_CONFIGMAP_NAME}},
                        {"name": "work", "emptyDir": {}},
                    ],
                },
            },
        },
    }


def _read_service_account_token(token_path: str = SERVICE_ACCOUNT_TOKEN_PATH) -> str:
    with open(token_path, encoding="utf-8") as handle:
        token = handle.read().strip()
    if not token:
        raise ValueError("service account token is empty")
    return token


def _kubernetes_api_base() -> str:
    host = os.environ.get("KUBERNETES_SERVICE_HOST")
    port = os.environ.get("KUBERNETES_SERVICE_PORT")
    if not host or not port:
        raise RuntimeError("kubernetes service host/port are not configured")
    return f"https://{host}:{port}"


def _kubernetes_ssl_context(ca_path: str = SERVICE_ACCOUNT_CA_PATH) -> ssl.SSLContext:
    return ssl.create_default_context(cafile=ca_path)


def _fetch_kubernetes_json(url: str, token: str, context: ssl.SSLContext) -> object:
    req = request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with request.urlopen(req, context=context, timeout=5.0) as response:
        return json.load(response)


def _get_kubernetes_job(
    base_url: str, token: str, context: ssl.SSLContext, namespace: str, name: str,
) -> dict[str, object] | None:
    url = f"{base_url}/apis/batch/v1/namespaces/{quote(namespace, safe='')}/jobs/{quote(name, safe='')}"
    try:
        job = _fetch_kubernetes_json(url, token, context)
    except error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise
    return job if isinstance(job, dict) else None


def _create_kubernetes_job(
    base_url: str, token: str, context: ssl.SSLContext, namespace: str, manifest: dict[str, object],
) -> None:
    url = f"{base_url}/apis/batch/v1/namespaces/{quote(namespace, safe='')}/jobs"
    req = request.Request(
        url,
        data=json.dumps(manifest).encode(),
        method="POST",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    with request.urlopen(req, context=context, timeout=10.0):
        return


def _delete_kubernetes_job(
    base_url: str, token: str, context: ssl.SSLContext, namespace: str, name: str,
) -> None:
    url = (
        f"{base_url}/apis/batch/v1/namespaces/{quote(namespace, safe='')}/jobs/{quote(name, safe='')}"
        "?propagationPolicy=Background"
    )
    req = request.Request(url, method="DELETE", headers={"Authorization": f"Bearer {token}"})
    try:
        with request.urlopen(req, context=context, timeout=10.0):
            return
    except error.HTTPError as exc:
        if exc.code != 404:
            raise


def _job_status_count(status: dict[str, object], field: str) -> int:
    value = status.get(field)
    return value if isinstance(value, int) else 0


class ControllerHandler(BaseHTTPRequestHandler):
    server_version = "NetassertController/1.0"

    def log_message(self, format: str, *args: object) -> None:
        return

    def _json(self, status: int, payload: object) -> None:
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def _drain_body(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        if length:
            self.rfile.read(length)

    def _handle_scan(self) -> None:
        """POST /scan — (re)create the fixed netassert-run Job.

        Mirrors the guard that used to live in fake-integration-proxy: a
        currently-active Job means 409, a finished Job is deleted and
        recreated, and the manifest submitted is always the same constant
        from _netassert_job_manifest — no caller input reaches it (the body
        is drained and discarded, never parsed).
        """
        self._drain_body()
        try:
            token = _read_service_account_token()
            context = _kubernetes_ssl_context()
            base_url = _kubernetes_api_base()
        except (OSError, ValueError, TypeError, ssl.SSLError) as exc:
            self._json(HTTPStatus.BAD_GATEWAY, {"error": str(exc)})
            return

        existing = _get_kubernetes_job(base_url, token, context, NETASSERT_JOB_NAMESPACE, NETASSERT_JOB_NAME)
        if existing is not None:
            status = existing.get("status")
            if isinstance(status, dict) and _job_status_count(status, "active") >= 1:
                self._json(HTTPStatus.CONFLICT, {"error": "a network test scan is already running"})
                return
            try:
                _delete_kubernetes_job(base_url, token, context, NETASSERT_JOB_NAMESPACE, NETASSERT_JOB_NAME)
            except (OSError, ValueError, TypeError, error.HTTPError, error.URLError, ssl.SSLError) as exc:
                self._json(HTTPStatus.BAD_GATEWAY, {"error": f"could not clear previous scan: {exc}"})
                return
            # Jobs delete asynchronously (propagationPolicy=Background); a
            # same-name create can race the deletion and 409. netassert-run's
            # name is fixed by design, so a short bounded wait is simpler and
            # safer here than minting per-scan unique names.
            for _ in range(10):
                if _get_kubernetes_job(base_url, token, context, NETASSERT_JOB_NAMESPACE, NETASSERT_JOB_NAME) is None:
                    break
                time.sleep(0.3)

        try:
            _create_kubernetes_job(base_url, token, context, NETASSERT_JOB_NAMESPACE, _netassert_job_manifest())
        except (OSError, ValueError, TypeError, error.HTTPError, error.URLError, ssl.SSLError) as exc:
            print(f"netassert-controller: scan failed to start: {exc}", file=sys.stderr, flush=True)
            self._json(HTTPStatus.BAD_GATEWAY, {"error": f"failed to start scan: {exc}"})
            return

        self._json(HTTPStatus.ACCEPTED, {"job": NETASSERT_JOB_NAME, "status": "started"})

    def _dispatch(self) -> None:
        path = urlparse(self.path).path
        if path == "/health" and self.command == "GET":
            self._json(HTTPStatus.OK, {"status": "ok"})
        elif path == "/scan" and self.command == "POST":
            self._handle_scan()
        else:
            self._drain_body()
            self._json(HTTPStatus.NOT_FOUND, {"error": "unknown route"})

    do_GET = _dispatch
    do_POST = _dispatch


def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    ThreadingHTTPServer(("0.0.0.0", port), ControllerHandler).serve_forever()


if __name__ == "__main__":
    main()
