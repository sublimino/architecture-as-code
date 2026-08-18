import json
import unittest
from urllib import error
from urllib.parse import urlparse

import server


NOW = "2026-08-11T16:10:00Z"


def load_tests(loader, tests, pattern):
    """Make `unittest discover` see the plain functions in this module.

    Not cosmetic. The sanctioned suite is `python3 -m unittest discover -s test`
    (see the Makefile), and unittest collects TestCase subclasses only -- so
    every test in this file, all 184 lines of them, was silently absent from
    every run of `make test` since the file was written. Not failing: never
    executed, and never counted, so the suite reported OK across a collector
    whose error path had no coverage whatsoever.

    That is the same shape as this repo's known Playwright hazard, where a spec
    matching no project is skipped with exit 0 and no warning. A test that is
    not run is indistinguishable from a test that passes, right up until it
    matters.

    The load_tests protocol is the surgical fix: it keeps the readable
    function-per-behaviour style and pytest compatibility, and adds no
    dependency the CI VM might not have.
    """
    suite = unittest.TestSuite(tests)
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            suite.addTest(unittest.FunctionTestCase(value, description=name))
    return suite


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


# --- collector failure diagnosis -------------------------------------------
#
# Everything above this line injects a fetch that SUCCEEDS. The collector's
# error path -- the one the demo actually ran in for its entire life, because
# the Agent Trust slice was never deployed by the standard bring-up -- had no
# test at all, so `collector_errors.append(f"{namespace}: {exc}")` was free to
# emit the raw urllib string and the panel printed it verbatim:
#
#   kubernetes collector unavailable: agent-trust-platform: HTTP Error 403: Forbidden; ...
#
# which reads as "RBAC refused me" when the truth was "there is nothing here".
# Kubernetes answers 403 rather than 404 for an object the caller may not read,
# specifically so a denial cannot be used to probe existence -- so the raw code
# is genuinely ambiguous and must not be rendered as a verdict.


def _http_error(url, code, reason):
    return error.HTTPError(url, code, reason, {}, None)


def _raise(exc):
    raise exc


def test_absent_namespace_is_diagnosed_as_absent_not_as_a_denial():
    """404 is unambiguous: the object is gone. Never call that a denial."""

    def fetch(url, *args):
        if url.endswith("/agent-trust-acme-risk"):
            raise _http_error(url, 404, "Not Found")
        return successful_fetch(url, *args)

    snapshot = server.collect_trust_topology(
        "https://kubernetes.test", "service-account", None,
        fetch=fetch, review=lambda **_kwargs: None, now=NOW,
    )
    collector = snapshot["collectors"]["kubernetes"]
    assert collector["status"] == "partial"
    assert "agent-trust-acme-risk: namespace does not exist" in collector["reason"]
    assert "Forbidden" not in collector["reason"]
    assert "denied" not in collector["reason"]


def test_uniform_forbidden_with_no_grant_is_reported_as_an_undeployed_slice():
    """The exact production symptom: 403 on all six, and the collector holds no
    grant because the grant ships with the slice that is not there."""
    snapshot = server.collect_trust_topology(
        "https://kubernetes.test", "service-account", None,
        fetch=lambda url, *_args: _raise(_http_error(url, 403, "Forbidden")),
        review=lambda **_kwargs: False, now=NOW,
    )
    collector = snapshot["collectors"]["kubernetes"]
    assert collector["status"] == "unavailable"
    reason = collector["reason"]
    assert "HTTP Error 403" not in reason
    # It must not assert existence it cannot observe, and must not assert a
    # denial of something that may simply be absent.
    assert "not disclose" in reason
    assert "not deployed" in reason
    # One sentence about six identical failures, not six repetitions.
    assert reason.count("agent-trust-platform") <= 1


def test_forbidden_that_is_genuinely_authorized_elsewhere_is_still_a_denial():
    """Namespace readable, pods refused: existence is observed, so the 403 is a
    real permission denial inside a namespace that demonstrably exists."""

    def fetch(url, *args):
        if url.endswith("/pods") and "agent-trust-acme-risk" in url:
            raise _http_error(url, 403, "Forbidden")
        return successful_fetch(url, *args)

    snapshot = server.collect_trust_topology(
        "https://kubernetes.test", "service-account", None,
        fetch=fetch, review=lambda **_kwargs: False, now=NOW,
    )
    reason = snapshot["collectors"]["kubernetes"]["reason"]
    assert "agent-trust-acme-risk" in reason
    assert "namespace exists" in reason
    assert "permission denied" in reason


def test_forbidden_with_an_unusable_access_review_stays_undetermined():
    """A review that could not be performed proves nothing. Say so; do not
    guess in either direction."""
    snapshot = server.collect_trust_topology(
        "https://kubernetes.test", "service-account", None,
        fetch=lambda url, *_args: _raise(_http_error(url, 403, "Forbidden")),
        review=lambda **_kwargs: None, now=NOW,
    )
    reason = snapshot["collectors"]["kubernetes"]["reason"]
    assert "undetermined" in reason
    assert "not deployed" not in reason


def test_transport_failure_is_not_dressed_up_as_an_authorization_verdict():
    snapshot = server.collect_trust_topology(
        "https://kubernetes.test", "service-account", None,
        fetch=lambda url, *_args: _raise(error.URLError("connection refused")),
        review=lambda **_kwargs: False, now=NOW,
    )
    reason = snapshot["collectors"]["kubernetes"]["reason"]
    assert "unreachable" in reason
    assert "permission denied" not in reason
    assert "not deployed" not in reason


def test_access_review_asks_about_the_object_that_was_actually_refused():
    """The review has to name the cluster-scoped namespace object by name --
    reviewing the wrong attributes returns an answer about something else and
    would be worse than not reviewing at all."""
    asked = []

    server.collect_trust_topology(
        "https://kubernetes.test", "service-account", None,
        fetch=lambda url, *_args: _raise(_http_error(url, 403, "Forbidden")),
        review=lambda **kwargs: (asked.append(kwargs), False)[1], now=NOW,
    )
    assert asked, "a 403 on the namespace read must trigger an access review"
    for attributes in asked:
        assert attributes["resource"] == "namespaces"
        assert attributes["verb"] == "get"
        assert attributes["name"] in server.TRUST_TOPOLOGY_NAMESPACES
    assert {attributes["name"] for attributes in asked} == set(server.TRUST_TOPOLOGY_NAMESPACES)


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
