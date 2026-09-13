"""Command-line interface for the AgentMaxxing host process telemetry collector."""
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
    from .models import BoundedProcessAttributes, ExportSource, ProcessTelemetryEvent
    from .proc import ProcReader
    from .sensor import HostSensor
except (ImportError, ValueError):
    from cgroups import CgroupV2Reader
    from collector import ProcessTelemetryCollector
    from models import BoundedProcessAttributes, ExportSource, ProcessTelemetryEvent
    from proc import ProcReader
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


def build_parser() -> argparse.ArgumentParser:
    """Construct CLI argument parser."""
    parser = argparse.ArgumentParser(
        prog="agentmaxxing-host-sensor",
        description="AgentMaxxing Host Telemetry Sensor — Bounded Process Lifecycle Collector",
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

    return parser


def main(argv: Optional[List[str]] = None) -> int:
    """Main CLI entry point."""
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
