import json
from urllib.parse import urlparse

import server


NOW = "2026-08-11T16:10:00Z"


def workload_pod(name, namespace, service_account, *, ready=True):
    return {
        "metadata": {
            "name": f"{name}-abcde",
            "namespace": namespace,
            "uid": f"uid-{name}",
            "labels": {"app.kubernetes.io/name": name},
        },
        "spec": {"serviceAccountName": service_account, "nodeName": "kind"},
        "status": {
            "phase": "Running",
            "containerStatuses": [{"name": name, "ready": ready}],
        },
    }


def probe_pod(probe, message):
    return {
        "metadata": {
            "name": f"{probe}-291234-abcd",
            "namespace": "agent-trust-acme-payments",
            "uid": f"uid-{probe}",
            "labels": {"agent-trust.signalloom.io/probe": probe},
        },
        "spec": {"serviceAccountName": "agent-trust-planner"},
        "status": {
            "phase": "Succeeded",
            "containerStatuses": [{
                "name": "probe",
                "ready": False,
                "state": {"terminated": {"exitCode": 0, "message": json.dumps(message)}},
            }],
        },
    }


def namespace_labels(namespace):
    mapping = {
        "agent-trust-platform": {},
        "agent-trust-tenant-acme-control": {"agent-trust.signalloom.io/tenant": "acme"},
        "agent-trust-tenant-northstar-control": {"agent-trust.signalloom.io/tenant": "northstar"},
        "agent-trust-acme-payments": {"agent-trust.signalloom.io/tenant": "acme", "agent-trust.signalloom.io/project": "payments"},
        "agent-trust-acme-risk": {"agent-trust.signalloom.io/tenant": "acme", "agent-trust.signalloom.io/project": "risk"},
        "agent-trust-northstar-investigations": {"agent-trust.signalloom.io/tenant": "northstar", "agent-trust.signalloom.io/project": "investigations"},
    }
    return mapping[namespace]


def successful_fetch(url, *_args):
    parsed = urlparse(url)
    parts = parsed.path.split("/")
    namespace = parts[parts.index("namespaces") + 1]
    if parsed.path.startswith("/api/v1/namespaces/") and parsed.path.endswith(f"/{namespace}"):
        return {"metadata": {"labels": namespace_labels(namespace)}}
    if parsed.path.endswith("/networkpolicies"):
        policies = []
        if namespace == "agent-trust-acme-payments":
            policies = [{"metadata": {"name": "allow-planner-to-triage"}}]
        return {"items": policies}
    if parsed.path.endswith("/pods"):
        pods = []
        if namespace == "agent-trust-acme-payments":
            pods.extend([
                workload_pod("agent-trust-planner", namespace, "agent-trust-planner"),
                workload_pod("agent-trust-triage", namespace, "agent-trust-triage"),
            ])
        if namespace == "agent-trust-acme-risk":
            pods.append(workload_pod("agent-trust-risk-reader", namespace, "agent-trust-risk-reader"))
        if namespace == "agent-trust-northstar-investigations":
            pods.append(workload_pod("agent-trust-investigator", namespace, "agent-trust-investigator"))
        for probe in server.TRUST_PROBES:
            probe_namespace = (
                "agent-trust-acme-risk" if probe in {"spiffe-risk-reader", "cross-project-denied"}
                else "agent-trust-northstar-investigations" if probe in {"spiffe-investigator", "cross-tenant-denied"}
                else "agent-trust-acme-payments"
            )
            if namespace != probe_namespace:
                continue
            message = {
                "observed_at": "2026-08-11T16:09:00Z",
                "outcome": "pass",
                "reason": f"{probe} passed",
            }
            if probe.startswith("spiffe-") or probe == "openbao-planner":
                subject = probe.removeprefix("spiffe-").replace("-reader", "-reader")
                message["spiffe_id"] = f"spiffe://signalloom.demo/{subject}"
            if probe == "openbao-planner":
                message.update({"renewable": False, "lease_duration": 300, "token_type": "batch"})
            pods.append(probe_pod(probe, message))
        return {"items": pods}
    raise AssertionError(f"unexpected Kubernetes URL: {url}")


def test_collect_topology_builds_integral_runtime_graph_from_live_sources():
    snapshot = server.collect_trust_topology(
        "https://kubernetes.test", "service-account", None,
        fetch=successful_fetch, now=NOW,
    )

    assert snapshot["version"] == "v1"
    nodes = {node["id"]: node for node in snapshot["nodes"]}
    assert nodes["planner"]["service_account"] == "agent-trust-planner"
    assert nodes["planner"]["ready"] is True
    assert nodes["planner"]["tenant"] == "acme"
    assert nodes["planner"]["evidence_state"] == "observed"
    assert nodes["planner"]["spiffe_id"].startswith("spiffe://")
    assert {"platform", "acme", "northstar", "spire", "openbao", "internet"} <= set(nodes)

    edges = {edge["id"]: edge for edge in snapshot["edges"]}
    assert edges["planner-triage"]["evidence_state"] == "observed"
    assert edges["risk-triage-denied"]["decision"] == "denied"
    assert edges["bao-planner"]["lease_duration"] == 300
    assert edges["bao-planner"]["renewable"] is False
    assert edges["bao-planner"]["token_type"] == "batch"
    assert all(edge["from_id"] in nodes and edge["to_id"] in nodes for edge in edges.values())

    policy = next(gap for gap in snapshot["modeled_gaps"] if gap["id"].startswith("networkpolicy:"))
    assert policy["evidence_state"] == "modeled"
    assert policy["assurance"] == "configuration-observed"
    rendered = json.dumps(snapshot).lower()
    assert "client_token" not in rendered
    assert "bearer" not in rendered


def test_probe_evidence_uses_newest_valid_result_then_becomes_stale():
    old = probe_pod("planner-triage-a2a", {
        "observed_at": "2026-08-11T15:00:00Z", "outcome": "pass", "reason": "old",
    })
    fresh = probe_pod("planner-triage-a2a", {
        "observed_at": "2026-08-11T16:09:00Z", "outcome": "pass", "reason": "fresh",
    })
    evidence, _ = server._probe_evidence_from_pods([old, fresh], "planner-triage-a2a", server.datetime.fromisoformat("2026-08-11T16:10:00+00:00"))
    assert evidence["evidence_state"] == "observed"
    assert evidence["reason"] == "fresh"

    stale, _ = server._probe_evidence_from_pods([fresh], "planner-triage-a2a", server.datetime.fromisoformat("2026-08-11T16:30:00+00:00"))
    assert stale["evidence_state"] == "stale"
    assert stale["freshness"] == "stale"


def test_probe_message_rejects_unknown_or_secret_fields():
    assert server._safe_probe_message(json.dumps({
        "observed_at": NOW, "outcome": "pass", "reason": "ok", "client_token": "secret",
    })) is None
    assert server._safe_probe_message(json.dumps({
        "observed_at": NOW, "outcome": "pass", "reason": "ok", "token_type": "service",
    })) is None


def test_missing_probes_remain_unavailable_without_fixture_fallback():
    snapshot = server.collect_trust_topology(
        "https://kubernetes.test", "service-account", None,
        fetch=lambda url, *_args: (
            {"metadata": {"labels": namespace_labels(urlparse(url).path.split("/")[-1])}}
            if "/api/v1/namespaces/" in url and not url.endswith("/pods")
            else {"items": []}
        ),
        now=NOW,
    )
    probe_gaps = [gap for gap in snapshot["modeled_gaps"] if gap["kind"] == "probe"]
    assert len(probe_gaps) == len(server.TRUST_PROBES)
    assert all(gap["evidence_state"] == "unavailable" for gap in probe_gaps)
    assert not any(edge["evidence_state"] == "observed" for edge in snapshot["edges"])


def test_tenant_filter_preserves_shared_nodes_without_relabeling():
    snapshot = server.collect_trust_topology(
        "https://kubernetes.test", "service-account", None,
        fetch=successful_fetch, now=NOW,
    )
    filtered = server.filter_trust_topology(snapshot, "acme")
    assert all(node["tenant"] in {None, "acme"} for node in filtered["nodes"])
    assert not any(node["tenant"] == "northstar" for node in filtered["nodes"])
    visible = {node["id"] for node in filtered["nodes"]}
    assert all(edge["from_id"] in visible and edge["to_id"] in visible for edge in filtered["edges"])
