"""Command-line interface for the AgentMaxxing host telemetry sensor and artifact hasher."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
from typing import List, Optional

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .cgroups import CgroupV2Reader
    from .collector import ProcessTelemetryCollector
    from .hasher import BoundedArtifactHasher
    from .models import BoundedProcessAttributes, ExportSource, ProcessTelemetryEvent
    from .proc import ProcReader
    from .ratelimit import RateLimiter
    from .sensor import HostSensor
except (ImportError, ValueError):
    from cgroups import CgroupV2Reader
    from collector import ProcessTelemetryCollector
    from hasher import BoundedArtifactHasher
    from models import BoundedProcessAttributes, ExportSource, ProcessTelemetryEvent
    from proc import ProcReader
    from ratelimit import RateLimiter
    from sensor import HostSensor


def get_schema_path() -> Path:
    """Return path to process lifecycle JSON schema."""
    return Path(__file__).resolve().parent / "schemas" / "process-lifecycle-telemetry.v1.schema.json"


def cmd_collect(args: argparse.Namespace) -> int:
    """Execute collect command."""
    collector = ProcessTelemetryCollector()
    event = collector.collect_event(
        session_id=args.session_id or f"session-{args.pid:04d}",
        sequence=args.sequence,
        agent_id=args.agent_id or "agentmaxxing-linux-001",
        host_id=args.host_id or "amx-host-001",
        pid=args.pid,
        tenant_id=args.tenant_id,
        cgroup_path=args.cgroup_dir,
    )

    output = event.to_dict(
        include_tenant=bool(args.tenant_id),
        include_extended=args.extended,
    )
    print(json.dumps(output, indent=2 if args.pretty else None, sort_keys=True))
    return 0


def cmd_inspect(args: argparse.Namespace) -> int:
    """Execute inspect command."""
    collector = ProcessTelemetryCollector()
    attrs = collector.collect_attributes(
        pid=args.pid,
        cgroup_path=args.cgroup_dir,
    )
    data = attrs.to_dict(include_extended=True)
    if args.json:
        print(json.dumps(data, indent=2, sort_keys=True))
    else:
        print(f"Process Metrics for PID {args.pid}:")
        print(f"  Health State:          {data['health_state']}")
        print(f"  CPU Time (ms):         {data['cpu_time_ms']}")
        print(f"  CPU Utilization:       {data.get('cpu_percent', 0.0)}%")
        print(f"  Resident Memory:       {data['resident_memory_bytes']} bytes ({data['resident_memory_bytes'] / (1024*1024):.2f} MB)")
        print(f"  Exit Code:             {data['exit_code']}")
        print(f"  Restart Count:         {data['restart_count']}")
        print(f"  Parent PID:            {data.get('ppid')}")
    return 0


def cmd_schema(args: argparse.Namespace) -> int:
    """Dump JSON schema."""
    schema_file = get_schema_path()
    if not schema_file.exists():
        sys.stderr.write(f"Schema file not found at {schema_file}\n")
        return 1
    print(schema_file.read_text(encoding="utf-8").strip())
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    """Verify host kernel and procfs capabilities."""
    reader = ProcReader()
    cg_reader = CgroupV2Reader()

    print("=== Host Sensor Capabilities Verification ===")
    print(f"Procfs Root:             {reader.proc_root} (exists: {reader.proc_root.exists()})")
    print(f"Page Size:               {reader.page_size} bytes")
    print(f"Clock Ticks (SC_CLK_TCK):{reader.clk_tck} Hz")
    print(f"Cgroups v2 Root:         {cg_reader.cgroup_root} (exists: {cg_reader.cgroup_root.exists()})")

    # Probe current process
    my_pid = os.getpid()
    stat = reader.read_stat(my_pid)
    if stat is not None:
        print(f"Self-Inspection (PID {my_pid}): SUCCESS (state={stat.state}, utime={stat.utime_ticks})")
    else:
        print(f"Self-Inspection (PID {my_pid}): FAILED")
        return 1
    return 0


def cmd_hash_relative(args: argparse.Namespace) -> int:
    """Hash a file relative to a pinned root directory with TOCTOU checks."""
    limiter = RateLimiter(
        max_files_per_window=args.max_files_per_window,
        max_bytes_per_window=args.max_bytes_per_window,
        max_file_size_bytes=args.max_file_size,
    )
    hasher = BoundedArtifactHasher(
        rate_limiter=limiter,
        max_file_size_bytes=args.max_file_size,
    )
    result = hasher.hash_relative_path(
        root_dir_path=args.root_dir,
        relpath=args.relpath,
        root_id=args.root_id,
    )
    print(json.dumps(result.to_dict(), indent=2))
    return 0 if result.observation_state == "observed" else 1


def cmd_enroll(args: argparse.Namespace) -> int:
    """Execute host sensor agent enrollment against Signal Loom registration API."""
    import secrets
    import urllib.error
    import urllib.request

    client_nonce = args.client_nonce or secrets.token_urlsafe(24)
    public_key = args.public_key or "MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE"

    payload: dict[str, Any] = {
        "schema_version": "1.0.0",
        "agent_id": args.agent_id,
        "host_id": args.host_id,
        "key_id": args.key_id,
        "key_algorithm": "Ed25519",
        "public_key": public_key,
        "client_nonce": client_nonce,
        "credential_kind": "existing-mtls-identity",
        "credential_scope": "audit-upload-only",
        "credential_bootstrap": "pre-provisioned-out-of-band",
    }
    if args.tenant_id:
        payload["tenant_id"] = args.tenant_id

    raw_path = (args.enroll_path or "").strip().strip("/")
    enroll_path = f"/{raw_path}" if raw_path else "/enroll"
    base_url = (args.base_url or "").strip().rstrip("/")
    endpoint_url = f"{base_url}{enroll_path}"
    req = urllib.request.Request(
        endpoint_url,
        data=json.dumps(payload).encode("utf-8"),
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {args.token}",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=args.timeout) as resp:
            resp_bytes = resp.read()
            data = json.loads(resp_bytes.decode("utf-8")) if resp_bytes else {}

            if args.state_file:
                state_path = Path(args.state_file)
                state_path.parent.mkdir(parents=True, exist_ok=True)
                state_path.write_text(json.dumps(data, indent=2), encoding="utf-8")

            print(json.dumps(data, indent=2 if args.pretty else None, sort_keys=True))
            return 0
    except urllib.error.HTTPError as exc:
        err_body = exc.read().decode("utf-8", errors="replace")
        sys.stderr.write(f"Enrollment failed (HTTP {exc.code}): {err_body}\n")
        return 1
    except urllib.error.URLError as exc:
        sys.stderr.write(f"Enrollment failed (Network error): {exc.reason}\n")
        return 1
    except Exception as exc:
        sys.stderr.write(f"Enrollment error: {exc}\n")
        return 1


def build_parser() -> argparse.ArgumentParser:
    """Construct CLI argument parser."""
    parser = argparse.ArgumentParser(
        prog="agentmaxxing-host-sensor",
        description="AgentMaxxing Host Telemetry Sensor — Bounded Process Lifecycle Collector and Artifact Hasher",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # Collect
    p_collect = subparsers.add_parser("collect", help="Collect single process evidence event")
    p_collect.add_argument("--pid", type=int, required=True, help="Target process ID")
    p_collect.add_argument("--session-id", type=str, default=None, help="Session identifier")
    p_collect.add_argument("--sequence", type=int, default=0, help="Event sequence number")
    p_collect.add_argument("--agent-id", type=str, default="agentmaxxing-linux-001", help="Agent identifier")
    p_collect.add_argument("--host-id", type=str, default="amx-host-001", help="Host identifier")
    p_collect.add_argument("--tenant-id", type=str, default=None, help="Tenant identifier")
    p_collect.add_argument("--cgroup-dir", type=str, default=None, help="Path to cgroup v2 directory")
    p_collect.add_argument("--extended", action="store_true", help="Include extended metrics (cpu_percent, ppid)")
    p_collect.add_argument("--pretty", action="store_true", help="Pretty print JSON output")
    p_collect.set_defaults(func=cmd_collect)

    # Inspect
    p_inspect = subparsers.add_parser("inspect", help="Inspect process lifecycle metrics")
    p_inspect.add_argument("--pid", type=int, required=True, help="Target process ID")
    p_inspect.add_argument("--cgroup-dir", type=str, default=None, help="Path to cgroup v2 directory")
    p_inspect.add_argument("--json", action="store_true", help="Output in JSON format")
    p_inspect.set_defaults(func=cmd_inspect)

    # Schema
    p_schema = subparsers.add_parser("schema", help="Output telemetry JSON schema")
    p_schema.set_defaults(func=cmd_schema)

    # Verify
    p_verify = subparsers.add_parser("verify", help="Verify host sensor environment")
    p_verify.set_defaults(func=cmd_verify)

    # Hash Relative
    p_hash = subparsers.add_parser(
        "hash-relative",
        help="Hash a file relative to a pinned root directory with TOCTOU checks",
    )
    p_hash.add_argument(
        "--root-dir", required=True, help="Absolute path to approved root directory"
    )
    p_hash.add_argument(
        "--relpath", required=True, help="Relative path within the root directory"
    )
    p_hash.add_argument(
        "--root-id", default="agent-work", help="Approved root ID (e.g. agent-work, agent-output)"
    )
    p_hash.add_argument(
        "--max-file-size",
        type=int,
        default=16_777_216,
        help="Maximum permissible file size in bytes",
    )
    p_hash.add_argument(
        "--max-files-per-window",
        type=int,
        default=120,
        help="Max files permitted per 60s window",
    )
    p_hash.add_argument(
        "--max-bytes-per-window",
        type=int,
        default=67_108_864,
        help="Max bytes permitted per 60s window",
    )
    p_hash.set_defaults(func=cmd_hash_relative)

    # Enroll
    p_enroll = subparsers.add_parser(
        "enroll",
        help="Enroll host sensor agent using an operator-issued token to receive server-minted SPIFFE ID and SVID",
    )
    p_enroll.add_argument("--token", type=str, required=True, help="Operator-issued enrollment token")
    p_enroll.add_argument("--base-url", type=str, default="http://localhost:8080", help="Signal Loom base URL")
    p_enroll.add_argument("--enroll-path", type=str, default="/api/v1/external-agents/enroll", help="Enrollment endpoint path (e.g. /enroll or /api/v1/external-agents/enroll)")
    p_enroll.add_argument("--agent-id", type=str, default="agentmaxxing-linux-001", help="Agent identifier")
    p_enroll.add_argument("--host-id", type=str, default="amx-host-001", help="Host identifier")
    p_enroll.add_argument("--key-id", type=str, default="key-agentmaxxing-001", help="Agent signing key identifier")
    p_enroll.add_argument("--public-key", type=str, default=None, help="Base64url Ed25519 public key")
    p_enroll.add_argument("--client-nonce", type=str, default=None, help="Client nonce for idempotency")
    p_enroll.add_argument("--tenant-id", type=str, default=None, help="Tenant identifier")
    p_enroll.add_argument("--state-file", type=str, default=None, help="Path to persist enrollment state JSON")
    p_enroll.add_argument("--timeout", type=float, default=10.0, help="Request timeout in seconds")
    p_enroll.add_argument("--pretty", action="store_true", help="Pretty print JSON output")
    p_enroll.set_defaults(func=cmd_enroll)

    return parser


def main(argv: Optional[List[str]] = None) -> int:
    """Main CLI entry point."""
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
