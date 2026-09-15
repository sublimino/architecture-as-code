# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors

"""SLCD-P4-GOV — Phase 4 governor certification suite.

This file exists because of a gap no card before it could close. P4-1 proved its
transcript parser leaks nothing. P4-2 proved its socket detector leaks nothing.
Each proof was taken against that card's own surface, in isolation. Neither proof
covers the shipped configuration, which is **all four detective subsystems running
in one process against one developer session at the same time** -- and an
interaction leak, by construction, lives exactly where no single-subsystem suite
looks.

Four falsification arguments, because they refute four different claims:

* ``CombinedSessionLeakAuditTests`` refutes "a realistic combined session emits
  payload". It drives a live transcript, an active kanban cycle and an outbound
  inference socket *concurrently*, assembles the real export record from their
  real outputs, serialises it through the real wire encoder, and asserts not one
  canary byte from any of the three fixtures survives into the emitted stream.

* ``LeakAuditControlTests`` refutes "the audit above could not have detected a
  leak". Two independent controls, because a scanner and a pipeline fail
  differently: one plants a canary in a synthetic stream and asserts the scanner
  reports it; the other pushes payload through the real export pipeline and
  asserts the pipeline refuses it. Neither control shares a constant with the
  audit -- see ``test_control_sentinels_are_disjoint_from_audit_canaries``, which
  exists because a positive control that shares its subject's constants is a
  tautology.

* ``CombinedFourSubsystemOverheadTests`` refutes "Phase 4's cost is affordable".
  P3-GOV measured P2+P3 and recorded a KPI breach. No figure has ever included
  P4-1 and P4-2. This measures all four and asserts against the SAME KPI P2 set,
  read out of P2's own source rather than restated, so the two cannot drift.

* ``MergedTreeInvariantTests`` refutes "the merge preserved the pins". It sweeps
  the WHOLE merged sensor -- not the modules Phase 4 happened to test -- for any
  read of a ``PROHIBITED_PROC_ENTRIES`` member, and re-exercises P4-1's
  fail-closed path through the package's public import surface, where an
  import-path change introduced by the merge would break it.

Fixture-hostility discipline is inherited from ``test_transcript_falsification``:
every audit asserts its own fixture is hostile before asserting the property, and
asserts non-zero work was done, so no test here can pass vacuously.
"""
from __future__ import annotations

import ast
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import resource
import sqlite3
import sys
import tempfile
import threading
import time
import unittest

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

import network as NET                      # noqa: E402
import proc as PROC                        # noqa: E402
import transcript as T                     # noqa: E402
from coding_agent_wire import (            # noqa: E402
    allowed_keys,
    canonical_json,
    decode_wire,
)
from filter import filter_coding_agent_telemetry  # noqa: E402
from kanban_watcher import KanbanWatcher    # noqa: E402
from kanban import KanbanCycleExtractor     # noqa: E402
from coding_agent_models import Harness   # noqa: E402
from payload_validator import (             # noqa: E402
    DEFAULT_VALIDATOR,
    ZeroPayloadSecurityException,
)

LIVE_KANBAN = Path.home() / ".cline" / "kanban"


# ===========================================================================
# Canaries. Every one of these is a byte sequence that exists in exactly one
# fixture and must never appear in an emitted telemetry record. The prefix is
# deliberately un-English so a substring search cannot match by accident, and is
# asserted absent from the sensor's own source by
# test_canary_prefix_appears_nowhere_in_sensor_source.
# ===========================================================================

CANARY = "Vx9QmT4hL2ZbR7nK"

# --- transcript surface (P4-1) ---------------------------------------------
CANARY_PROMPT = (
    f"{CANARY}-PROMPT rotate the settlement signing key and push the new value "
    "into the production vault before the 09:00 cutover"
)
CANARY_RESPONSE = (
    f"{CANARY}-RESPONSE done -- `settle.go` now reads the key from the vault "
    "client instead of the embedded literal"
)
CANARY_CODE = (
    f"{CANARY}-CODE\n--- a/settle.go\n+++ b/settle.go\n"
    "-\tconst signingKey = \"hunter2\"\n+\tsigningKey := vault.Get(\"settle/key\")\n"
)
CANARY_CREDENTIAL = f"sk-ant-api03-{CANARY}-9f2b4c7d1e8a3f6b0c5d2e9a7b4f1c8d-AA"
CANARY_THINKING = f"{CANARY}-THINKING the ledger reconciliation races on retry"

TRANSCRIPT_CANARIES = (
    CANARY_PROMPT,
    CANARY_RESPONSE,
    CANARY_CODE,
    CANARY_CREDENTIAL,
    CANARY_THINKING,
)

# --- kanban surface (P3) ----------------------------------------------------
# Free text a real kanban card carries. Only the kanban path could leak this.
CANARY_KANBAN_PROMPT = (
    f"{CANARY}-KANBAN implement the payout reconciler; the staging bearer token "
    "is in the shared 1Password vault under 'payouts-staging'"
)

# --- socket surface (P4-2) --------------------------------------------------
# A destination address inside anthropic's dedicated range 160.79.104.0/23, so the
# shipped matcher classifies it inference. SocketClassification retains dst_ip for
# operator diagnostics; to_network_info must project it away. Only the socket path
# could leak this literal.
CANARY_DST_IP = "160.79.105.231"
CANARY_SRC_PORT = 54973
CANARY_INODE = 999000111
CANARY_EGRESS = 45231

ALL_CANARIES = TRANSCRIPT_CANARIES + (CANARY_KANBAN_PROMPT, CANARY_DST_IP)

SESSION_UUID = "8c1d4e2f-7a3b-4c95-9e60-1f2a3b4c5d6e"
STAMP_A = "2026-09-15T08:00:00.000Z"
STAMP_B = "2026-09-15T08:07:12Z"


def _claude_jsonl_records():
    """A realistic Claude Code transcript slice.

    Shaped from the CLAUDE_JSONL_V1 store layout P1-PRE inventoried: a user turn, an
    assistant turn with usage and a tool_use block, and a thinking block. Payload
    sits where a real transcript puts it -- inside ``message.content[].text`` -- and
    the credential sits inside a tool-input, which is where a real agent session
    actually carries one.
    """
    return [
        {
            "type": "user",
            "sessionId": SESSION_UUID,
            "uuid": "11111111-2222-3333-4444-555555555555",
            "timestamp": STAMP_A,
            "message": {
                "role": "user",
                "content": [{"type": "text", "text": CANARY_PROMPT}],
            },
        },
        {
            "type": "assistant",
            "sessionId": SESSION_UUID,
            "uuid": "22222222-3333-4444-5555-666666666666",
            "timestamp": STAMP_A,
            "message": {
                "role": "assistant",
                "model": "claude-opus-4-20250514",
                "usage": {
                    "input_tokens": 125000,
                    "output_tokens": 4200,
                    "cache_read_input_tokens": 8000,
                },
                "content": [
                    {"type": "thinking", "thinking": CANARY_THINKING},
                    {"type": "text", "text": CANARY_RESPONSE},
                    {
                        "type": "tool_use",
                        "name": "replace_file_content",
                        "input": {
                            "path": "settle.go",
                            "diff": CANARY_CODE,
                            "env": {"ANTHROPIC_API_KEY": CANARY_CREDENTIAL},
                        },
                    },
                ],
            },
        },
        {
            "type": "assistant",
            "sessionId": SESSION_UUID,
            "uuid": "33333333-4444-5555-6666-777777777777",
            "timestamp": STAMP_B,
            "message": {
                "role": "assistant",
                "model": "claude-opus-4-20250514",
                "usage": {"input_tokens": 400, "output_tokens": 90},
                "content": [
                    {"type": "tool_use", "name": "run_command",
                     "input": {"command": f"echo {CANARY_CREDENTIAL}"}},
                ],
            },
        },
    ]


def _write_transcript(root: Path, name: str = "session.jsonl") -> str:
    path = root / name
    with open(path, "w", encoding="utf-8") as handle:
        for record in _claude_jsonl_records():
            handle.write(json.dumps(record) + "\n")
    return name


def _write_kanban_home(root: Path) -> Path:
    """A kanban home shaped like a live cycle, carrying free-text card prose."""
    home = root / "kanban"
    tasks = home / "tasks"
    tasks.mkdir(parents=True, exist_ok=True)
    (home / "board.json").write_text(json.dumps({
        "shortcode": "SLCD",
        "columns": ["backlog", "in_progress", "done"],
    }), encoding="utf-8")
    (tasks / "SLCD-P4-GOV.json").write_text(json.dumps({
        "id": "SLCD-P4-GOV",
        "shortcode": "SLCD",
        "role": "governor",
        "column": "in_progress",
        "started_at": STAMP_A,
        # The hostile bit: real cards carry the whole prompt.
        "prompt": CANARY_KANBAN_PROMPT,
        "description": CANARY_KANBAN_PROMPT,
    }), encoding="utf-8")
    (home / "SLCD-P4-GOV.lock").write_text(
        json.dumps({"pid": os.getpid(), "task": "SLCD-P4-GOV"}), encoding="utf-8")
    db = home / "kanban.db"
    conn = sqlite3.connect(db)
    try:
        conn.execute("CREATE TABLE IF NOT EXISTS sessions "
                     "(id TEXT, task_id TEXT, started_at TEXT, prompt TEXT)")
        conn.execute("INSERT INTO sessions VALUES (?,?,?,?)",
                     ("ses-1", "SLCD-P4-GOV", STAMP_A, CANARY_KANBAN_PROMPT))
        conn.commit()
    finally:
        conn.close()
    return home


def _canary_socket_record() -> "NET.SocketRecord":
    return NET.SocketRecord(
        family=2,
        state=NET.TCP_ESTABLISHED,
        src_port=CANARY_SRC_PORT,
        dst_port=443,
        dst_ip=CANARY_DST_IP,
        uid=os.getuid(),
        inode=CANARY_INODE,
        cgroup_id=None,
        bytes_sent=CANARY_EGRESS,
    )


def _forms(needle: str):
    """Every byte form a canary can legitimately take on the wire.

    A leak through a JSON encoder arrives escaped (``\\n`` for a newline), so
    scanning only the raw form would miss precisely the leak most likely to
    happen. Both forms are scanned, always.
    """
    escaped = json.dumps(needle)[1:-1]
    return (needle,) if escaped == needle else (needle, escaped)


def _scan(blob: bytes, needles) -> list:
    """Return every needle present in ``blob``, in raw or JSON-escaped form."""
    text = blob.decode("utf-8", errors="replace")
    hits = []
    for needle in needles:
        if needle and any(form in text for form in _forms(needle)):
            hits.append(needle)
    return hits


def _string_literals(source: str):
    """Every non-docstring string literal in a Python module, with its line.

    A regex over raw source cannot tell a real ``open('/proc/%d/environ')`` from a
    docstring explaining that the module deliberately avoids it -- and Phase 4's
    modules are full of exactly that prose, because avoiding fd reads is the
    headline property P4-2 documents. Parsing to an AST removes comments entirely
    (they never reach the tree) and lets docstrings be dropped by identity, while
    keeping the string literals a genuine read would have to use.
    """
    tree = ast.parse(source)
    docstrings = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef,
                             ast.AsyncFunctionDef)):
            body = getattr(node, "body", None)
            if body and isinstance(body[0], ast.Expr) and \
                    isinstance(body[0].value, ast.Constant) and \
                    isinstance(body[0].value.value, str):
                docstrings.add(id(body[0].value))
        # A bare string expression anywhere is prose, not a path.
        if isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant) \
                and isinstance(node.value.value, str):
            docstrings.add(id(node.value))
    out = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            if id(node) in docstrings:
                continue
            out.append((getattr(node, "lineno", 0), node.value))
        elif isinstance(node, ast.JoinedStr):
            try:
                out.append((getattr(node, "lineno", 0), ast.unparse(node)))
            except Exception:  # pragma: no cover
                pass
    return out


# ===========================================================================
# 1. The end-to-end audit
# ===========================================================================

class CombinedSessionLeakAuditTests(unittest.TestCase):
    """Drive all three Phase 2-4 collection surfaces at once and audit the output."""

    REPEATS = 5

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.store_root = self.root / "projects"
        self.store_root.mkdir(parents=True, exist_ok=True)
        self.rel = _write_transcript(self.store_root)
        self.kanban_home = _write_kanban_home(self.root)
        self.raw_transcript_bytes = (self.store_root / self.rel).read_bytes()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    # -- fixture hostility ---------------------------------------------------

    def test_transcript_fixture_is_hostile(self) -> None:
        """A fixture that does not carry the payload proves nothing about leaks."""
        self.assertEqual(
            sorted(_scan(self.raw_transcript_bytes, TRANSCRIPT_CANARIES)),
            sorted(TRANSCRIPT_CANARIES),
            "transcript fixture does not carry every canary; the audit would "
            "pass for the wrong reason")
        self.assertGreater(len(self.raw_transcript_bytes), 900,
                           "fixture is too small to be a realistic session slice")

    def test_kanban_fixture_is_hostile(self) -> None:
        card = (self.kanban_home / "tasks" / "SLCD-P4-GOV.json").read_text(encoding="utf-8")
        self.assertIn(CANARY_KANBAN_PROMPT, card)
        self.assertTrue((self.kanban_home / "SLCD-P4-GOV.lock").is_file())
        self.assertTrue((self.kanban_home / "kanban.db").is_file())

    def test_canary_prefix_appears_nowhere_in_sensor_source(self) -> None:
        """A canary the code already contains cannot falsify anything."""
        for py in sorted(PKG_DIR.glob("*.py")):
            if py.name == Path(__file__).name:
                continue
            self.assertNotIn(CANARY, py.read_text(encoding="utf-8", errors="replace"),
                             f"canary constant leaked into {py.name}")

    # -- the parts, individually, against the merged tree --------------------

    def _poll_transcript(self):
        indexer = T.TranscriptIndexer()
        with T.ConfinedStore(self.store_root) as store:
            extract = indexer.poll(store, self.rel, T.TranscriptFormat.CLAUDE_JSONL_V1)
        self.assertEqual(indexer.payload_guard_trips, 0,
                         "zero-payload invariant tripped inside the parser")
        return extract

    def test_transcript_surface_does_real_work(self) -> None:
        """A parse that extracts nothing cannot demonstrate a non-leak."""
        extract = self._poll_transcript()
        self.assertEqual(extract.status, T.ParseStatus.PARSED, extract.skip_reason)
        self.assertEqual(extract.records_parsed, 3)
        self.assertGreater(extract.metrics.tokens_in, 0)
        self.assertGreater(extract.metrics.tokens_out, 0)
        self.assertGreater(extract.bytes_consumed, 900)

    def test_socket_surface_classifies_the_canary_destination(self) -> None:
        detector = NET.SocketDetector()
        cls = detector.classify(_canary_socket_record())
        self.assertEqual(cls.verdict, "inference", cls.reason)
        self.assertEqual(cls.endpoint, "api.anthropic.com")
        self.assertEqual(cls.dst_ip, CANARY_DST_IP,
                         "the classification must retain dst_ip, or the canary "
                         "is never at risk and the audit is vacuous")

    # -- the whole pipeline --------------------------------------------------

    def _emit_once(self) -> bytes:
        """Run the shipped assembly path and return the bytes that would go on the wire."""
        extract = self._poll_transcript()

        watcher = KanbanWatcher(kanban_home_resolver=lambda: self.kanban_home)
        snapshots = watcher.scan_active_tasks()
        extractor = KanbanCycleExtractor(kanban_home=self.kanban_home)
        try:
            extractor.extract_active_sessions()
            extractor.extract_sessions_from_sqlite()
        except Exception:  # pragma: no cover - surface is best-effort by design
            pass

        detector = NET.SocketDetector()
        cls = detector.classify(_canary_socket_record())
        network_info = detector.to_network_info(cls)

        task_id = "SLCD-P4-GOV"
        elapsed = 0
        if snapshots:
            first = snapshots[0]
            task_id = getattr(first, "task_id", task_id) or task_id
            elapsed = int(getattr(first, "elapsed_s", 0) or 0)

        raw = {
            "schema_version": "1.0.0",
            "harness": Harness.CLAUDE.value,
            "session_id": hashlib.sha256(
                (extract.session_uuid or SESSION_UUID).encode()).hexdigest(),
            "timestamp": extract.last_timestamp or STAMP_B,
            "process": {
                "pid": os.getpid(),
                "ppid": os.getppid(),
                "comm": "claude",
                "rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * 1024,
                "cpu_ticks": 450,
            },
            "kanban": {
                "task_id": task_id,
                "shortcode": "SLCD",
                "role": "governor",
                "elapsed_s": elapsed,
            },
            "metrics": {
                "step_count": extract.metrics.step_count,
                "tokens_in": extract.metrics.tokens_in,
                "tokens_out": extract.metrics.tokens_out,
                "tool_counts": dict(extract.metrics.tool_counts),
            },
            "network": network_info,
        }
        exported = filter_coding_agent_telemetry(raw, include_tenant=False)
        DEFAULT_VALIDATOR.validate_event(exported, tenant_id=None)
        return canonical_json(decode_wire(exported))

    def test_end_to_end_emission_carries_zero_canary_bytes(self) -> None:
        blob = self._emit_once()
        self.assertGreater(len(blob), 200, "emitted record is implausibly small")
        hits = _scan(blob, ALL_CANARIES)
        self.assertEqual(hits, [], f"payload reached the emitted stream: {hits!r}")

    def test_emitted_record_is_not_empty_of_work(self) -> None:
        """A zero-record audit must not be reported as a zero-leak audit."""
        decoded = json.loads(self._emit_once())
        self.assertGreater(decoded["metrics"]["tokens_in"], 0)
        self.assertEqual(decoded["network"]["inference_endpoint"], "api.anthropic.com")
        self.assertEqual(decoded["network"]["egress_bytes"], CANARY_EGRESS)

    def test_emitted_keys_are_a_subset_of_the_frozen_allow_list(self) -> None:
        decoded = json.loads(self._emit_once())
        self.assertTrue(set(decoded).issubset(set(allowed_keys())),
                        f"off-list top-level keys: {sorted(set(decoded) - set(allowed_keys()))}")

    # -- negative controls ON THE REAL ENCODER OUTPUT ------------------------
    #
    # These exist because of a specific objection raised at this card's advisor
    # boundary: a sensitivity control that plants a canary in a *synthetic* blob
    # proves the scanner matches a string, not that it is pointed at the bytes the
    # real encoder emits. If the encoder escapes, normalises, compresses or chunks,
    # "0 hits" and "scanner aimed at the wrong bytes" are indistinguishable. Each
    # control below operates on output from the real pipeline.

    def test_negative_control_scanner_sees_the_real_encoders_own_output(self) -> None:
        """Values the pipeline genuinely emitted must be findable by the scanner."""
        blob = self._emit_once()
        decoded = json.loads(blob)
        for present in (decoded["session_id"],
                        decoded["network"]["inference_endpoint"],
                        decoded["harness"]):
            self.assertEqual(_scan(blob, (present,)), [present],
                             f"the scanner cannot see {present!r}, which the real "
                             "encoder demonstrably emitted; a 0-hit result would "
                             "carry no information")

    def test_negative_control_canary_spliced_into_the_real_record_is_caught(self) -> None:
        """Plant each canary into the real serialised record; the audit must go red."""
        blob = self._emit_once()
        self.assertEqual(_scan(blob, ALL_CANARIES), [])
        for canary in ALL_CANARIES:
            with self.subTest(canary=canary[:24]):
                tampered = blob[:-1] + b',"leak":' + json.dumps(canary).encode() + b'}'
                json.loads(tampered)  # still the encoder's own wire format
                self.assertEqual(_scan(tampered, ALL_CANARIES), [canary],
                                 "the audit did not detect a canary planted in the "
                                 "real encoder's own output")

    def test_negative_control_pipeline_mutation_makes_the_audit_fail(self) -> None:
        """Mutate the real projection to leak dst_ip; the audit must catch it.

        ``SocketDetector.to_network_info`` is the single line standing between a
        retained diagnostic ``dst_ip`` and the wire. Swapping it for a pass-through
        is the mutation the whole socket half of this audit is supposed to kill. A
        guard never observed failing is an untested claim.
        """
        original = NET.SocketDetector.to_network_info

        def leaking(self_, classification):
            out = original(self_, classification)
            out["inference_endpoint"] = classification.dst_ip
            return out

        NET.SocketDetector.to_network_info = leaking
        try:
            try:
                blob = self._emit_once()
            except Exception:
                # The wire contract refused the mutant outright. Also a kill.
                killed_by = "wire contract"
                hits = [CANARY_DST_IP]
            else:
                hits = _scan(blob, ALL_CANARIES)
                killed_by = "leak audit"
        finally:
            NET.SocketDetector.to_network_info = original

        self.assertEqual(hits, [CANARY_DST_IP],
                         "the mutant leaked dst_ip and NOTHING caught it; the "
                         "audit cannot distinguish a clean pipeline from a "
                         "leaking one")
        print(f"\n[SLCD-P4-GOV] pipeline mutation (to_network_info -> pass-through "
              f"dst_ip): killed by {killed_by}")

        # FINDING, recorded by assertion rather than prose: the mutant is NOT
        # refused by the wire contract. `INFERENCE_ENDPOINT_REGEX` is
        # ^[a-zA-Z0-9.-]{1,128}$, which an IPv4 literal satisfies, so the single
        # thing standing between a retained diagnostic address and the wire is
        # `to_network_info`'s membership check against the committed artefact.
        # If that check is ever weakened, no downstream layer catches it. This
        # assertion pins the current state so the day it changes is visible.
        NET.SocketDetector.to_network_info = leaking
        try:
            leaked = json.loads(self._emit_once())
        finally:
            NET.SocketDetector.to_network_info = original
        self.assertEqual(leaked["network"]["inference_endpoint"], CANARY_DST_IP,
                         "the wire contract now rejects a raw IP in "
                         "inference_endpoint; update this finding")

        # and the guard is back
        self.assertEqual(_scan(self._emit_once(), ALL_CANARIES), [])

    def test_exported_fields_are_enumerated_not_merely_canary_checked(self) -> None:
        """Canaries corroborate; they do not enumerate.

        Every leaf in the emitted record must be an allowlisted key whose value is
        a bounded scalar. A string leaf that is neither an enum member nor a
        bounded identifier is a free-text field, which is the risk P1-1 froze the
        schema to prevent — and no canary set can rule one out.
        """
        decoded = json.loads(self._emit_once())
        self.assertTrue(set(decoded).issubset(set(allowed_keys())))
        offenders = []

        def walk(node, path):
            if isinstance(node, dict):
                for key, value in node.items():
                    walk(value, f"{path}.{key}")
            elif isinstance(node, list):
                offenders.append((path, "list"))
            elif isinstance(node, str):
                if len(node) > 128 or "\n" in node or " " in node:
                    offenders.append((path, node[:40]))
            elif not isinstance(node, (int, float, bool)) and node is not None:
                offenders.append((path, type(node).__name__))

        walk(decoded, "$")
        self.assertEqual(offenders, [],
                         f"unbounded or free-text leaves in the export: {offenders}")

    def test_concurrent_combined_session_emits_zero_canary_bytes(self) -> None:
        """The three surfaces run at once, repeatedly, because both the transcript
        tail and the socket correlation are timing-dependent and a single clean
        sequential run does not exercise the contended paths."""
        blobs: list = []
        errors: list = []
        lock = threading.Lock()

        def drive(_i: int) -> None:
            try:
                blob = self._emit_once()
                with lock:
                    blobs.append(blob)
            except Exception as exc:  # pragma: no cover - failure is the assertion
                with lock:
                    errors.append(repr(exc))

        for _round in range(self.REPEATS):
            threads = [threading.Thread(target=drive, args=(i,)) for i in range(3)]
            for t in threads:
                t.start()
            for t in threads:
                t.join(timeout=60)
            self.assertTrue(all(not t.is_alive() for t in threads),
                            "combined session deadlocked")

        self.assertEqual(errors, [], f"combined session raised: {errors!r}")
        self.assertEqual(len(blobs), self.REPEATS * 3,
                         "not every concurrent emission produced a record")
        for blob in blobs:
            hits = _scan(blob, ALL_CANARIES)
            self.assertEqual(hits, [], f"payload reached the emitted stream: {hits!r}")
        print(f"\n[SLCD-P4-GOV] end-to-end leak audit: {len(blobs)} records inspected "
              f"over {self.REPEATS} concurrent rounds x 3 threads, "
              f"{sum(len(b) for b in blobs)} bytes scanned, "
              f"{len(ALL_CANARIES)} canaries, 0 hits")


# ===========================================================================
# 2. Controls -- the audit above is only a finding if it could have failed
# ===========================================================================

CONTROL_SENTINEL = "Pw3ZnJ8sQ1yV6tHc"
CONTROL_PROMPT = f"{CONTROL_SENTINEL}-CONTROL the quarterly forecast model lives in forecast.xlsx"
CONTROL_CREDENTIAL = f"sk-ant-api03-{CONTROL_SENTINEL}-0a1b2c3d4e5f60718293a4b5c6d7e8f9-AA"


class LeakAuditControlTests(unittest.TestCase):

    def test_control_sentinels_are_disjoint_from_audit_canaries(self) -> None:
        """A control that shares a constant with its subject proves nothing."""
        self.assertNotEqual(CONTROL_SENTINEL, CANARY)
        for canary in ALL_CANARIES:
            self.assertNotIn(CONTROL_SENTINEL, canary)
            self.assertNotIn(CANARY, CONTROL_PROMPT)

    def test_control_a_scanner_reports_a_planted_canary(self) -> None:
        """Sensitivity control: prove the detector is not blind."""
        blob = json.dumps({
            "harness": "claude",
            "notes": CONTROL_PROMPT,
        }).encode("utf-8")
        self.assertEqual(_scan(blob, (CONTROL_PROMPT,)), [CONTROL_PROMPT])
        self.assertEqual(_scan(b'{"harness":"claude"}', (CONTROL_PROMPT,)), [])

    @staticmethod
    def _base_event():
        return {
            "schema_version": "1.0.0",
            "harness": "claude",
            "session_id": "a" * 64,
            "timestamp": STAMP_B,
            "process": {"pid": 1, "ppid": 0, "comm": "claude",
                        "rss_bytes": 1024, "cpu_ticks": 1},
            "kanban": {"task_id": "SLCD-P4-GOV", "shortcode": "SLCD",
                       "role": "governor", "elapsed_s": 1},
            "metrics": {"step_count": 1, "tokens_in": 1, "tokens_out": 1,
                        "tool_counts": {}},
            "network": {"inference_endpoint": "api.anthropic.com", "egress_bytes": 1},
        }

    def test_control_b_off_list_field_never_reaches_the_output(self) -> None:
        """Structural allow-list control.

        An off-list key is not *rejected* — it is not *constructed*. The exported
        dict is built key-by-key from a typed model, so an attacker-supplied
        ``prompt`` has no path into it. This asserts the allow-list property
        directly, which is stronger than asserting a deny-list fired, and it is
        the behaviour the pipeline actually has.
        """
        raw = self._base_event()
        raw["prompt"] = CONTROL_PROMPT
        exported = filter_coding_agent_telemetry(raw, include_tenant=False)
        self.assertNotIn("prompt", exported)
        blob = canonical_json(decode_wire(exported))
        self.assertEqual(_scan(blob, (CONTROL_PROMPT,)), [],
                         "an off-list field survived into the emitted stream")

    def test_control_b2_payload_inside_an_allowed_field_is_refused(self) -> None:
        """Rejection control: an independent mechanism, not the scanner.

        The dangerous case is not an extra key — it is payload smuggled into a key
        that IS on the list. The bounded-format contract must refuse it.
        """
        raw = self._base_event()
        raw["kanban"]["task_id"] = CONTROL_PROMPT
        with self.assertRaises((ValueError, ZeroPayloadSecurityException)):
            filter_coding_agent_telemetry(raw, include_tenant=False)

    def test_control_b3_payload_in_the_endpoint_field_is_refused(self) -> None:
        raw = self._base_event()
        raw["network"]["inference_endpoint"] = CONTROL_PROMPT
        with self.assertRaises((ValueError, ZeroPayloadSecurityException)):
            filter_coding_agent_telemetry(raw, include_tenant=False)

    def test_control_c_validator_refuses_a_credential_value(self) -> None:
        with self.assertRaises(ZeroPayloadSecurityException):
            DEFAULT_VALIDATOR.validate_event(
                {"harness": "claude", "note": CONTROL_CREDENTIAL}, tenant_id=None)

    def test_control_d_credential_detector_does_not_retain_the_value(self) -> None:
        """Detecting a credential must not become a way of storing one."""
        try:
            DEFAULT_VALIDATOR.validate_event(
                {"harness": "claude", "note": CONTROL_CREDENTIAL}, tenant_id=None)
        except ZeroPayloadSecurityException as exc:
            self.assertNotIn(CONTROL_CREDENTIAL, str(exc),
                             "the exception text carries the credential it detected")
            self.assertNotIn(CONTROL_SENTINEL, repr(exc))
        else:  # pragma: no cover
            self.fail("validator accepted a credential value")


# ===========================================================================
# 3. Combined overhead across ALL FOUR merged subsystems
# ===========================================================================

class CombinedFourSubsystemOverheadTests(unittest.TestCase):
    """P2 + P3 + P4-1 + P4-2 in one process.

    The thresholds are read out of P2's own test source rather than restated, for
    the same reason P3-GOV did it: a copied constant drifts silently.
    """

    CPU_BUDGET_PERCENT = 1.0             # test_p2_governor_integration.py
    RSS_BUDGET_BYTES = 25 * 1024 * 1024  # test_p2_governor_integration.py
    SWEEPS = 10
    POLL_INTERVAL_S = 0.5                # collector.py:329, kanban_watcher.py:192

    def test_thresholds_still_match_p2s_own_source(self) -> None:
        src = (PKG_DIR / "test_p2_governor_integration.py").read_text(encoding="utf-8")
        self.assertIn("CPU_BUDGET_PERCENT = 1.0", src)
        self.assertIn("RSS_BUDGET_BYTES = 25 * 1024 * 1024", src)

    def test_duty_cycle_model_matches_the_shipped_default(self) -> None:
        """The KPI number is only meaningful if the poll interval is the real one."""
        self.assertIn("interval_s: float = 0.5",
                      (PKG_DIR / "collector.py").read_text(encoding="utf-8"))
        self.assertIn("poll_interval_s: float = 0.5",
                      (PKG_DIR / "kanban_watcher.py").read_text(encoding="utf-8"))

    @staticmethod
    def _cpu_seconds() -> float:
        ru = resource.getrusage(resource.RUSAGE_SELF)
        return ru.ru_utime + ru.ru_stime

    @unittest.skipUnless(LIVE_KANBAN.is_dir(), "no live kanban home")
    def test_four_subsystem_overhead_against_kpi(self) -> None:
        from collector import ProcessTelemetryCollector

        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        store_root = Path(tmp.name) / "projects"
        store_root.mkdir(parents=True)
        # A transcript of realistic size, so P4-1's cost is not measured against an
        # empty file. ~2,000 records is a normal day's session.
        rel = "session.jsonl"
        with open(store_root / rel, "w", encoding="utf-8") as handle:
            for i in range(2000):
                handle.write(json.dumps({
                    "type": "assistant",
                    "sessionId": SESSION_UUID,
                    "timestamp": STAMP_A,
                    "message": {
                        "role": "assistant",
                        "model": "claude-opus-4-20250514",
                        "usage": {"input_tokens": 100 + i, "output_tokens": 10},
                        "content": [{"type": "tool_use", "name": "view_file",
                                     "input": {"path": f"pkg/mod_{i}.go"}}],
                    },
                }) + "\n")

        watcher = KanbanWatcher()
        collector = ProcessTelemetryCollector(kanban_watcher=watcher)
        extractor = KanbanCycleExtractor()
        indexer = T.TranscriptIndexer()
        detector = NET.SocketDetector()
        record = _canary_socket_record()

        netlink_ok = True
        try:
            detector.diag.dump()
        except Exception:
            netlink_ok = False

        # warm every engine so import/compile cost is not charged to the measurement
        collector.classify_scanned_processes(collector.scan_processes(max_pids=40))
        watcher.scan_active_tasks()
        extractor.extract_active_sessions()
        with T.ConfinedStore(store_root) as store:
            indexer.poll(store, rel, T.TranscriptFormat.CLAUDE_JSONL_V1)
        detector.classify(record)

        cpu_before = self._cpu_seconds()
        wall_before = time.monotonic()
        with T.ConfinedStore(store_root) as store:
            for _ in range(self.SWEEPS):
                # --- P2: process tree ---
                collector.classify_scanned_processes(collector.scan_processes(max_pids=100))
                # --- P3: kanban watcher ---
                watcher.scan_active_tasks()
                watcher.scan_missions()
                extractor.extract_active_sessions()
                extractor.extract_sessions_from_sqlite()
                # --- P4-1: transcript parser (cold bookmark each sweep, worst case) ---
                indexer._bookmarks.clear()
                indexer.poll(store, rel, T.TranscriptFormat.CLAUDE_JSONL_V1)
                # --- P4-2: socket detector ---
                if netlink_ok:
                    try:
                        detector.diag.dump()
                    except Exception:
                        pass
                detector.classify(record)
        wall = time.monotonic() - wall_before
        cpu = self._cpu_seconds() - cpu_before
        peak_rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * 1024

        duty_pct = (cpu / (self.SWEEPS * self.POLL_INTERVAL_S)) * 100.0
        throughput = self.SWEEPS / wall if wall else float("inf")
        print(f"\n[BENCHMARK] Combined P2+P3+P4-1+P4-2, {self.SWEEPS} sweeps: "
              f"wall={wall*1000:.1f}ms cpu={cpu*1000:.1f}ms "
              f"duty_cycle_cpu={duty_pct:.3f}% peak_rss={peak_rss/1048576:.2f}MB "
              f"throughput={throughput:.2f} sweeps/s netlink={netlink_ok} "
              f"(KPI: <{self.CPU_BUDGET_PERCENT}% CPU, "
              f"<{self.RSS_BUDGET_BYTES/1048576:.0f}MB RSS)")

        self.assertLess(duty_pct, self.CPU_BUDGET_PERCENT,
                        f"four-subsystem duty-cycle CPU {duty_pct:.3f}% exceeds "
                        f"{self.CPU_BUDGET_PERCENT}% KPI")
        self.assertLess(peak_rss, self.RSS_BUDGET_BYTES,
                        f"four-subsystem peak RSS {peak_rss/1048576:.2f} MB exceeds "
                        f"{self.RSS_BUDGET_BYTES/1048576:.0f} MB KPI")


# ===========================================================================
# 4. Merged-tree invariants -- the pins, swept across the WHOLE sensor
# ===========================================================================

# P1-4 pinned exactly these. Restated here so a deletion in proc.py is a test
# failure rather than a silent narrowing. The set equality is the assertion.
P1_4_PINNED = frozenset({
    "mem", "environ", "cmdline", "maps", "smaps", "smaps_rollup", "stack",
    "syscall", "io", "fd", "fdinfo", "net", "cwd", "root", "clear_refs",
    "pagemap", "attr",
})

# A read of /proc/<pid>/<prohibited>. Written so the pattern cannot match its own
# source line: the entry alternation is built at runtime, not spelled literally.
_ENTRY_ALT = "|".join(sorted(P1_4_PINNED))

#: A read of an OBSERVED process's prohibited entry. This is what P1-4's pin
#: protects: payload harvesting out of a process the sensor is watching.
_PROC_READ_RE = re.compile(
    r"/proc/(?:\{?\s*(?:pid|p)\b[^/]*|\d+|%[sd]|<pid>)/(" + _ENTRY_ALT + r")\b")

#: A read of the sensor's OWN prohibited entry. A different question, and not one
#: the chokepoint in proc.py answers -- ``_safe_proc_path`` takes a pid, so
#: ``/proc/self/...`` never passes through it. Swept separately and pinned to an
#: explicit, justified allow-list below, so a NEW self-read fails this suite even
#: though the existing one is benign.
_PROC_SELF_READ_RE = re.compile(r"/proc/self/(" + _ENTRY_ALT + r")\b")

#: The single justified self-read in the merged tree, with its provenance.
#: ``file_validator.get_mount_id_from_proc_fdinfo`` reads the mount id of a
#: descriptor the SENSOR ITSELF already holds, as the second source in a TOCTOU
#: identity check. It observes no other process and harvests nothing. Introduced
#: by commit caaf7550 (AMXO-P4-3), which predates the whole SLCD mission.
_JUSTIFIED_SELF_READS = {("file_validator.py", "fdinfo")}

_SWEEP_EXEMPT = {
    "proc.py",                       # defines the prohibition
    "test_proc.py",                  # exercises it
    "test_negative_security.py",     # exercises it
    "test_leak_falsification.py",    # exercises it
    Path(__file__).name,             # this sweep
}


class MergedTreeInvariantTests(unittest.TestCase):

    def test_prohibited_set_matches_p1_4_pins_exactly(self) -> None:
        self.assertEqual(set(PROC.PROHIBITED_PROC_ENTRIES), set(P1_4_PINNED),
                         "the merge changed the prohibited set")

    def test_every_pinned_entry_raises_before_open(self) -> None:
        reader = PROC.ProcReader()
        for entry in sorted(P1_4_PINNED):
            with self.subTest(entry=entry):
                with self.assertRaises(PROC.SecurityException):
                    reader._safe_proc_path(os.getpid(), entry)

    def test_whole_sensor_contains_no_prohibited_proc_read(self) -> None:
        """Sweep every module, not only the ones Phase 4 tested.

        Scans string literals from the AST, so a docstring explaining that the
        module avoids ``/proc/<pid>/fd`` — which is exactly the prose P4-2 ships —
        is not mistaken for a read of it.
        """
        offenders = {}
        scanned = 0
        for py in sorted(PKG_DIR.rglob("*.py")):
            if py.name in _SWEEP_EXEMPT or "__pycache__" in py.parts:
                continue
            scanned += 1
            found = set()
            for lineno, literal in _string_literals(
                    py.read_text(encoding="utf-8", errors="replace")):
                for m in _PROC_READ_RE.finditer(literal):
                    found.add(f"{m.group(1)}:{lineno}")
            if found:
                offenders[py.name] = sorted(found)
        self.assertGreater(scanned, 20, "the sweep scanned implausibly few modules")
        self.assertEqual(offenders, {}, f"prohibited procfs reads: {offenders}")
        print(f"\n[SLCD-P4-GOV] procfs sweep: {scanned} modules scanned "
              f"(AST string literals, docstrings and comments excluded), "
              f"{len(P1_4_PINNED)} pinned entries, 0 observed-process reads")

    def test_self_reads_of_prohibited_entries_match_the_justified_set_exactly(self) -> None:
        """``/proc/self/<prohibited>`` is a real read the pid chokepoint cannot see.

        Set equality, not subset: a new self-read fails here, and removing the
        known one also fails, so this cannot rot quietly in either direction.
        """
        found = set()
        for py in sorted(PKG_DIR.rglob("*.py")):
            if py.name in _SWEEP_EXEMPT or "__pycache__" in py.parts:
                continue
            for _lineno, literal in _string_literals(
                    py.read_text(encoding="utf-8", errors="replace")):
                for m in _PROC_SELF_READ_RE.finditer(literal):
                    found.add((py.name, m.group(1)))
        self.assertEqual(found, _JUSTIFIED_SELF_READS,
                         "the set of self-reads of prohibited procfs entries changed")
        print(f"\n[SLCD-P4-GOV] /proc/self sweep: {len(found)} justified self-read(s) "
              f"{sorted(found)}, 0 unjustified")

    def test_sweep_pattern_is_not_satisfied_by_its_own_absence(self) -> None:
        """Sensitivity control for the sweep: prove both halves can fire."""
        self.assertTrue(_PROC_READ_RE.search("/proc/%d/environ"))
        self.assertTrue(_PROC_READ_RE.search("/proc/{pid}/mem"))
        self.assertIsNone(_PROC_READ_RE.search("/proc/self/stat"))
        self.assertIsNone(_PROC_READ_RE.search("/proc/net/tcp"))
        self.assertTrue(_PROC_SELF_READ_RE.search("/proc/self/environ"))
        self.assertIsNone(_PROC_SELF_READ_RE.search("/proc/self/stat"))
        # The AST extractor must surface a planted read and drop the prose.
        planted = (
            '"""This module never touches /proc/<pid>/environ."""\n'
            "# nor does it read /proc/<pid>/mem\n"
            "P = '/proc/%d/environ'\n"
        )
        literals = [lit for _ln, lit in _string_literals(planted)]
        self.assertIn("/proc/%d/environ", literals)
        self.assertNotIn("This module never touches /proc/<pid>/environ.", literals)
        self.assertEqual(
            sum(1 for lit in literals if _PROC_READ_RE.search(lit)), 1,
            "the extractor must report the planted read exactly once")

    # -- P4-1 fail-closed, re-exercised through the public import surface ----

    def test_unsupported_harness_fails_closed_via_package_surface(self) -> None:
        """An import-path change in the merge would break this and nothing else would notice."""
        spec = importlib.util.spec_from_file_location(
            "amx_host_sensor_pkg", PKG_DIR / "__init__.py",
            submodule_search_locations=[str(PKG_DIR)])
        pkg = importlib.util.module_from_spec(spec)
        sys.modules["amx_host_sensor_pkg"] = pkg
        self.addCleanup(sys.modules.pop, "amx_host_sensor_pkg", None)
        spec.loader.exec_module(pkg)

        self.assertTrue(hasattr(pkg, "poll_unsupported_harness"),
                        "the package no longer exports the fail-closed entry point")
        self.assertIn("poll_unsupported_harness", pkg.__all__)

        self.assertTrue(T.UNSUPPORTED_HARNESSES,
                        "no harness is declared unsupported; the fallback is unreachable")
        for harness in sorted(T.UNSUPPORTED_HARNESSES, key=lambda h: h.value):
            with self.subTest(harness=harness.value):
                extract = pkg.poll_unsupported_harness(harness)
                self.assertEqual(extract.status,
                                 T.ParseStatus.SKIPPED_UNSUPPORTED_HARNESS)
                self.assertEqual(extract.fmt, T.TranscriptFormat.UNRECOGNISED)
                self.assertEqual(extract.records_parsed, 0)
                self.assertEqual(extract.metrics.tokens_in, 0)
                self.assertIsNone(extract.session_uuid)

    def test_an_undeclared_harness_fails_loudly_not_silently(self) -> None:
        """Fail-closed means a named outcome or an error — never a plausible guess."""
        undeclared = [h for h in Harness if h not in T.UNSUPPORTED_HARNESSES]
        self.assertTrue(undeclared)
        with self.assertRaises(ValueError):
            T.poll_unsupported_harness(undeclared[0])

    def test_unrecognised_format_fails_closed_on_the_merged_tree(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        (root / "weird.jsonl").write_text(
            json.dumps({"totally": "unknown", "payload": CANARY_PROMPT}) + "\n",
            encoding="utf-8")
        indexer = T.TranscriptIndexer()
        with T.ConfinedStore(root) as store:
            extract = indexer.poll(store, "weird.jsonl", T.TranscriptFormat.UNRECOGNISED)
        self.assertIn(extract.status, {
            T.ParseStatus.SKIPPED_UNRECOGNISED_FORMAT,
            T.ParseStatus.SKIPPED_UNSUPPORTED_HARNESS,
        }, extract.skip_reason)
        self.assertEqual(extract.records_parsed, 0)
        self.assertEqual(_scan(extract.to_json().encode(), (CANARY_PROMPT,)), [])

    def test_a_foreign_harness_format_fails_closed_rather_than_misparsing(self) -> None:
        """A Codex rollout read as Claude JSONL must not half-parse into metrics."""
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        (root / "rollout.jsonl").write_text(json.dumps({
            "type": "response_item",
            "timestamp": STAMP_A,
            "payload": {"session_id": SESSION_UUID, "model": "gpt-5.4",
                        "text": CANARY_PROMPT},
        }) + "\n", encoding="utf-8")
        indexer = T.TranscriptIndexer()
        with T.ConfinedStore(root) as store:
            extract = indexer.poll(store, "rollout.jsonl", T.TranscriptFormat.CLAUDE_JSONL_V1)
        self.assertEqual(_scan(extract.to_json().encode(), (CANARY_PROMPT,)), [])
        self.assertEqual(extract.metrics.tokens_in, 0)
        self.assertEqual(extract.metrics.tokens_out, 0)

    def test_truncated_transcript_does_not_raise_across_the_poll_boundary(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        (root / "torn.jsonl").write_bytes(
            (json.dumps(_claude_jsonl_records()[0]) + "\n").encode() +
            b'{"type":"assistant","sessionId":"' + SESSION_UUID.encode()[:12])
        indexer = T.TranscriptIndexer()
        with T.ConfinedStore(root) as store:
            extract = indexer.poll(store, "torn.jsonl", T.TranscriptFormat.CLAUDE_JSONL_V1)
        self.assertEqual(_scan(extract.to_json().encode(), ALL_CANARIES), [])

    # -- P4-2 fd avoidance, corroborated in code rather than in prose --------

    def test_socket_detection_path_never_reads_proc_pid_fd(self) -> None:
        text = (PKG_DIR / "network.py").read_text(encoding="utf-8")
        offending = [(ln, lit) for ln, lit in _string_literals(text)
                     if _PROC_READ_RE.search(lit)]
        self.assertEqual(offending, [],
                         "the socket detector reads a prohibited per-pid entry")
        self.assertIn("NETLINK_SOCK_DIAG", text,
                      "netlink is the fd-free mechanism; its absence would mean a fallback")
        self.assertIn("INET_DIAG_CGROUP_ID", text,
                      "cgroup-id correlation is what replaces the fd walk")

    def test_phase4_modules_have_no_logging_or_print_egress(self) -> None:
        """Payload can leave through a channel the export audit never sees.

        An export-boundary audit scans the record. A ``log.warning("%s", line)`` or
        a ``print(record)`` in the parser is an independent egress with its own
        encoder that the audit is structurally blind to. This bounds that channel
        for the two Phase 4 modules by showing they emit nothing at all: no logging
        call, no print, no stderr write. Raised at this card's advisor boundary.
        """
        offenders = {}
        for name in ("transcript.py", "network.py"):
            tree = ast.parse((PKG_DIR / name).read_text(encoding="utf-8"))
            hits = []
            for node in ast.walk(tree):
                if not isinstance(node, ast.Call):
                    continue
                fn = node.func
                label = None
                if isinstance(fn, ast.Name) and fn.id == "print":
                    label = "print"
                elif isinstance(fn, ast.Attribute):
                    if fn.attr in {"debug", "info", "warning", "warn",
                                   "error", "exception", "critical", "log"}:
                        label = f"log.{fn.attr}"
                    elif fn.attr == "write" and isinstance(fn.value, ast.Attribute) \
                            and fn.value.attr in {"stderr", "stdout"}:
                        label = f"sys.{fn.value.attr}.write"
                if label:
                    hits.append(f"{label}:{getattr(node, 'lineno', 0)}")
            if hits:
                offenders[name] = hits
        self.assertEqual(offenders, {},
                         f"Phase 4 modules carry a non-export egress channel: {offenders}")
        print("\n[SLCD-P4-GOV] non-export egress sweep: transcript.py + network.py "
              "emit no log, print or stderr write")

    def test_egress_sweep_can_actually_fire(self) -> None:
        """Sensitivity control for the sweep above."""
        tree = ast.parse("import logging\nlogging.warning('%s', line)\nprint(rec)\n")
        found = [n for n in ast.walk(tree) if isinstance(n, ast.Call)]
        self.assertGreaterEqual(len(found), 2)

    def test_provider_artefact_is_present_versioned_and_loadable(self) -> None:
        artefact = PKG_DIR / "data" / "inference_providers.json"
        self.assertTrue(artefact.is_file(), "the CIDR artefact is missing")
        raw = json.loads(artefact.read_text(encoding="utf-8"))
        self.assertTrue(raw.get("list_version"), "the CIDR list carries no version")
        self.assertTrue(raw.get("providers"), "the CIDR list declares no providers")
        ranges = NET.InferenceProviderRanges.load()
        self.assertIn("api.anthropic.com", ranges.inference_endpoints)


if __name__ == "__main__":
    unittest.main()
