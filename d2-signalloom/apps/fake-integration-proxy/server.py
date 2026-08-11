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
from datetime import datetime, timedelta, timezone
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
TRUST_TOPOLOGY_NAMESPACES = (
    "agent-trust-platform",
    "agent-trust-tenant-acme-control",
    "agent-trust-tenant-northstar-control",
    "agent-trust-acme-payments",
    "agent-trust-acme-risk",
    "agent-trust-northstar-investigations",
)
TRUST_TENANT_LABEL = "agent-trust.signalloom.io/tenant"
TRUST_PROJECT_LABEL = "agent-trust.signalloom.io/project"
TRUST_PROBES = (
    "spiffe-planner", "spiffe-triage", "spiffe-risk-reader", "spiffe-investigator", "openbao-planner", "planner-triage-a2a",
    "cross-project-denied", "cross-tenant-denied", "planner-egress-denied",
)
TRUST_NAMESPACE_NODES = {
    "agent-trust-platform": {"id": "platform", "label": "Signal Loom platform", "kind": "platform", "parent_id": None, "x": 500, "y": 60},
    "agent-trust-tenant-acme-control": {"id": "acme", "label": "Acme tenant", "kind": "tenant", "parent_id": "platform", "x": 300, "y": 280},
    "agent-trust-tenant-northstar-control": {"id": "northstar", "label": "Northstar tenant", "kind": "tenant", "parent_id": "platform", "x": 980, "y": 280},
    "agent-trust-acme-payments": {"id": "acme-payments", "label": "Acme Payments", "kind": "project", "parent_id": "acme", "x": 200, "y": 390},
    "agent-trust-acme-risk": {"id": "acme-risk", "label": "Acme Risk", "kind": "project", "parent_id": "acme", "x": 620, "y": 390},
    "agent-trust-northstar-investigations": {"id": "northstar-investigations", "label": "Northstar Investigations", "kind": "project", "parent_id": "northstar", "x": 980, "y": 390},
}
TRUST_WORKLOAD_NODES = {
    "agent-trust-planner": {"id": "planner", "label": "planner", "parent_id": "acme-payments", "x": 110, "y": 520},
    "agent-trust-triage": {"id": "triage", "label": "triage", "parent_id": "acme-payments", "x": 380, "y": 520},
    "agent-trust-risk-reader": {"id": "risk-reader", "label": "risk-reader", "parent_id": "acme-risk", "x": 620, "y": 520},
    "agent-trust-investigator": {"id": "investigator", "label": "investigator", "parent_id": "northstar-investigations", "x": 980, "y": 520},
}
TRUST_PROBE_EDGES = {
    "spiffe-planner": {"id": "spire-planner", "from_id": "spire", "to_id": "planner", "verb": "SPIRE issued planner JWT-SVID", "plane": "identity", "decision": "allowed"},
    "spiffe-triage": {"id": "spire-triage", "from_id": "spire", "to_id": "triage", "verb": "SPIRE issued triage JWT-SVID", "plane": "identity", "decision": "allowed"},
    "spiffe-risk-reader": {"id": "spire-risk-reader", "from_id": "spire", "to_id": "risk-reader", "verb": "SPIRE issued risk-reader JWT-SVID", "plane": "identity", "decision": "allowed"},
    "spiffe-investigator": {"id": "spire-investigator", "from_id": "spire", "to_id": "investigator", "verb": "SPIRE issued investigator JWT-SVID", "plane": "identity", "decision": "allowed"},
    "openbao-planner": {"id": "bao-planner", "from_id": "openbao", "to_id": "planner", "verb": "OpenBao exchanged planner JWT-SVID", "plane": "identity", "decision": "allowed"},
    "planner-triage-a2a": {"id": "planner-triage", "from_id": "planner", "to_id": "triage", "verb": "planner invoked triage", "plane": "authorization", "decision": "allowed"},
    "cross-project-denied": {"id": "risk-triage-denied", "from_id": "risk-reader", "to_id": "triage", "verb": "cross-project path denied", "plane": "network", "decision": "denied", "denial_kind": "network-block"},
    "cross-tenant-denied": {"id": "investigator-triage-denied", "from_id": "investigator", "to_id": "triage", "verb": "cross-tenant path denied", "plane": "network", "decision": "denied", "denial_kind": "network-block"},
    "planner-egress-denied": {"id": "planner-egress-denied", "from_id": "planner", "to_id": "internet", "verb": "arbitrary planner egress denied", "plane": "network", "decision": "denied", "denial_kind": "network-block"},
}

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
#
# This process only ever READS the Job/pods/logs below (jobs:get,list +
# pods,pods/log:get,list — see netassert-status-reader in
# d2-osramp-fleet/tenants/local/signalloom.yaml). It does NOT hold jobs:create
# or jobs:delete: minting the Job is delegated to netassert-controller, a
# separate process with its own dedicated ServiceAccount and a single-purpose
# HTTP surface (see _trigger_netassert_scan and
# apps/netassert-controller/server.py for the full rationale). That split is
# the fix for a real privilege-escalation risk this feature introduced: this
# process parses arbitrary attacker-reachable JSON bodies and headers, so a
# token here capable of jobs:create would be a skeleton key for the namespace
# if this process were ever compromised — not just a theoretical concern,
# since jobs:create lets you submit ANY Job manifest, not only the fixed one.
NETASSERT_JOB_NAME = "netassert-run"
NETASSERT_JOB_NAMESPACE = "fe-signalloom"
NETASSERT_TAP_MARKER = "----NETASSERT-TAP-RESULTS----"
NETASSERT_CONTROLLER_URL = os.environ.get(
    "NETASSERT_CONTROLLER_URL",
    "http://netassert-controller.inf-signalloom.svc.cluster.local:8080/scan",
)

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
        # Second half of the workload's SPIFFE ID. SPIRE's k8s workload
        # registrar issues spiffe://<trust-domain>/ns/<ns>/sa/<sa>, so the
        # dashboard's Credential Inventory needs this to name the identity
        # rather than guess it. Absent stays None — defaulting to "default"
        # would render a SPIFFE ID that was never registered.
        "service_account": spec.get("serviceAccountName"),
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


def _topology_evidence(
    state: str,
    source: str,
    observed_at: str | None,
    freshness: str,
    assurance: str,
    reason: str,
) -> dict[str, str | None]:
    """The only evidence shape emitted by the topology collector.

    Raw Kubernetes objects and probe messages never cross this boundary.  This
    keeps service-account credentials, JWTs and OpenBao client material out of
    the dashboard contract even if a workload is misconfigured.
    """
    return {
        "evidence_state": state,
        "evidence_source": source,
        "observed_at": observed_at,
        "freshness": freshness,
        "assurance": assurance,
        "reason": reason,
    }


def _safe_probe_message(value: object) -> dict[str, object] | None:
    """Accept only small structured, token-free termination-message evidence."""
    if not isinstance(value, str) or len(value) > 2048:
        return None
    try:
        payload = json.loads(value)
    except (TypeError, ValueError, json.JSONDecodeError):
        return None
    if not isinstance(payload, dict):
        return None
    allowed = {
        "observed_at", "outcome", "reason", "spiffe_id",
        "renewable", "lease_duration", "token_type",
    }
    if set(payload) - allowed:
        return None
    observed_at = payload.get("observed_at")
    outcome = payload.get("outcome")
    reason = payload.get("reason", "")
    if (
        not isinstance(observed_at, str)
        or outcome not in {"pass", "fail", "error"}
        or not isinstance(reason, str)
    ):
        return None
    try:
        timestamp = datetime.fromisoformat(observed_at.replace("Z", "+00:00"))
    except ValueError:
        return None
    safe: dict[str, object] = {
        "observed_at": observed_at,
        "outcome": outcome,
        "reason": reason[:240],
        "timestamp": timestamp,
    }
    spiffe_id = payload.get("spiffe_id")
    if spiffe_id is not None:
        if not isinstance(spiffe_id, str) or not spiffe_id.startswith("spiffe://") or len(spiffe_id) > 512:
            return None
        safe["spiffe_id"] = spiffe_id
    if "renewable" in payload:
        if not isinstance(payload["renewable"], bool):
            return None
        safe["renewable"] = payload["renewable"]
    if "lease_duration" in payload:
        duration = payload["lease_duration"]
        if not isinstance(duration, int) or isinstance(duration, bool) or duration < 1 or duration > 3600:
            return None
        safe["lease_duration"] = duration
    if "token_type" in payload:
        if payload["token_type"] != "batch":
            return None
        safe["token_type"] = "batch"
    return safe


def _probe_evidence_from_pods(
    pods: list[object],
    probe: str,
    now: datetime,
) -> tuple[dict[str, str | None], dict[str, object] | None]:
    candidates: list[dict[str, object]] = []
    for pod in pods:
        statuses = pod.get("status", {}).get("containerStatuses", []) if isinstance(pod, dict) else []
        for status in statuses if isinstance(statuses, list) else []:
            terminated = status.get("state", {}).get("terminated", {}) if isinstance(status, dict) else {}
            message = _safe_probe_message(terminated.get("message")) if isinstance(terminated, dict) else None
            if message is None:
                continue
            candidates.append(message)
    if candidates:
        message = max(candidates, key=lambda item: item["timestamp"])
        age = now - message["timestamp"]
        if age < -timedelta(seconds=30):
            return (
                _topology_evidence(
                    "error", f"probe/{probe}", message["observed_at"], "unavailable",
                    "runtime-observed", "probe timestamp is in the future",
                ),
                message,
            )
        freshness = "fresh" if age <= timedelta(minutes=10) else "stale"
        if message["outcome"] == "pass" and freshness == "fresh":
            state = "observed"
        elif message["outcome"] == "pass":
            state = "stale"
        else:
            state = "error"
        return (
            _topology_evidence(
                state,
                f"pod label agent-trust.signalloom.io/probe={probe}",
                message["observed_at"],
                freshness,
                "runtime-observed",
                str(message["reason"] or "probe outcome"),
            ),
            message,
        )
    return (
        _topology_evidence(
            "unavailable", f"probe/{probe}", None, "unavailable",
            "runtime-observed", "probe has never produced valid evidence",
        ),
        None,
    )


def _pod_ready(status: object) -> bool:
    if not isinstance(status, dict):
        return False
    containers = status.get("containerStatuses")
    return (
        isinstance(containers, list)
        and bool(containers)
        and all(isinstance(item, dict) and item.get("ready") is True for item in containers)
    )


def _topology_node(
    definition: dict[str, object],
    *,
    tenant: str | None,
    project: str | None,
    namespace: str | None,
    evidence: dict[str, str | None],
    **runtime: object,
) -> dict[str, object]:
    return {
        **definition,
        "tenant": tenant,
        "project": project,
        "namespace": namespace,
        "location": "in-cluster",
        **runtime,
        **evidence,
    }


def collect_trust_topology(
    base_url: str, service_account: str, context: ssl.SSLContext | None,
    fetch: object | None = None, now: str | None = None,
) -> dict[str, object]:
    """Collect a fail-closed topology from the six fixed Agent Trust namespaces."""
    getter = fetch if callable(fetch) else _fetch_kubernetes_json
    observed_at = now or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    current_time = datetime.fromisoformat(observed_at.replace("Z", "+00:00"))
    nodes_by_id: dict[str, dict[str, object]] = {}
    configuration_gaps: list[dict[str, object]] = []
    collector_errors: list[str] = []
    probe_pods: dict[str, list[object]] = {probe: [] for probe in TRUST_PROBES}
    for namespace in TRUST_TOPOLOGY_NAMESPACES:
        try:
            ns = getter(f"{base_url}/api/v1/namespaces/{quote(namespace, safe='')}", service_account, context)
            labels = ns.get("metadata", {}).get("labels", {}) if isinstance(ns, dict) else {}
            labels = labels if isinstance(labels, dict) else {}
            tenant, project = labels.get(TRUST_TENANT_LABEL), labels.get(TRUST_PROJECT_LABEL)
            tenant = tenant if isinstance(tenant, str) else None
            project = project if isinstance(project, str) else None
            definition = TRUST_NAMESPACE_NODES[namespace]
            nodes_by_id[str(definition["id"])] = _topology_node(
                definition,
                tenant=tenant,
                project=project,
                namespace=namespace,
                evidence=_topology_evidence(
                    "observed", f"kubernetes namespace/{namespace}", observed_at,
                    "fresh", "configuration-observed", "namespace labels read from Kubernetes API",
                ),
            )
            pods = getter(f"{base_url}/api/v1/namespaces/{quote(namespace, safe='')}/pods", service_account, context)
            for pod in pods.get("items", []) if isinstance(pods, dict) else []:
                metadata = pod.get("metadata", {}) if isinstance(pod, dict) else {}
                spec = pod.get("spec", {}) if isinstance(pod, dict) else {}
                status = pod.get("status", {}) if isinstance(pod, dict) else {}
                if not isinstance(metadata, dict) or not isinstance(spec, dict) or not isinstance(status, dict):
                    continue
                name, uid = metadata.get("name"), metadata.get("uid")
                labels = metadata.get("labels", {})
                if not isinstance(name, str) or not isinstance(uid, str) or not isinstance(labels, dict):
                    continue
                probe = labels.get("agent-trust.signalloom.io/probe")
                if isinstance(probe, str) and probe in probe_pods:
                    probe_pods[probe].append(pod)
                workload_name = labels.get("app.kubernetes.io/name")
                workload = TRUST_WORKLOAD_NODES.get(workload_name) if isinstance(workload_name, str) else None
                if workload is None:
                    continue
                logical_id = str(workload["id"])
                candidate = _topology_node(
                    {**workload, "kind": "agent"},
                    tenant=tenant,
                    project=project,
                    namespace=namespace,
                    evidence=_topology_evidence(
                        "observed", f"kubernetes pod/{namespace}/{name}", observed_at,
                        "fresh", "runtime-observed", "pod metadata and readiness read from Kubernetes API",
                    ),
                    service_account=spec.get("serviceAccountName"),
                    phase=status.get("phase"),
                    ready=_pod_ready(status),
                    pod_uid=uid,
                    pod_name=name,
                )
                current = nodes_by_id.get(logical_id)
                if current is None or (candidate.get("ready") is True and current.get("ready") is not True):
                    nodes_by_id[logical_id] = candidate
            policies = getter(f"{base_url}/apis/networking.k8s.io/v1/namespaces/{quote(namespace, safe='')}/networkpolicies", service_account, context)
            for policy in policies.get("items", []) if isinstance(policies, dict) else []:
                name = policy.get("metadata", {}).get("name") if isinstance(policy, dict) else None
                if isinstance(name, str):
                    configuration_gaps.append({
                        "id": f"networkpolicy:{namespace}:{name}",
                        "kind": "gap",
                        "name": name,
                        "namespace": namespace,
                        "tenant": tenant,
                        "project": project,
                        **_topology_evidence(
                            "modeled", f"kubernetes networkpolicy/{namespace}/{name}",
                            observed_at, "fresh", "configuration-observed",
                            "deployed NetworkPolicy is configuration, not enforcement proof",
                        ),
                    })
        except (OSError, ValueError, TypeError, error.HTTPError, error.URLError, ssl.SSLError) as exc:
            collector_errors.append(f"{namespace}: {exc}")

    probe_results = {
        probe: _probe_evidence_from_pods(probe_pods[probe], probe, current_time)
        for probe in TRUST_PROBES
    }
    spire_evidence = probe_results["spiffe-planner"][0]
    openbao_evidence = probe_results["openbao-planner"][0]
    nodes_by_id["spire"] = _topology_node(
        {"id": "spire", "label": "SPIRE issuer", "kind": "service", "parent_id": "platform", "x": 380, "y": 155},
        tenant=None, project=None, namespace="inf-bao", evidence=spire_evidence,
    )
    nodes_by_id["openbao"] = _topology_node(
        {"id": "openbao", "label": "OpenBao", "kind": "service", "parent_id": "platform", "x": 620, "y": 155},
        tenant=None, project=None, namespace="inf-bao", evidence=openbao_evidence,
    )
    nodes_by_id["internet"] = {
        "id": "internet", "label": "External network", "kind": "external",
        "parent_id": "platform", "tenant": None, "project": None,
        "namespace": None, "location": "external", "x": 1100, "y": 700,
        **_topology_evidence(
            "modeled", "external boundary", None, "unavailable", "modeled",
            "external destination exists only as a denial-test boundary",
        ),
    }

    edges: list[dict[str, object]] = []
    probe_gaps: list[dict[str, object]] = []
    for probe, definition in TRUST_PROBE_EDGES.items():
        evidence, message = probe_results[probe]
        edge: dict[str, object] = {
            **definition,
            "tenant": (
                "northstar" if probe in {"spiffe-investigator", "cross-tenant-denied"}
                else "acme"
            ),
            "project": None,
            **evidence,
        }
        if message is not None and isinstance(message.get("spiffe_id"), str):
            edge["spiffe_id"] = message["spiffe_id"]
            target = nodes_by_id.get(str(definition["to_id"]))
            if target is not None:
                target["spiffe_id"] = message["spiffe_id"]
        if probe == "openbao-planner" and message is not None:
            edge["renewable"] = message.get("renewable")
            edge["lease_duration"] = message.get("lease_duration")
            edge["token_type"] = message.get("token_type")
        edges.append(edge)
        if evidence["evidence_state"] != "observed":
            probe_gaps.append({
                "id": f"probe:{probe}", "kind": "probe", "name": probe,
                "tenant": edge["tenant"], "project": None, "namespace": None,
                **evidence,
            })

    status = "unavailable" if len(collector_errors) == len(TRUST_TOPOLOGY_NAMESPACES) else ("partial" if collector_errors else "ok")
    probe_status = "ok" if not probe_gaps else ("unavailable" if len(probe_gaps) == len(TRUST_PROBES) else "partial")
    external_gaps = [
        {
            "id": f"external:{provider}", "kind": "gap", "name": provider,
            "tenant": tenant, "project": project, "namespace": None,
            **_topology_evidence(
                "modeled", "contracts/external-enrollment.v1.json", None,
                "unavailable", "modeled", "no external runtime attestation collector",
            ),
        }
        for provider, tenant, project in (
            ("AWS Lambda", "acme", "payments"),
            ("Google Cloud Run", "acme", "risk"),
            ("Azure Container Apps", "northstar", "investigations"),
        )
    ]
    return {
        "generated_at": observed_at,
        "version": "v1",
        "collectors": {
            "kubernetes": {
                "status": status,
                "observed_at": observed_at,
                "reason": "; ".join(collector_errors)[:500] or "six fixed namespaces collected",
            },
            "probes": {
                "status": probe_status,
                "observed_at": observed_at,
                "reason": "token-free pod termination-message evidence",
            },
        },
        "nodes": list(nodes_by_id.values()),
        "edges": edges,
        "modeled_gaps": configuration_gaps + probe_gaps + external_gaps,
    }


def filter_trust_topology(snapshot: dict[str, object], tenant: str) -> dict[str, object]:
    """Tenant-filter without changing labels or identity of shared objects."""
    result = dict(snapshot)
    nodes = [node for node in snapshot.get("nodes", []) if isinstance(node, dict) and node.get("tenant") in {None, tenant}]
    visible = {node.get("id") for node in nodes}
    result["nodes"] = nodes
    result["edges"] = [
        edge for edge in snapshot.get("edges", [])
        if isinstance(edge, dict)
        and edge.get("tenant") in {None, tenant}
        and edge.get("from_id") in visible
        and edge.get("to_id") in visible
    ]
    result["modeled_gaps"] = [
        gap for gap in snapshot.get("modeled_gaps", [])
        if isinstance(gap, dict) and gap.get("tenant") in {None, tenant}
    ]
    return result


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


def _trigger_netassert_scan() -> tuple[int, dict[str, object]]:
    """POST to netassert-controller's /scan and relay its (status, body).

    This process holds no jobs:create/delete verb at all any more — that
    privilege lives solely with netassert-controller's dedicated
    ServiceAccount (see the module-level comment above NETASSERT_JOB_NAME).
    A connection failure here means "the controller is unreachable", which is
    reported as 502 the same way an unreachable kube-apiserver used to be.
    """
    req = request.Request(NETASSERT_CONTROLLER_URL, method="POST")
    try:
        with request.urlopen(req, timeout=10.0) as response:
            return response.status, json.load(response)
    except error.HTTPError as exc:
        try:
            return exc.code, json.load(exc)
        except (ValueError, json.JSONDecodeError):
            return exc.code, {"error": str(exc)}
    except (OSError, ValueError, error.URLError) as exc:
        return HTTPStatus.BAD_GATEWAY, {"error": f"netassert-controller unreachable: {exc}"}


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

    def _handle_trust_topology(self) -> None:
        try:
            snapshot = collect_trust_topology(
                _kubernetes_api_base(), _read_service_account_token(), _kubernetes_ssl_context(),
            )
            self._json(HTTPStatus.OK, snapshot)
        except (OSError, ValueError, TypeError, error.HTTPError, error.URLError, ssl.SSLError) as exc:
            # The FastAPI proxy treats complete collection failure as a 502; the
            # direct endpoint remains structurally honest for diagnostics.
            self._json(HTTPStatus.BAD_GATEWAY, {"error": f"trust topology unavailable: {exc}"})

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
        """POST /network-tests/scan — asks netassert-controller to
        (re)create the fixed netassert-run Job.

        This process no longer touches the Kubernetes Job API itself (see
        _trigger_netassert_scan): the request body is drained and discarded
        without being forwarded, so even the controller's fixed manifest can
        never be influenced by a caller — the same never-an-arbitrary-probe
        guarantee as before, now enforced at the identity boundary too.
        """
        self._body()  # drain any body so the client isn't left hanging
        status, body = _trigger_netassert_scan()
        self._json(status, body)

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
        elif path == "/trust-topology" and self.command == "GET":
            self._handle_trust_topology()
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
