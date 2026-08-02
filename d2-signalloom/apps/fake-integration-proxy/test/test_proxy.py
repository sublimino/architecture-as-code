import http.client
import io
import json
import os
import threading
import unittest
from types import SimpleNamespace
from unittest import mock
from urllib import error
from urllib.parse import urlparse

os.environ["SIGNALLOOM_DEMO_PROFILE"] = "demo"

import server
from server import ProxyHandler, ThreadingHTTPServer


AGENTS_NAMESPACE = "fe-signalloom-agents"
FLUX_NAMESPACE = "fe-signalloom"
FAKE_API_BASE = "https://kubernetes.test"


class ProxyServerTestCase(unittest.TestCase):
    """Shared in-process HTTP server plumbing for the proxy handler."""

    @classmethod
    def setUpClass(cls):
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), ProxyHandler)
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.thread.start()
        cls.port = cls.httpd.server_port

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.thread.join()

    def request(self, method, path, payload=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port)
        data = json.dumps(payload) if payload is not None else None
        request_headers = headers or {}
        if data:
            request_headers.setdefault("Content-Type", "application/json")
        connection.request(method, path, data, request_headers)
        response = connection.getresponse()
        body = json.loads(response.read())
        connection.close()
        return response.status, body

    def raw_request(self, method, path, payload, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port)
        connection.request(method, path, payload, headers or {})
        response = connection.getresponse()
        body = json.loads(response.read())
        connection.close()
        return response.status, body


class ProxyTest(ProxyServerTestCase):
    def setUp(self):
        self.request("DELETE", "/_test/requests")

    def test_all_route_groups_return_deterministic_fixtures(self):
        for path in ("/llm/assistants", "/crm/contacts", "/notification/messages", "/outbound-reporting/reports"):
            status, first = self.request("POST", path, {"name": "demo"})
            self.assertEqual(200, status)
            self.assertEqual((status, first), self.request("POST", path, {"name": "demo"}))

    def test_capture_redacts_secrets_and_excludes_authorization(self):
        self.request("POST", "/llm/assistants", {"token": "never-store", "openai_api_key": "never-store", "nested": {"password": "never-store"}}, {
            "Authorization": "Bearer never-store", "X-Api-Key": "never-store", "X-Request-ID": "trace-1"})
        status, captured = self.request("GET", "/_test/requests")
        self.assertEqual(200, status)
        request = captured["requests"][0]
        self.assertEqual("[REDACTED]", request["body"]["token"])
        self.assertEqual("[REDACTED]", request["body"]["openai_api_key"])
        self.assertEqual("[REDACTED]", request["body"]["nested"]["password"])
        self.assertEqual("trace-1", request["headers"]["x-request-id"])
        self.assertNotIn("authorization", request["headers"])
        self.assertNotIn("x-api-key", request["headers"])
        self.assertNotIn("never-store", json.dumps(captured))

    def test_reset_mutation_and_unknown_routes(self):
        self.request("PUT", "/_test/fixtures/crm/customer", {"id": "customer-42"})
        self.assertEqual((200, {"id": "customer-42"}), self.request("POST", "/crm/customer", {}))
        self.request("POST", "/crm/customer", {})
        self.assertEqual((200, {"requests": []}), self.request("DELETE", "/_test/requests"))
        self.assertEqual(404, self.request("GET", "/unrecognised")[0])

    def test_reset_clears_capture_without_reverting_fixtures(self):
        self.request("PUT", "/_test/fixtures/crm/preserved", {"id": "preserved"})
        self.request("POST", "/crm/preserved", {"name": "captured"})
        self.assertEqual((200, {"requests": []}), self.request("DELETE", "/_test/requests"))
        self.assertEqual((200, {"requests": []}), self.request("GET", "/_test/requests"))
        self.assertEqual((200, {"id": "preserved"}), self.request("POST", "/crm/preserved", {}))

    def test_capture_redacts_non_json_request_bodies(self):
        secret = b"token=never-store"
        self.assertEqual(200, self.raw_request("POST", "/llm/assistants", secret, {
            "Content-Type": "text/plain"})[0])
        status, captured = self.request("GET", "/_test/requests")
        self.assertEqual(200, status)
        self.assertEqual("[REDACTED_NON_JSON_BODY]", captured["requests"][0]["body"])
        self.assertNotIn("never-store", json.dumps(captured))

    def test_control_api_is_not_exposed_outside_demo(self):
        old = os.environ.pop("SIGNALLOOM_DEMO_PROFILE")
        try:
            self.assertEqual(404, self.request("GET", "/_test/fixtures")[0])
        finally:
            os.environ["SIGNALLOOM_DEMO_PROFILE"] = old


# ─── Agent discovery ─────────────────────────────────────────────────────────


def agent_pod(name, namespace, supercred=False, phase="Running", state="idle",
              service_account="cardvault-agent"):
    """Build a pod document shaped like the ones the demo's agents produce."""
    labels = {
        "signalloom.ai/agent": "true",
        "signalloom.ai/agent-name": name.removeprefix("agent-"),
        "signalloom.ai/agent-type": "supercred-demo",
        "signalloom.ai/framework": "custom",
        "signalloom.ai/model": "gpt-4o",
        "signalloom.ai/state": state,
    }
    annotations = {"signalloom.ai/model-full": "openai/gpt-4o"}
    if supercred:
        labels["signalloom.ai/supercred"] = "true"
        annotations["signalloom.ai/supercred-target"] = "cardvault.inf-signalloom.svc.cluster.local:8080"
    return {
        "metadata": {
            "name": name,
            "namespace": namespace,
            "labels": labels,
            "annotations": annotations,
            "creationTimestamp": "2026-01-01T00:00:00Z",
        },
        "spec": {
            "nodeName": "osramp-control-plane",
            "serviceAccountName": service_account,
            "containers": [{"name": "agent"}],
        },
        "status": {"phase": phase},
    }


def not_found(url, message):
    """A 404 the proxy's handlers will see as a real HTTPError."""
    return error.HTTPError(url, 404, message, {}, io.BytesIO(b""))


class FakeKubernetes:
    """Stand-in for the pod, kustomization and policy-engine calls the proxy makes."""

    def __init__(self, pods_by_namespace, unreachable=()):
        self.pods_by_namespace = pods_by_namespace
        self.unreachable = set(unreachable)
        self.listed_namespaces = []
        self.patched_urls = []
        self.evaluations = []

    @staticmethod
    def _namespace_of(path):
        parts = path.strip("/").split("/")
        return parts[parts.index("namespaces") + 1] if "namespaces" in parts else None

    def fetch_json(self, url, token, context):
        path = urlparse(url).path
        if path.endswith("/kustomizations"):
            return {"items": []}
        namespace = self._namespace_of(path)
        if namespace in self.unreachable:
            raise not_found(url, "namespace not found")
        pods = self.pods_by_namespace.get(namespace, [])
        if path.endswith("/pods"):
            self.listed_namespaces.append(namespace)
            return {"items": pods}
        if "/pods/" in path:
            wanted = path.rsplit("/", 1)[-1]
            for pod in pods:
                if pod["metadata"]["name"] == wanted:
                    return pod
            raise not_found(url, "pod not found")
        raise not_found(url, "unhandled route")

    def patch_json(self, url, token, context, patch):
        self.patched_urls.append(url)
        return {}

    def evaluate(self, url, payload):
        self.evaluations.append(payload)
        return {
            "agent_id": payload["agent_id"],
            "compliant": False,
            "results": [{"check": "security-context-present", "pass": False, "reason": "not set"}],
            "evaluated_at": "2026-01-01T00:00:00Z",
        }


class AgentNamespaceTestCase(ProxyServerTestCase):
    """Installs a fake Kubernetes for the agent-facing handlers."""

    def install(self, pods_by_namespace, unreachable=(), namespaces=None):
        fake = FakeKubernetes(pods_by_namespace, unreachable)
        patches = [
            mock.patch.object(server, "_fetch_kubernetes_json", fake.fetch_json),
            mock.patch.object(server, "_patch_kubernetes_json", fake.patch_json),
            mock.patch.object(server, "_post_policy_evaluate", fake.evaluate),
            mock.patch.object(server, "_read_service_account_token", lambda *a, **k: "fake-token"),
            mock.patch.object(server, "_kubernetes_ssl_context", lambda *a, **k: None),
            mock.patch.object(server, "_kubernetes_api_base", lambda: FAKE_API_BASE),
        ]
        if namespaces is not None:
            patches.append(mock.patch.dict(os.environ, {"AGENT_DISCOVERY_NAMESPACES": namespaces}))
        else:
            patches.append(mock.patch.dict(os.environ, {}, clear=False))
            os.environ.pop("AGENT_DISCOVERY_NAMESPACES", None)
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        return fake


class AgentDiscoveryTest(AgentNamespaceTestCase):
    """Discovery must span namespaces: Flux's targetNamespace relocates the
    SuperCred agent pod away from the namespace its own manifest declares."""

    def test_agents_union_pods_across_both_default_namespaces(self):
        self.install({
            AGENTS_NAMESPACE: [agent_pod("agent-dennis", AGENTS_NAMESPACE)],
            FLUX_NAMESPACE: [agent_pod("agent-cardvault", FLUX_NAMESPACE, supercred=True)],
        })
        status, body = self.request("GET", "/agents")
        self.assertEqual(200, status)
        self.assertEqual(
            {"agent-dennis", "agent-cardvault"},
            {agent["id"] for agent in body["agents"]},
        )
        self.assertEqual([AGENTS_NAMESPACE, FLUX_NAMESPACE], body["namespaces"])

    def test_agents_report_the_namespace_they_were_found_in(self):
        self.install({
            AGENTS_NAMESPACE: [agent_pod("agent-dennis", AGENTS_NAMESPACE)],
            FLUX_NAMESPACE: [agent_pod("agent-cardvault", FLUX_NAMESPACE, supercred=True)],
        })
        by_id = {agent["id"]: agent for agent in self.request("GET", "/agents")[1]["agents"]}
        self.assertEqual(AGENTS_NAMESPACE, by_id["agent-dennis"]["namespace"])
        self.assertEqual(FLUX_NAMESPACE, by_id["agent-cardvault"]["namespace"])

    def test_agents_preserve_the_supercred_label_mapping(self):
        self.install({FLUX_NAMESPACE: [agent_pod("agent-cardvault", FLUX_NAMESPACE, supercred=True)]})
        agent = self.request("GET", "/agents")[1]["agents"][0]
        self.assertTrue(agent["supercred"])
        self.assertEqual(
            "cardvault.inf-signalloom.svc.cluster.local:8080",
            agent["supercred_target"],
        )
        self.assertEqual("Running", agent["phase"])

    def test_agents_expose_the_pod_service_account(self):
        """The dashboard's Credential Inventory derives the SPIFFE ID from
        namespace + service account. SPIRE's k8s workload registrar issues
        spiffe://<trust-domain>/ns/<ns>/sa/<sa>, so without this field the
        second half of every identity would have to be guessed."""
        self.install({FLUX_NAMESPACE: [
            agent_pod("agent-cardvault", FLUX_NAMESPACE, supercred=True,
                      service_account="cardvault-agent"),
        ]})
        agent = self.request("GET", "/agents")[1]["agents"][0]
        self.assertEqual("cardvault-agent", agent["service_account"])

    def test_agents_report_no_service_account_when_the_pod_omits_one(self):
        """None, not "default" — a fabricated service account renders a SPIFFE
        ID that does not exist. The dashboard drops such agents deliberately."""
        pod = agent_pod("agent-cardvault", FLUX_NAMESPACE, supercred=True)
        del pod["spec"]["serviceAccountName"]
        self.install({FLUX_NAMESPACE: [pod]})
        agent = self.request("GET", "/agents")[1]["agents"][0]
        self.assertIsNone(agent["service_account"])

    def test_agents_deduplicate_when_a_namespace_is_configured_twice(self):
        self.install(
            {FLUX_NAMESPACE: [agent_pod("agent-cardvault", FLUX_NAMESPACE, supercred=True)]},
            namespaces=f"{FLUX_NAMESPACE},{AGENTS_NAMESPACE},{FLUX_NAMESPACE}",
        )
        agents = self.request("GET", "/agents")[1]["agents"]
        self.assertEqual(["agent-cardvault"], [agent["id"] for agent in agents])

    def test_agent_discovery_namespaces_are_env_overridable(self):
        fake = self.install(
            {"custom-agents": [agent_pod("agent-brave-sir-robin", "custom-agents")]},
            namespaces="custom-agents",
        )
        status, body = self.request("GET", "/agents")
        self.assertEqual(200, status)
        self.assertEqual(["custom-agents"], fake.listed_namespaces)
        self.assertEqual(["agent-brave-sir-robin"], [agent["id"] for agent in body["agents"]])
        self.assertEqual(["custom-agents"], body["namespaces"])

    def test_one_unreachable_namespace_does_not_empty_the_response(self):
        self.install(
            {FLUX_NAMESPACE: [agent_pod("agent-cardvault", FLUX_NAMESPACE, supercred=True)]},
            unreachable=[AGENTS_NAMESPACE],
        )
        status, body = self.request("GET", "/agents")
        self.assertEqual(200, status)
        self.assertEqual(["agent-cardvault"], [agent["id"] for agent in body["agents"]])
        self.assertIn(AGENTS_NAMESPACE, body["namespace_errors"])
        self.assertNotIn("error", body)

    def test_all_namespaces_unreachable_reports_an_error(self):
        self.install({}, unreachable=[AGENTS_NAMESPACE, FLUX_NAMESPACE])
        status, body = self.request("GET", "/agents")
        self.assertEqual(200, status)
        self.assertEqual([], body["agents"])
        self.assertIn("error", body)

    def test_agents_response_keeps_the_legacy_namespace_key(self):
        self.install({AGENTS_NAMESPACE: [agent_pod("agent-patsy", AGENTS_NAMESPACE)]})
        body = self.request("GET", "/agents")[1]
        self.assertIn("namespace", body)
        self.assertIn(AGENTS_NAMESPACE, body["namespace"])


class AgentActionNamespaceTest(AgentNamespaceTestCase):
    """Compliance and stun must follow the agent to whichever namespace holds it."""

    def test_compliance_resolves_the_namespace_without_a_hint(self):
        fake = self.install({FLUX_NAMESPACE: [agent_pod("agent-cardvault", FLUX_NAMESPACE, supercred=True)]})
        status, body = self.request("GET", "/agents/agent-cardvault/compliance")
        self.assertEqual(200, status)
        self.assertEqual("agent-cardvault", body["agent_id"])
        self.assertEqual(FLUX_NAMESPACE, fake.evaluations[0]["namespace"])

    def test_compliance_honours_an_explicit_namespace_hint(self):
        fake = self.install({
            AGENTS_NAMESPACE: [agent_pod("agent-cardvault", AGENTS_NAMESPACE, supercred=True)],
            FLUX_NAMESPACE: [agent_pod("agent-cardvault", FLUX_NAMESPACE, supercred=True)],
        })
        status, _ = self.request("GET", f"/agents/agent-cardvault/compliance?namespace={FLUX_NAMESPACE}")
        self.assertEqual(200, status)
        self.assertEqual(FLUX_NAMESPACE, fake.evaluations[0]["namespace"])

    def test_compliance_reports_not_found_when_no_namespace_holds_the_agent(self):
        self.install({AGENTS_NAMESPACE: []})
        status, body = self.request("GET", "/agents/agent-missing/compliance")
        self.assertEqual(404, status)
        self.assertIn("agent-missing", body["error"])

    def test_stun_patches_the_pod_in_its_resolved_namespace(self):
        fake = self.install({FLUX_NAMESPACE: [agent_pod("agent-cardvault", FLUX_NAMESPACE, supercred=True)]})
        status, body = self.request("POST", "/agents/agent-cardvault/stun")
        self.assertEqual(200, status)
        self.assertEqual("stunned", body["state"])
        self.assertEqual(FLUX_NAMESPACE, body["namespace"])
        self.assertIn(f"/namespaces/{FLUX_NAMESPACE}/pods/agent-cardvault", fake.patched_urls[0])

    def test_stun_honours_an_explicit_namespace_hint(self):
        fake = self.install({
            AGENTS_NAMESPACE: [agent_pod("agent-cardvault", AGENTS_NAMESPACE, supercred=True)],
            FLUX_NAMESPACE: [agent_pod("agent-cardvault", FLUX_NAMESPACE, supercred=True)],
        })
        status, body = self.request("POST", f"/agents/agent-cardvault/stun?namespace={AGENTS_NAMESPACE}")
        self.assertEqual(200, status)
        self.assertEqual(AGENTS_NAMESPACE, body["namespace"])
        self.assertIn(f"/namespaces/{AGENTS_NAMESPACE}/pods/agent-cardvault", fake.patched_urls[0])

    def test_stun_reports_not_found_when_no_namespace_holds_the_agent(self):
        self.install({AGENTS_NAMESPACE: []})
        status, body = self.request("POST", "/agents/agent-missing/stun")
        self.assertEqual(404, status)
        self.assertIn("agent-missing", body["error"])

    def test_an_unknown_namespace_hint_is_ignored_rather_than_trusted(self):
        fake = self.install({FLUX_NAMESPACE: [agent_pod("agent-cardvault", FLUX_NAMESPACE, supercred=True)]})
        status, body = self.request("GET", "/agents/agent-cardvault/compliance?namespace=kube-system")
        self.assertEqual(200, status)
        self.assertEqual(FLUX_NAMESPACE, fake.evaluations[0]["namespace"])
        self.assertNotIn("kube-system", json.dumps(body))


# ─── Network tests (netassert) ────────────────────────────────────────────────


class NetworkTestsTestCase(ProxyServerTestCase):
    """GET /network-tests reads the Kubernetes Job/pod-log helpers directly
    (there is no per-pod fake to route through, unlike agent discovery), so
    tests patch those helpers the same way AgentActionNamespaceTest patches
    _post_policy_evaluate. POST /network-tests/scan no longer touches the
    Kubernetes Job API at all — job creation/deletion moved to
    netassert-controller (apps/netassert-controller/), a separate process
    with its own dedicated ServiceAccount, so this process no longer holds
    jobs:create/delete. See ScanTestCase below."""

    def install(self, *, job=None, pod_logs=None, get_job_calls=None):
        pod_logs = pod_logs or {}
        get_job_calls = get_job_calls if get_job_calls is not None else []

        def fake_get_job(base_url, token, context, namespace, name):
            get_job_calls.append((namespace, name))
            return job

        def fake_list_job_pods(base_url, token, context, namespace, job_name):
            return [{"metadata": {"name": pod_name, "namespace": namespace}} for pod_name in pod_logs]

        def fake_fetch_text(url, token, context):
            for pod_name, log_text in pod_logs.items():
                if f"/pods/{pod_name}/log" in url:
                    return log_text
            raise not_found(url, "log not found")

        patches = [
            mock.patch.object(server, "_read_service_account_token", lambda *a, **k: "fake-token"),
            mock.patch.object(server, "_kubernetes_ssl_context", lambda *a, **k: None),
            mock.patch.object(server, "_kubernetes_api_base", lambda: FAKE_API_BASE),
            mock.patch.object(server, "_get_kubernetes_job", fake_get_job),
            mock.patch.object(server, "_list_job_pods", fake_list_job_pods),
            mock.patch.object(server, "_fetch_kubernetes_text", fake_fetch_text),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        return SimpleNamespace(get_job_calls=get_job_calls)

    def test_get_returns_every_definition_as_pending_when_no_scan_has_run(self):
        self.install(job=None)
        status, body = self.request("GET", "/network-tests")
        self.assertEqual(200, status)
        self.assertEqual("never-run", body["scanStatus"])
        self.assertEqual(len(server.NETWORK_TEST_DEFINITIONS), len(body["tests"]))
        self.assertTrue(all(t["result"] == "pending" for t in body["tests"]))
        names = {t["name"] for t in body["tests"]}
        self.assertIn("dashboard-to-api-allowed", names)
        self.assertIn("agents-to-postgresql-denied", names)

    def test_get_maps_tap_output_to_pass_and_fail_per_test(self):
        tap = (
            "TAP version 13\n"
            "1..2\n"
            "ok 1 - dashboard-to-api-allowed\n"
            "not ok 2 - dashboard-to-postgresql-denied\n"
        )
        log = f"some netassert log noise\n{server.NETASSERT_TAP_MARKER}\n{tap}"
        job = {"status": {"succeeded": 1, "conditions": [{"type": "Complete", "status": "True"}]}}
        self.install(job=job, pod_logs={"netassert-run-abcde": log})

        status, body = self.request("GET", "/network-tests")
        self.assertEqual(200, status)
        self.assertEqual("complete", body["scanStatus"])
        by_name = {t["name"]: t for t in body["tests"]}
        self.assertEqual("pass", by_name["dashboard-to-api-allowed"]["result"])
        self.assertEqual("fail", by_name["dashboard-to-postgresql-denied"]["result"])
        # Tests absent from the TAP output but with a finished job read as
        # errors rather than silently staying "pending" forever.
        self.assertEqual("error", by_name["api-to-redis-allowed"]["result"])

    def test_get_reports_running_while_the_job_is_still_active(self):
        job = {"status": {"active": 1}}
        self.install(job=job, pod_logs={"netassert-run-abcde": "no results yet"})
        status, body = self.request("GET", "/network-tests")
        self.assertEqual(200, status)
        self.assertEqual("running", body["scanStatus"])
        self.assertTrue(all(t["result"] == "running" for t in body["tests"]))

    def test_get_reports_an_explicit_error_state_when_the_api_is_unreachable(self):
        patches = [
            mock.patch.object(server, "_read_service_account_token", mock.Mock(side_effect=OSError("no token"))),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        status, body = self.request("GET", "/network-tests")
        self.assertEqual(200, status)
        self.assertEqual("unavailable", body["scanStatus"])
        self.assertTrue(all(t["result"] == "error" for t in body["tests"]))


class ScanTestCase(ProxyServerTestCase):
    """POST /network-tests/scan is now a thin forward to netassert-controller
    (see _trigger_netassert_scan) — the create/delete/conflict logic itself
    is tested against the controller directly in
    apps/netassert-controller/test/test_controller.py. These tests only
    cover the proxy's half of the contract: it must call the controller and
    relay its response verbatim, and it must never forward the caller's body."""

    def test_scan_forwards_to_the_controller_and_relays_its_response(self):
        calls = []

        def fake_trigger():
            calls.append(1)
            return 202, {"job": "netassert-run", "status": "started"}

        with mock.patch.object(server, "_trigger_netassert_scan", fake_trigger):
            status, body = self.request("POST", "/network-tests/scan")
        self.assertEqual(202, status)
        self.assertEqual({"job": "netassert-run", "status": "started"}, body)
        self.assertEqual(1, len(calls))

    def test_scan_relays_a_conflict_from_the_controller(self):
        with mock.patch.object(
            server, "_trigger_netassert_scan",
            lambda: (409, {"error": "a network test scan is already running"}),
        ):
            status, body = self.request("POST", "/network-tests/scan")
        self.assertEqual(409, status)
        self.assertIn("already running", body["error"])

    def test_scan_relays_bad_gateway_when_the_controller_is_unreachable(self):
        with mock.patch.object(
            server, "_trigger_netassert_scan",
            lambda: (502, {"error": "netassert-controller unreachable: [Errno 111] Connection refused"}),
        ):
            status, body = self.request("POST", "/network-tests/scan")
        self.assertEqual(502, status)
        self.assertIn("unreachable", body["error"])

    def test_scan_never_forwards_the_caller_body_to_the_controller(self):
        """The proxy must not become an indirect arbitrary-target probe: the
        controller call takes no arguments at all, so nothing the caller
        sends can reach it."""
        received_args = []

        def fake_trigger(*args, **kwargs):
            received_args.append((args, kwargs))
            return 202, {"job": "netassert-run", "status": "started"}

        with mock.patch.object(server, "_trigger_netassert_scan", fake_trigger):
            self.request("POST", "/network-tests/scan", {"target": "10.0.0.1", "namespace": "kube-system"})
        self.assertEqual([((), {})], received_args)


if __name__ == "__main__":
    unittest.main()
