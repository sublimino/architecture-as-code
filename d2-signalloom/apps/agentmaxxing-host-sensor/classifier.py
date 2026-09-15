"""Multi-signal harness process ancestry classifier with zero single point of trust.

Grounds coding agent attribution in empirical signatures from P2-PRE and procfs
scanner metrics from P2-1. Links child compiler/tool processes to parent coding
agents using multi-signal corroboration (comm, binary provenance via exe realpath,
session markers, protocol stubs) and race-safe ancestry tree walking.

Zero-Customer-Payload Invariant:
Never inspects command line arguments or any member of PROHIBITED_PROC_ENTRIES.
All classifications are confidence-scored claims conforming to codingagent.v1.
"""
from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
import os
from pathlib import Path
import re
import sys
from typing import (
    TYPE_CHECKING,
    Any,
    Callable,
    Dict,
    List,
    NamedTuple,
    Optional,
    Protocol,
    Set,
    Tuple,
    Union,
)

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .coding_agent_models import Harness
    from .proc import PROHIBITED_PROC_ENTRIES, ProcReader, ProcStat
except (ImportError, ValueError):
    from coding_agent_models import Harness
    from proc import PROHIBITED_PROC_ENTRIES, ProcReader, ProcStat

if TYPE_CHECKING:
    try:
        from .collector import ScannedProcess
    except (ImportError, ValueError):
        from collector import ScannedProcess


@dataclass(frozen=True)
class HarnessSignature:
    """Ground-truth empirical signature definition for a known coding agent harness."""
    harness: Harness
    primary_comms: Tuple[str, ...]
    secondary_comms: Tuple[str, ...]
    exe_basenames: Tuple[str, ...]
    exe_path_patterns: Tuple[str, ...]
    requires_secondary_corroboration: bool = False
    session_marker_patterns: Tuple[str, ...] = ()


# Empirical signatures database derived from P2-PRE host ground truth
HARNESS_SIGNATURES: Tuple[HarnessSignature, ...] = (
    HarnessSignature(
        harness=Harness.CLAUDE,
        primary_comms=("claude",),
        secondary_comms=(),
        exe_basenames=("claude",),
        exe_path_patterns=(
            r"(^|/)(claude|claude-[0-9.]+)(/|$)",
            r"\.local/share/claude/versions/",
            r"\.local/bin/claude",
            r"/usr/local/bin/claude",
            r"/opt/claude/claude",
        ),
        requires_secondary_corroboration=False,
        session_marker_patterns=(r"\.claude/projects/",),
    ),
    HarnessSignature(
        harness=Harness.ANTIGRAVITY,
        primary_comms=("agy",),
        secondary_comms=(),
        exe_basenames=("agy", "antigravity"),
        exe_path_patterns=(
            r"(^|/)(agy|antigravity)(/|$)",
            r"\.gemini/antigravity-cli/",
            r"\.local/bin/agy",
            r"/usr/local/bin/agy",
            r"/opt/agy/agy",
        ),
        requires_secondary_corroboration=False,
        session_marker_patterns=(r"\.gemini/antigravity-cli/brain/",),
    ),
    HarnessSignature(
        harness=Harness.CODEX,
        primary_comms=("node", "node-MainThread", "codex"),
        secondary_comms=("bun",),
        exe_basenames=("node", "codex", "bun"),
        exe_path_patterns=(
            r"(^|/)codex(\.js)?(/|$)",
            r"@openai/codex",
            r"\.codex/",
            r"\.local/bin/codex",
        ),
        requires_secondary_corroboration=True,
        session_marker_patterns=(r"\.codex/sessions/",),
    ),
    HarnessSignature(
        harness=Harness.CPAI,
        primary_comms=("cpai-launcher", "cpai"),
        secondary_comms=(),
        exe_basenames=("cpai-launcher", "cpai"),
        exe_path_patterns=(
            r"(^|/)(cpai-launcher|cpai)(/|$)",
            r"cpai-cli/cmd/cpai",
            r"\.local/bin/cpai",
        ),
        requires_secondary_corroboration=False,
        session_marker_patterns=(r"\.local/share/cpai",),
    ),
    HarnessSignature(
        harness=Harness.OPENCODE,
        primary_comms=("opencode",),
        secondary_comms=(),
        exe_basenames=("opencode",),
        exe_path_patterns=(
            r"(^|/)opencode(/|$)",
            r"\.opencode/bin/",
        ),
        requires_secondary_corroboration=False,
        session_marker_patterns=(r"\.local/share/opencode/opencode\.db",),
    ),
    HarnessSignature(
        harness=Harness.HERMES,
        primary_comms=("hermes",),
        secondary_comms=("node", "node-MainThread"),
        exe_basenames=("hermes", "node"),
        exe_path_patterns=(
            r"(^|/)hermes(/|$)",
            r"\.hermes/node/bin/node",
            r"\.local/bin/hermes",
        ),
        requires_secondary_corroboration=False,
        session_marker_patterns=(r"\.hermes/sessions",),
    ),
    HarnessSignature(
        harness=Harness.AIDER,
        primary_comms=("aider",),
        secondary_comms=("python", "python3"),
        exe_basenames=("aider", "python", "python3"),
        exe_path_patterns=(
            r"(^|/)aider(/|$)",
            r"site-packages/aider",
        ),
        requires_secondary_corroboration=True,
        session_marker_patterns=(r"\.aider\.chat\.history\.md",),
    ),
)


class ProtocolCorroborator(Protocol):
    """Interface for observable protocol / network socket corroboration (stub for P4-2)."""

    def corroborate_socket(self, pid: int, harness: Harness) -> Optional[bool]:
        """Return True if corroborated, False if contradicted, None if unobserved/neutral."""
        ...


class NullProtocolCorroborator:
    """Default protocol corroborator stub returning None (unobserved).

    Never returns True so that the classifier does NOT prematurely assume
    socket corroboration before P4-2 lands.
    """

    def corroborate_socket(self, pid: int, harness: Harness) -> Optional[bool]:
        return None


class SessionMarkerCorroborator:
    """Checks presence of local session stores or configuration markers."""

    def __init__(self, home_dir: Optional[Union[str, Path]] = None) -> None:
        self.home_dir = Path(home_dir) if home_dir else Path.home()

    def check_session_marker(self, harness: Harness, pid: Optional[int] = None) -> bool:
        """Check if known session markers exist on disk for the harness."""
        try:
            if harness == Harness.CODEX:
                return (self.home_dir / ".codex").exists() or (self.home_dir / ".codex" / "sessions").exists()
            elif harness == Harness.CLAUDE:
                return (self.home_dir / ".claude").exists()
            elif harness == Harness.ANTIGRAVITY:
                return (self.home_dir / ".gemini" / "antigravity-cli").exists()
            elif harness == Harness.CPAI:
                return (self.home_dir / ".local" / "share" / "cpai").exists()
            elif harness == Harness.OPENCODE:
                return (self.home_dir / ".local" / "share" / "opencode").exists() or (self.home_dir / ".opencode").exists()
            elif harness == Harness.HERMES:
                return (self.home_dir / ".hermes").exists()
            return False
        except (PermissionError, OSError):
            return False


@dataclass(frozen=True)
class ClassificationClaim:
    """Confidence-scored claim representing the result of harness ancestry classification."""
    harness: Harness
    confidence: float
    candidate_pid: int
    harness_pid: Optional[int]
    ancestry_depth: int
    corroboration_signals: Tuple[str, ...]
    reasons: Tuple[str, ...]

    def is_attributed(self, min_confidence: float = 0.5) -> bool:
        """Check if classification is confidently attributed to a known harness."""
        return self.harness != Harness.UNKNOWN and self.confidence >= min_confidence

    def to_telemetry_harness(self, min_confidence: float = 0.5) -> Harness:
        """Convert to allowlisted Harness enum for CodingAgentTelemetry."""
        if self.is_attributed(min_confidence=min_confidence):
            return self.harness
        return Harness.UNKNOWN

    def to_dict(self) -> Dict[str, Any]:
        """Convert to serializable dictionary for audit and telemetry inspection."""
        return {
            "harness": self.harness.value,
            "confidence": round(self.confidence, 4),
            "candidate_pid": self.candidate_pid,
            "harness_pid": self.harness_pid,
            "ancestry_depth": self.ancestry_depth,
            "corroboration_signals": list(self.corroboration_signals),
            "reasons": list(self.reasons),
        }


class HarnessAncestryClassifier:
    """Multi-signal harness ancestry classifier with zero single point of trust.

    Discovers whether a process is a coding agent harness or a child/descendant
    of one by traversing the process tree upward and verifying multiple corroborating
    signals at each step.
    """

    def __init__(
        self,
        proc_reader: Optional[ProcReader] = None,
        protocol_corroborator: Optional[ProtocolCorroborator] = None,
        session_corroborator: Optional[SessionMarkerCorroborator] = None,
        max_ancestry_depth: int = 32,
    ) -> None:
        self.proc_reader: ProcReader = proc_reader or ProcReader()
        self.protocol_corroborator: ProtocolCorroborator = (
            protocol_corroborator or NullProtocolCorroborator()
        )
        self.session_corroborator: SessionMarkerCorroborator = (
            session_corroborator or SessionMarkerCorroborator()
        )
        self.max_ancestry_depth: int = max(1, int(max_ancestry_depth))

    def _matches_exe_pattern(self, exe_str: str, patterns: Tuple[str, ...]) -> bool:
        """Test if executable realpath matches any signature regex pattern."""
        for pat in patterns:
            if re.search(pat, exe_str):
                return True
        return False

    def corroborate_direct_harness(
        self,
        pid: int,
        comm: str,
        exe_path: Optional[Path],
        exe_basename: Optional[str],
    ) -> Tuple[bool, Harness, float, List[str], List[str]]:
        """Evaluate if a process directly matches a known harness signature.

        Returns (is_match, harness, confidence, corroboration_signals, reasons).
        Never trusts comm name alone. If comm claims a harness but exe contradicts,
        returns (False, Harness.UNKNOWN, 0.0, ["comm_mismatch_exe_rejected"], [...]).
        """
        clean_comm = (comm or "").strip()
        exe_str = str(exe_path) if exe_path is not None else ""
        clean_exe_base = (
            exe_basename.strip()
            if exe_basename
            else (exe_path.name if exe_path else "")
        )

        for sig in HARNESS_SIGNATURES:
            # 1. Check Primary Comm Match
            if clean_comm in sig.primary_comms:
                # Primary comm matches. Now corroborate against binary provenance.
                if exe_path is not None or clean_exe_base:
                    # Check if exe path or basename supports this harness
                    exe_match = (
                        clean_exe_base in sig.exe_basenames
                        or self._matches_exe_pattern(exe_str, sig.exe_path_patterns)
                    )

                    if not exe_match:
                        # Exe is present but CONTRADICTS the claimed comm!
                        # This is a classic spoofing attack (prctl PR_SET_NAME or binary rename)
                        return (
                            False,
                            Harness.UNKNOWN,
                            0.0,
                            ["comm_mismatch_exe_rejected"],
                            [
                                f"Comm '{clean_comm}' claims harness '{sig.harness.value}' "
                                f"but exe '{exe_str or clean_exe_base}' fails binary provenance check"
                            ],
                        )

                    # Exe matches! Check if secondary corroboration is required (e.g. Codex on node)
                    if sig.requires_secondary_corroboration:
                        # Requires path pattern match or session marker
                        has_path_pattern = self._matches_exe_pattern(exe_str, sig.exe_path_patterns)
                        has_session = self.session_corroborator.check_session_marker(sig.harness, pid=pid)
                        proto_verdict = self.protocol_corroborator.corroborate_socket(pid, sig.harness)

                        if has_path_pattern or has_session or proto_verdict is True:
                            signals = ["comm_match", "exe_provenance_verified"]
                            reasons = [f"Direct match for {sig.harness.value} with binary provenance"]
                            if has_session:
                                signals.append("session_marker_verified")
                                reasons.append(f"Session marker found for {sig.harness.value}")
                            if proto_verdict is True:
                                signals.append("socket_protocol_verified")
                            return (True, sig.harness, 0.95, signals, reasons)
                        else:
                            # Generic runtime (e.g. benign node process) without codex marker
                            return (
                                False,
                                Harness.UNKNOWN,
                                0.0,
                                ["insufficient_secondary_corroboration"],
                                [f"Comm '{clean_comm}' matches {sig.harness.value} runtime but lacks session or script corroboration"],
                            )

                    # Full primary match with corroborated exe
                    return (
                        True,
                        sig.harness,
                        1.0,
                        ["comm_match", "exe_provenance_verified"],
                        [f"Direct match for {sig.harness.value} with verified exe {exe_str or clean_exe_base}"],
                    )
                else:
                    # Exe path unresolvable. Check session marker or protocol stub.
                    has_session = self.session_corroborator.check_session_marker(sig.harness, pid=pid)
                    proto_verdict = self.protocol_corroborator.corroborate_socket(pid, sig.harness)
                    if has_session or proto_verdict is True:
                        signals = ["comm_match"]
                        reasons = [f"Comm '{clean_comm}' matched {sig.harness.value}"]
                        if has_session:
                            signals.append("session_marker_verified")
                            reasons.append("Corroborated via session marker")
                        if proto_verdict is True:
                            signals.append("socket_protocol_verified")
                        return (True, sig.harness, 0.85, signals, reasons)

                    # Comm matches but NO corroborating signal is available -> Unknown
                    return (
                        False,
                        Harness.UNKNOWN,
                        0.0,
                        ["unsupported_uncorroborated_comm"],
                        [f"Comm '{clean_comm}' claims {sig.harness.value} but lacks any corroborating signal"],
                    )

            # 2. Check Secondary Comm Match (e.g. node for codex/hermes worker, python3 for aider)
            elif clean_comm in sig.secondary_comms:
                if exe_path is not None or clean_exe_base:
                    exe_match = (
                        clean_exe_base in sig.exe_basenames
                        or self._matches_exe_pattern(exe_str, sig.exe_path_patterns)
                    )
                    has_path_pattern = self._matches_exe_pattern(exe_str, sig.exe_path_patterns)
                    has_session = self.session_corroborator.check_session_marker(sig.harness, pid=pid)
                    proto_verdict = self.protocol_corroborator.corroborate_socket(pid, sig.harness)

                    if exe_match and (has_path_pattern or has_session or proto_verdict is True):
                        signals = ["secondary_comm_match", "exe_provenance_verified"]
                        reasons = [f"Secondary comm '{clean_comm}' corroborated for {sig.harness.value}"]
                        if has_session:
                            signals.append("session_marker_verified")
                        return (True, sig.harness, 0.90, signals, reasons)

        return (
            False,
            Harness.UNKNOWN,
            0.0,
            ["no_harness_signature_match"],
            ["Process does not match any known coding agent signature"],
        )

    def classify_process(
        self,
        candidate_pid: int,
        process_table: Optional[Dict[int, ScannedProcess]] = None,
        direct_stat: Optional[ProcStat] = None,
        direct_exe: Optional[Path] = None,
    ) -> ClassificationClaim:
        """Classify a candidate process and its ancestry tree.

        Walks up the ppid chain using P2-1's process table or procfs stat reads.
        Verifies generation counters (starttime_ticks) to prevent PID recycling misattribution.
        Bounds depth defensively against cycles and deep chains.
        Never inspects command line argument payloads or any prohibited procfs entry.
        """
        if candidate_pid <= 0:
            return ClassificationClaim(
                harness=Harness.UNKNOWN,
                confidence=0.0,
                candidate_pid=candidate_pid,
                harness_pid=None,
                ancestry_depth=0,
                corroboration_signals=("invalid_pid",),
                reasons=("Invalid candidate PID",),
            )

        # 1. Fetch initial candidate state
        candidate_scanned = process_table.get(candidate_pid) if process_table else None
        stat = (
            candidate_scanned.stat
            if candidate_scanned
            else (direct_stat or self.proc_reader.read_stat(candidate_pid))
        )

        if stat is None:
            return ClassificationClaim(
                harness=Harness.UNKNOWN,
                confidence=0.0,
                candidate_pid=candidate_pid,
                harness_pid=None,
                ancestry_depth=0,
                corroboration_signals=("process_not_found",),
                reasons=(f"Candidate PID {candidate_pid} not found in process table or procfs",),
            )

        exe_path = (
            direct_exe
            if direct_exe is not None
            else (
                Path(candidate_scanned.exe_basename)
                if (candidate_scanned and candidate_scanned.exe_basename)
                else self.proc_reader.read_exe(candidate_pid)
            )
        )
        exe_basename = (
            candidate_scanned.exe_basename
            if candidate_scanned
            else self.proc_reader.read_exe_basename(candidate_pid)
        )

        # 2. Check if candidate itself is directly a verified harness
        is_direct, direct_harness, direct_conf, direct_sigs, direct_reasons = (
            self.corroborate_direct_harness(
                pid=candidate_pid,
                comm=stat.comm,
                exe_path=exe_path,
                exe_basename=exe_basename,
            )
        )

        if is_direct and direct_conf >= 0.85:
            return ClassificationClaim(
                harness=direct_harness,
                confidence=direct_conf,
                candidate_pid=candidate_pid,
                harness_pid=candidate_pid,
                ancestry_depth=0,
                corroboration_signals=tuple(direct_sigs),
                reasons=tuple(direct_reasons),
            )

        # If direct check detected an active spoof or insufficient corroboration on a process without parent
        if "comm_mismatch_exe_rejected" in direct_sigs:
            return ClassificationClaim(
                harness=Harness.UNKNOWN,
                confidence=0.0,
                candidate_pid=candidate_pid,
                harness_pid=None,
                ancestry_depth=0,
                corroboration_signals=tuple(direct_sigs),
                reasons=tuple(direct_reasons),
            )

        if stat.ppid <= 1 and direct_sigs != ["no_harness_signature_match"]:
            return ClassificationClaim(
                harness=Harness.UNKNOWN,
                confidence=0.0,
                candidate_pid=candidate_pid,
                harness_pid=None,
                ancestry_depth=0,
                corroboration_signals=tuple(direct_sigs),
                reasons=tuple(direct_reasons),
            )

        # 3. Walk ancestry tree upward via ppid
        visited: Set[int] = {candidate_pid}
        current_pid = candidate_pid
        current_starttime = stat.starttime_ticks
        depth = 0

        while depth < self.max_ancestry_depth:
            # Get current process's ppid
            curr_scanned = process_table.get(current_pid) if process_table else None
            curr_stat = (
                curr_scanned.stat
                if curr_scanned
                else (stat if current_pid == candidate_pid else self.proc_reader.read_stat(current_pid))
            )

            if curr_stat is None:
                break

            parent_pid = curr_stat.ppid

            # Stop condition: reached systemd/init (PID 1) or invalid parent
            if parent_pid <= 1:
                break

            # Stop condition: cycle detected
            if parent_pid in visited:
                break
            visited.add(parent_pid)

            # Fetch parent record
            parent_scanned = process_table.get(parent_pid) if process_table else None
            parent_stat = (
                parent_scanned.stat
                if parent_scanned
                else self.proc_reader.read_stat(parent_pid)
            )

            if parent_stat is None:
                # Parent process exited mid-walk or not in table
                break

            # PID recycling race check:
            # A valid parent process MUST have started BEFORE or AT the same time as its child.
            # If parent_stat.starttime_ticks > current_starttime, this PID was recycled by the kernel!
            if parent_stat.starttime_ticks > current_starttime:
                # Race detected: parent PID was recycled to an unrelated newer process
                return ClassificationClaim(
                    harness=Harness.UNKNOWN,
                    confidence=0.0,
                    candidate_pid=candidate_pid,
                    harness_pid=None,
                    ancestry_depth=depth + 1,
                    corroboration_signals=("pid_reuse_race_detected",),
                    reasons=(
                        f"Parent PID {parent_pid} starttime ({parent_stat.starttime_ticks}) "
                        f"is newer than child starttime ({current_starttime}); PID reuse detected"
                    ,),
                )

            # Resolve parent exe for corroboration
            parent_exe = (
                Path(parent_scanned.exe_basename)
                if (parent_scanned and parent_scanned.exe_basename)
                else self.proc_reader.read_exe(parent_pid)
            )
            parent_exe_base = (
                parent_scanned.exe_basename
                if parent_scanned
                else self.proc_reader.read_exe_basename(parent_pid)
            )

            # Evaluate parent against harness signatures
            is_parent_match, p_harness, p_conf, p_sigs, p_reasons = (
                self.corroborate_direct_harness(
                    pid=parent_pid,
                    comm=parent_stat.comm,
                    exe_path=parent_exe,
                    exe_basename=parent_exe_base,
                )
            )

            if is_parent_match and p_conf >= 0.85:
                # Found corroborated harness ancestor!
                hop_count = depth + 1
                # Attenuate confidence slightly per hop, bounded to [0.70, 0.98]
                hop_confidence = max(0.70, round(p_conf - (hop_count * 0.02), 4))
                signals = [
                    "process_tree_ancestry",
                    f"ancestry_hops_{hop_count}",
                    f"ancestor_harness_pid_{parent_pid}",
                ] + p_sigs
                reasons = [
                    f"Linked child process '{stat.comm}' (PID {candidate_pid}) to ancestor harness "
                    f"'{p_harness.value}' (PID {parent_pid}) at depth {hop_count}"
                ] + p_reasons

                return ClassificationClaim(
                    harness=p_harness,
                    confidence=hop_confidence,
                    candidate_pid=candidate_pid,
                    harness_pid=parent_pid,
                    ancestry_depth=hop_count,
                    corroboration_signals=tuple(signals),
                    reasons=tuple(reasons),
                )

            # Step up to grandparent
            current_pid = parent_pid
            current_starttime = parent_stat.starttime_ticks
            depth += 1

        # No harness ancestor found in tree
        final_sigs = tuple(direct_sigs) if (depth == 0 and direct_sigs != ["no_harness_signature_match"]) else ("no_harness_ancestor_found",)
        final_reasons = tuple(direct_reasons) if (depth == 0 and direct_sigs != ["no_harness_signature_match"]) else (f"Process '{stat.comm}' (PID {candidate_pid}) has no corroborated coding agent ancestor in process tree",)

        return ClassificationClaim(
            harness=Harness.UNKNOWN,
            confidence=0.0,
            candidate_pid=candidate_pid,
            harness_pid=None,
            ancestry_depth=depth,
            corroboration_signals=final_sigs,
            reasons=final_reasons,
        )

    def classify_scanned_process(
        self,
        scanned: ScannedProcess,
        process_table: Optional[Dict[int, ScannedProcess]] = None,
    ) -> ClassificationClaim:
        """Convenience method to classify a ScannedProcess from P2-1."""
        return self.classify_process(
            candidate_pid=scanned.pid,
            process_table=process_table,
            direct_stat=scanned.stat,
        )

    def classify_batch(
        self,
        scanned_list: List[ScannedProcess],
    ) -> Dict[int, ClassificationClaim]:
        """Classify a batch of scanned processes from P2-1's scan_processes().

        Constructs a lookup table and classifies all candidate processes.
        """
        table: Dict[int, ScannedProcess] = {sp.pid: sp for sp in scanned_list}
        claims: Dict[int, ClassificationClaim] = {}
        for sp in scanned_list:
            claims[sp.pid] = self.classify_scanned_process(sp, process_table=table)
        return claims
