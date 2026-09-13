# AgentMaxxing Host Sensor (`agentmaxxing-host-sensor`)

The **AgentMaxxing Host Sensor** is a host-level telemetry collector designed to monitor external Linux agent processes and emit strictly bounded, allowlisted process lifecycle metadata.

---

## 1. Zero-Payload Isolation & Security Invariants

In compliance with the **Signal Loom Host Policy** and **AMXO Charter**, the sensor strictly enforces:

1. **Zero Memory Inspection:** The sensor never reads `/proc/<pid>/mem`, `/proc/<pid>/maps`, `/proc/<pid>/stack`, or process registers.
2. **Zero Environment or Command Secret Extraction:** The sensor never reads `/proc/<pid>/environ` or parses commandline arguments/secrets from `/proc/<pid>/cmdline`.
3. **Zero Customer File or Payload Harvesting:** Sensor records contain no customer data, file payloads, or network request/response bodies.
4. **Strict Field Allowlisting:** Emitted records strictly contain only:
   - `health_state`: Lifecycle state (`starting`, `running`, `stopped`, `failed`, `unknown`)
   - `cpu_time_ms`: Total CPU time consumed in milliseconds (`utime` + `stime` or cgroup `cpu.stat`)
   - `resident_memory_bytes`: RSS memory usage in bytes (`statm` / `status` / `memory.current`)
   - `exit_code`: Process exit code (integer if terminated, `null` if active)
   - `restart_count`: Monotonically increasing restart counter across process respawns
   - Extended metrics: `cpu_percent`, `pid`, `ppid`

---

## 2. Telemetry Schema & Wire Format

Process lifecycle records strictly conform to the Signal Loom evidence contract (`process-lifecycle-telemetry.v1.schema.json` and `agentmaxxing-export.v1.json`):

```json
{
  "schema_version": "1.0.0",
  "session_id": "amxo-session-0001",
  "sequence": 0,
  "observed_at": "2026-09-13T18:30:00Z",
  "source": "host-sensor-v1",
  "evidence_type": "process",
  "observation_state": "observed",
  "integrity_state": "not-integrity-verified",
  "agent_id": "agentmaxxing-linux-001",
  "host_id": "amx-host-001",
  "attributes": {
    "health_state": "running",
    "cpu_time_ms": 241,
    "resident_memory_bytes": 33554432,
    "exit_code": null,
    "restart_count": 0
  }
}
```

---

## 3. Kernel & Cgroup Extraction Details

- **`/proc/<pid>/stat`**: Parsed using safe boundary markers around process `comm` (handling nested parentheses and spaces) to extract CPU ticks (`utime`, `stime`), start time, and raw state.
- **`/proc/<pid>/statm`**: Extracts resident page count multiplied by system page size (`SC_PAGE_SIZE` = 4096).
- **Cgroups v2 Unified Hierarchy**: When available, reads `cpu.stat` (`usage_usec`) and `memory.current` for aggregate resource accounting under systemd slice boundaries.

---

## 4. CLI Usage

### Inspect Process
```bash
python3 -m agentmaxxing_host_sensor inspect --pid 1234
```

### Collect Single Telemetry Record
```bash
python3 -m agentmaxxing_host_sensor collect --pid 1234 --session-id sess-001 --pretty
```

### Dump Schema
```bash
python3 -m agentmaxxing_host_sensor schema
```

### Verify Host Environment
```bash
python3 -m agentmaxxing_host_sensor verify
```

---

## 5. Running Tests

```bash
python3 -m unittest discover -s d2-signalloom/apps/agentmaxxing-host-sensor/ -p 'test_*.py'
```
