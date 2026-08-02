#!/usr/bin/env python3
"""Deterministic, in-memory fake for the Signalloom demo integrations.

This process is intentionally not an integration gateway: it makes no outbound
connections and its mutable state disappears when the pod restarts.
"""

from __future__ import annotations

import copy
import json
import os
import re
import ssl
import sys
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock
from urllib import error, request
from urllib.parse import parse_qs, quote, urlparse


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
# Agent discovery is namespace-plural on purpose. `agents-cardvault.yaml` declares
# `namespace: fe-signalloom-agents`, but the Flux Kustomization's `targetNamespace`
# overrides that and lands the pod in `fe-signalloom` — so the namespace a manifest
# claims is not the namespace the pod ends up in. Searching a configured list keeps
# discovery correct regardless of where Flux places the pod, and makes a future
# namespace move a config change rather than a code change.
#
# The deeper fix would be to stop Flux relocating the pod (drop `targetNamespace`
# from the signalloom-infra ResourceSet so the manifest's own namespace wins).
# Trade-off: that centralises namespace control back into each manifest and would
# undo commit 141a757, which deliberately moved agent namespace + RBAC into the
# ResourceSet so one place governs tenancy. Multi-namespace discovery is resilient
# to either choice; it is deliberately NOT a workaround that blocks the cleanup.
DEFAULT_AGENT_DISCOVERY_NAMESPACES = ("fe-signalloom-agents", "fe-signalloom")
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

# ── Network tests (netassert) ────────────────────────────────────────────────
#
# NETWORK_TEST_DEFINITIONS mirrors d2-signalloom/test/netassert-signalloom.yaml
# 1:1 (kept in sync by hand — the same trade-off already accepted for
# CRYPTO_PROOF_DEFINITIONS above; this process has no YAML dependency). It is
# the catalogue GET /network-tests always returns; live per-test status is
# layered on top from the most recent netassert-run Job's TAP output.
#
# The Job itself runs the real `netassert` CLI (github.com/controlplaneio/
# netassert) via Kubernetes ephemeral containers injected into the ALREADY
# RUNNING src pods, so traffic genuinely originates from those pods' real
# network identity and is subject to the real, unmodified NetworkPolicies —
# this is not a simulation and not a proxy-initiated probe.
NETASSERT_JOB_NAME = "netassert-run"
NETASSERT_JOB_NAMESPACE = "fe-signalloom"
NETASSERT_RUNNER_SERVICE_ACCOUNT = "netassert-runner"
NETASSERT_RUNNER_IMAGE = os.environ.get("NETASSERT_RUNNER_IMAGE", "netassert-runner:local")
NETASSERT_CONFIGMAP_NAME = "netassert-signalloom-config"
NETASSERT_TAP_MARKER = "----NETASSERT-TAP-RESULTS----"

NETWORK_TEST_DEFINITIONS: tuple[dict[str, object], ...] = (
    {"name": "dashboard-to-api-allowed", "expectedExit": 0, "targetPort": 8000,
     "src": {"namespace": "fe-signalloom", "name": "dashboard-signalloom"},
     "dst": {"namespace": "fe-signalloom", "name": "fe-signalloom"},
     "description": "Dashboard to API backend (nginx /api proxy)"},
    {"name": "dashboard-to-dex-allowed", "expectedExit": 0, "targetPort": 5556,
     "src": {"namespace": "fe-signalloom", "name": "dashboard-signalloom"},
     "dst": {"namespace": "inf-signalloom", "name": "dex"},
     "description": "Dashboard to Dex (OIDC discovery/auth/token)"},
    {"name": "api-to-postgresql-allowed", "expectedExit": 0, "targetPort": 5432,
     "src": {"namespace": "fe-signalloom", "name": "fe-signalloom"},
     "dst": {"namespace": "inf-signalloom", "name": "postgresql"},
     "description": "API to PostgreSQL (persistence)"},
    {"name": "api-to-redis-allowed", "expectedExit": 0, "targetPort": 6379,
     "src": {"namespace": "fe-signalloom", "name": "fe-signalloom"},
     "dst": {"namespace": "inf-signalloom", "name": "redis"},
     "description": "API to Redis (cache)"},
    {"name": "api-to-minio-allowed", "expectedExit": 0, "targetPort": 9000,
     "src": {"namespace": "fe-signalloom", "name": "fe-signalloom"},
     "dst": {"namespace": "inf-signalloom", "name": "minio"},
     "description": "API to MinIO (report storage)"},
    {"name": "agents-to-api-denied", "expectedExit": 1, "targetPort": 8000,
     "src": {"namespace": "fe-signalloom-agents", "name": "agent-patsy"},
     "dst": {"namespace": "fe-signalloom", "name": "fe-signalloom"},
     "description": "Agent pods MUST NOT reach the API backend directly"},
    {"name": "agents-to-dashboard-denied", "expectedExit": 1, "targetPort": 8080,
     "src": {"namespace": "fe-signalloom-agents", "name": "agent-patsy"},
     "dst": {"namespace": "fe-signalloom", "name": "dashboard-signalloom"},
     "description": "Agent pods MUST NOT reach the dashboard"},
    {"name": "agents-to-postgresql-denied", "expectedExit": 1, "targetPort": 5432,
     "src": {"namespace": "fe-signalloom-agents", "name": "agent-patsy"},
     "dst": {"namespace": "inf-signalloom", "name": "postgresql"},
     "description": "Agent pods MUST NOT reach PostgreSQL directly"},
    {"name": "dashboard-to-postgresql-denied", "expectedExit": 1, "targetPort": 5432,
     "src": {"namespace": "fe-signalloom", "name": "dashboard-signalloom"},
     "dst": {"namespace": "inf-signalloom", "name": "postgresql"},
     "description": "Dashboard MUST NOT reach PostgreSQL directly (only via API)"},
    {"name": "dashboard-to-redis-denied", "expectedExit": 1, "targetPort": 6379,
     "src": {"namespace": "fe-signalloom", "name": "dashboard-signalloom"},
     "dst": {"namespace": "inf-signalloom", "name": "redis"},
     "description": "Dashboard MUST NOT reach Redis directly"},
)

_TAP_LINE = re.compile(r"^(ok|not ok)\s+\d+\s*-\s*(.+?)\s*$")


def _parse_tap_results(log_text: str) -> dict[str, str]:
    """Map test name -> 'pass'/'fail' from netassert's TAP (-t) output.

    The Job's container prints the TAP file to its own log after
    NETASSERT_TAP_MARKER (see _netassert_job_manifest), so a plain pod-log
    fetch is enough to read results — no artifact store needed. TAP lines look
    like `ok 1 - dashboard-to-api-allowed` / `not ok 2 - some-test`.
    """
    results: dict[str, str] = {}
    marker_seen = False
    for line in log_text.splitlines():
        if NETASSERT_TAP_MARKER in line:
            marker_seen = True
            continue
        if not marker_seen:
            continue
        match = _TAP_LINE.match(line.strip())
        if match is None:
            continue
        outcome, name = match.groups()
        results[name] = "pass" if outcome == "ok" else "fail"
    return results


def _netassert_job_manifest() -> dict[str, object]:
    """The single, fixed netassert-run Job spec.

    Every field here is a constant. Nothing from the triggering HTTP request
    (see _handle_network_tests_scan) reaches this manifest, so the scan
    endpoint can never be turned into an arbitrary-target network probe — it
    only ever runs the committed d2-signalloom/test/netassert-signalloom.yaml
    config, mounted read-only from NETASSERT_CONFIGMAP_NAME.
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


def _patch_kubernetes_json(
    url: str,
    token: str,
    context: ssl.SSLContext,
    patch: dict[str, object],
) -> None:
    req = request.Request(
        url,
        data=json.dumps(patch).encode(),
        method="PATCH",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/strategic-merge-patch+json",
        },
    )
    request.urlopen(req, context=context, timeout=5.0)


def _post_policy_evaluate(url: str, payload: dict[str, object]) -> object:
    req = request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with request.urlopen(req, timeout=5.0) as response:
        return json.load(response)


def _agent_discovery_namespaces() -> list[str]:
    """Namespaces searched for agent pods, in priority order.

    Overridable via AGENT_DISCOVERY_NAMESPACES (comma-separated) so relocating
    the agents is a config change. Duplicates are left in place deliberately —
    `/agents` de-duplicates on (namespace, name), so a repeated entry costs one
    redundant list call rather than producing duplicate agents.
    """
    raw = os.environ.get("AGENT_DISCOVERY_NAMESPACES", "")
    namespaces = [candidate.strip() for candidate in raw.split(",") if candidate.strip()]
    return namespaces or list(DEFAULT_AGENT_DISCOVERY_NAMESPACES)


def _list_agent_pods(
    base_url: str,
    token: str,
    context: ssl.SSLContext,
    namespace: str,
) -> list[object]:
    pods_url = (
        f"{base_url}/api/v1/namespaces/{quote(namespace, safe='')}/pods"
        f"?labelSelector={quote(AGENT_DISCOVERY_SELECTOR, safe='')}"
    )
    payload = _fetch_kubernetes_json(pods_url, token, context)
    if not isinstance(payload, dict):
        raise TypeError("kubernetes pod list payload must be a JSON object")
    items = payload.get("items", [])
    if not isinstance(items, list):
        raise TypeError("kubernetes pod list items must be a JSON array")
    return items


def _resolve_agent_namespace(
    base_url: str,
    token: str,
    context: ssl.SSLContext,
    agent_id: str,
    requested: str | None = None,
) -> tuple[str, dict[str, object]] | None:
    """Find the namespace that actually holds `agent_id`, with its pod.

    `requested` is only honoured when it is one of the configured discovery
    namespaces — an unrecognised hint is ignored rather than trusted, so the
    query parameter cannot be used to read pods outside the demo's own tenancy.

    This allow-list is one of the two things keeping agent discovery from
    becoming a cross-tenant pod reader. The other is RBAC: the proxy's
    ServiceAccount (default/inf-signalloom) holds only a narrow per-namespace
    `agent-inventory-reader` Role — pods, read-only — granted separately for
    fe-signalloom-agents and for the tenant namespace in
    d2-osramp-fleet/tenants/local/signalloom.yaml. Adding a namespace to
    AGENT_DISCOVERY_NAMESPACES without adding its Role yields 403s and a short
    agent list, not wider access; d2-signalloom/test/agent-discovery-rbac.bats
    fails when the two drift apart.
    """
    candidates = _agent_discovery_namespaces()
    if requested and requested in candidates:
        candidates = [requested] + [ns for ns in candidates if ns != requested]
    for namespace in candidates:
        pod_url = (
            f"{base_url}/api/v1/namespaces/{quote(namespace, safe='')}"
            f"/pods/{quote(agent_id, safe='')}"
        )
        try:
            pod = _fetch_kubernetes_json(pod_url, token, context)
        except (OSError, ValueError, TypeError, error.HTTPError, error.URLError, ssl.SSLError):
            continue
        if isinstance(pod, dict):
            return namespace, pod
    return None


def _agent_from_pod(pod: object, namespace: str | None = None) -> dict[str, object] | None:
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

    pod_namespace = metadata.get("namespace") if isinstance(metadata, dict) else None

    agent = {
        "id": pod_name,
        # The pod's own metadata is authoritative; the queried namespace is the
        # fallback for fixtures that omit it.
        "namespace": pod_namespace or namespace,
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


def _list_namespace_jobs(base_url: str, token: str, context: ssl.SSLContext, namespace: str) -> dict[str, object]:
    jobs_url = f"{base_url}/apis/batch/v1/namespaces/{quote(namespace, safe='')}/jobs"
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
    namespace: str,
    job_name: str,
) -> list[object]:
    pods_url = (
        f"{base_url}/api/v1/namespaces/{quote(namespace, safe='')}/pods"
        f"?labelSelector={quote(f'job-name={job_name}', safe='')}"
    )
    payload = _fetch_kubernetes_json(pods_url, token, context)
    if not isinstance(payload, dict):
        raise TypeError("kubernetes pod list payload must be a JSON object")
    items = payload.get("items", [])
    if not isinstance(items, list):
        raise TypeError("kubernetes pod list items must be a JSON array")
    return items


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
        namespaces = _agent_discovery_namespaces()
        # `namespace` is retained for backwards compatibility and reflects the
        # whole configured list; `namespaces` is the structured form.
        legacy_namespace = ",".join(namespaces)
        try:
            token = _read_service_account_token()
            context = _kubernetes_ssl_context()
            base_url = _kubernetes_api_base()
        except (OSError, ValueError, TypeError, ssl.SSLError) as exc:
            print(f"agent discovery failed: {exc}", file=sys.stderr, flush=True)
            self._json(
                HTTPStatus.OK,
                {
                    "agents": [],
                    "error": str(exc),
                    "namespace": legacy_namespace,
                    "namespaces": namespaces,
                },
            )
            return

        agents: list[dict[str, object]] = []
        seen: set[tuple[object, object]] = set()
        namespace_errors: dict[str, str] = {}
        for namespace in namespaces:
            try:
                items = _list_agent_pods(base_url, token, context, namespace)
            except (OSError, ValueError, TypeError, error.HTTPError, error.URLError, ssl.SSLError) as exc:
                # One missing or forbidden namespace must not empty the whole
                # response — the agent may well live in one of the others.
                namespace_errors[namespace] = str(exc)
                print(f"agent discovery failed for {namespace}: {exc}", file=sys.stderr, flush=True)
                continue
            for pod in items:
                agent = _agent_from_pod(pod, namespace)
                if agent is None:
                    continue
                key = (agent.get("namespace"), agent.get("id"))
                if key in seen:
                    continue
                seen.add(key)
                agents.append(agent)

        response: dict[str, object] = {
            "agents": agents,
            "namespace": legacy_namespace,
            "namespaces": namespaces,
        }
        if namespace_errors:
            response["namespace_errors"] = namespace_errors
        if namespace_errors and len(namespace_errors) == len(namespaces):
            response["error"] = "; ".join(
                f"{namespace}: {message}" for namespace, message in namespace_errors.items()
            )
        response.update(_flux_status(base_url, token, context))
        self._json(HTTPStatus.OK, response)

    def _handle_crypto_proofs(self) -> None:
        try:
            token = _read_service_account_token()
            context = _kubernetes_ssl_context()
            base_url = _kubernetes_api_base()
            jobs = _list_namespace_jobs(base_url, token, context, CRYPTO_PROOF_NAMESPACE)
            proofs = []
            for definition in CRYPTO_PROOF_DEFINITIONS:
                job_name = definition["name"]
                pods = _list_job_pods(base_url, token, context, CRYPTO_PROOF_NAMESPACE, job_name)
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

    def _network_scan_status(self, job: object) -> str:
        if not isinstance(job, dict):
            return "never-run"
        status = job.get("status")
        if not isinstance(status, dict):
            return "pending"
        if _job_status_count(status, "active") >= 1:
            return "running"
        if _job_has_condition(status, "Complete"):
            return "complete"
        if _job_has_condition(status, "Failed"):
            return "failed"
        return "pending"

    def _network_test_result(
        self,
        definition: dict[str, object],
        job: object,
        pods: list[object],
        tap_results: dict[str, str],
    ) -> tuple[str, str]:
        name = definition["name"]
        if name in tap_results:
            outcome = tap_results[name]
            tap_line = "ok" if outcome == "pass" else "not ok"
            return outcome, f"netassert TAP: {tap_line} - {name}"
        if not isinstance(job, dict):
            return "pending", "no scan has been run yet"
        pod_error = _pod_error_evidence(pods)
        if pod_error is not None:
            return "error", pod_error
        status = job.get("status")
        if isinstance(status, dict) and _job_status_count(status, "active") >= 1:
            return "running", "scan in progress"
        if isinstance(status, dict) and (
            _job_has_condition(status, "Complete") or _job_has_condition(status, "Failed")
        ):
            return "error", "scan finished but produced no result for this test — check Job logs"
        return "pending", _pod_phase_evidence(pods) if pods else "job not found in namespace"

    def _handle_network_tests(self) -> None:
        """GET /network-tests — live status derived from the most recent
        netassert-run Job (see _netassert_job_manifest) rather than a
        hardcoded fixture. Falls back to 'pending' for every test if no scan
        has run yet, and to an explicit error state if the Kubernetes API is
        unreachable — it never fabricates a pass/fail."""
        try:
            token = _read_service_account_token()
            context = _kubernetes_ssl_context()
            base_url = _kubernetes_api_base()
        except (OSError, ValueError, TypeError, ssl.SSLError) as exc:
            print(f"network tests failed: {exc}", file=sys.stderr, flush=True)
            self._json(
                HTTPStatus.OK,
                {
                    "tests": [
                        {**definition, "result": "error", "evidence": str(exc), "lastRun": None}
                        for definition in NETWORK_TEST_DEFINITIONS
                    ],
                    "scanStatus": "unavailable",
                },
            )
            return

        job = _get_kubernetes_job(base_url, token, context, NETASSERT_JOB_NAMESPACE, NETASSERT_JOB_NAME)
        pods: list[object] = []
        tap_results: dict[str, str] = {}
        last_run: str | None = None
        if job is not None:
            pods = _list_job_pods(base_url, token, context, NETASSERT_JOB_NAMESPACE, NETASSERT_JOB_NAME)
            for pod in pods:
                pod_name = _pod_name(pod)
                if pod_name is None:
                    continue
                log_url = (
                    f"{base_url}/api/v1/namespaces/{quote(NETASSERT_JOB_NAMESPACE, safe='')}"
                    f"/pods/{quote(pod_name, safe='')}/log?container=netassert"
                )
                try:
                    log_text = _fetch_kubernetes_text(log_url, token, context)
                except (OSError, ValueError, TypeError, error.HTTPError, error.URLError, ssl.SSLError):
                    continue
                tap_results.update(_parse_tap_results(log_text))
            status = job.get("status")
            if isinstance(status, dict):
                start_time = status.get("startTime")
                if isinstance(start_time, str):
                    last_run = start_time

        tests = []
        for definition in NETWORK_TEST_DEFINITIONS:
            result, evidence = self._network_test_result(definition, job, pods, tap_results)
            tests.append({**definition, "result": result, "evidence": evidence, "lastRun": last_run})

        self._json(
            HTTPStatus.OK,
            {
                "tests": tests,
                "scanStatus": self._network_scan_status(job),
                "job": {"name": NETASSERT_JOB_NAME} if job is not None else None,
            },
        )

    def _handle_network_tests_scan(self) -> None:
        """POST /network-tests/scan — (re)creates the fixed netassert-run Job.

        The request body is deliberately never inspected: the Job spec is the
        constant returned by _netassert_job_manifest, so this endpoint can
        only ever run the one, committed netassert config — never an
        arbitrary target supplied by a caller.
        """
        self._body()  # drain any body so the client isn't left hanging
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
            # name is fixed by design (see _handle_network_tests's GET-side
            # contract), so a short bounded wait is simpler and safer here
            # than minting per-scan unique names.
            for _ in range(10):
                if _get_kubernetes_job(base_url, token, context, NETASSERT_JOB_NAMESPACE, NETASSERT_JOB_NAME) is None:
                    break
                time.sleep(0.3)

        try:
            _create_kubernetes_job(base_url, token, context, NETASSERT_JOB_NAMESPACE, _netassert_job_manifest())
        except (OSError, ValueError, TypeError, error.HTTPError, error.URLError, ssl.SSLError) as exc:
            print(f"network test scan failed to start: {exc}", file=sys.stderr, flush=True)
            self._json(HTTPStatus.BAD_GATEWAY, {"error": f"failed to start scan: {exc}"})
            return

        self._json(HTTPStatus.ACCEPTED, {"job": NETASSERT_JOB_NAME, "status": "started"})

    def _handle_agent_compliance(self, agent_id: str, requested_namespace: str | None = None) -> None:
        """GET /agents/<id>/compliance — evaluate an agent's pod spec against policy."""
        try:
            token = _read_service_account_token()
            context = _kubernetes_ssl_context()
            base_url = _kubernetes_api_base()
            resolved = _resolve_agent_namespace(
                base_url, token, context, agent_id, requested_namespace
            )
            if resolved is None:
                self._json(
                    HTTPStatus.NOT_FOUND,
                    {
                        "error": f"agent {agent_id} not found",
                        "namespaces": _agent_discovery_namespaces(),
                    },
                )
                return
            namespace, pod = resolved
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
            result = _post_policy_evaluate(evaluate_url, {
                "agent_id": agent_id,
                "namespace": namespace,
                "pod_spec": pod_spec,
                "checks": SUPERCRED_CHECKS,
            })
            self._json(HTTPStatus.OK, result)
        except error.HTTPError as exc:
            if exc.code == 404:
                self._json(HTTPStatus.NOT_FOUND, {"error": f"agent {agent_id} not found"})
            else:
                self._json(HTTPStatus.BAD_GATEWAY, {"error": str(exc)})
        except Exception as exc:
            print(f"compliance check failed: {exc}", file=sys.stderr, flush=True)
            self._json(HTTPStatus.BAD_GATEWAY, {"error": str(exc)})

    def _handle_agent_stun(self, agent_id: str, requested_namespace: str | None = None) -> None:
        """POST /agents/<id>/stun — revoke agent credentials and mark as stunned."""
        try:
            token = _read_service_account_token()
            context = _kubernetes_ssl_context()
            base_url = _kubernetes_api_base()
            resolved = _resolve_agent_namespace(
                base_url, token, context, agent_id, requested_namespace
            )
            if resolved is None:
                self._json(
                    HTTPStatus.NOT_FOUND,
                    {
                        "error": f"agent {agent_id} not found",
                        "namespaces": _agent_discovery_namespaces(),
                    },
                )
                return
            namespace, _pod = resolved
            # Label the pod as stunned
            now = __import__("datetime").datetime.now(__import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            patch = {
                "metadata": {
                    "labels": {"signalloom.ai/state": "stunned"},
                    "annotations": {
                        "signalloom.ai/stunned-at": now,
                        "signalloom.ai/stun-reason": "compliance-failure: securityContext not set",
                    },
                }
            }
            patch_url = (
                f"{base_url}/api/v1/namespaces/{quote(namespace, safe='')}"
                f"/pods/{quote(agent_id, safe='')}"
            )
            _patch_kubernetes_json(patch_url, token, context, patch)
            self._json(HTTPStatus.OK, {
                "agent_id": agent_id,
                "namespace": namespace,
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

    def _requested_namespace(self) -> str | None:
        """Optional ?namespace= disambiguation hint; never required."""
        values = parse_qs(urlparse(self.path).query).get("namespace", [])
        return values[0] if values and values[0] else None

    def _dispatch(self) -> None:
        path = urlparse(self.path).path
        if path == "/health" and self.command == "GET":
            self._json(HTTPStatus.OK, {"status": "ok"})
        elif path == "/agents" and self.command == "GET":
            self._handle_agents()
        elif path == "/crypto-proofs" and self.command == "GET":
            self._handle_crypto_proofs()
        elif path == "/network-tests" and self.command == "GET":
            self._handle_network_tests()
        elif path == "/network-tests/scan" and self.command == "POST":
            self._handle_network_tests_scan()
        elif path.startswith("/agents/") and path.endswith("/compliance") and self.command == "GET":
            agent_id = path.split("/")[2]
            self._handle_agent_compliance(agent_id, self._requested_namespace())
        elif path.startswith("/agents/") and path.endswith("/stun") and self.command == "POST":
            agent_id = path.split("/")[2]
            self._handle_agent_stun(agent_id, self._requested_namespace())
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
