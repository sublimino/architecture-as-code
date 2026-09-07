import json
import os
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


SCRIPT = Path(__file__).with_name("resolve-agent-pod.sh")
AGENT_URL = "/api/v1/namespaces/fe-signalloom-agents/pods?labelSelector=signalloom.ai%2Fagent%3Dtrue"
GATEWAY_URL = "/api/v1/namespaces/ingress/pods?labelSelector=gateway.envoyproxy.io%2Fowning-gateway-name%3Dcluster"
CARDVAULT_URL = (
    "/api/v1/namespaces/fe-signalloom-agents/pods?labelSelector="
    "app.kubernetes.io%2Fname%3Dcardvault-agent%2C"
    "signalloom.ai%2Fsupercred%3Dtrue%2C"
    "bao.controlplane.io%2Fconsumer%3Dcardvault-agent"
)
DESTINATION_URL = "/apis/apps/v1/namespaces/fe-signalloom/deployments/api"

SUITE = """- name: generic-agent
  src:
    k8sResource: {kind: pod, name: agent-patsy, namespace: fe-signalloom-agents}
  dst:
    k8sResource: {kind: deployment, name: api, namespace: fe-signalloom}
- name: gateway
  src:
    k8sResource: {kind: pod, name: envoy-gateway-pod, namespace: ingress}
  dst:
    k8sResource: {kind: deployment, name: api, namespace: fe-signalloom}
- name: cardvault
  src:
    k8sResource: {kind: pod, name: netassert-cardvault-probe-pod, namespace: fe-signalloom-agents}
  dst:
    k8sResource: {kind: deployment, name: api, namespace: fe-signalloom}
"""


def ready_pod(name, *, deleting=False, phase="Running", ready=True, owner_kind=None):
    metadata = {"name": name, "creationTimestamp": "2026-01-01T00:00:00Z"}
    if deleting:
        metadata["deletionTimestamp"] = "now"
    if owner_kind:
        metadata["ownerReferences"] = [{"kind": owner_kind, "name": "owner"}]
    return {
        "metadata": metadata,
        "status": {
            "phase": phase,
            "conditions": [{"type": "Ready", "status": "True" if ready else "False"}],
        },
    }


class ApiHandler(BaseHTTPRequestHandler):
    responses = {}

    def log_message(self, *_args):
        pass

    def do_GET(self):
        payload, status = self.responses.get(self.path, ({"message": "missing fixture"}, 404))
        encoded = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


class ResolverTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.api = ThreadingHTTPServer(("127.0.0.1", 0), ApiHandler)
        cls.thread = threading.Thread(target=cls.api.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.api.shutdown()
        cls.thread.join()

    def run_resolver(self, overrides=None, suite=SUITE):
        responses = {
            AGENT_URL: ({"items": [ready_pod("agent-ready")]}, 200),
            GATEWAY_URL: ({"items": [ready_pod("envoy-cluster-abcd")]}, 200),
            CARDVAULT_URL: ({"items": [ready_pod("netassert-cardvault-probe-abcd")]}, 200),
            DESTINATION_URL: ({"status": {"availableReplicas": 1}}, 200),
        }
        responses.update(overrides or {})
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            token = root / "token"
            config = root / "suite.yaml"
            output = root / "resolved.yaml"
            token.write_text("test-token")
            config.write_text(suite)
            ApiHandler.responses = responses
            env = {
                **os.environ,
                "TOKEN_FILE": str(token),
                "CA_CERT": str(token),
                "KUBERNETES_API": f"http://127.0.0.1:{self.api.server_port}",
                "CONFIG_FILE": str(config),
                "OUTPUT_FILE": str(output),
            }
            result = subprocess.run(["sh", str(SCRIPT)], env=env, text=True, capture_output=True)
            return result, output.read_text() if output.exists() else ""

    def test_resolves_generic_agent_placeholder(self):
        result, output = self.run_resolver()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("name: agent-ready", output)
        self.assertNotIn("agent-patsy", output)

    def test_resolves_envoy_gateway_placeholder(self):
        result, output = self.run_resolver()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("name: envoy-cluster-abcd", output)
        self.assertNotIn("envoy-gateway-pod", output)

    def test_resolves_sustained_cardvault_probe_placeholder(self):
        result, output = self.run_resolver()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("name: netassert-cardvault-probe-abcd", output)
        self.assertNotIn("netassert-cardvault-probe-pod", output)

    def test_ignores_nonrunning_unready_and_terminating_candidates(self):
        candidates = [
            ready_pod("terminating", deleting=True),
            ready_pod("pending", phase="Pending"),
            ready_pod("unready", ready=False),
            ready_pod("usable"),
        ]
        result, output = self.run_resolver({AGENT_URL: ({"items": candidates}, 200)})
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("name: usable", output)

    def test_each_missing_placeholder_candidate_fails_closed(self):
        for url in (AGENT_URL, GATEWAY_URL, CARDVAULT_URL):
            with self.subTest(url=url):
                result, _ = self.run_resolver({url: ({"items": []}, 200)})
                self.assertNotEqual(0, result.returncode)
                self.assertIn("expected exactly one Running, Ready", result.stderr)

    def test_sustained_probe_does_not_select_transient_job_pod(self):
        transient = ready_pod("supercred-agent-run-abcd", owner_kind="Job")
        result, _ = self.run_resolver({CARDVAULT_URL: ({"items": [transient]}, 200)})
        self.assertNotEqual(0, result.returncode)
        self.assertIn("found 0", result.stderr)

    def test_each_ambiguous_placeholder_candidate_fails_closed(self):
        for url in (AGENT_URL, GATEWAY_URL, CARDVAULT_URL):
            with self.subTest(url=url):
                candidates = [ready_pod("candidate-one"), ready_pod("candidate-two")]
                result, _ = self.run_resolver({url: ({"items": candidates}, 200)})
                self.assertNotEqual(0, result.returncode)
                self.assertIn("found 2", result.stderr)

    def test_fails_when_destination_has_no_available_replica(self):
        result, _ = self.run_resolver({DESTINATION_URL: ({"status": {"availableReplicas": 0}}, 200)})
        self.assertNotEqual(0, result.returncode)
        self.assertIn("destination unavailable", result.stderr)

    def test_does_not_require_placeholders_absent_from_suite(self):
        suite = SUITE.split("- name: gateway", 1)[0]
        result, output = self.run_resolver(
            {GATEWAY_URL: ({"items": []}, 200), CARDVAULT_URL: ({"items": []}, 200)}, suite
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertNotIn("agent-patsy", output)


if __name__ == "__main__":
    unittest.main()
