import json
import os
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


SCRIPT = Path(__file__).with_name("resolve-agent-pod.sh")


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

    def run_resolver(self, pods, deployment=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            token = root / "token"
            config = root / "suite.yaml"
            output = root / "resolved.yaml"
            token.write_text("test-token")
            config.write_text("""- name: denied
  src:
    k8sResource:
      kind: pod
      name: agent-patsy
      namespace: fe-signalloom-agents
  dst:
    k8sResource:
      kind: deployment
      name: api
      namespace: fe-signalloom
""")
            ApiHandler.responses = {
                "/api/v1/namespaces/fe-signalloom-agents/pods?labelSelector=signalloom.ai%2Fagent%3Dtrue": (pods, 200),
                "/apis/apps/v1/namespaces/fe-signalloom/deployments/api": (
                    deployment or {"status": {"availableReplicas": 1}}, 200
                ),
            }
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

    def test_selects_only_running_ready_nonterminating_pod(self):
        pods = {"items": [
            {"metadata": {"name": "agent-terminating", "deletionTimestamp": "now"},
             "status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}]}},
            {"metadata": {"name": "agent-pending"}, "status": {"phase": "Pending"}},
            {"metadata": {"name": "agent-ready", "creationTimestamp": "2026-01-01T00:00:00Z"},
             "status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}]}},
        ]}
        result, output = self.run_resolver(pods)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("name: agent-ready", output)
        self.assertNotIn("agent-terminating", output)

    def test_fails_when_no_usable_agent_exists(self):
        result, _ = self.run_resolver({"items": []})
        self.assertNotEqual(0, result.returncode)
        self.assertIn("no Running, Ready", result.stderr)

    def test_fails_when_destination_has_no_available_replica(self):
        pods = {"items": [{
            "metadata": {"name": "agent-ready", "creationTimestamp": "2026-01-01T00:00:00Z"},
            "status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}]},
        }]}
        result, _ = self.run_resolver(pods, {"status": {"availableReplicas": 0}})
        self.assertNotEqual(0, result.returncode)
        self.assertIn("destination unavailable", result.stderr)


if __name__ == "__main__":
    unittest.main()
