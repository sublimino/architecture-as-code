"""Closed, type-safe, length-bounded data models for CodingAgentTelemetry."""
from __future__ import annotations

import datetime
from enum import Enum
import hashlib
import hmac
import json
import re
import struct
from typing import Any, Dict, List, Optional, Set, Tuple, Union

try:
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    from cryptography.hazmat.primitives import hashes
    HAS_CRYPTOGRAPHY = True
except ImportError:
    HAS_CRYPTOGRAPHY = False


SCHEMA_VERSION = "1.0.0"
PSEUDONYM_DOMAIN = b"signalloom/identity/alias-pseudonym/v1"
PSEUDONYM_HEX_LEN = 64
MIN_ROOT_KEY_BYTES = 32

RFC3339_REGEX = re.compile(
    r"^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])"
    r"T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]{1,9})?"
    r"(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"
)

HARNESS_REGEX = re.compile(r"^[a-z0-9_-]{1,32}$")
SESSION_ID_REGEX = re.compile(r"^[a-f0-9]{64}$")
COMM_REGEX = re.compile(r"^[a-zA-Z0-9_.-]{1,16}$")
TASK_ID_REGEX = re.compile(r"^[A-Z0-9_-]{1,64}$")
SHORTCODE_REGEX = re.compile(r"^[A-Z0-9]{2,16}$")
ROLE_REGEX = re.compile(r"^[a-z0-9_-]{1,32}$")
INFERENCE_ENDPOINT_REGEX = re.compile(r"^[a-zA-Z0-9.-]{1,128}$")
ENTITY_ID_REGEX = re.compile(r"^[a-z][a-z0-9-]{2,63}$")


class Harness(str, Enum):
    """Closed enum of known coding agent harnesses."""
    CLAUDE = "claude"
    ANTIGRAVITY = "antigravity"
    CODEX = "codex"
    CPAI = "cpai"
    OPENCODE = "opencode"
    HERMES = "hermes"
    AIDER = "aider"
    UNKNOWN = "unknown"


# Mapping aliases to canonical tool category keys
TOOL_ALIASES: Dict[str, str] = {
    "view_file": "view_file",
    "viewfile": "view_file",
    "read_file": "view_file",
    "readfile": "view_file",
    "read": "view_file",
    "view_image": "view_file",
    "write_to_file": "write_to_file",
    "writetofile": "write_to_file",
    "write_file": "write_to_file",
    "writefile": "write_to_file",
    "write": "write_to_file",
    "replace_file_content": "replace_file_content",
    "replacefilecontent": "replace_file_content",
    "edit_file": "replace_file_content",
    "editfile": "replace_file_content",
    "edit": "replace_file_content",
    "multiedit": "replace_file_content",
    "multi_edit": "replace_file_content",
    "run_command": "run_command",
    "runcommand": "run_command",
    "execute_command": "run_command",
    "bash": "run_command",
    "shell": "run_command",
    "exec": "run_command",
    "grep_search": "grep_search",
    "grepsearch": "grep_search",
    "search_code": "grep_search",
    "grep": "grep_search",
    "ripgrep": "grep_search",
    "rg": "grep_search",
    "find_by_name": "find_by_name",
    "findbyname": "find_by_name",
    "glob": "find_by_name",
    "find": "find_by_name",
    "fd": "find_by_name",
    "list_files": "find_by_name",
    "list_dir": "list_dir",
    "listdir": "list_dir",
    "list_directory": "list_dir",
    "ls": "list_dir",
    "read_url_content": "read_url_content",
    "readurlcontent": "read_url_content",
    "fetch_web": "read_url_content",
    "web_fetch": "read_url_content",
    "webfetch": "read_url_content",
    "search_web": "search_web",
    "searchweb": "search_web",
    "web_search": "search_web",
    "websearch": "search_web",
    "invoke_subagent": "invoke_subagent",
    "invokesubagent": "invoke_subagent",
    "spawn_agent": "invoke_subagent",
    "agent": "invoke_subagent",
    "subagent": "invoke_subagent",
    "send_message": "send_message",
    "sendmessage": "send_message",
    "message_agent": "send_message",
    "msg": "send_message",
    "manage_task": "manage_task",
    "managetask": "manage_task",
    "task_status": "manage_task",
    "kill_task": "manage_task",
    "ask_question": "ask_question",
    "askquestion": "ask_question",
    "ask_user": "ask_question",
    "question": "ask_question",
}

CANONICAL_TOOL_KEYS: List[str] = [
    "view_file",
    "write_to_file",
    "replace_file_content",
    "run_command",
    "grep_search",
    "find_by_name",
    "list_dir",
    "read_url_content",
    "search_web",
    "invoke_subagent",
    "send_message",
    "manage_task",
    "ask_question",
    "other_count",
]


def normalize_tool_name(raw_name: str) -> str:
    """Normalize raw tool names to one of the 13 canonical categories or other_count.

    Customer-defined MCP tools (e.g. mcp__server__tool) and unrecognised names
    are strictly routed to 'other_count' to prevent schema key expansion.
    """
    cleaned = str(raw_name).strip().lower()
    return TOOL_ALIASES.get(cleaned, "other_count")


class ToolCounts:
    """Fixed-arity tool execution counters with overflow bucket.

    Guarantees no customer MCP tool names can expand the schema.
    """

    def __init__(
        self,
        view_file: int = 0,
        write_to_file: int = 0,
        replace_file_content: int = 0,
        run_command: int = 0,
        grep_search: int = 0,
        find_by_name: int = 0,
        list_dir: int = 0,
        read_url_content: int = 0,
        search_web: int = 0,
        invoke_subagent: int = 0,
        send_message: int = 0,
        manage_task: int = 0,
        ask_question: int = 0,
        other_count: int = 0,
    ) -> None:
        self.view_file = int(view_file)
        self.write_to_file = int(write_to_file)
        self.replace_file_content = int(replace_file_content)
        self.run_command = int(run_command)
        self.grep_search = int(grep_search)
        self.find_by_name = int(find_by_name)
        self.list_dir = int(list_dir)
        self.read_url_content = int(read_url_content)
        self.search_web = int(search_web)
        self.invoke_subagent = int(invoke_subagent)
        self.send_message = int(send_message)
        self.manage_task = int(manage_task)
        self.ask_question = int(ask_question)
        self.other_count = int(other_count)
        self.validate()

    def record_tool(self, raw_name: str, count: int = 1) -> None:
        """Record one or more tool invocations, mapping unknown/MCP tools to other_count."""
        canonical = normalize_tool_name(raw_name)
        curr = getattr(self, canonical, 0)
        setattr(self, canonical, curr + count)

    def validate(self) -> None:
        for key in CANONICAL_TOOL_KEYS:
            val = getattr(self, key, 0)
            if not isinstance(val, int) or val < 0 or val > 9007199254740991:
                raise ValueError(f"Tool count {key} out of bounds: {val}")

    def to_dict(self) -> Dict[str, int]:
        return {key: getattr(self, key, 0) for key in CANONICAL_TOOL_KEYS}

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "ToolCounts":
        known_kwargs = {}
        other_acc = int(data.get("other_count", 0))
        for k, v in data.items():
            if k in CANONICAL_TOOL_KEYS and k != "other_count":
                known_kwargs[k] = int(v)
            elif k != "other_count":
                norm = normalize_tool_name(k)
                if norm == "other_count":
                    other_acc += int(v)
                else:
                    known_kwargs[norm] = known_kwargs.get(norm, 0) + int(v)
        known_kwargs["other_count"] = other_acc
        return cls(**known_kwargs)

    def __eq__(self, other: Any) -> bool:
        if not isinstance(other, ToolCounts):
            return False
        return self.to_dict() == other.to_dict()


class ProcessInfo:
    """Allowlisted process metrics from procfs."""

    def __init__(
        self,
        pid: int,
        ppid: int,
        comm: str,
        rss_bytes: int,
        cpu_ticks: int,
    ) -> None:
        self.pid = int(pid)
        self.ppid = int(ppid)
        self.comm = str(comm)
        self.rss_bytes = int(rss_bytes)
        self.cpu_ticks = int(cpu_ticks)
        self.validate()

    def validate(self) -> None:
        if not (1 <= self.pid <= 4194304):
            raise ValueError(f"process.pid out of bounds [1, 4194304]: {self.pid}")
        if not (0 <= self.ppid <= 4194304):
            raise ValueError(f"process.ppid out of bounds [0, 4194304]: {self.ppid}")
        if not (1 <= len(self.comm) <= 16) or not COMM_REGEX.match(self.comm):
            raise ValueError(f"process.comm invalid (length {len(self.comm)}, pattern {COMM_REGEX.pattern}): {self.comm!r}")
        if not (0 <= self.rss_bytes <= 9007199254740991):
            raise ValueError(f"process.rss_bytes out of bounds: {self.rss_bytes}")
        if not (0 <= self.cpu_ticks <= 9007199254740991):
            raise ValueError(f"process.cpu_ticks out of bounds: {self.cpu_ticks}")

    def to_dict(self) -> Dict[str, Any]:
        return {
            "pid": self.pid,
            "ppid": self.ppid,
            "comm": self.comm,
            "rss_bytes": self.rss_bytes,
            "cpu_ticks": self.cpu_ticks,
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "ProcessInfo":
        return cls(
            pid=data["pid"],
            ppid=data["ppid"],
            comm=data["comm"],
            rss_bytes=data["rss_bytes"],
            cpu_ticks=data["cpu_ticks"],
        )


class KanbanInfo:
    """Non-intrusive kanban task execution metadata."""

    def __init__(
        self,
        task_id: str,
        shortcode: str,
        role: str,
        elapsed_s: int,
    ) -> None:
        self.task_id = str(task_id)
        self.shortcode = str(shortcode)
        self.role = str(role)
        self.elapsed_s = int(elapsed_s)
        self.validate()

    def validate(self) -> None:
        if not (1 <= len(self.task_id) <= 64) or not TASK_ID_REGEX.match(self.task_id):
            raise ValueError(f"kanban.task_id invalid (length {len(self.task_id)}, pattern {TASK_ID_REGEX.pattern}): {self.task_id!r}")
        if not (2 <= len(self.shortcode) <= 16) or not SHORTCODE_REGEX.match(self.shortcode):
            raise ValueError(f"kanban.shortcode invalid (length {len(self.shortcode)}, pattern {SHORTCODE_REGEX.pattern}): {self.shortcode!r}")
        if not (1 <= len(self.role) <= 32) or not ROLE_REGEX.match(self.role):
            raise ValueError(f"kanban.role invalid (length {len(self.role)}, pattern {ROLE_REGEX.pattern}): {self.role!r}")
        if not (0 <= self.elapsed_s <= 9007199254740991):
            raise ValueError(f"kanban.elapsed_s out of bounds: {self.elapsed_s}")

    def to_dict(self) -> Dict[str, Any]:
        return {
            "task_id": self.task_id,
            "shortcode": self.shortcode,
            "role": self.role,
            "elapsed_s": self.elapsed_s,
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "KanbanInfo":
        return cls(
            task_id=data["task_id"],
            shortcode=data["shortcode"],
            role=data["role"],
            elapsed_s=data["elapsed_s"],
        )


class MetricsInfo:
    """Session metrics and fixed-arity tool invocation counts.

    tokens_in and tokens_out are 64-bit integers to support long-running sessions.
    """

    def __init__(
        self,
        step_count: int,
        tokens_in: int,
        tokens_out: int,
        tool_counts: Union[ToolCounts, Dict[str, Any]],
    ) -> None:
        self.step_count = int(step_count)
        self.tokens_in = int(tokens_in)
        self.tokens_out = int(tokens_out)
        if isinstance(tool_counts, ToolCounts):
            self.tool_counts = tool_counts
        elif isinstance(tool_counts, dict):
            self.tool_counts = ToolCounts.from_dict(tool_counts)
        else:
            raise TypeError(f"Invalid tool_counts type: {type(tool_counts)}")
        self.validate()

    def validate(self) -> None:
        if not (0 <= self.step_count <= 9007199254740991):
            raise ValueError(f"metrics.step_count out of bounds: {self.step_count}")
        if not (0 <= self.tokens_in <= 9007199254740991):
            raise ValueError(f"metrics.tokens_in out of bounds: {self.tokens_in}")
        if not (0 <= self.tokens_out <= 9007199254740991):
            raise ValueError(f"metrics.tokens_out out of bounds: {self.tokens_out}")
        self.tool_counts.validate()

    def to_dict(self) -> Dict[str, Any]:
        return {
            "step_count": self.step_count,
            "tokens_in": self.tokens_in,
            "tokens_out": self.tokens_out,
            "tool_counts": self.tool_counts.to_dict(),
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "MetricsInfo":
        return cls(
            step_count=data["step_count"],
            tokens_in=data["tokens_in"],
            tokens_out=data["tokens_out"],
            tool_counts=data["tool_counts"],
        )


class NetworkInfo:
    """Outbound model egress endpoint and bytes."""

    def __init__(
        self,
        inference_endpoint: str,
        egress_bytes: int,
    ) -> None:
        self.inference_endpoint = str(inference_endpoint)
        self.egress_bytes = int(egress_bytes)
        self.validate()

    def validate(self) -> None:
        if not (1 <= len(self.inference_endpoint) <= 128) or not INFERENCE_ENDPOINT_REGEX.match(self.inference_endpoint):
            raise ValueError(
                f"network.inference_endpoint invalid (length {len(self.inference_endpoint)}, pattern {INFERENCE_ENDPOINT_REGEX.pattern}): {self.inference_endpoint!r}"
            )
        if not (0 <= self.egress_bytes <= 9007199254740991):
            raise ValueError(f"network.egress_bytes out of bounds: {self.egress_bytes}")

    def to_dict(self) -> Dict[str, Any]:
        return {
            "inference_endpoint": self.inference_endpoint,
            "egress_bytes": self.egress_bytes,
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "NetworkInfo":
        return cls(
            inference_endpoint=data["inference_endpoint"],
            egress_bytes=data["egress_bytes"],
        )


def derive_session_pseudonym(
    root_key: bytes,
    epoch: int,
    tenant_id: str,
    raw_session_id: str,
) -> str:
    """Derive deterministic, tenant-and-epoch scoped pseudonym for session_id.

    Byte-for-byte matches Go pseudonym.KeyRing.Pseudonym().
    """
    if len(root_key) < MIN_ROOT_KEY_BYTES:
        raise ValueError(f"Pseudonym root key must be at least {MIN_ROOT_KEY_BYTES} bytes")
    if not tenant_id:
        raise ValueError("tenant_id is required")
    if not raw_session_id:
        raise ValueError("raw_session_id is required")

    tenant_bytes = tenant_id.encode("utf-8")
    info = (
        struct.pack(">I", len(PSEUDONYM_DOMAIN))
        + PSEUDONYM_DOMAIN
        + struct.pack(">I", int(epoch))
        + struct.pack(">I", len(tenant_bytes))
        + tenant_bytes
    )

    if HAS_CRYPTOGRAPHY:
        hkdf = HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=info)
        tenant_key = hkdf.derive(root_key)
    else:
        # Standard RFC 5869 HKDF-SHA256 fallback
        prk = hmac.new(b"\x00" * 32, root_key, hashlib.sha256).digest()
        t = hmac.new(prk, info + b"\x01", hashlib.sha256).digest()
        tenant_key = t[:32]

    mac = hmac.new(tenant_key, raw_session_id.encode("utf-8"), hashlib.sha256)
    return mac.hexdigest()


class CodingAgentTelemetry:
    """Canonical allowlisted event envelope for coding agent detective telemetry."""

    def __init__(
        self,
        harness: Union[Harness, str],
        session_id: str,
        timestamp: Union[str, datetime.datetime],
        process: Union[ProcessInfo, Dict[str, Any]],
        kanban: Union[KanbanInfo, Dict[str, Any]],
        metrics: Union[MetricsInfo, Dict[str, Any]],
        network: Union[NetworkInfo, Dict[str, Any]],
        schema_version: str = SCHEMA_VERSION,
        observed_at: Optional[Union[str, datetime.datetime]] = None,
        tenant_id: Optional[str] = None,
        agent_id: Optional[str] = None,
        host_id: Optional[str] = None,
    ) -> None:
        self.schema_version = str(schema_version)

        # Harness validation & conversion
        if isinstance(harness, str):
            if len(harness) > 32 or not HARNESS_REGEX.match(harness):
                raise ValueError(f"harness length {len(harness)} exceeds maximum 32 or invalid pattern: {harness!r}")
            try:
                self.harness = Harness(harness)
            except ValueError:
                raise ValueError(f"harness {harness!r} is not in allowlisted Harness enum")
        elif isinstance(harness, Harness):
            self.harness = harness
        else:
            raise TypeError(f"Invalid harness type: {type(harness)}")

        self.session_id = str(session_id)

        if isinstance(timestamp, datetime.datetime):
            if timestamp.tzinfo is None:
                timestamp = timestamp.replace(tzinfo=datetime.timezone.utc)
            self.timestamp = timestamp.isoformat()
        else:
            self.timestamp = str(timestamp)

        if observed_at is not None:
            if isinstance(observed_at, datetime.datetime):
                if observed_at.tzinfo is None:
                    observed_at = observed_at.replace(tzinfo=datetime.timezone.utc)
                self.observed_at = observed_at.isoformat()
            else:
                self.observed_at = str(observed_at)
        else:
            self.observed_at = None

        self.tenant_id = str(tenant_id) if tenant_id is not None else None
        self.agent_id = str(agent_id) if agent_id is not None else None
        self.host_id = str(host_id) if host_id is not None else None

        if isinstance(process, ProcessInfo):
            self.process = process
        elif isinstance(process, dict):
            self.process = ProcessInfo.from_dict(process)
        else:
            raise TypeError(f"Invalid process type: {type(process)}")

        if isinstance(kanban, KanbanInfo):
            self.kanban = kanban
        elif isinstance(kanban, dict):
            self.kanban = KanbanInfo.from_dict(kanban)
        else:
            raise TypeError(f"Invalid kanban type: {type(kanban)}")

        if isinstance(metrics, MetricsInfo):
            self.metrics = metrics
        elif isinstance(metrics, dict):
            self.metrics = MetricsInfo.from_dict(metrics)
        else:
            raise TypeError(f"Invalid metrics type: {type(metrics)}")

        if isinstance(network, NetworkInfo):
            self.network = network
        elif isinstance(network, dict):
            self.network = NetworkInfo.from_dict(network)
        else:
            raise TypeError(f"Invalid network type: {type(network)}")

        self.validate()

    def validate(self) -> None:
        """Strict validation of all envelope constraints. Fails closed on any violation."""
        if self.schema_version != SCHEMA_VERSION:
            raise ValueError(f"schema_version must be {SCHEMA_VERSION!r}, got {self.schema_version!r}")

        if not isinstance(self.harness, Harness):
            raise ValueError(f"harness must be instance of Harness enum: {self.harness!r}")

        if len(self.session_id) != PSEUDONYM_HEX_LEN or not SESSION_ID_REGEX.match(self.session_id):
            raise ValueError(
                f"session_id must be exactly {PSEUDONYM_HEX_LEN} lowercase hex characters, got length {len(self.session_id)}: {self.session_id!r}"
            )

        ts = self.timestamp or self.observed_at
        if not ts or not RFC3339_REGEX.match(ts):
            raise ValueError(f"timestamp must be valid RFC3339 date-time, got {ts!r}")

        if self.tenant_id is not None and not ENTITY_ID_REGEX.match(self.tenant_id):
            raise ValueError(f"Invalid tenant_id: {self.tenant_id!r}")
        if self.agent_id is not None and not ENTITY_ID_REGEX.match(self.agent_id):
            raise ValueError(f"Invalid agent_id: {self.agent_id!r}")
        if self.host_id is not None and not ENTITY_ID_REGEX.match(self.host_id):
            raise ValueError(f"Invalid host_id: {self.host_id!r}")

        self.process.validate()
        self.kanban.validate()
        self.metrics.validate()
        self.network.validate()

    def to_dict(self) -> Dict[str, Any]:
        data: Dict[str, Any] = {
            "schema_version": self.schema_version,
            "harness": self.harness.value,
            "session_id": self.session_id,
            "timestamp": self.timestamp,
            "process": self.process.to_dict(),
            "kanban": self.kanban.to_dict(),
            "metrics": self.metrics.to_dict(),
            "network": self.network.to_dict(),
        }
        if self.observed_at is not None:
            data["observed_at"] = self.observed_at
        if self.tenant_id is not None:
            data["tenant_id"] = self.tenant_id
        if self.agent_id is not None:
            data["agent_id"] = self.agent_id
        if self.host_id is not None:
            data["host_id"] = self.host_id
        return data

    def to_json(self, indent: Optional[int] = None) -> str:
        return json.dumps(self.to_dict(), indent=indent, sort_keys=True)

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "CodingAgentTelemetry":
        return cls(
            schema_version=data.get("schema_version", SCHEMA_VERSION),
            harness=data["harness"],
            session_id=data["session_id"],
            timestamp=data.get("timestamp") or data.get("observed_at"),
            observed_at=data.get("observed_at"),
            tenant_id=data.get("tenant_id"),
            agent_id=data.get("agent_id"),
            host_id=data.get("host_id"),
            process=data["process"],
            kanban=data["kanban"],
            metrics=data["metrics"],
            network=data["network"],
        )
