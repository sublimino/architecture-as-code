"""Passive, non-blocking Kanban cycle telemetry extractor with monotonic clock-skew defense.

Extracts task ID, role, shortcode, turn count, retry count, and elapsed time from
live Kanban controller storage layers (sessions.json, kanban.sqlite, auto-controller cycle ring,
and supervisor state) using shared read-only descriptors (O_RDONLY, SQLite WAL mode=ro).

Guarantees:
  1. Strictly Detective Posture: zero locks (no flock, no proper-lockfile), zero writes.
  2. Absolute Zero-Customer-Payload: excludes prompt text, command activity, and summaries.
  3. Monotonic Clock-Skew Defense: derives elapsed_s from monotonic cycle bookkeeping,
     records monotonic anchors (sequence and monotonic nanoseconds), and clamps/flags
     backwards local clock jumps.
  4. Monotonic Non-Decreasing Sequence: enforces turn_count and retry_count invariants.
  5. Dynamic Path Resolution: resolves KANBAN_HOME and KANBAN_WORKTREES_HOME dynamically.
  6. Frozen Schema Conformance: converts observations to 4-field KanbanInfo wire model.
"""
from __future__ import annotations

import datetime
from enum import Enum
import json
import os
from pathlib import Path
import random
import re
import sqlite3
import sys
import time
from typing import Any, Callable, Dict, List, NamedTuple, Optional, Set, Tuple, Union

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .coding_agent_models import KanbanInfo, coerce_turn_count
except (ImportError, ValueError):
    try:
        from coding_agent_models import KanbanInfo, coerce_turn_count
    except (ImportError, ValueError):
        KanbanInfo = None  # type: ignore


# Validation regex matching coding_agent_models and frozen schema
TASK_ID_REGEX = re.compile(r"^[A-Z0-9_-]{1,64}$")
SHORTCODE_REGEX = re.compile(r"^[A-Z0-9]{2,16}$")
ROLE_REGEX = re.compile(r"^[a-z0-9_-]{1,32}$")

SENTINEL_CLOCK_SKEW_FLAGGED = 0
MAX_ELAPSED_S = 864000  # 10 days in seconds


def get_kanban_home() -> Path:
    """Resolve KANBAN_HOME dynamically per call.

    Order:
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

    Order:
      1. KANBAN_WORKTREES_HOME environment variable
      2. Default fallback: ~/.cline/worktrees (resolves symlink to ~/src/.worktrees)
    """
    env_val = os.environ.get("KANBAN_WORKTREES_HOME")
    if env_val:
        return Path(env_val).expanduser().resolve()

    return (Path.home() / ".cline" / "worktrees").resolve()


def is_kanban_available(kanban_home: Optional[Path] = None) -> bool:
    """Check if Kanban runtime directory is present and accessible on this host."""
    home = kanban_home or get_kanban_home()
    try:
        return home.exists() and home.is_dir()
    except (PermissionError, OSError):
        return False


def normalize_task_id(raw_task_id: Any) -> str:
    """Normalize task ID to conform to TASK_ID_REGEX (uppercase alphanumeric, hyphen, underscore)."""
    val = str(raw_task_id).strip().upper()
    cleaned = re.sub(r"[^A-Z0-9_-]", "_", val)[:64]
    return cleaned or "UNKNOWN_TASK"


def normalize_shortcode(raw_shortcode: Any, default: str = "SLCD") -> str:
    """Normalize shortcode to conform to SHORTCODE_REGEX (2-16 uppercase alphanumeric)."""
    val = str(raw_shortcode).strip().upper()
    cleaned = re.sub(r"[^A-Z0-9]", "", val)[:16]
    if len(cleaned) < 2:
        return default
    return cleaned


def normalize_role(raw_role: Any, default: str = "implementation") -> str:
    """Normalize role string to conform to ROLE_REGEX (1-32 lowercase alphanumeric, hyphen, underscore)."""
    val = str(raw_role).strip().lower()
    cleaned = re.sub(r"[^a-z0-9_-]", "_", val)[:32]
    return cleaned or default


class CycleObservationSource(str, Enum):
    """Source descriptor for cycle telemetry extraction."""
    SESSIONS_JSON = "sessions_json"
    SQLITE_TASK_RUNS = "sqlite_task_runs"
    SQLITE_SESSIONS = "sqlite_sessions"
    AUTO_CONTROLLER_CYCLE = "auto_controller_cycle"
    SUPERVISOR_STATE = "supervisor_state"
    SYNTHETIC = "synthetic"


class CycleObservation:
    """Allowlisted, monotonic-anchored cycle telemetry snapshot."""

    def __init__(
        self,
        task_id: str,
        shortcode: str,
        role: str,
        elapsed_s: int,
        turn_count: int = 0,
        retry_count: int = 0,
        state: str = "running",
        wall_clock_iso: Optional[str] = None,
        wall_clock_ts: Optional[float] = None,
        monotonic_anchor_ns: Optional[int] = None,
        monotonic_seq: int = 1,
        clock_skew_flagged: bool = False,
        turn_count_corrected: bool = False,
        retry_count_corrected: bool = False,
        source: CycleObservationSource = CycleObservationSource.SESSIONS_JSON,
        raw_start_wall_ms: Optional[int] = None,
        raw_duration_ms: Optional[int] = None,
        workspace_id: Optional[str] = None,
    ) -> None:
        self.task_id: str = normalize_task_id(task_id)
        self.shortcode: str = normalize_shortcode(shortcode)
        self.role: str = normalize_role(role)
        self.elapsed_s: int = max(0, min(int(elapsed_s), MAX_ELAPSED_S))
        self.turn_count: int = max(0, int(turn_count))
        self.retry_count: int = max(0, int(retry_count))
        self.state: str = str(state)

        now_ts = wall_clock_ts if wall_clock_ts is not None else time.time()
        self.wall_clock_ts: float = now_ts
        self.wall_clock_iso: str = (
            wall_clock_iso
            or datetime.datetime.fromtimestamp(now_ts, datetime.timezone.utc).isoformat().replace("+00:00", "Z")
        )
        self.monotonic_anchor_ns: int = (
            monotonic_anchor_ns
            if monotonic_anchor_ns is not None
            else time.monotonic_ns()
        )
        self.monotonic_seq: int = max(1, int(monotonic_seq))
        self.clock_skew_flagged: bool = bool(clock_skew_flagged)
        self.turn_count_corrected: bool = bool(turn_count_corrected)
        self.retry_count_corrected: bool = bool(retry_count_corrected)
        self.source: CycleObservationSource = source
        self.raw_start_wall_ms: Optional[int] = raw_start_wall_ms
        self.raw_duration_ms: Optional[int] = raw_duration_ms
        self.workspace_id: Optional[str] = workspace_id

        self.validate()

    def validate(self) -> None:
        """Validate all fields conform to schema constraints."""
        if not TASK_ID_REGEX.match(self.task_id):
            raise ValueError(f"Invalid task_id {self.task_id!r}")
        if not SHORTCODE_REGEX.match(self.shortcode):
            raise ValueError(f"Invalid shortcode {self.shortcode!r}")
        if not ROLE_REGEX.match(self.role):
            raise ValueError(f"Invalid role {self.role!r}")
        if self.elapsed_s < 0:
            raise ValueError(f"Negative elapsed_s {self.elapsed_s}")
        if self.turn_count < 0:
            raise ValueError(f"Negative turn_count {self.turn_count}")
        if self.retry_count < 0:
            raise ValueError(f"Negative retry_count {self.retry_count}")

    def to_kanban_info(self) -> KanbanInfo:
        """Convert to frozen 4-field KanbanInfo wire model."""
        if KanbanInfo is None:
            raise RuntimeError("KanbanInfo model not available")
        return KanbanInfo(
            task_id=self.task_id,
            shortcode=self.shortcode,
            role=self.role,
            elapsed_s=self.elapsed_s,
        )

    def to_dict(self) -> Dict[str, Any]:
        """Convert full observation with monotonic anchors to dictionary."""
        return {
            "task_id": self.task_id,
            "shortcode": self.shortcode,
            "role": self.role,
            "elapsed_s": self.elapsed_s,
            "turn_count": self.turn_count,
            "retry_count": self.retry_count,
            "state": self.state,
            "wall_clock_iso": self.wall_clock_iso,
            "wall_clock_ts": self.wall_clock_ts,
            "monotonic_anchor_ns": self.monotonic_anchor_ns,
            "monotonic_seq": self.monotonic_seq,
            "clock_skew_flagged": self.clock_skew_flagged,
            "turn_count_corrected": self.turn_count_corrected,
            "retry_count_corrected": self.retry_count_corrected,
            "source": self.source.value,
            "raw_start_wall_ms": self.raw_start_wall_ms,
            "raw_duration_ms": self.raw_duration_ms,
            "workspace_id": self.workspace_id,
        }

    def __repr__(self) -> str:
        return (
            f"CycleObservation(task_id={self.task_id!r}, shortcode={self.shortcode!r}, "
            f"role={self.role!r}, elapsed_s={self.elapsed_s}, turns={self.turn_count}, "
            f"retries={self.retry_count}, seq={self.monotonic_seq}, skew_flag={self.clock_skew_flagged})"
        )


class TaskLifecycleTracker:
    """Tracks running task lifecycle state for monotonic invariants and clock-skew detection."""

    def __init__(
        self,
        task_id: str,
        shortcode: str = "SLCD",
        role: str = "implementation",
        first_monotonic_ns: Optional[int] = None,
        first_wall_ts: Optional[float] = None,
        start_wall_ts: Optional[float] = None,
    ) -> None:
        self.task_id: str = normalize_task_id(task_id)
        self.shortcode: str = normalize_shortcode(shortcode)
        self.role: str = normalize_role(role)

        now_mono = first_monotonic_ns if first_monotonic_ns is not None else time.monotonic_ns()
        now_wall = first_wall_ts if first_wall_ts is not None else time.time()

        self.first_monotonic_ns: int = now_mono
        self.last_monotonic_ns: int = now_mono
        self.start_wall_ts: Optional[float] = start_wall_ts
        self.first_wall_ts: float = now_wall
        self.last_wall_ts: float = now_wall

        self.last_turn_count: int = 0
        self.last_retry_count: int = 0
        self.last_elapsed_s: int = 0
        self.seq_counter: int = 0
        self.skew_events_count: int = 0
        self.is_skewed: bool = False

    def update_cycle(
        self,
        incoming_turn_count: int,
        incoming_retry_count: int,
        start_wall_ms: Optional[int] = None,
        explicit_duration_ms: Optional[int] = None,
        state: str = "running",
        now_wall_ts: Optional[float] = None,
        now_monotonic_ns: Optional[int] = None,
        source: CycleObservationSource = CycleObservationSource.SESSIONS_JSON,
        workspace_id: Optional[str] = None,
    ) -> CycleObservation:
        """Update tracker state with new cycle sample and return validated CycleObservation."""
        self.seq_counter += 1
        seq = self.seq_counter

        wall_now = now_wall_ts if now_wall_ts is not None else time.time()
        mono_now = now_monotonic_ns if now_monotonic_ns is not None else time.monotonic_ns()

        # Update start wall timestamp if provided
        if start_wall_ms is not None:
            # Handle milliseconds vs seconds
            s_ts = start_wall_ms / 1000.0 if start_wall_ms > 10_000_000_000 else float(start_wall_ms)
            if self.start_wall_ts is None:
                self.start_wall_ts = s_ts

        # 1. Monotonic non-decreasing turn_count enforcement
        turn_count_corrected = False
        if incoming_turn_count < self.last_turn_count:
            turn_count = self.last_turn_count
            turn_count_corrected = True
        else:
            turn_count = max(0, incoming_turn_count)
            self.last_turn_count = turn_count

        # 2. Monotonic non-decreasing retry_count enforcement
        retry_count_corrected = False
        if incoming_retry_count < self.last_retry_count:
            retry_count = self.last_retry_count
            retry_count_corrected = True
        else:
            retry_count = max(0, incoming_retry_count)
            self.last_retry_count = retry_count

        # 3. Clock Skew Detection and Sound Elapsed Time Derivation
        clock_skew_flagged = False

        # Detect backwards wall clock jump
        backwards_jump = (wall_now < self.last_wall_ts) or (
            self.start_wall_ts is not None and wall_now < self.start_wall_ts
        )

        if backwards_jump:
            clock_skew_flagged = True
            self.skew_events_count += 1
            self.is_skewed = True

        if explicit_duration_ms is not None and explicit_duration_ms >= 0:
            # Source controller provided duration from its own monotonic bookkeeping
            derived_elapsed = int(explicit_duration_ms / 1000)
        else:
            # Derive elapsed time using monotonic anchor
            mono_delta_s = max(0.0, (mono_now - self.first_monotonic_ns) / 1_000_000_000.0)

            # Initial offset between start time and first observation
            initial_offset_s = 0.0
            if self.start_wall_ts is not None and self.first_wall_ts >= self.start_wall_ts:
                initial_offset_s = max(0.0, self.first_wall_ts - self.start_wall_ts)

            monotonic_elapsed_s = int(initial_offset_s + mono_delta_s)

            if backwards_jump:
                # Local wall clock jumped backwards; anchor to monotonic progression
                derived_elapsed = max(self.last_elapsed_s, monotonic_elapsed_s)
            else:
                # Normal progression
                if self.start_wall_ts is not None:
                    wall_elapsed_s = int(max(0.0, wall_now - self.start_wall_ts))
                    # Check for severe forward divergence between wall and monotonic (>5s delta)
                    if abs(wall_elapsed_s - monotonic_elapsed_s) > 5.0 and mono_delta_s > 0:
                        clock_skew_flagged = True
                        self.is_skewed = True
                        derived_elapsed = max(self.last_elapsed_s, monotonic_elapsed_s)
                    else:
                        derived_elapsed = max(self.last_elapsed_s, wall_elapsed_s)
                else:
                    derived_elapsed = max(self.last_elapsed_s, monotonic_elapsed_s)

        # Enforce non-decreasing elapsed_s across observations within same task lifetime
        elapsed_s = max(self.last_elapsed_s, max(0, derived_elapsed))
        self.last_elapsed_s = elapsed_s
        self.last_wall_ts = wall_now
        self.last_monotonic_ns = mono_now

        return CycleObservation(
            task_id=self.task_id,
            shortcode=self.shortcode,
            role=self.role,
            elapsed_s=elapsed_s,
            turn_count=turn_count,
            retry_count=retry_count,
            state=state,
            wall_clock_ts=wall_now,
            monotonic_anchor_ns=mono_now,
            monotonic_seq=seq,
            clock_skew_flagged=clock_skew_flagged or self.is_skewed,
            turn_count_corrected=turn_count_corrected,
            retry_count_corrected=retry_count_corrected,
            source=source,
            raw_start_wall_ms=start_wall_ms,
            raw_duration_ms=explicit_duration_ms,
            workspace_id=workspace_id,
        )


class KanbanCycleExtractor:
    """Extracts cycle telemetry from live Kanban controller storage files with zero locks."""

    def __init__(
        self,
        kanban_home: Optional[Path] = None,
        clock_fn: Optional[Callable[[], float]] = None,
        monotonic_fn: Optional[Callable[[], int]] = None,
    ) -> None:
        self._custom_kanban_home: Optional[Path] = kanban_home
        self._clock_fn: Callable[[], float] = clock_fn or time.time
        self._monotonic_fn: Callable[[], int] = monotonic_fn or time.monotonic_ns
        self._trackers: Dict[str, TaskLifecycleTracker] = {}
        self._card_spec_cache: Dict[Tuple[str, str], Tuple[str, str]] = {}
        self._metadata_resolution_cache: Dict[Tuple[str, Optional[str], str, str], Tuple[str, str]] = {}

    @property
    def kanban_home(self) -> Path:
        """Resolve current kanban home dynamically."""
        if self._custom_kanban_home is not None:
            return self._custom_kanban_home
        return get_kanban_home()

    def reset_trackers(self) -> None:
        """Clear all active in-memory task trackers."""
        self._trackers.clear()
        self._card_spec_cache.clear()
        self._metadata_resolution_cache.clear()

    def get_tracker(
        self,
        task_id: str,
        shortcode: str = "SLCD",
        role: str = "implementation",
        start_wall_ts: Optional[float] = None,
    ) -> TaskLifecycleTracker:
        """Retrieve or initialize lifecycle tracker for task ID."""
        clean_id = normalize_task_id(task_id)
        if clean_id not in self._trackers:
            now_wall = self._clock_fn()
            now_mono = self._monotonic_fn()
            self._trackers[clean_id] = TaskLifecycleTracker(
                task_id=clean_id,
                shortcode=shortcode,
                role=role,
                first_monotonic_ns=now_mono,
                first_wall_ts=now_wall,
                start_wall_ts=start_wall_ts,
            )
        return self._trackers[clean_id]

    def resolve_card_metadata(
        self,
        raw_task_id: str,
        workspace_path: Optional[str] = None,
        default_shortcode: str = "SLCD",
        default_role: str = "implementation",
    ) -> Tuple[str, str]:
        """Resolve shortcode and role for a task ID from card-specs or identifier patterns."""
        clean_task_id = str(raw_task_id).strip()
        res_cache_key = (clean_task_id, workspace_path, default_shortcode, default_role)
        if res_cache_key in self._metadata_resolution_cache:
            return self._metadata_resolution_cache[res_cache_key]

        # 1. Check if task_id has explicit shortcode prefix (e.g. SLCD-P3-2)
        match = re.match(r"^([A-Z0-9]{2,16})-([A-Z0-9_\-\.]+)$", clean_task_id, re.IGNORECASE)
        if match:
            sc = match.group(1).upper()
            lid = match.group(2).upper()
            cache_key = (sc, lid)
            if cache_key in self._card_spec_cache:
                self._metadata_resolution_cache[res_cache_key] = self._card_spec_cache[cache_key]
                return self._card_spec_cache[cache_key]

            # Try to read card specification
            spec_file = self.kanban_home / "card-specs" / sc / f"{lid}.v1.json"
            if spec_file.exists():
                data = self.safe_read_json(spec_file)
                if data and "cardSpecification" in data:
                    card_spec = data["cardSpecification"]
                    extracted_role = card_spec.get("role", default_role)
                    result = (sc, normalize_role(extracted_role))
                    self._card_spec_cache[cache_key] = result
                    self._metadata_resolution_cache[res_cache_key] = result
                    return result
            result = (sc, default_role)
            self._metadata_resolution_cache[res_cache_key] = result
            return result

        # 2. Check auto-controller leases or mission metadata in kanban_home
        auto_controller_dir = self.kanban_home / "auto-controller"
        if auto_controller_dir.exists():
            for f in auto_controller_dir.glob("*-*.json"):
                if f.name.endswith(".cycle.json") or f.name.endswith(".notify.json") or f.name.endswith(".supervise.json"):
                    continue
                sc_match = re.search(r"-([A-Z0-9]{2,16})\.json$", f.name)
                if sc_match:
                    detected_sc = sc_match.group(1)
                    # Check card specs under detected shortcode
                    card_spec_file = self.kanban_home / "card-specs" / detected_sc / f"{clean_task_id}.v1.json"
                    if card_spec_file.exists():
                        data = self.safe_read_json(card_spec_file)
                        if data and "cardSpecification" in data:
                            extracted_role = data["cardSpecification"].get("role", default_role)
                            result = (detected_sc, normalize_role(extracted_role))
                            self._metadata_resolution_cache[res_cache_key] = result
                            return result
                    result = (detected_sc, default_role)
                    self._metadata_resolution_cache[res_cache_key] = result
                    return result

        result = (normalize_shortcode(default_shortcode), normalize_role(default_role))
        self._metadata_resolution_cache[res_cache_key] = result
        return result

    def safe_read_json(
        self,
        file_path: Path,
        max_retries: int = 3,
        retry_delay_s: float = 0.02,
    ) -> Optional[Dict[str, Any]]:
        """Read JSON file with shared read descriptor (O_RDONLY) and transient race retry.

        Never acquires flock or exclusive locks. Zero file mutations.
        """
        if not file_path.exists():
            return None

        for attempt in range(max_retries):
            try:
                # Open strictly read-only
                with open(file_path, "r", encoding="utf-8") as f:
                    content = f.read()
                if not content.strip():
                    if attempt < max_retries - 1:
                        time.sleep(retry_delay_s + random.uniform(0.005, 0.015))
                        continue
                    return None
                return json.loads(content)
            except json.JSONDecodeError:
                # Transient partial read during atomic swap
                if attempt < max_retries - 1:
                    time.sleep(retry_delay_s + random.uniform(0.005, 0.015))
                    continue
                return None
            except (PermissionError, FileNotFoundError, OSError):
                return None
        return None

    def safe_query_sqlite_ro(
        self,
        query: str,
        params: Tuple[Any, ...] = (),
        db_path: Optional[Path] = None,
    ) -> List[Tuple[Any, ...]]:
        """Query SQLite database in read-only mode with WAL isolation."""
        target_db = db_path or (self.kanban_home / "kanban.sqlite")
        if not target_db.exists():
            return []

        uri_path = f"file:{target_db.resolve()}?mode=ro"
        try:
            conn = sqlite3.connect(uri_path, uri=True, timeout=1.0)
            try:
                cur = conn.cursor()
                cur.execute("PRAGMA query_only = ON;")
                cur.execute(query, params)
                return cur.fetchall()
            finally:
                conn.close()
        except sqlite3.Error:
            return []

    def extract_from_session_dict(
        self,
        session_data: Dict[str, Any],
        shortcode: Optional[str] = None,
        role: Optional[str] = None,
        workspace_id: Optional[str] = None,
        now_wall_ts: Optional[float] = None,
        now_monotonic_ns: Optional[int] = None,
    ) -> CycleObservation:
        """Extract cycle telemetry from a single session dictionary with clock-skew guard.

        Zero-Customer-Payload guarantee: strictly ignores prompt, latestHookActivity, and free text.
        """
        raw_task_id = session_data.get("taskId") or session_data.get("task_id") or "UNKNOWN"
        task_id = normalize_task_id(raw_task_id)

        ws_path = session_data.get("workspacePath")
        sc = shortcode
        r = role
        if sc is None or r is None:
            resolved_sc, resolved_role = self.resolve_card_metadata(raw_task_id, ws_path)
            sc = sc or resolved_sc
            r = r or resolved_role

        start_wall_ms = session_data.get("startedAt") or session_data.get("started_at")
        # The live controller writes latestTurnCheckpoint as an object; test
        # fixtures write a bare int. coerce_turn_count() reads only the allowlisted
        # integer key and never stringifies. See SLCD-P3-GOV.
        raw_turn = session_data.get("latestTurnCheckpoint")
        if raw_turn is None or raw_turn == 0:
            raw_turn = session_data.get("tool_calls_count")
        turn_count = coerce_turn_count(raw_turn)
        restart_count = int(session_data.get("restartCount") or 0)
        respawn_count = int(session_data.get("respawnCount") or 0)
        retry_count = restart_count + respawn_count
        state = str(session_data.get("state", "running"))

        tracker = self.get_tracker(task_id, shortcode=sc, role=r)

        return tracker.update_cycle(
            incoming_turn_count=turn_count,
            incoming_retry_count=retry_count,
            start_wall_ms=int(start_wall_ms) if start_wall_ms else None,
            state=state,
            now_wall_ts=now_wall_ts or self._clock_fn(),
            now_monotonic_ns=now_monotonic_ns or self._monotonic_fn(),
            source=CycleObservationSource.SESSIONS_JSON,
            workspace_id=workspace_id,
        )

    def extract_from_task_run_dict(
        self,
        task_run: Dict[str, Any],
        shortcode: Optional[str] = None,
        role: Optional[str] = None,
        now_wall_ts: Optional[float] = None,
        now_monotonic_ns: Optional[int] = None,
    ) -> CycleObservation:
        """Extract cycle telemetry from task_runs record (from SQLite or runs/ JSON)."""
        raw_task_id = task_run.get("task_id") or task_run.get("taskId") or "UNKNOWN"
        task_id = normalize_task_id(raw_task_id)

        sc = shortcode
        r = role
        if sc is None or r is None:
            resolved_sc, resolved_role = self.resolve_card_metadata(raw_task_id)
            sc = sc or resolved_sc
            r = r or resolved_role

        start_wall_ms = task_run.get("started_at") or task_run.get("startedAt")
        duration_ms = task_run.get("duration_ms")
        turn_count = int(task_run.get("tool_calls_count", 0))
        restart_count = int(task_run.get("restart_count", 0))
        respawn_count = int(task_run.get("respawn_count", 0))
        retry_count = restart_count + respawn_count
        state = str(task_run.get("state", "running"))
        workspace_id = task_run.get("workspace_id")

        tracker = self.get_tracker(task_id, shortcode=sc, role=r)

        return tracker.update_cycle(
            incoming_turn_count=turn_count,
            incoming_retry_count=retry_count,
            start_wall_ms=int(start_wall_ms) if start_wall_ms else None,
            explicit_duration_ms=int(duration_ms) if duration_ms is not None else None,
            state=state,
            now_wall_ts=now_wall_ts or self._clock_fn(),
            now_monotonic_ns=now_monotonic_ns or self._monotonic_fn(),
            source=CycleObservationSource.SQLITE_TASK_RUNS,
            workspace_id=workspace_id,
        )

    def extract_active_sessions(
        self,
        workspace_id: str = "osramp-demo",
    ) -> List[CycleObservation]:
        """Extract telemetry for all active sessions in a workspace."""
        if not is_kanban_available(self.kanban_home):
            return []

        sessions_file = self.kanban_home / "workspaces" / workspace_id / "sessions.json"
        data = self.safe_read_json(sessions_file)
        if not data or not isinstance(data, dict):
            # Fallback to SQLite sessions table
            return self.extract_sessions_from_sqlite(workspace_id=workspace_id)

        observations: List[CycleObservation] = []
        for tid, sess in data.items():
            if not isinstance(sess, dict):
                continue
            obs = self.extract_from_session_dict(
                session_data=sess,
                workspace_id=workspace_id,
            )
            observations.append(obs)

        return observations

    def extract_sessions_from_sqlite(
        self,
        workspace_id: Optional[str] = None,
    ) -> List[CycleObservation]:
        """Query sessions table from kanban.sqlite with shared read-only connection."""
        if not is_kanban_available(self.kanban_home):
            return []

        query = "SELECT task_id, workspace_id, state, started_at, payload_json FROM sessions"
        params: Tuple[Any, ...] = ()
        if workspace_id:
            query += " WHERE workspace_id = ?"
            params = (workspace_id,)

        rows = self.safe_query_sqlite_ro(query, params)
        observations: List[CycleObservation] = []

        for row in rows:
            task_id, ws_id, state, started_at, payload_raw = row
            try:
                payload = json.loads(payload_raw) if payload_raw else {}
            except (json.JSONDecodeError, TypeError):
                payload = {}

            payload["taskId"] = task_id
            payload["workspace_id"] = ws_id
            payload["state"] = state
            if started_at:
                payload["startedAt"] = started_at

            obs = self.extract_from_session_dict(
                session_data=payload,
                workspace_id=ws_id,
            )
            observations.append(obs)

        return observations

    def extract_task_runs_sqlite(
        self,
        task_id: Optional[str] = None,
        limit: int = 50,
    ) -> List[CycleObservation]:
        """Query task_runs table from kanban.sqlite with strict allowlist projection.

        Excludes response_snippet, summary_json, last_activity_description.
        """
        if not is_kanban_available(self.kanban_home):
            return []

        query = (
            "SELECT task_id, workspace_id, started_at, duration_ms, state, "
            "tool_calls_count, restart_count, respawn_count "
            "FROM task_runs"
        )
        params: Tuple[Any, ...] = ()
        if task_id:
            query += " WHERE task_id = ?"
            params = (task_id,)
        query += " ORDER BY started_at DESC LIMIT ?"
        params = params + (max(1, limit),)

        rows = self.safe_query_sqlite_ro(query, params)
        observations: List[CycleObservation] = []

        for row in rows:
            tid, ws_id, started_at, duration_ms, state, tool_calls, restarts, respawns = row
            d = {
                "task_id": tid,
                "workspace_id": ws_id,
                "started_at": started_at,
                "duration_ms": duration_ms,
                "state": state,
                "tool_calls_count": tool_calls or 0,
                "restart_count": restarts or 0,
                "respawn_count": respawns or 0,
            }
            obs = self.extract_from_task_run_dict(task_run=d)
            observations.append(obs)

        return observations

    def extract_task_by_id(
        self,
        task_id: str,
        workspace_id: Optional[str] = None,
    ) -> Optional[CycleObservation]:
        """Extract live cycle telemetry for a specific task ID across storage layers."""
        clean_id = normalize_task_id(task_id)

        # 1. Try active sessions in workspace
        ws = workspace_id or "osramp-demo"
        sessions_file = self.kanban_home / "workspaces" / ws / "sessions.json"
        data = self.safe_read_json(sessions_file)
        if data and isinstance(data, dict):
            for tid, sdata in data.items():
                if normalize_task_id(tid) == clean_id and isinstance(sdata, dict):
                    return self.extract_from_session_dict(
                        session_data=sdata,
                        workspace_id=ws,
                    )

        # 2. Try SQLite task_runs
        runs = self.extract_task_runs_sqlite(task_id=clean_id, limit=1)
        if runs:
            return runs[0]

        # 3. Try SQLite sessions
        sessions = self.extract_sessions_from_sqlite(workspace_id=workspace_id)
        for s in sessions:
            if s.task_id == clean_id:
                return s

        return None

    def extract_cycle_ring(self, shortcode: str) -> List[Dict[str, Any]]:
        """Extract 10-tick ring buffer metrics from auto-controller."""
        if not is_kanban_available(self.kanban_home):
            return []

        sc = normalize_shortcode(shortcode)
        auto_dir = self.kanban_home / "auto-controller"
        if not auto_dir.exists():
            return []

        for f in auto_dir.glob(f"*-{sc}.cycle.json"):
            data = self.safe_read_json(f)
            if data and "ticks" in data and isinstance(data["ticks"], list):
                # Return allowlisted metrics only
                return [
                    {
                        "ts": t.get("ts"),
                        "verdict": t.get("verdict"),
                        "exceptionCount": t.get("exceptionCount", 0),
                        "tickElapsedMs": t.get("tickElapsedMs", 0),
                        "counts": t.get("counts", {}),
                    }
                    for t in data["ticks"]
                    if isinstance(t, dict)
                ]
        return []

    def extract_supervisor_state(
        self,
        shortcode: str,
        workspace_id: str = "osramp-demo",
    ) -> Optional[Dict[str, Any]]:
        """Extract cycle streak and last cycle stats from supervisor state."""
        if not is_kanban_available(self.kanban_home):
            return None

        sc = normalize_shortcode(shortcode)
        state_file = self.kanban_home / "workspaces" / workspace_id / f"supervisor-cycle-state.{sc}.json"
        data = self.safe_read_json(state_file)
        if data and isinstance(data, dict):
            return {
                "streak": data.get("streak", 0),
                "last_cycle": data.get("last_cycle", {}),
            }
        return None

    def assert_monotonic_sequence(self, task_id: str) -> None:
        """Assert that tracker invariants (monotonic turn and retry count) hold."""
        clean_id = normalize_task_id(task_id)
        if clean_id not in self._trackers:
            raise KeyError(f"No tracker registered for task {task_id}")
        tracker = self._trackers[clean_id]
        if tracker.last_turn_count < 0:
            raise AssertionError(f"Negative turn count in tracker: {tracker.last_turn_count}")
        if tracker.last_retry_count < 0:
            raise AssertionError(f"Negative retry count in tracker: {tracker.last_retry_count}")
        if tracker.last_elapsed_s < 0:
            raise AssertionError(f"Negative elapsed_s in tracker: {tracker.last_elapsed_s}")
