"""Integration tests exercising real Linux subprocess lifecycle telemetry."""
from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import time
import unittest

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .collector import ProcessTelemetryCollector
    from .models import HealthState
    from .sensor import HostSensor
except (ImportError, ValueError):
    from collector import ProcessTelemetryCollector
    from models import HealthState
    from sensor import HostSensor


class SensorIntegrationTests(unittest.TestCase):
    """End-to-end integration tests with real OS processes."""

    def test_live_process_lifecycle_monitoring(self) -> None:
        # Spawn a short-lived worker process
        proc = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(0.4)"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        sensor = HostSensor(
            session_id="integration-sess-001",
            agent_id="agentmaxxing-linux-001",
            host_id="amx-host-001",
            tenant_id="tenant-agentmaxxing",
        )
        sensor.bind_pid(proc.pid)

        # 1. Sample while running
        running_event = sensor.sample()
        self.assertEqual(running_event.sequence, 0)
        self.assertEqual(running_event.attributes.health_state, HealthState.RUNNING)
        self.assertGreater(running_event.attributes.resident_memory_bytes, 0)
        self.assertIsNone(running_event.attributes.exit_code)

        # 2. Wait for process completion
        exit_code = proc.wait()
        self.assertEqual(exit_code, 0)

        # 3. Sample after clean exit
        exit_event = sensor.record_exit(exit_code)
        self.assertEqual(exit_event.sequence, 1)
        self.assertEqual(exit_event.attributes.health_state, HealthState.STOPPED)
        self.assertEqual(exit_event.attributes.exit_code, 0)

    def test_failed_process_exit_code_capture(self) -> None:
        proc = subprocess.Popen(
            [sys.executable, "-c", "import sys; sys.exit(42)"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        exit_code = proc.wait()
        self.assertEqual(exit_code, 42)

        sensor = HostSensor(
            session_id="integration-sess-002",
            agent_id="agentmaxxing-linux-001",
            host_id="amx-host-001",
        )
        sensor.bind_pid(proc.pid)
        exit_event = sensor.record_exit(exit_code)
        self.assertEqual(exit_event.attributes.health_state, HealthState.FAILED)
        self.assertEqual(exit_event.attributes.exit_code, 42)

    def test_process_restart_tracking(self) -> None:
        sensor = HostSensor(
            session_id="integration-sess-003",
            agent_id="agentmaxxing-linux-001",
            host_id="amx-host-001",
        )

        # Initial launch
        proc1 = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(0.1)"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        sensor.bind_pid(proc1.pid)
        proc1.wait()
        sensor.record_exit(0)

        # Restarted launch
        proc2 = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(0.1)"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        sensor.bind_pid(proc2.pid, is_restart=True)
        sample2 = sensor.sample()
        self.assertEqual(sample2.attributes.restart_count, 1)
        proc2.wait()
        sensor.record_exit(0)


if __name__ == "__main__":
    unittest.main()
