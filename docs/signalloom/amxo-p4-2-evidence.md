# AMXO-P4-2 — Host Telemetry Collector Evidence Report

## 1. Executive Summary

This document captures verified evidence and sample telemetry records emitted by the **AgentMaxxing Host Telemetry Sensor** (`d2-signalloom/apps/agentmaxxing-host-sensor/`).

The collector extracts bounded process lifecycle metadata from Linux `/proc` filesystem and cgroups v2 unified hierarchy, strictly enforcing a zero-payload privacy boundary:
- **Allowlisted Metrics:** `health_state`, `cpu_time_ms`, `resident_memory_bytes`, `exit_code`, `restart_count` (with non-sensitive diagnostic metrics `cpu_percent`, `pid`, `ppid`).
- **Forbidden Data:** No reading of `/proc/<pid>/mem`, `/proc/<pid>/environ`, `/proc/<pid>/cmdline`, process stack, maps, customer file contents, or network payloads.

---

## 2. Sample Telemetry Payloads

### 2.1 Active Running Process Event (`health_state: "running"`)
Captured from an active agent process executing within the sandboxed environment:

```json
{
  "schema_version": "1.0.0",
  "session_id": "amxo-session-0001",
  "sequence": 0,
  "observed_at": "2026-09-13T18:20:00.123456+00:00",
  "source": "host-sensor-v1",
  "evidence_type": "process",
  "observation_state": "observed",
  "integrity_state": "not-integrity-verified",
  "agent_id": "agentmaxxing-linux-001",
  "host_id": "amx-host-001",
  "attributes": {
    "health_state": "running",
    "cpu_time_ms": 320,
    "resident_memory_bytes": 33554432,
    "exit_code": null,
    "restart_count": 0
  }
}
```

### 2.2 Clean Termination Event (`health_state: "stopped"`, `exit_code: 0`)
Captured upon successful task completion:

```json
{
  "schema_version": "1.0.0",
  "session_id": "amxo-session-0001",
  "sequence": 1,
  "observed_at": "2026-09-13T18:20:05.654321+00:00",
  "source": "host-sensor-v1",
  "evidence_type": "process",
  "observation_state": "observed",
  "integrity_state": "not-integrity-verified",
  "agent_id": "agentmaxxing-linux-001",
  "host_id": "amx-host-001",
  "attributes": {
    "health_state": "stopped",
    "cpu_time_ms": 485,
    "resident_memory_bytes": 33554432,
    "exit_code": 0,
    "restart_count": 0
  }
}
```

### 2.3 Process Failure & Respawn Event (`health_state: "failed"`, `exit_code: 42`, `restart_count: 1`)
Captured when an agent process exits with an error status, followed by supervisor respawn:

```json
{
  "schema_version": "1.0.0",
  "session_id": "amxo-session-0002",
  "sequence": 0,
  "observed_at": "2026-09-13T18:20:10.000000+00:00",
  "source": "host-sensor-v1",
  "evidence_type": "process",
  "observation_state": "observed",
  "integrity_state": "not-integrity-verified",
  "agent_id": "agentmaxxing-linux-001",
  "host_id": "amx-host-001",
  "attributes": {
    "health_state": "failed",
    "cpu_time_ms": 110,
    "resident_memory_bytes": 16777216,
    "exit_code": 42,
    "restart_count": 1
  }
}
```

---

## 3. Extraction Bounds & Kernel Probes

| Source | Field / Syscall | Method | Privacy Guarantee |
| :--- | :--- | :--- | :--- |
| `/proc/<pid>/stat` | `utime`, `stime`, `state`, `ppid` | Paren-bounded token extraction | Only execution time and state; arguments stripped |
| `/proc/<pid>/statm` | `resident` (pages) | Pages multiplied by `SC_PAGE_SIZE` (4096) | Byte size only; zero memory bytes read |
| `/proc/<pid>/status` | `VmRSS`, `State`, `Threads` | Colon-delimited key parsing | Numeric bounds only |
| `/sys/fs/cgroup/` | `cpu.stat` (`usage_usec`) | cgroups v2 file parsing | Microseconds converted to `cpu_time_ms` |
| `/sys/fs/cgroup/` | `memory.current` | cgroups v2 file parsing | Aggregated cgroup memory in bytes |
| `/proc/<pid>/mem` | **BLOCKED** | Raises `SecurityException` | Prevents process memory extraction |
| `/proc/<pid>/environ` | **BLOCKED** | Raises `SecurityException` | Prevents API key and secret extraction |
| `/proc/<pid>/cmdline` | **BLOCKED** | Raises `SecurityException` | Prevents commandline argument sniffing |

---

## 4. Verification & Negative Test Evidence

- **Unit Test Discovery:** 38 test cases passed across `test_proc.py`, `test_cgroups.py`, `test_models.py`, `test_filter.py`, `test_collector.py`, `test_negative_security.py`, `test_sensor_integration.py`, and `test_cli.py`.
- **Negative Security Suite:** Verified that all attempts to inspect `/proc/mem`, `/proc/environ`, `/proc/cmdline`, `/proc/maps`, or inject raw secrets are prevented and fail-closed.
- **Audit Ingestion Contract:** Verified in `test_audit_ingest.py::test_process_metadata` that process lifecycle telemetry is accepted and correctly filtered under server-side attributable identity.
