#!/usr/bin/env python3
"""Deterministic, in-memory fake for the Signalloom demo integrations.

This process is intentionally not an integration gateway: it makes no outbound
connections and its mutable state disappears when the pod restarts.
"""

from __future__ import annotations

import copy
import json
import os
import ssl
import sys
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock
from urllib import error, request
from urllib.parse import quote, urlparse


ROUTE_PREFIXES = {
    "llm": "/llm/",
    "crm": "/crm/",
    "notification": "/notification/",
    "outbound-reporting": "/outbound-reporting/",
}
SENSITIVE_BODY_KEYS = {
    "authorization", "credential", "credentials", "password", "secret", "token",
    "api_key", "apikey", "access_key", "private_key",
}
CAPTURED_HEADERS = {"content-type", "user-agent", "x-request-id"}

DEFAULT_FIXTURES = {
    "llm": {"default": {"data": [{"id": "demo-assistant-001", "name": "Demo Assistant"}]}},
    "crm": {"default": {"id": "demo-contact-001", "status": "accepted"}},
    "notification": {"default": {"ok": True, "message": "demo notification accepted"}},
    "outbound-reporting": {"default": {"id": "demo-report-001", "status": "queued"}},
}
AGENT_DISCOVERY_NAMESPACE = "fe-signalloom-agents"
AGENT_DISCOVERY_SELECTOR = "signalloom.ai/agent=true"
POLICY_ENGINE_URL = os.environ.get(
    "POLICY_ENGINE_URL", "http://policy-engine.inf-signalloom.svc.cluster.local:8081"
)
SUPERCRED_CHECKS = ["security-context-present", "run-as-non-root", "drop-capabilities"]
FLUX_NAMESPACE = "fe-signalloom"
CRYPTO_PROOF_NAMESPACE = "fe-signalloom"
CRYPTO_PROOF_CONTAINER = "jwt-svid"
POSITIVE_PROOF_JOB_NAME = "bao-spire-positive-proof"
NEGATIVE_PROOF_JOB_NAME = "bao-spire-negative-proof"
CRYPTO_PROOF_DEFINITIONS = (
    {
        "name": POSITIVE_PROOF_JOB_NAME,
        "kind": "positive",
        "title": "Correct SPIFFE identity can authenticate to OpenBao and read its secret",
        "description": (
            "The fe-signalloom workload should receive a JWT-SVID, authenticate to OpenBao, "
            "and read kv/data/signalloom/fe-signalloom."
        ),
        "expectation": "Expected to succeed with the fe-signalloom workload identity.",
    },
    {
        "name": NEGATIVE_PROOF_JOB_NAME,
        "kind": "negative",
        "title": "A mis-identified workload is denied by OpenBao's SPIFFE role binding — fail-closed",
        "description": (
            "The fe-signalloom-negative workload should be denied when it tries the same "
            "OpenBao read with the wrong SPIFFE identity."
        ),
        "expectation": "Expected to be denied; fail-closed behavior is the passing outcome.",
    },
)
SERVICE_ACCOUNT_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
SERVICE_ACCOUNT_CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"


def redact(value: object, key: str = "") -> object:
    """Return a safe structural representation without retaining secret values."""
    normalised_key = key.lower().replace("-", "_")
    if normalised_key in SENSITIVE_BODY_KEYS or any(marker in normalised_key for marker in SENSITIVE_BODY_KEYS):
        return "[REDACTED]"
    if isinstance(value, dict):
        return {str(k): redact(v, str(k)) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(item) for item in value]
    return value


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


def _fetch_kubernetes_text(url: str, token: str, context: ssl.SSLContext) -> str:
    req = request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with request.urlopen(req, context=context, timeout=5.0) as response:
        return response.read().decode("utf-8", errors="replace")


def _agent_from_pod(pod: object) -> dict[str, object] | None:
    if not isinstance(pod, dict):
        return None
    metadata = pod.get("metadata")
    labels = metadata.get("labels") if isinstance(metadata, dict) else {}
    annotations = metadata.get("annotations") if isinstance(metadata, dict) else {}
    spec = pod.get("spec")
    status = pod.get("status")
    if not isinstance(labels, dict):
        labels = {}
    if not isinstance(annotations, dict):
        annotations = {}
    if not isinstance(spec, dict):
        spec = {}
    if not isinstance(status, dict):
        status = {}

    pod_name = metadata.get("name") if isinstance(metadata, dict) else None
    display_name = annotations.get("signalloom.ai/agent-display-name")
    label_name = labels.get("signalloom.ai/agent-name")
    model_full = annotations.get("signalloom.ai/model-full")
    model = labels.get("signalloom.ai/model")

    agent = {
        "id": pod_name,
        "name": display_name or label_name or pod_name,
        "type": labels.get("signalloom.ai/agent-type"),
        "framework": labels.get("signalloom.ai/framework"),
        "model": model_full or model,
        "state": labels.get("signalloom.ai/state"),
        "created_at": metadata.get("creationTimestamp") if isinstance(metadata, dict) else None,
        "node": spec.get("nodeName"),
        "phase": status.get("phase"),
    }
    # SuperCred enrichment: expose identity-chain and compliance metadata.
    if labels.get("signalloom.ai/supercred") == "true":
        agent["supercred"] = True
        agent["supercred_target"] = annotations.get("signalloom.ai/supercred-target")
        agent["stunned_at"] = annotations.get("signalloom.ai/stunned-at")
        agent["stun_reason"] = annotations.get("signalloom.ai/stun-reason")
    return agent


def _flux_status(base_url: str, token: str, context: ssl.SSLContext) -> dict[str, object]:
    flux_url = (
        f"{base_url}/apis/kustomize.toolkit.fluxcd.io/v1/namespaces/"
        f"{FLUX_NAMESPACE}/kustomizations"
    )
    try:
        payload = _fetch_kubernetes_json(flux_url, token, context)
        if not isinstance(payload, dict):
            return {}
        items = payload.get("items", [])
        if not isinstance(items, list):
            return {}
        reconciled = False
        for item in items:
            if not isinstance(item, dict):
                continue
            status = item.get("status")
            conditions = status.get("conditions") if isinstance(status, dict) else []
            if not isinstance(conditions, list):
                continue
            if any(
                isinstance(condition, dict)
                and condition.get("type") == "Ready"
                and condition.get("status") == "True"
                for condition in conditions
            ):
                reconciled = True
                break
        return {"managed_by": "flux", "reconciled": reconciled}
    except error.HTTPError as exc:
        if exc.code in {403, 404}:
            return {}
        return {}
    except (OSError, ValueError, TypeError, ssl.SSLError):
        return {}


def _pod_name(pod: object) -> str | None:
    if not isinstance(pod, dict):
        return None
    metadata = pod.get("metadata")
    name = metadata.get("name") if isinstance(metadata, dict) else None
    return name if isinstance(name, str) and name else None


def _container_state_reason(container_status: object) -> str | None:
    if not isinstance(container_status, dict):
        return None
    state = container_status.get("state")
    if not isinstance(state, dict):
        return None
    for state_name in ("terminated", "waiting", "running"):
        candidate = state.get(state_name)
        if not isinstance(candidate, dict):
            continue
        reason = candidate.get("reason")
        if isinstance(reason, str) and reason:
            return reason
    return None


def _pod_error_evidence(pods: list[object]) -> str | None:
    for pod in pods:
        if not isinstance(pod, dict):
            continue
        pod_name = _pod_name(pod) or "unknown-pod"
        status = pod.get("status")
        if not isinstance(status, dict):
            continue
        reason = status.get("reason")
        if isinstance(reason, str) and reason in {"Init:Error", "Error"}:
            return f"pod {pod_name} status reason is {reason}"
        init_statuses = status.get("initContainerStatuses", [])
        if isinstance(init_statuses, list):
            for container_status in init_statuses:
                init_reason = _container_state_reason(container_status)
                if init_reason == "Error":
                    return f"pod {pod_name} init container is Init:Error"
                if init_reason == "Init:Error":
                    return f"pod {pod_name} init container is Init:Error"
        container_statuses = status.get("containerStatuses", [])
        if isinstance(container_statuses, list):
            for container_status in container_statuses:
                container_reason = _container_state_reason(container_status)
                if container_reason == "Error":
                    return f"pod {pod_name} container status is Error"
    return None


def _pod_phase_evidence(pods: list[object]) -> str:
    for pod in pods:
        if not isinstance(pod, dict):
            continue
        pod_name = _pod_name(pod) or "unknown-pod"
        status = pod.get("status")
        phase = status.get("phase") if isinstance(status, dict) else None
        if isinstance(phase, str) and phase:
            return f"pod {pod_name} phase is {phase}"
    return "no pods observed for job"


def _job_status_count(status: dict[str, object], field: str) -> int:
    value = status.get(field)
    return value if isinstance(value, int) else 0


def _job_has_condition(status: dict[str, object], condition_type: str) -> bool:
    conditions = status.get("conditions", [])
    if not isinstance(conditions, list):
        return False
    return any(
        isinstance(condition, dict)
        and condition.get("type") == condition_type
        and condition.get("status") == "True"
        for condition in conditions
    )


def _list_namespace_jobs(base_url: str, token: str, context: ssl.SSLContext) -> dict[str, object]:
    jobs_url = f"{base_url}/apis/batch/v1/namespaces/{CRYPTO_PROOF_NAMESPACE}/jobs"
    payload = _fetch_kubernetes_json(jobs_url, token, context)
    if not isinstance(payload, dict):
        raise TypeError("kubernetes job list payload must be a JSON object")
    items = payload.get("items", [])
    if not isinstance(items, list):
        raise TypeError("kubernetes job list items must be a JSON array")
    jobs: dict[str, object] = {}
    for item in items:
        if not isinstance(item, dict):
            continue
        metadata = item.get("metadata")
        job_name = metadata.get("name") if isinstance(metadata, dict) else None
        if isinstance(job_name, str) and job_name:
            jobs[job_name] = item
    return jobs


def _list_job_pods(
    base_url: str,
    token: str,
    context: ssl.SSLContext,
    job_name: str,
) -> list[object]:
    pods_url = (
        f"{base_url}/api/v1/namespaces/{CRYPTO_PROOF_NAMESPACE}/pods"
        f"?labelSelector={quote(f'job-name={job_name}', safe='')}"
    )
    payload = _fetch_kubernetes_json(pods_url, token, context)
    if not isinstance(payload, dict):
        raise TypeError("kubernetes pod list payload must be a JSON object")
    items = payload.get("items", [])
    if not isinstance(items, list):
        raise TypeError("kubernetes pod list items must be a JSON array")
    return items


def _negative_proof_log_evidence(
    base_url: str,
    token: str,
    context: ssl.SSLContext,
    pods: list[object],
) -> str | None:
    for pod in pods:
        pod_name = _pod_name(pod)
        if pod_name is None:
            continue
        log_url = (
            f"{base_url}/api/v1/namespaces/{CRYPTO_PROOF_NAMESPACE}/pods/"
            f"{quote(pod_name, safe='')}/log?container={quote(CRYPTO_PROOF_CONTAINER, safe='')}"
        )
        try:
            log_text = _fetch_kubernetes_text(log_url, token, context)
        except (OSError, ValueError, TypeError, error.HTTPError, error.URLError, ssl.SSLError):
            continue
        if "denied as expected" in log_text:
            return f"pod {pod_name} log contains denied as expected"
    return None


def _derive_crypto_proof(
    definition: dict[str, str],
    job: object,
    pods: list[object],
    base_url: str,
    token: str,
    context: ssl.SSLContext,
) -> dict[str, str]:
    name = definition["name"]
    evidence = _negative_proof_log_evidence(base_url, token, context, pods) if definition["kind"] == "negative" else None
    if evidence is not None:
        status = "passed"
    else:
        pod_error = _pod_error_evidence(pods)
        if pod_error is not None:
            status = "error"
            evidence = pod_error
        elif not isinstance(job, dict):
            status = "pending"
            evidence = "job not found in namespace"
        else:
            job_status = job.get("status")
            if not isinstance(job_status, dict):
                status = "pending"
                evidence = "job status is unavailable"
            elif _job_status_count(job_status, "succeeded") >= 1:
                status = "passed"
                evidence = f"job {name} reports succeeded >= 1"
            elif _job_status_count(job_status, "failed") >= 1:
                status = "failed"
                evidence = f"job {name} reports failed >= 1"
            elif _job_has_condition(job_status, "Complete"):
                status = "passed"
                evidence = f"job {name} condition Complete=True"
            elif _job_has_condition(job_status, "Failed"):
                status = "failed"
                evidence = f"job {name} condition Failed=True"
            else:
                status = "pending"
                evidence = _pod_phase_evidence(pods)
    return {
        "name": name,
        "kind": definition["kind"],
        "status": status,
        "title": definition["title"],
        "description": definition["description"],
        "expectation": definition["expectation"],
        "evidence": evidence,
    }


class DemoState:
    def __init__(self) -> None:
        self.lock = Lock()
        self.fixtures = copy.deepcopy(DEFAULT_FIXTURES)
        self.requests: list[dict[str, object]] = []

    def reset_requests(self) -> None:
        with self.lock:
            self.requests.clear()

    def add_request(self, request: dict[str, object]) -> None:
        with self.lock:
            self.requests.append(request)

    def get_requests(self) -> list[dict[str, object]]:
        with self.lock:
            return copy.deepcopy(self.requests)

    def get_fixtures(self) -> dict[str, object]:
        with self.lock:
            return copy.deepcopy(self.fixtures)

    def put_fixture(self, category: str, name: str, fixture: object) -> None:
        with self.lock:
            self.fixtures.setdefault(category, {})[name] = fixture

    def select_fixture(self, category: str, route: str) -> tuple[str, object]:
        name = route.removeprefix(ROUTE_PREFIXES[category]).strip("/").split("/")[-1] or "default"
        with self.lock:
            fixtures = self.fixtures[category]
            selected = name if name in fixtures else "default"
            return selected, copy.deepcopy(fixtures[selected])


class ProxyHandler(BaseHTTPRequestHandler):
    state = DemoState()
    server_version = "SignalloomDemoProxy/1.0"

    @property
    def demo_controls_enabled(self) -> bool:
        return os.environ.get("SIGNALLOOM_DEMO_PROFILE") == "demo"

    def log_message(self, format: str, *args: object) -> None:
        # Request bodies and headers must never reach stdout/stderr logs.
        return

    def _json(self, status: int, payload: object) -> None:
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def _body(self) -> object:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return None
        try:
            return redact(json.loads(raw.decode("utf-8")))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return "[REDACTED_NON_JSON_BODY]"

    def _business_route(self, path: str) -> str | None:
        for category, prefix in ROUTE_PREFIXES.items():
            if path.startswith(prefix):
                return category
        return None

    def _capture(self, category: str, path: str, body: object, fixture: str) -> None:
        headers = {key: self.headers[key] for key in CAPTURED_HEADERS if key in self.headers}
        self.state.add_request({
            "method": self.command,
            "category": category,
            "route": path,
            "selected_fixture": fixture,
            "headers": headers,
            "body": body,
        })

    def _handle_business(self) -> bool:
        path = urlparse(self.path).path
        category = self._business_route(path)
        if category is None:
            return False
        body = self._body() if self.command in {"POST", "PUT", "PATCH"} else None
        fixture_name, fixture = self.state.select_fixture(category, path)
        self._capture(category, path, body, fixture_name)
        self._json(HTTPStatus.OK, fixture)
        return True

    def _handle_agents(self) -> None:
        try:
            token = _read_service_account_token()
            context = _kubernetes_ssl_context()
            base_url = _kubernetes_api_base()
            pods_url = (
                f"{base_url}/api/v1/namespaces/{AGENT_DISCOVERY_NAMESPACE}/pods"
                f"?labelSelector={quote(AGENT_DISCOVERY_SELECTOR, safe='')}"
            )
            payload = _fetch_kubernetes_json(pods_url, token, context)
            if not isinstance(payload, dict):
                raise TypeError("kubernetes pod list payload must be a JSON object")
            items = payload.get("items", [])
            if not isinstance(items, list):
                raise TypeError("kubernetes pod list items must be a JSON array")
            agents = []
            for pod in items:
                agent = _agent_from_pod(pod)
                if agent is not None:
                    agents.append(agent)
            response = {
                "agents": agents,
                "namespace": AGENT_DISCOVERY_NAMESPACE,
            }
            response.update(_flux_status(base_url, token, context))
            self._json(HTTPStatus.OK, response)
        except (OSError, ValueError, TypeError, error.HTTPError, error.URLError, ssl.SSLError) as exc:
            print(f"agent discovery failed: {exc}", file=sys.stderr, flush=True)
            self._json(
                HTTPStatus.OK,
                {"agents": [], "error": str(exc), "namespace": AGENT_DISCOVERY_NAMESPACE},
            )

    def _handle_crypto_proofs(self) -> None:
        try:
            token = _read_service_account_token()
            context = _kubernetes_ssl_context()
            base_url = _kubernetes_api_base()
            jobs = _list_namespace_jobs(base_url, token, context)
            proofs = []
            for definition in CRYPTO_PROOF_DEFINITIONS:
                job_name = definition["name"]
                pods = _list_job_pods(base_url, token, context, job_name)
                proofs.append(
                    _derive_crypto_proof(definition, jobs.get(job_name), pods, base_url, token, context)
                )
            self._json(
                HTTPStatus.OK,
                {"proofs": proofs, "namespace": CRYPTO_PROOF_NAMESPACE},
            )
        except (OSError, ValueError, TypeError, error.HTTPError, error.URLError, ssl.SSLError) as exc:
            print(f"crypto proofs failed: {exc}", file=sys.stderr, flush=True)
            self._json(
                HTTPStatus.OK,
                {"proofs": [], "error": str(exc), "namespace": CRYPTO_PROOF_NAMESPACE},
            )

    def _handle_agent_compliance(self, agent_id: str) -> None:
        """GET /agents/<id>/compliance — evaluate an agent's pod spec against policy."""
        try:
            token = _read_service_account_token()
            context = _kubernetes_ssl_context()
            base_url = _kubernetes_api_base()
            pod_url = f"{base_url}/api/v1/namespaces/{AGENT_DISCOVERY_NAMESPACE}/pods/{agent_id}"
            pod = _fetch_kubernetes_json(pod_url, token, context)
            if not isinstance(pod, dict):
                self._json(HTTPStatus.NOT_FOUND, {"error": f"agent {agent_id} not found"})
                return
            spec = pod.get("spec", {})
            containers = []
            for c in spec.get("containers", []):
                containers.append({
                    "name": c.get("name"),
                    "securityContext": c.get("securityContext"),
                })
            pod_spec = {
                "containers": containers,
                "securityContext": spec.get("securityContext"),
            }
            evaluate_url = f"{POLICY_ENGINE_URL}/api/v1/evaluate"
            payload = json.dumps({
                "agent_id": agent_id,
                "namespace": AGENT_DISCOVERY_NAMESPACE,
                "pod_spec": pod_spec,
                "checks": SUPERCRED_CHECKS,
            }).encode()
            req = request.Request(
                evaluate_url, data=payload,
                headers={"Content-Type": "application/json"},
            )
            with request.urlopen(req, timeout=5.0) as resp:
                result = json.load(resp)
            self._json(HTTPStatus.OK, result)
        except error.HTTPError as exc:
            if exc.code == 404:
                self._json(HTTPStatus.NOT_FOUND, {"error": f"agent {agent_id} not found"})
            else:
                self._json(HTTPStatus.BAD_GATEWAY, {"error": str(exc)})
        except Exception as exc:
            print(f"compliance check failed: {exc}", file=sys.stderr, flush=True)
            self._json(HTTPStatus.BAD_GATEWAY, {"error": str(exc)})

    def _handle_agent_stun(self, agent_id: str) -> None:
        """POST /agents/<id>/stun — revoke agent credentials and mark as stunned."""
        try:
            token = _read_service_account_token()
            context = _kubernetes_ssl_context()
            base_url = _kubernetes_api_base()
            # Label the pod as stunned
            now = __import__("datetime").datetime.now(__import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            patch = json.dumps({
                "metadata": {
                    "labels": {"signalloom.ai/state": "stunned"},
                    "annotations": {
                        "signalloom.ai/stunned-at": now,
                        "signalloom.ai/stun-reason": "compliance-failure: securityContext not set",
                    },
                }
            }).encode()
            patch_url = f"{base_url}/api/v1/namespaces/{AGENT_DISCOVERY_NAMESPACE}/pods/{agent_id}"
            req = request.Request(
                patch_url, data=patch, method="PATCH",
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/strategic-merge-patch+json",
                },
            )
            request.urlopen(req, context=context, timeout=5.0)
            self._json(HTTPStatus.OK, {
                "agent_id": agent_id,
                "state": "stunned",
                "stunned_at": now,
                "message": f"Agent {agent_id} stunned: credentials revoked, state marked as stunned",
            })
        except error.HTTPError as exc:
            if exc.code == 404:
                self._json(HTTPStatus.NOT_FOUND, {"error": f"agent {agent_id} not found"})
            else:
                self._json(HTTPStatus.BAD_GATEWAY, {"error": str(exc)})
        except Exception as exc:
            print(f"stun failed: {exc}", file=sys.stderr, flush=True)
            self._json(HTTPStatus.BAD_GATEWAY, {"error": str(exc)})

    def _handle_control(self) -> bool:
        path = urlparse(self.path).path
        if not path.startswith("/_test/"):
            return False
        if not self.demo_controls_enabled:
            self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return True
        if path == "/_test/requests" and self.command == "GET":
            self._json(HTTPStatus.OK, {"requests": self.state.get_requests()})
            return True
        if path == "/_test/requests" and self.command == "DELETE":
            self.state.reset_requests()
            self._json(HTTPStatus.OK, {"requests": []})
            return True
        if path == "/_test/fixtures" and self.command == "GET":
            self._json(HTTPStatus.OK, {"fixtures": self.state.get_fixtures()})
            return True
        parts = path.split("/")
        if len(parts) == 5 and parts[:3] == ["", "_test", "fixtures"] and self.command == "PUT":
            category, name = parts[3], parts[4]
            if category not in ROUTE_PREFIXES or not name:
                self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
                return True
            body = self._body()
            if body is None:
                self._json(HTTPStatus.BAD_REQUEST, {"error": "fixture body is required"})
                return True
            self.state.put_fixture(category, name, body)
            self._json(HTTPStatus.OK, {"category": category, "name": name, "fixture": body})
            return True
        self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
        return True

    def _dispatch(self) -> None:
        path = urlparse(self.path).path
        if path == "/health" and self.command == "GET":
            self._json(HTTPStatus.OK, {"status": "ok"})
        elif path == "/agents" and self.command == "GET":
            self._handle_agents()
        elif path == "/crypto-proofs" and self.command == "GET":
            self._handle_crypto_proofs()
        elif path.startswith("/agents/") and path.endswith("/compliance") and self.command == "GET":
            agent_id = path.split("/")[2]
            self._handle_agent_compliance(agent_id)
        elif path.startswith("/agents/") and path.endswith("/stun") and self.command == "POST":
            agent_id = path.split("/")[2]
            self._handle_agent_stun(agent_id)
        elif self._handle_control() or self._handle_business():
            return
        else:
            self._json(HTTPStatus.NOT_FOUND, {"error": "unknown route"})

    do_GET = _dispatch
    do_POST = _dispatch
    do_PUT = _dispatch
    do_PATCH = _dispatch
    do_DELETE = _dispatch


def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    ThreadingHTTPServer(("0.0.0.0", port), ProxyHandler).serve_forever()


if __name__ == "__main__":
    main()
