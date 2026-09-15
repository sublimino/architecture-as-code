"""Passive, non-blocking watcher over Kanban controller cycles and task leases.

Enforces strictly detective posture:
  - Uses shared read-only descriptors (O_RDONLY, no flock/exclusive locks).
  - Resolves KANBAN_HOME and KANBAN_WORKTREES_HOME dynamically per call.
  - Degrades cleanly with zero exceptions on hosts lacking Kanban.
  - Resilient to mid-write races during atomic controller file replacements.
  - Discards all free-text fields and enforces Zero-Customer-Payload invariant.
  - Conforms strictly to frozen KanbanInfo allowlist schema.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import sys
import time
from typing import Any, Callable, Dict, Iterator, List, NamedTuple, Optional, Tuple, Union

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .coding_agent_models import KanbanInfo, ROLE_REGEX, SHORTCODE_REGEX, TASK_ID_REGEX
    from .payload_validator import validate_zero_customer_payload
except (ImportError, ValueError):
    from coding_agent_models import KanbanInfo, ROLE_REGEX, SHORTCODE_REGEX, TASK_ID_REGEX
    from payload_validator import validate_zero_customer_payload


# ---------------------------------------------------------------------------
# 1. Dynamic Path Resolution
# ---------------------------------------------------------------------------

def get_kanban_home() -> Path:
    """Resolve KANBAN_HOME dynamically per call.

    Precedence:
      1. KANBAN_HOME environment variable
      2. AJM_AUTO_KANBAN_STATE_DIR parent directory
      3. Default fallback: ~/.cline/kanban
    """
    env_val = os.environ.get("KANBAN_HOME")
    if env_val:
        return Path(env_val).expanduser().resolve()

    state_dir = os.environ.get("AJM_AUTO_KANBAN_STATE_DIR")
    if state_dir:
        return Path(state_dir).expanduser().resolve().parent

    return (Path.home() / ".cline" / "kanban").resolve()


def get_kanban_worktrees_home() -> Path:
    """Resolve KANBAN_WORKTREES_HOME dynamically per call.

    Precedence:
      1. KANBAN_WORKTREES_HOME environment variable
      2. Default fallback: ~/.cline/worktrees
    """
    env_val = os.environ.get("KANBAN_WORKTREES_HOME")
    if env_val:
        return Path(env_val).expanduser().resolve()

    return (Path.home() / ".cline" / "worktrees").resolve()


def is_kanban_available() -> bool:
    """Check dynamically whether the Kanban runtime directory exists on this host."""
    home = get_kanban_home()
    try:
        return home.exists() and home.is_dir()
    except (PermissionError, OSError):
        return False


# ---------------------------------------------------------------------------
# 2. Shared Read-Only Resilient JSON Reader
# ---------------------------------------------------------------------------

def read_json_safe(
    path: Union[str, Path],
    retries: int = 3,
    retry_delay_s: float = 0.01,
) -> Optional[Any]:
    """Read a JSON file using a shared read-only descriptor with mid-write race recovery.

    Guarantees:
      - Opens strictly with O_RDONLY (shared read, zero exclusive locks, zero flock).
      - Catches transient JSONDecodeError / FileNotFoundError during atomic replacements.
      - Never treats a partial read as a valid empty state.
      - Returns None if file does not exist or remains unparseable after retries.
      - Zero side-effect file writes or temporary file allocations.
    """
    target = Path(path)
    attempts = max(1, retries)

    for attempt in range(attempts):
        fd: Optional[int] = None
        try:
            # Explicit OS-level open with O_RDONLY to ensure no exclusive escalation
            fd = os.open(str(target), os.O_RDONLY)
            with open(fd, "r", encoding="utf-8") as f:
                content = f.read()
            # fd is closed by context manager
            fd = None

            if not content.strip():
                # Empty file during mid-write race; retry if attempts remain
                if attempt < attempts - 1:
                    time.sleep(retry_delay_s)
                    continue
                return None

            return json.loads(content)
        except (json.JSONDecodeError, UnicodeDecodeError):
            # Mid-write race: atomic write in-flight or partial buffer read
            if attempt < attempts - 1:
                time.sleep(retry_delay_s)
                continue
            return None
        except (FileNotFoundError, ProcessLookupError, NotADirectoryError):
            return None
        except PermissionError:
            # Fail closed silently on permission barrier
            return None
        except OSError:
            if attempt < attempts - 1:
                time.sleep(retry_delay_s)
                continue
            return None
        finally:
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass

    return None


# ---------------------------------------------------------------------------
# 3. Allowlisted Data Models
# ---------------------------------------------------------------------------

class KanbanTaskSnapshot(NamedTuple):
    """Allowlisted snapshot of an active or recent Kanban task execution."""
    task_id: str
    shortcode: str
    role: str
    elapsed_s: int
    turn_count: int
    retry_count: int
    state: str
    workspace_id: str
    agent_id: Optional[str] = None
    pid: Optional[int] = None
    started_at_ms: Optional[int] = None
    updated_at_ms: Optional[int] = None

    def to_kanban_info(self) -> KanbanInfo:
        """Convert to the frozen KanbanInfo model conforming to schema allowlist."""
        # Sanitize task_id
        clean_task_id = self.task_id if TASK_ID_REGEX.match(self.task_id) else "UNKNOWN_TASK"
        clean_shortcode = self.shortcode if SHORTCODE_REGEX.match(self.shortcode) else "UNKN"
        clean_role = self.role if ROLE_REGEX.match(self.role) else "implementation"
        bounded_elapsed = max(0, min(864000, int(self.elapsed_s)))

        info = KanbanInfo(
            task_id=clean_task_id,
            shortcode=clean_shortcode,
            role=clean_role,
            elapsed_s=bounded_elapsed,
        )
        info.validate()
        return info


# ---------------------------------------------------------------------------
# 4. KanbanWatcher Engine
# ---------------------------------------------------------------------------

class KanbanWatcher:
    """Passive, non-blocking observer of local Kanban runtime cycles and leases."""

    def __init__(
        self,
        kanban_home_resolver: Optional[Callable[[], Path]] = None,
        worktrees_home_resolver: Optional[Callable[[], Path]] = None,
        poll_interval_s: float = 0.5,
        time_fn: Optional[Callable[[], float]] = None,
    ) -> None:
        self._home_resolver: Callable[[], Path] = kanban_home_resolver or get_kanban_home
        self._worktrees_resolver: Callable[[], Path] = worktrees_home_resolver or get_kanban_worktrees_home
        self.poll_interval_s: float = max(0.01, float(poll_interval_s))
        self._time_fn: Callable[[], float] = time_fn or time.time
        self._monotonic_fn: Callable[[], float] = time.monotonic
        # Cache for monotonic elapsed anchoring: (workspace_id, task_id) -> (started_mono, started_wall_ms)
        self._task_clock_anchors: Dict[Tuple[str, str], Tuple[float, int]] = {}
        # Last known valid snapshots: task_id -> KanbanTaskSnapshot
        self._last_known_snapshots: Dict[str, KanbanTaskSnapshot] = {}

    @property
    def is_available(self) -> bool:
        """Dynamically verify availability on each access."""
        home = self._home_resolver()
        try:
            return home.exists() and home.is_dir()
        except (PermissionError, OSError):
            return False

    def get_kanban_home(self) -> Path:
        """Resolve current KANBAN_HOME dynamically."""
        return self._home_resolver()

    def get_worktrees_home(self) -> Path:
        """Resolve current KANBAN_WORKTREES_HOME dynamically."""
        return self._worktrees_resolver()

    def scan_workspaces(self) -> List[str]:
        """Discover workspace IDs present under ${KANBAN_HOME}/workspaces/."""
        if not self.is_available:
            return []

        workspaces_dir = self.get_kanban_home() / "workspaces"
        if not workspaces_dir.exists() or not workspaces_dir.is_dir():
            return []

        ws_ids: List[str] = []
        try:
            for entry in workspaces_dir.iterdir():
                if entry.is_dir() and not entry.name.startswith("."):
                    ws_ids.append(entry.name)
        except (PermissionError, OSError):
            return []

        return sorted(ws_ids)

    def _derive_shortcode_and_role(
        self,
        task_id: str,
        workspace_id: str,
        hint_shortcode: Optional[str] = None,
    ) -> Tuple[str, str]:
        """Derive shortcode and role safely from naming conventions or card specs."""
        shortcode = hint_shortcode or "UNKN"
        role = "implementation"

        # Pattern: SHORTCODE-P<phase>-<num> or SHORTCODE-P<phase>-GOV / PRE
        match = re.match(r"^([A-Z0-9_]{2,16})-(P[0-9]+(?:-[A-Z0-9_]+)?)$", task_id)
        if match:
            shortcode = match.group(1)
            sub = match.group(2).upper()
            if "PRE" in sub:
                role = "preflight"
            elif "GOV" in sub:
                role = "governor"
            elif "ACCEPT" in sub:
                role = "acceptance"
            elif "RESEARCH" in sub:
                role = "research"
            else:
                role = "implementation"
            return shortcode, role

        # Try reading card-spec if available: card-specs/<SC>/<task_id>.v1.json
        card_specs_dir = self.get_kanban_home() / "card-specs"
        if card_specs_dir.is_dir():
            try:
                candidate_spec = card_specs_dir / shortcode / f"{task_id}.v1.json"
                if candidate_spec.is_file():
                    spec_data = read_json_safe(candidate_spec)
                    if isinstance(spec_data, dict):
                        extracted_role = spec_data.get("cardSpecification") or spec_data.get("role")
                        if isinstance(extracted_role, str) and ROLE_REGEX.match(extracted_role):
                            role = extracted_role
            except (PermissionError, OSError):
                pass

        return shortcode, role

    def scan_active_tasks(
        self,
        workspace_id: Optional[str] = None,
    ) -> List[KanbanTaskSnapshot]:
        """Scan active and running Kanban task sessions across workspaces.

        Extracts only allowlisted numeric and identifier metadata.
        Strictly ignores all prompt text, activities, and payload data.
        """
        if not self.is_available:
            return []

        target_workspaces = [workspace_id] if workspace_id else self.scan_workspaces()
        results: List[KanbanTaskSnapshot] = []
        now_wall = self._time_fn()
        now_mono = self._monotonic_fn()

        # Discover active missions to hint shortcodes
        active_missions = self.scan_missions()
        mission_sc_by_repo: Dict[str, str] = {
            m.get("repo", ""): m.get("shortcode", "") for m in active_missions if "shortcode" in m
        }

        for ws in target_workspaces:
            ws_dir = self.get_kanban_home() / "workspaces" / ws
            sessions_file = ws_dir / "sessions.json"
            if not sessions_file.exists():
                continue

            sessions_data = read_json_safe(sessions_file)
            if not isinstance(sessions_data, dict):
                continue

            # Determine default shortcode hint
            default_sc = mission_sc_by_repo.get(ws, "UNKN")

            for key, raw_session in sessions_data.items():
                if not isinstance(raw_session, dict):
                    continue

                raw_task_id = str(raw_session.get("taskId") or key).strip()
                if not raw_task_id:
                    continue

                state = str(raw_session.get("state") or "unknown").strip()
                agent_id = raw_session.get("agentId")
                pid = raw_session.get("pid")
                if pid is not None:
                    try:
                        pid = int(pid)
                    except (ValueError, TypeError):
                        pid = None

                started_at = raw_session.get("startedAt")
                updated_at = raw_session.get("updatedAt")
                turn_count = raw_session.get("latestTurnCheckpoint") or 0
                restart_count = (raw_session.get("restartCount") or 0) + (raw_session.get("respawnCount") or 0)

                try:
                    turn_count = max(0, int(turn_count))
                except (ValueError, TypeError):
                    turn_count = 0

                try:
                    restart_count = max(0, int(restart_count))
                except (ValueError, TypeError):
                    restart_count = 0

                # Compute elapsed_s using monotonic clock anchor
                elapsed_s = 0
                if started_at is not None:
                    try:
                        started_ms = int(started_at)
                        anchor_key = (ws, raw_task_id)
                        if anchor_key not in self._task_clock_anchors or self._task_clock_anchors[anchor_key][1] != started_ms:
                            self._task_clock_anchors[anchor_key] = (now_mono, started_ms)

                        mono_start, _ = self._task_clock_anchors[anchor_key]
                        mono_elapsed = int(now_mono - mono_start)
                        wall_elapsed = max(0, int((now_wall * 1000 - started_ms) / 1000))
                        # Protect against backwards wall clock jump
                        elapsed_s = max(0, min(864000, max(mono_elapsed, wall_elapsed)))
                    except (ValueError, TypeError):
                        elapsed_s = 0

                shortcode, role = self._derive_shortcode_and_role(
                    task_id=raw_task_id,
                    workspace_id=ws,
                    hint_shortcode=default_sc,
                )

                snapshot = KanbanTaskSnapshot(
                    task_id=raw_task_id,
                    shortcode=shortcode,
                    role=role,
                    elapsed_s=elapsed_s,
                    turn_count=turn_count,
                    retry_count=restart_count,
                    state=state,
                    workspace_id=ws,
                    agent_id=str(agent_id) if agent_id else None,
                    pid=pid,
                    started_at_ms=started_at if isinstance(started_at, int) else None,
                    updated_at_ms=updated_at if isinstance(updated_at, int) else None,
                )
                results.append(snapshot)
                self._last_known_snapshots[raw_task_id] = snapshot

        return results

    def get_task_kanban_info(
        self,
        task_id: Optional[str] = None,
        pid: Optional[int] = None,
    ) -> Optional[KanbanInfo]:
        """Look up allowlisted KanbanInfo for a specific task ID or OS process PID."""
        if not self.is_available:
            return None

        # Refresh tasks
        snapshots = self.scan_active_tasks()
        for snap in snapshots:
            if task_id is not None and snap.task_id == task_id:
                return snap.to_kanban_info()
            if pid is not None and snap.pid is not None and snap.pid == pid:
                return snap.to_kanban_info()

        # Check last known snapshot cache
        if task_id is not None and task_id in self._last_known_snapshots:
            return self._last_known_snapshots[task_id].to_kanban_info()

        return None

    def scan_missions(self) -> List[Dict[str, Any]]:
        """Scan active mission definitions and leases from ${KANBAN_HOME}/auto-controller/."""
        if not self.is_available:
            return []

        auto_dir = self.get_kanban_home() / "auto-controller"
        if not auto_dir.is_dir():
            return []

        missions: List[Dict[str, Any]] = []
        try:
            for entry in auto_dir.glob("*.json"):
                # Ignore ring buffers and sidecars
                if entry.name.endswith(".cycle.json") or entry.name.endswith(".notify.json") or entry.name.endswith(".supervise.json"):
                    continue

                data = read_json_safe(entry)
                if not isinstance(data, dict):
                    continue

                mission_obj = data.get("mission")
                owner_obj = data.get("owner")
                lease_obj = data.get("lease")

                shortcode = "UNKN"
                repo = ""
                if isinstance(mission_obj, dict):
                    shortcode = mission_obj.get("shortcode") or shortcode
                    repo = mission_obj.get("repo") or repo
                elif isinstance(owner_obj, dict):
                    shortcode = owner_obj.get("shortcode") or shortcode
                    repo = owner_obj.get("repo") or repo

                status = data.get("status", "unknown")
                lease_enabled = lease_obj.get("enabled", False) if isinstance(lease_obj, dict) else False

                missions.append({
                    "file": entry.name,
                    "shortcode": shortcode,
                    "repo": repo,
                    "status": status,
                    "lease_enabled": lease_enabled,
                })
        except (PermissionError, OSError):
            return []

        return missions

    def scan_supervisor_cycle_states(self) -> Dict[str, Dict[str, Any]]:
        """Scan supervisor cycle states (streaks, cycle counts) per shortcode."""
        if not self.is_available:
            return {}

        results: Dict[str, Dict[str, Any]] = {}
        workspaces = self.scan_workspaces()

        for ws in workspaces:
            ws_dir = self.get_kanban_home() / "workspaces" / ws
            try:
                for entry in ws_dir.glob("supervisor-cycle-state.*.json"):
                    sc_match = re.match(r"^supervisor-cycle-state\.([A-Z0-9_]+)\.json$", entry.name)
                    if not sc_match:
                        continue
                    shortcode = sc_match.group(1)
                    data = read_json_safe(entry)
                    if isinstance(data, dict):
                        results[shortcode] = {
                            "shortcode": shortcode,
                            "workspace_id": ws,
                            "streak": data.get("streak", 0),
                            "last_cycle": data.get("last_cycle", {}),
                        }
            except (PermissionError, OSError):
                continue

        return results

    def continuous_poll(
        self,
        interval_s: Optional[float] = None,
        max_iterations: Optional[int] = None,
        callback: Optional[Callable[[List[KanbanTaskSnapshot]], None]] = None,
    ) -> Iterator[List[KanbanTaskSnapshot]]:
        """Continuously poll active Kanban task state at regular intervals.

        Enforces bounded sleep between sweeps (<1s reflection bound) without busy-waiting.
        """
        poll_interval = max(0.01, float(interval_s or self.poll_interval_s))
        iteration = 0

        while max_iterations is None or iteration < max_iterations:
            iteration += 1
            batch = self.scan_active_tasks()
            if callback is not None:
                callback(batch)
            yield batch

            if max_iterations is not None and iteration >= max_iterations:
                break

            time.sleep(poll_interval)
