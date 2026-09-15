# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors

"""
Functional and structural test suite for the SLCD-P4-1 transcript metadata parser.

Covers schema conformance against P1-1's frozen contract, the allowlist table's
structural properties, the zero-payload invariant itself, model-identifier
enumeration, 64-bit token arithmetic, streaming/tailing/partial-line handling,
fail-closed behaviour on unrecognised formats, and openat2 symlink confinement.

The adversarial payload-leak argument lives in ``test_transcript_falsification.py``.
"""
from __future__ import annotations

import ast
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import tracemalloc
import unittest

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from . import transcript as T
    from .coding_agent_models import (
        CANONICAL_TOOL_KEYS,
        CodingAgentTelemetry,
        Harness,
        KanbanInfo,
        MetricsInfo,
        NetworkInfo,
        ProcessInfo,
    )
    from .proc import PROHIBITED_PROC_ENTRIES
except (ImportError, ValueError):
    import transcript as T
    from coding_agent_models import (
        CANONICAL_TOOL_KEYS,
        CodingAgentTelemetry,
        Harness,
        KanbanInfo,
        MetricsInfo,
        NetworkInfo,
        ProcessInfo,
    )
    from proc import PROHIBITED_PROC_ENTRIES


UUID_A = "3f2a1b4c-5d6e-4f70-8a9b-0c1d2e3f4a5b"
STAMP = "2026-09-15T08:00:00Z"


# ---------------------------------------------------------------------------
# AST helpers.
#
# Structural guards over this module are written against the AST, never against
# raw source text. A text grep for a forbidden construct matches the module's own
# documentation of why that construct is forbidden -- a guard that fails on its own
# prose, which then gets "fixed" by weakening the guard. The AST sees code only.
# ---------------------------------------------------------------------------


#: Names that hold a FieldRule/SqliteSpec constant rather than decoded record data.
#: Iterating one of these cannot widen the read surface. The exemption is justified
#: by ``test_rule_constant_names_really_are_rule_constants``, not merely asserted.
RULE_CONSTANT_NAMES = {"path", "rules", "statements"}


def module_ast():
    return ast.parse((PKG_DIR / "transcript.py").read_text(encoding="utf-8"))


def _docstring_nodes(tree):
    """Every string Constant that is a module/class/function docstring."""
    found = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            body = getattr(node, "body", None)
            if (
                body
                and isinstance(body[0], ast.Expr)
                and isinstance(body[0].value, ast.Constant)
                and isinstance(body[0].value.value, str)
            ):
                found.add(id(body[0].value))
    return found


def code_string_constants(tree):
    """String literals that are real code operands, excluding every docstring."""
    docstrings = _docstring_nodes(tree)
    return [
        node.value
        for node in ast.walk(tree)
        if isinstance(node, ast.Constant)
        and isinstance(node.value, str)
        and id(node) not in docstrings
    ]


def claude_record(**overrides):
    record = {
        "sessionId": UUID_A,
        "timestamp": STAMP,
        "type": "assistant",
        "message": {
            "model": "claude-opus-5",
            "usage": {"input_tokens": 10, "output_tokens": 3},
            "content": [{"type": "tool_use", "name": "Bash"}],
        },
    }
    record.update(overrides)
    return record


def write_lines(root: Path, name: str, records) -> str:
    with open(root / name, "w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record) + "\n")
    return name


def append_lines(root: Path, name: str, records) -> None:
    with open(root / name, "a", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record) + "\n")


class SchemaConformanceTests(unittest.TestCase):
    """ISC-1..8: the parser's output conforms to P1-1's frozen schema."""

    def test_transcript_metrics_exposes_exactly_the_p4_pre_shape(self) -> None:
        """ISC-2: SLCD-P4-PRE section 6.1 froze these five attributes."""
        metrics = T.TranscriptMetrics()
        for attr in ("step_count", "tokens_in", "tokens_out", "tool_counts", "models"):
            self.assertTrue(hasattr(metrics, attr), f"missing {attr}")
        self.assertEqual(len(metrics), 5)

    def test_tool_counts_is_p1_1_fixed_arity_vector(self) -> None:
        """ISC-3: exactly CANONICAL_TOOL_KEYS, no more and no fewer."""
        counts = T.TranscriptMetrics().tool_counts
        self.assertEqual(sorted(counts), sorted(CANONICAL_TOOL_KEYS))
        self.assertEqual(len(counts), 14)

    def test_tool_counts_rejects_a_non_canonical_key(self) -> None:
        """A second tool-counting scheme cannot be smuggled in via the constructor."""
        with self.assertRaises(ValueError):
            T.TranscriptMetrics(tool_counts={"mcp__customer__secret_tool": 1})

    def test_converts_to_p1_1_metrics_info(self) -> None:
        """ISC-4: the frozen downstream model accepts the parser's output as-is."""
        metrics = T.TranscriptMetrics(
            step_count=14, tokens_in=125000, tokens_out=4200,
            tool_counts={"view_file": 8, "run_command": 3},
        )
        info = metrics.to_metrics_info()
        self.assertIsInstance(info, MetricsInfo)
        self.assertEqual(info.tokens_in, 125000)
        self.assertEqual(info.tool_counts.view_file, 8)
        self.assertEqual(info.tool_counts.run_command, 3)

    def test_feeds_a_full_coding_agent_telemetry_envelope(self) -> None:
        """ISC-5: end-to-end into P1-3's wire contract shape without a ValueError."""
        metrics = T.TranscriptMetrics(
            step_count=14, tokens_in=125000, tokens_out=4200,
            tool_counts={"view_file": 8, "run_command": 3},
        )
        event = CodingAgentTelemetry(
            harness=Harness.CLAUDE,
            session_id="a" * 64,
            timestamp=STAMP,
            process=ProcessInfo(pid=1234, ppid=1, comm="claude",
                                rss_bytes=104857600, cpu_ticks=450),
            kanban=KanbanInfo(task_id="SLCD-P4-1", shortcode="SLCD",
                              role="implementation", elapsed_s=120),
            metrics=metrics.to_metrics_info(),
            network=NetworkInfo(inference_endpoint="api.anthropic.com", egress_bytes=45000),
        )
        payload = event.to_dict()
        self.assertEqual(payload["metrics"]["tokens_in"], 125000)
        self.assertEqual(sorted(payload["metrics"]["tool_counts"]), sorted(CANONICAL_TOOL_KEYS))


class PackageExportTests(unittest.TestCase):
    """ISC-8: the module is reachable under both import styles the package supports."""

    def test_flat_module_import_works(self) -> None:
        import importlib
        module = importlib.import_module("transcript")
        self.assertTrue(hasattr(module, "TranscriptIndexer"))

    def test_package_dunder_all_advertises_the_parser(self) -> None:
        source = (PKG_DIR / "__init__.py").read_text(encoding="utf-8")
        for symbol in ("TranscriptIndexer", "TranscriptExtract", "TranscriptFormat",
                       "ConfinedStore", "ModelFamily", "assert_zero_payload",
                       "poll_unsupported_harness"):
            self.assertIn(f'"{symbol}"', source, f"{symbol} missing from __all__")
        # Both import arms must carry the module, not just the relative one.
        self.assertEqual(source.count("import (\n        CONFIRMED_STORES,"), 2)


class TranscriptModuleBoundaryTests(unittest.TestCase):
    """ISC-6..7: the parser shares no code path with P2-1's procfs scanner.

    The card names this explicitly: sharing a helper "blurs a boundary where a
    future refactor of one could accidentally give the transcript parser a procfs
    read path it should never have". Asserted at the import graph, by AST, so a
    future ``from proc import ...`` fails this test rather than review.
    """

    def _module_ast(self):
        return module_ast()

    def test_transcript_does_not_import_proc(self) -> None:
        for node in ast.walk(self._module_ast()):
            if isinstance(node, ast.ImportFrom):
                self.assertNotIn(
                    (node.module or "").lstrip("."), {"proc"},
                    "transcript.py must not import from proc.py",
                )
            if isinstance(node, ast.Import):
                for alias in node.names:
                    self.assertNotEqual(alias.name.lstrip("."), "proc")

    def test_transcript_never_targets_a_prohibited_proc_entry(self) -> None:
        """ISC-7: no PROHIBITED_PROC_ENTRIES member appears as a read target.

        Scans code string literals only. A raw-text grep would match this module's
        own prose about procfs and then be "fixed" by weakening the guard.
        """
        literals = code_string_constants(module_ast())
        self.assertGreater(len(literals), 20, "AST scan found no literals -- guard is vacuous")
        for literal in literals:
            self.assertNotIn("/proc/", literal, f"procfs path literal in code: {literal!r}")
            for entry in PROHIBITED_PROC_ENTRIES:
                self.assertNotEqual(literal, entry)

    def test_prohibited_proc_entries_set_is_unchanged(self) -> None:
        """Hard blocker: this card must not remove an entry from the prohibited set."""
        required = {
            "mem", "environ", "cmdline", "maps", "smaps", "smaps_rollup", "stack",
            "syscall", "io", "fd", "fdinfo", "net", "cwd", "root", "clear_refs",
            "pagemap", "attr",
        }
        self.assertTrue(required.issubset(PROHIBITED_PROC_ENTRIES))


class AllowlistStructureTests(unittest.TestCase):
    """ISC-9..16: the field set is a structurally-enforced allowlist, not a deny-list."""

    def test_every_format_declares_a_frozen_rule_tuple(self) -> None:
        """ISC-9/ISC-14: rules are tuples of frozen dataclasses."""
        for fmt, spec in T.FORMAT_RULES.items():
            self.assertIsInstance(spec.rules, tuple, f"{fmt} rules must be a tuple")
            self.assertGreater(len(spec.rules), 0)
            for rule in spec.rules:
                self.assertIsInstance(rule, T.FieldRule)
                with self.assertRaises(dataclasses_frozen_error()):
                    rule.kind = T.FieldKind.TOKENS_IN

    def test_every_rule_path_is_a_tuple_of_plain_strings(self) -> None:
        """A rule cannot express a wildcard, a regex, or 'all keys'."""
        for spec in T.FORMAT_RULES.values():
            for rule in spec.rules:
                for segment in tuple(rule.path) + tuple(rule.list_path):
                    self.assertIsInstance(segment, str)
                    self.assertNotIn("*", segment)
                    self.assertNotIn("$", segment)

    def test_read_path_cannot_enumerate_record_keys(self) -> None:
        """ISC-10: the only record-reading function addresses exactly what it is given.

        Instrumented: a Mapping that records every key lookup proves the parser
        touched only allowlisted paths -- not 'we did not see anything sensitive
        in the fields we happened to check', but 'these are the fields it checked'.
        """
        touched = []

        class _SpyDict(dict):
            def __contains__(self, key):  # noqa: D105
                touched.append(key)
                return dict.__contains__(self, key)

            def __getitem__(self, key):  # noqa: D105
                touched.append(key)
                return dict.__getitem__(self, key)

            def get(self, key, default=None):  # noqa: D102
                touched.append(key)
                return dict.get(self, key, default)

        record = _SpyDict(claude_record())
        record["message"] = _SpyDict(record["message"])
        record["message"]["usage"] = _SpyDict(record["message"]["usage"])
        record["secretCustomerKey"] = "must never be touched"

        spec = T.FORMAT_RULES[T.TranscriptFormat.CLAUDE_JSONL_V1]
        T.extract_record(spec, record, T.TranscriptBookmark())

        self.assertNotIn("secretCustomerKey", touched)
        allowed = {"sessionId", "session_id", "uuid", "type", "timestamp", "message",
                   "model", "usage", "input_tokens", "cache_read_input_tokens",
                   "output_tokens", "content", "name"}
        self.assertTrue(
            set(touched).issubset(allowed),
            f"parser touched unexpected keys: {sorted(set(touched) - allowed)}",
        )

    def test_code_never_stringifies_or_enumerates_a_record(self) -> None:
        """ISC-15/16: no whole-record copy, stringification, or key enumeration.

        AST-based, because a raw-text grep for these constructs matches the module's
        own docstring explaining why they are forbidden -- a guard that fails on its
        own prose invites being weakened rather than obeyed.

        Two checks:
          * no call of ``str``/``repr``/``dict``/``list``/``json.dumps`` on a name
            that carries a decoded record;
          * no attribute access of ``keys``/``items``/``values`` and no ``for`` loop
            directly over such a name.
        """
        # Names that hold a decoded record or a mapping *within* one. Iterating any
        # of these enumerates keys, which is how an unknown key gets addressed.
        # ``container``/``raw`` are excluded here and covered by the stricter
        # list-guard check below: they are the JSON *arrays* an explicit rule path
        # names, and each element is then addressed by explicit keys.
        record_names = {"record", "node", "element"}
        wrapping_calls = {"str", "repr", "dict", "list", "sorted", "tuple"}
        enumerating_attrs = {"keys", "items", "values"}
        tree = module_ast()
        violations = []

        for node in ast.walk(tree):
            if isinstance(node, ast.Call):
                func = node.func
                name = func.id if isinstance(func, ast.Name) else None
                if isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name):
                    if func.value.id == "json" and func.attr == "dumps":
                        name = "json.dumps"
                    elif func.attr in enumerating_attrs and func.value.id in record_names:
                        violations.append(f"{func.value.id}.{func.attr}() at line {node.lineno}")
                if name in wrapping_calls or name == "json.dumps":
                    for arg in node.args:
                        if isinstance(arg, ast.Name) and arg.id in record_names:
                            violations.append(f"{name}({arg.id}) at line {node.lineno}")
            if isinstance(node, ast.For):
                it = node.iter
                if isinstance(it, ast.Name) and it.id in record_names:
                    violations.append(f"for ... in {it.id} at line {node.lineno}")
                if (
                    isinstance(it, ast.Attribute)
                    and isinstance(it.value, ast.Name)
                    and it.value.id in record_names
                ):
                    violations.append(f"for ... in {it.value.id}.{it.attr} at line {node.lineno}")

        self.assertEqual(violations, [], f"record enumeration/stringification: {violations}")

    def test_every_loop_over_decoded_data_is_guarded_as_a_list(self) -> None:
        """The other half of the enumeration guard.

        ``for x in y`` over a dict yields KEYS -- exactly the widening this module
        must not do. Every ``for`` over a bare name inside the extraction functions
        must therefore sit in a function that first proves the name is a ``list``
        via ``isinstance(..., list)``. That turns "those two loops are fine, trust
        me" into a checked property.
        """
        extraction_funcs = {"_apply_rule", "_fold", "extract_record", "_read_path"}
        checked = 0
        for node in ast.walk(module_ast()):
            if not isinstance(node, ast.FunctionDef) or node.name not in extraction_funcs:
                continue
            isinstance_list_targets = {
                call.args[0].id
                for call in ast.walk(node)
                if isinstance(call, ast.Call)
                and isinstance(call.func, ast.Name)
                and call.func.id == "isinstance"
                and len(call.args) == 2
                and isinstance(call.args[0], ast.Name)
                and isinstance(call.args[1], ast.Name)
                and call.args[1].id == "list"
            }
            for loop in ast.walk(node):
                if isinstance(loop, ast.For) and isinstance(loop.iter, ast.Name):
                    if loop.iter.id in RULE_CONSTANT_NAMES:
                        continue
                    checked += 1
                    self.assertIn(
                        loop.iter.id,
                        isinstance_list_targets,
                        f"{node.name}: 'for ... in {loop.iter.id}' at line {loop.lineno} is not "
                        "guarded by isinstance(..., list) -- it may be enumerating dict keys",
                    )
        self.assertGreaterEqual(checked, 2, "guard is vacuous -- no loops were inspected")

    def test_rule_constant_names_really_are_rule_constants(self) -> None:
        """Justifies the RULE_CONSTANT_NAMES exemption above, rather than asserting it.

        ``path`` in ``_read_path`` holds a FieldRule's frozen key tuple, never
        decoded record data, so iterating it cannot widen the read surface. That is
        only true because every rule's ``path`` is a tuple of plain strings fixed at
        import time -- which ``test_every_rule_path_is_a_tuple_of_plain_strings``
        and ``test_every_format_declares_a_frozen_rule_tuple`` establish.
        """
        for spec in T.FORMAT_RULES.values():
            for rule in spec.rules:
                self.assertIsInstance(rule.path, tuple)
                self.assertIsInstance(rule.list_path, tuple)
                self.assertTrue(all(isinstance(s, str) for s in rule.path))
        # And the exemption list is narrow: three names, all rule-table members.
        self.assertEqual(RULE_CONSTANT_NAMES, {"path", "rules", "statements"})

    def test_the_stringify_guard_is_not_vacuous(self) -> None:
        """A guard never observed failing is an untested claim. Prove it can fail."""
        hostile = ast.parse("def f(record):\n    return json.dumps(record)\n")
        found = [
            n for n in ast.walk(hostile)
            if isinstance(n, ast.Call)
            and isinstance(n.func, ast.Attribute)
            and n.func.attr == "dumps"
            and any(isinstance(a, ast.Name) and a.id == "record" for a in n.args)
        ]
        self.assertEqual(len(found), 1, "the AST pattern the guard looks for is unmatchable")

    def test_no_field_rule_has_a_free_text_codomain(self) -> None:
        """Every FieldKind folds through a bounded coercion, never a passthrough."""
        bounded_kinds = {
            T.FieldKind.SESSION_UUID, T.FieldKind.TIMESTAMP, T.FieldKind.MODEL,
            T.FieldKind.TOKENS_IN, T.FieldKind.TOKENS_OUT, T.FieldKind.STEP_INDEX,
            T.FieldKind.TOOL_NAME, T.FieldKind.TOOL_NAME_LIST,
        }
        self.assertEqual(set(T.FieldKind), bounded_kinds)
        for spec in T.FORMAT_RULES.values():
            for rule in spec.rules:
                self.assertIn(rule.kind, bounded_kinds)


def dataclasses_frozen_error():
    import dataclasses as _d
    return _d.FrozenInstanceError


class ZeroPayloadInvariantTests(unittest.TestCase):
    """ISC-17..23: the chokepoint predicate."""

    def test_accepts_a_populated_legitimate_struct(self) -> None:
        """ISC-23: non-vacuous -- the invariant passes on a struct with real strings."""
        extract = T.TranscriptExtract(
            fmt=T.TranscriptFormat.CLAUDE_JSONL_V1,
            status=T.ParseStatus.PARSED,
            harness=Harness.CLAUDE,
            metrics=T.TranscriptMetrics(step_count=1, models=("anthropic/claude-opus",)),
            session_uuid=UUID_A,
            first_timestamp=STAMP,
        )
        string_leaves = [v for v in extract.to_dict().values() if isinstance(v, str)]
        self.assertGreaterEqual(len(string_leaves), 2, "invariant must be tested on real strings")

    def test_rejects_a_free_text_value(self) -> None:
        with self.assertRaises(T.TranscriptPayloadViolation):
            T.assert_zero_payload({"session_uuid": "a customer prompt goes here"})

    def test_rejects_a_free_text_dict_key(self) -> None:
        """ISC-22: a payload smuggled as a KEY is rejected too."""
        with self.assertRaises(T.TranscriptPayloadViolation):
            T.assert_zero_payload({"a customer prompt as a key": 1})

    def test_recurses_into_lists_tuples_and_nested_dicts(self) -> None:
        """ISC-21."""
        for hostile in (
            {"models": ["totally not a model family"]},
            {"models": ("nested", )},
            {"tool_counts": {"view_file": {"deep": "leak"}}},
            [[["leak"]]],
        ):
            with self.subTest(shape=type(hostile).__name__):
                with self.assertRaises(T.TranscriptPayloadViolation):
                    T.assert_zero_payload(hostile)

    def test_rejects_an_unknown_object_type(self) -> None:
        class Opaque:
            pass
        with self.assertRaises(T.TranscriptPayloadViolation):
            T.assert_zero_payload(Opaque())

    def test_allows_only_the_four_documented_shapes(self) -> None:
        """ISC-18."""
        self.assertTrue(T.is_allowlisted_string("parsed"))                 # enum value
        self.assertTrue(T.is_allowlisted_string("view_file"))              # tool key
        self.assertTrue(T.is_allowlisted_string(UUID_A))                   # uuid shape
        self.assertTrue(T.is_allowlisted_string(STAMP))                    # rfc3339 shape
        self.assertTrue(T.is_allowlisted_string("a" * 64))                 # hex64 shape
        self.assertFalse(T.is_allowlisted_string("arbitrary text"))
        self.assertFalse(T.is_allowlisted_string(UUID_A + "x"))
        self.assertFalse(T.is_allowlisted_string("2026-13-45T99:99:99Z"))

    def test_shape_predicates_use_fullmatch_not_match(self) -> None:
        """A trailing newline must not slip past a ``^...$`` pattern.

        Python's ``$`` matches immediately before a trailing newline, so
        ``re.match(r"^[0-9a-f-]{36}$", uuid + "\\n")`` SUCCEEDS. That is a one-byte
        channel through a predicate whose whole job is to be exact.
        """
        for suffix in ("\n", "\r\n", "\n\n"):
            with self.subTest(suffix=repr(suffix)):
                self.assertFalse(T.is_allowlisted_string(UUID_A + suffix))
                self.assertFalse(T.is_allowlisted_string(STAMP + suffix))
                self.assertFalse(T.is_allowlisted_string("a" * 64 + suffix))
        # Non-vacuity: the un-suffixed forms DO pass.
        self.assertTrue(T.is_allowlisted_string(UUID_A))
        self.assertTrue(T.is_allowlisted_string(STAMP))

    def test_shape_predicates_reject_non_ascii_digits(self) -> None:
        """``\\d`` is Unicode-aware; these patterns must use ``[0-9]``.

        Arabic-Indic (U+0660..) and fullwidth (U+FF10..) digits satisfy ``\\d`` and
        would be admitted into something claiming to be a timestamp.
        """
        arabic_indic = "٢٠٢٦-09-15T08:00:00Z"   # ٢٠٢٦-09-15...
        fullwidth = "２０２６-09-15T08:00:00Z"      # ２０２６-09-15...
        self.assertEqual(len(arabic_indic), len(STAMP))
        for hostile in (arabic_indic, fullwidth):
            with self.subTest(value=hostile):
                self.assertFalse(T.is_allowlisted_string(hostile))
                self.assertIsNone(T.coerce_rfc3339(hostile))

    def test_timestamps_are_canonicalised_not_passed_through(self) -> None:
        """Validation is not sanitisation.

        Source formatting choices -- ``Z`` vs ``+00:00``, 0-9 fractional digits --
        are a covert channel if echoed verbatim. Equivalent instants must produce
        byte-identical output.
        """
        equivalent = [
            "2026-09-15T08:00:00Z",
            "2026-09-15T08:00:00.000Z",
            "2026-09-15T08:00:00.000000000Z",
            "2026-09-15T08:00:00+00:00",
            "2026-09-15T09:00:00+01:00",
            "2026-09-15T07:00:00-01:00",
        ]
        canonical = {T.coerce_rfc3339(v) for v in equivalent}
        self.assertEqual(
            canonical, {"2026-09-15T08:00:00Z"},
            f"formatting variance survived canonicalisation: {canonical}",
        )
        # Non-vacuity: a genuinely different instant differs.
        self.assertNotEqual(T.coerce_rfc3339("2026-09-15T08:00:01Z"),
                            T.coerce_rfc3339("2026-09-15T08:00:00Z"))

    def test_arbitrary_precision_integers_are_clamped_not_carried(self) -> None:
        """``json`` parses unbounded integers; ``isinstance(v, int)`` is not a bound.

        A 4,000-digit integer is half a kilobyte of attacker-chosen text that passes
        a naive int check. ``coerce_count`` clamps to MAX_COUNT, so the output carries
        at most 16 digits regardless.

        4,000 not 9,000: CPython >= 3.11 caps int<->str conversion at
        ``sys.get_int_max_str_digits()`` (4,300 by default), so a larger literal
        raises in ``json.loads`` before the parser ever sees it. That cap is a real
        second line of defence here, but it is an interpreter setting a deployment
        can raise, so the clamp must hold on its own.
        """
        digits = 4000
        self.assertLess(digits, sys.get_int_max_str_digits())
        giant = int("9" * digits)
        self.assertEqual(T.coerce_count(giant), T.MAX_COUNT)
        self.assertEqual(len(str(T.coerce_count(giant))), len(str(T.MAX_COUNT)))
        parsed = json.loads('{"input_tokens": ' + "9" * digits + "}")
        self.assertEqual(T.coerce_count(parsed["input_tokens"]), T.MAX_COUNT)
        # And it survives the downstream frozen model's bound.
        MetricsInfo(step_count=0, tokens_in=T.coerce_count(giant),
                    tokens_out=0, tool_counts={})

    def test_invariant_rejects_smuggling_types_not_just_strings(self) -> None:
        """The walker must be an allow-list on TYPE, not a deny-list on ``str``.

        ``bytes``, ``Decimal``, ``Path`` and ``datetime`` all carry text past a
        check that only inspects ``str``.
        """
        import decimal
        for hostile in (b"raw customer bytes", decimal.Decimal("1.5"),
                        Path("/home/customer/secret.go"),
                        __import__("datetime").datetime(2026, 9, 15)):
            with self.subTest(type=type(hostile).__name__):
                with self.assertRaises(T.TranscriptPayloadViolation):
                    T.assert_zero_payload({"session_uuid": hostile})

    def test_skip_reason_must_come_from_the_closed_set(self) -> None:
        """A skip reason is not a free-text channel."""
        with self.assertRaises(ValueError):
            T._skipped(
                T.TranscriptFormat.UNRECOGNISED, Harness.UNKNOWN,
                T.ParseStatus.SKIPPED_STORE_ABSENT, "invented reason with customer data",
            )


class ModelEnumerationTests(unittest.TestCase):
    """ISC-39..46: the model identifier is enumerated, never passed through."""

    def test_known_identifiers_map_to_the_right_family(self) -> None:
        cases = {
            "claude-opus-5-20260101": T.ModelFamily.ANTHROPIC_CLAUDE_OPUS,
            "claude-sonnet-5": T.ModelFamily.ANTHROPIC_CLAUDE_SONNET,
            "claude-haiku-4-5-20251001": T.ModelFamily.ANTHROPIC_CLAUDE_HAIKU,
            "claude-instant-1.2": T.ModelFamily.ANTHROPIC_CLAUDE_OTHER,
            "gpt-5.4": T.ModelFamily.OPENAI_GPT,
            "o3-mini": T.ModelFamily.OPENAI_O_SERIES,
            "gemini-3-pro": T.ModelFamily.GOOGLE_GEMINI,
            "kimi-k2.6": T.ModelFamily.MOONSHOT_KIMI,
            "grok-4": T.ModelFamily.XAI_GROK,
            "llama-3.3-70b": T.ModelFamily.META_LLAMA,
            "deepseek-v3": T.ModelFamily.DEEPSEEK,
            "qwen2.5-coder": T.ModelFamily.ALIBABA_QWEN,
        }
        for raw, expected in cases.items():
            with self.subTest(model=raw):
                self.assertEqual(T.map_model_identifier(raw), expected)

    def test_unknown_identifier_maps_to_unknown(self) -> None:
        """ISC-41/42."""
        self.assertEqual(T.map_model_identifier("acme-internal-v9"), T.ModelFamily.UNKNOWN)

    def test_a_prompt_in_the_model_field_maps_to_unknown_and_leaks_nothing(self) -> None:
        """ISC-43: the oversize guard refuses to even scan attacker-controlled text."""
        prompt = "Refactor " * 512
        self.assertGreater(len(prompt), 4096)
        self.assertEqual(T.map_model_identifier(prompt), T.ModelFamily.UNKNOWN)

    def test_non_string_model_values_do_not_raise(self) -> None:
        """ISC-44: total function over every JSON type."""
        for raw in (None, 42, 4.2, True, [], {}, {"model": "claude"}, [1, 2]):
            with self.subTest(value=repr(raw)):
                self.assertEqual(T.map_model_identifier(raw), T.ModelFamily.UNKNOWN)

    def test_models_output_is_sorted_deduplicated_enum_values(self) -> None:
        """ISC-45."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            records = []
            for model in ("gpt-5.4", "claude-opus-5", "claude-opus-5", "gemini-3-pro"):
                rec = claude_record()
                rec["message"] = dict(rec["message"], model=model)
                records.append(rec)
            rel = write_lines(root, "s.jsonl", records)
            with T.ConfinedStore(root) as store:
                extract = T.TranscriptIndexer().poll(
                    store, rel, T.TranscriptFormat.CLAUDE_JSONL_V1
                )
        self.assertEqual(
            extract.metrics.models,
            ("anthropic/claude-opus", "google/gemini", "openai/gpt"),
        )
        for value in extract.metrics.models:
            self.assertIn(value, {m.value for m in T.ModelFamily})

    def test_no_branch_returns_the_raw_identifier(self) -> None:
        """ISC-46: every ``return`` in map_model_identifier yields a ModelFamily.

        AST-based over the function definition, so a future branch returning ``raw``
        (the defect the card names: "passing a free-text model identifier through
        verbatim because it seems safe") fails here rather than at review.
        """
        func = None
        for node in ast.walk(module_ast()):
            if isinstance(node, ast.FunctionDef) and node.name == "map_model_identifier":
                func = node
        self.assertIsNotNone(func, "map_model_identifier not found")

        returns = [n for n in ast.walk(func) if isinstance(n, ast.Return)]
        self.assertGreaterEqual(len(returns), 4, "guard is vacuous -- too few returns found")
        for ret in returns:
            value = ret.value
            is_enum_member = (
                isinstance(value, ast.Attribute)
                and isinstance(value.value, ast.Name)
                and value.value.id == "ModelFamily"
            )
            # ``return family`` is the loop variable bound from MODEL_MATCH_RULES,
            # whose second element is always a ModelFamily member (asserted below).
            is_rule_family = isinstance(value, ast.Name) and value.id == "family"
            self.assertTrue(
                is_enum_member or is_rule_family,
                f"non-enum return at line {ret.lineno}: {ast.dump(value)[:80]}",
            )

    def test_every_model_match_rule_yields_an_enum_member(self) -> None:
        """Closes the ``return family`` hole in the test above."""
        self.assertGreater(len(T.MODEL_MATCH_RULES), 10)
        for token, family in T.MODEL_MATCH_RULES:
            self.assertIsInstance(token, str)
            self.assertIsInstance(family, T.ModelFamily)
            self.assertIsNot(family, T.ModelFamily.UNKNOWN, "a rule must classify, not punt")


class TokenArithmeticTests(unittest.TestCase):
    """ISC-47..52: 64-bit-safe accumulation reusing P1-1's bound."""

    def test_accumulates_past_2_to_the_31_without_wraparound(self) -> None:
        """ISC-47/48: the int32 overflow risk P1-1's own failure modes named."""
        acc = T.TranscriptBookmark()
        per_record = 3_000_000_000  # already > 2**31
        for _ in range(3):
            T._fold(T.FieldKind.TOKENS_IN, per_record, acc)
            T._fold(T.FieldKind.TOKENS_OUT, per_record, acc)
        self.assertEqual(acc.tokens_in, 9_000_000_000)
        self.assertEqual(acc.tokens_out, 9_000_000_000)
        self.assertGreater(acc.tokens_in, 2 ** 31 - 1)
        # And it survives the downstream frozen model's bound check.
        MetricsInfo(step_count=1, tokens_in=acc.tokens_in,
                    tokens_out=acc.tokens_out, tool_counts={})

    def test_saturates_at_the_p1_1_bound_rather_than_wrapping_or_raising(self) -> None:
        """ISC-49: MAX_COUNT is exactly MetricsInfo's own ceiling."""
        self.assertEqual(T.MAX_COUNT, 9007199254740991)
        acc = T.TranscriptBookmark()
        T._fold(T.FieldKind.TOKENS_IN, T.MAX_COUNT, acc)
        T._fold(T.FieldKind.TOKENS_IN, T.MAX_COUNT, acc)
        self.assertEqual(acc.tokens_in, T.MAX_COUNT)
        MetricsInfo(step_count=0, tokens_in=acc.tokens_in, tokens_out=0, tool_counts={})

    def test_negative_token_value_is_clamped_not_subtracted(self) -> None:
        """ISC-50."""
        acc = T.TranscriptBookmark()
        T._fold(T.FieldKind.TOKENS_IN, 100, acc)
        T._fold(T.FieldKind.TOKENS_IN, -1_000_000, acc)
        self.assertEqual(acc.tokens_in, 100)

    def test_odd_typed_token_values_coerce_safely(self) -> None:
        """ISC-51."""
        self.assertEqual(T.coerce_count(True), 0)
        self.assertEqual(T.coerce_count(False), 0)
        self.assertEqual(T.coerce_count(float("nan")), 0)
        self.assertEqual(T.coerce_count(float("inf")), 0)
        self.assertEqual(T.coerce_count("42"), 42)
        self.assertEqual(T.coerce_count("not a number"), 0)
        self.assertEqual(T.coerce_count("9" * 4000), 0)  # oversize: not scanned
        self.assertEqual(T.coerce_count({"a": 1}), 0)
        self.assertEqual(T.coerce_count(None), 0)
        self.assertEqual(T.coerce_count(12.9), 12)

    def test_cache_read_tokens_fold_into_tokens_in(self) -> None:
        """ISC-52, per SLCD-P4-PRE section 2."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rec = claude_record()
            rec["message"]["usage"] = {
                "input_tokens": 1000, "cache_read_input_tokens": 250, "output_tokens": 7,
            }
            rel = write_lines(root, "s.jsonl", [rec])
            with T.ConfinedStore(root) as store:
                extract = T.TranscriptIndexer().poll(
                    store, rel, T.TranscriptFormat.CLAUDE_JSONL_V1
                )
        self.assertEqual(extract.metrics.tokens_in, 1250)
        self.assertEqual(extract.metrics.tokens_out, 7)


class StreamingAndTailingTests(unittest.TestCase):
    """ISC-53..61: incremental tailing, partial lines, truncation, rotation."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.indexer = T.TranscriptIndexer()

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _poll(self, rel):
        with T.ConfinedStore(self.root) as store:
            return self.indexer.poll(store, rel, T.TranscriptFormat.CLAUDE_JSONL_V1)

    def test_appends_are_counted_exactly_once(self) -> None:
        """ISC-57: the core tailing correctness property."""
        rel = write_lines(self.root, "s.jsonl", [claude_record()] * 3)
        first = self._poll(rel)
        self.assertEqual(first.records_parsed, 3)
        append_lines(self.root, rel, [claude_record()] * 2)
        second = self._poll(rel)
        self.assertEqual(second.records_parsed, 5, "appended records double-counted or lost")
        self.assertEqual(second.metrics.tokens_in, 50)

    def test_unchanged_file_reads_zero_new_bytes(self) -> None:
        """ISC-56: re-polling an idle transcript costs nothing."""
        rel = write_lines(self.root, "s.jsonl", [claude_record()] * 2)
        first = self._poll(rel)
        before = first.bytes_consumed
        second = self._poll(rel)
        self.assertEqual(second.status, T.ParseStatus.NO_NEW_DATA)
        self.assertEqual(second.bytes_consumed, before)
        self.assertEqual(second.records_parsed, 2)

    def test_partial_trailing_line_is_buffered_not_misparsed(self) -> None:
        """ISC-54/55: a line truncated mid-write survives to the next poll.

        The failure this prevents: treating the fragment as a malformed record --
        which both loses it and inflates the malformed counter -- or crashing and
        dropping the whole poll cycle's data.
        """
        rel = write_lines(self.root, "s.jsonl", [claude_record()])
        # Simulate a torn write: a valid record's JSON, cut in half, no newline.
        torn = json.dumps(claude_record())
        head, tail = torn[: len(torn) // 2], torn[len(torn) // 2 :]
        with open(self.root / rel, "a", encoding="utf-8") as handle:
            handle.write(head)

        mid = self._poll(rel)
        self.assertEqual(mid.records_parsed, 1, "the torn fragment must not be parsed")
        self.assertEqual(mid.records_skipped_malformed, 0, "torn line wrongly counted malformed")

        # The writer finishes the line.
        with open(self.root / rel, "a", encoding="utf-8") as handle:
            handle.write(tail + "\n")
        final = self._poll(rel)
        self.assertEqual(final.records_parsed, 2, "completed line lost or double-counted")
        self.assertEqual(final.records_skipped_malformed, 0)

    def test_truncation_resets_the_bookmark(self) -> None:
        """ISC-58."""
        rel = write_lines(self.root, "s.jsonl", [claude_record()] * 4)
        self._poll(rel)
        write_lines(self.root, "s.jsonl", [claude_record()])  # truncate + rewrite
        after = self._poll(rel)
        self.assertEqual(after.bytes_consumed, (self.root / rel).stat().st_size)

    def test_rotation_resets_the_bookmark(self) -> None:
        """ISC-59: a new inode at the same path is a new file."""
        rel = write_lines(self.root, "s.jsonl", [claude_record()] * 4)
        self._poll(rel)
        os.unlink(self.root / rel)
        write_lines(self.root, "s.jsonl", [claude_record()] * 2)
        after = self._poll(rel)
        self.assertEqual(after.bytes_consumed, (self.root / rel).stat().st_size)

    def test_malformed_json_line_counts_and_does_not_abort_the_poll(self) -> None:
        """ISC-61."""
        path = self.root / "s.jsonl"
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(claude_record()) + "\n")
            handle.write("{not json at all,,,\n")
            handle.write(json.dumps(claude_record()) + "\n")
        result = self._poll("s.jsonl")
        self.assertEqual(result.records_parsed, 2)
        self.assertEqual(result.records_skipped_malformed, 1)

    def test_oversize_line_is_skipped_unparsed(self) -> None:
        """ISC-60: bounds the transient residency the module docstring describes."""
        path = self.root / "s.jsonl"
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(claude_record()) + "\n")
            handle.write("x" * (T.MAX_LINE_BYTES + 10) + "\n")
            handle.write(json.dumps(claude_record()) + "\n")
        result = self._poll("s.jsonl")
        self.assertEqual(result.records_parsed, 2)
        self.assertGreaterEqual(result.records_skipped_oversize, 1)

    def test_working_set_is_bounded_by_chunk_size_not_file_size(self) -> None:
        """ISC-53/71: peak allocation must not track the file size.

        Parses an 8 MiB transcript and asserts peak tracemalloc stays well under it.
        A parser that read the file as one string would allocate >= 8 MiB here.
        """
        big = self.root / "big.jsonl"
        record_line = json.dumps(claude_record()) + "\n"
        target = 8 * 1024 * 1024
        with open(big, "w", encoding="utf-8") as handle:
            written = 0
            while written < target:
                handle.write(record_line)
                written += len(record_line)
        size = big.stat().st_size
        self.assertGreaterEqual(size, target)

        tracemalloc.start()
        try:
            result = self._poll("big.jsonl")
            _current, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()

        self.assertGreater(result.records_parsed, 10_000)
        self.assertLess(
            peak, size // 4,
            f"peak allocation {peak} tracks file size {size} -- not streaming",
        )


class FailClosedAndConfinementTests(unittest.TestCase):
    """ISC-62..69: never guess, never follow a symlink out of a confirmed store."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_unknown_format_is_skipped_not_guessed(self) -> None:
        """ISC-62."""
        rel = write_lines(self.root, "s.jsonl", [claude_record()])
        with T.ConfinedStore(self.root) as store:
            result = T.TranscriptIndexer().poll(store, rel, T.TranscriptFormat.UNRECOGNISED)
        self.assertEqual(result.status, T.ParseStatus.SKIPPED_UNRECOGNISED_FORMAT)
        self.assertEqual(result.metrics.step_count, 0)
        self.assertEqual(result.metrics.tokens_in, 0)

    def test_records_lacking_every_discriminator_are_not_guessed_at(self) -> None:
        """ISC-63: a wrong guess can misroute payload into a metadata field."""
        alien = {"totally": "different", "schema": {"version": 9}, "entries": [1, 2, 3]}
        rel = write_lines(self.root, "s.jsonl", [alien, alien])
        with T.ConfinedStore(self.root) as store:
            result = T.TranscriptIndexer().poll(
                store, rel, T.TranscriptFormat.CLAUDE_JSONL_V1
            )
        self.assertEqual(result.status, T.ParseStatus.SKIPPED_UNRECOGNISED_FORMAT)
        self.assertEqual(result.records_parsed, 0)
        self.assertIsNotNone(result.skip_reason)

    def test_symlink_out_of_the_store_is_refused(self) -> None:
        """ISC-64: the kernel refuses it, not a check this module could get wrong."""
        outside = Path(tempfile.mkdtemp())
        try:
            secret = outside / "secret.jsonl"
            secret.write_text(json.dumps(claude_record()) + "\n", encoding="utf-8")
            os.symlink(secret, self.root / "link.jsonl")
            with T.ConfinedStore(self.root) as store:
                result = T.TranscriptIndexer().poll(
                    store, "link.jsonl", T.TranscriptFormat.CLAUDE_JSONL_V1
                )
            self.assertEqual(result.status, T.ParseStatus.SKIPPED_PATH_REFUSED)
            self.assertEqual(result.records_parsed, 0)
        finally:
            import shutil
            shutil.rmtree(outside, ignore_errors=True)

    def test_symlink_to_a_sibling_inside_the_store_is_also_refused(self) -> None:
        """RESOLVE_NO_SYMLINKS is absolute: no symlink component at all."""
        real = self.root / "real.jsonl"
        real.write_text(json.dumps(claude_record()) + "\n", encoding="utf-8")
        os.symlink(real, self.root / "alias.jsonl")
        with T.ConfinedStore(self.root) as store:
            result = T.TranscriptIndexer().poll(
                store, "alias.jsonl", T.TranscriptFormat.CLAUDE_JSONL_V1
            )
        self.assertEqual(result.status, T.ParseStatus.SKIPPED_PATH_REFUSED)

    def test_absolute_path_is_refused(self) -> None:
        """ISC-65."""
        with T.ConfinedStore(self.root) as store:
            result = T.TranscriptIndexer().poll(
                store, "/etc/passwd", T.TranscriptFormat.CLAUDE_JSONL_V1
            )
        self.assertEqual(result.status, T.ParseStatus.SKIPPED_PATH_REFUSED)

    def test_dotdot_traversal_is_refused(self) -> None:
        """ISC-66."""
        with T.ConfinedStore(self.root) as store:
            result = T.TranscriptIndexer().poll(
                store, "../../../etc/passwd", T.TranscriptFormat.CLAUDE_JSONL_V1
            )
        self.assertEqual(result.status, T.ParseStatus.SKIPPED_PATH_REFUSED)

    def test_unsupported_harnesses_return_an_explicit_named_outcome(self) -> None:
        """ISC-67: the Aider/CPAI gap is declared and tested, never silent."""
        for harness in (Harness.AIDER, Harness.CPAI):
            with self.subTest(harness=harness.value):
                result = T.poll_unsupported_harness(harness)
                self.assertEqual(result.status, T.ParseStatus.SKIPPED_UNSUPPORTED_HARNESS)
                self.assertEqual(result.harness, harness)
                self.assertIn(result.skip_reason, T.SKIP_REASONS)
                self.assertEqual(result.metrics.step_count, 0)

    def test_a_supported_harness_is_not_in_the_unsupported_set(self) -> None:
        """Non-vacuity: the declared-unsupported set is not everything."""
        for harness in (Harness.CLAUDE, Harness.ANTIGRAVITY, Harness.CODEX,
                        Harness.HERMES, Harness.OPENCODE):
            self.assertNotIn(harness, T.UNSUPPORTED_HARNESSES)
        with self.assertRaises(ValueError):
            T.poll_unsupported_harness(Harness.CLAUDE)

    def test_classify_format_uses_store_layout_not_content_sniffing(self) -> None:
        store = T.CONFIRMED_STORES[0]
        self.assertEqual(
            T.classify_format(store, "proj/abc.jsonl"), T.TranscriptFormat.CLAUDE_JSONL_V1
        )
        self.assertEqual(
            T.classify_format(store, "proj/abc.txt"), T.TranscriptFormat.UNRECOGNISED
        )

    def test_every_confirmed_store_maps_to_a_known_format(self) -> None:
        for store in T.CONFIRMED_STORES:
            self.assertTrue(
                store.fmt in T.FORMAT_RULES or store.fmt in T.SQLITE_RULES,
                f"{store.fmt} has no rule table",
            )


class SqliteStoreTests(unittest.TestCase):
    """ISC-68..69: read-only, count-only SQLite metadata extraction."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_no_sql_statement_references_a_content_column(self) -> None:
        """ISC-69: scan the frozen statement table for prohibited tokens."""
        for fmt, spec in T.SQLITE_RULES.items():
            for _kind, statement in spec.statements:
                lowered = statement.lower()
                for token in T.PROHIBITED_SQL_TOKENS:
                    self.assertNotIn(token, lowered, f"{fmt}: '{token}' in {statement!r}")

    def test_opencode_step_count_from_a_fixture_db(self) -> None:
        db = self.root / "opencode.db"
        conn = sqlite3.connect(db)
        conn.execute("CREATE TABLE session (id TEXT PRIMARY KEY)")
        conn.execute("CREATE TABLE message (id TEXT, session_id TEXT, content TEXT)")
        conn.execute("INSERT INTO session VALUES (?)", (UUID_A,))
        for i in range(7):
            conn.execute(
                "INSERT INTO message VALUES (?,?,?)",
                (f"m{i}", UUID_A, "CUSTOMER PROMPT TEXT THAT MUST NOT BE READ"),
            )
        conn.commit()
        conn.close()

        with T.ConfinedStore(self.root) as store:
            result = T.TranscriptIndexer().poll(
                store, "opencode.db", T.TranscriptFormat.OPENCODE_SQLITE_V1
            )
        self.assertEqual(result.status, T.ParseStatus.PARSED)
        self.assertEqual(result.metrics.step_count, 7)
        self.assertEqual(result.session_uuid, UUID_A)
        self.assertNotIn("CUSTOMER PROMPT", result.to_json())

    def test_wrong_schema_fails_closed(self) -> None:
        """A DB missing the required tables is skipped, not guessed at."""
        db = self.root / "opencode.db"
        conn = sqlite3.connect(db)
        conn.execute("CREATE TABLE unrelated (x INTEGER)")
        conn.commit()
        conn.close()
        with T.ConfinedStore(self.root) as store:
            result = T.TranscriptIndexer().poll(
                store, "opencode.db", T.TranscriptFormat.OPENCODE_SQLITE_V1
            )
        self.assertEqual(result.status, T.ParseStatus.SKIPPED_UNRECOGNISED_FORMAT)
        self.assertEqual(result.metrics.step_count, 0)

    def test_a_non_database_file_fails_closed(self) -> None:
        (self.root / "opencode.db").write_text("not a database", encoding="utf-8")
        with T.ConfinedStore(self.root) as store:
            result = T.TranscriptIndexer().poll(
                store, "opencode.db", T.TranscriptFormat.OPENCODE_SQLITE_V1
            )
        self.assertEqual(result.status, T.ParseStatus.SKIPPED_UNRECOGNISED_FORMAT)


class OtherHarnessFormatTests(unittest.TestCase):
    """Every confirmed JSONL/JSON format parses, not just Claude Code."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_antigravity_cli_jsonl(self) -> None:
        records = [
            {"step_index": 1, "source": "model", "session_id": UUID_A, "timestamp": STAMP,
             "model": "gemini-3-pro", "content": "PROMPT PAYLOAD",
             "tool_calls": [{"name": "run_command", "arguments": {"cmd": "rm -rf /"}}]},
            {"step_index": 2, "source": "tool", "thinking": "SECRET REASONING",
             "tool_calls": [{"name": "view_file"}, {"name": "mcp__acme__deploy"}]},
        ]
        rel = write_lines(self.root, "transcript.jsonl", records)
        with T.ConfinedStore(self.root) as store:
            result = T.TranscriptIndexer().poll(
                store, rel, T.TranscriptFormat.ANTIGRAVITY_CLI_JSONL_V1
            )
        self.assertEqual(result.status, T.ParseStatus.PARSED)
        self.assertEqual(result.metrics.tool_counts["run_command"], 1)
        self.assertEqual(result.metrics.tool_counts["view_file"], 1)
        self.assertEqual(result.metrics.tool_counts["other_count"], 1)  # the MCP tool
        self.assertEqual(result.metrics.models, ("google/gemini",))
        self.assertNotIn("PROMPT PAYLOAD", result.to_json())
        self.assertNotIn("SECRET REASONING", result.to_json())
        self.assertNotIn("rm -rf", result.to_json())

    def test_codex_rollout_jsonl(self) -> None:
        records = [
            {"timestamp": STAMP, "type": "session_meta",
             "payload": {"id": UUID_A, "model": "gpt-5.4",
                         "prompt": "CUSTOMER PROMPT", "code_diff": "SECRET DIFF"}},
            {"timestamp": STAMP, "type": "event_msg",
             "payload": {"name": "shell", "info": {"total_token_usage":
                         {"input_tokens": 99, "output_tokens": 11}}}},
        ]
        rel = write_lines(self.root, "rollout-x.jsonl", records)
        with T.ConfinedStore(self.root) as store:
            result = T.TranscriptIndexer().poll(
                store, rel, T.TranscriptFormat.CODEX_ROLLOUT_JSONL_V1
            )
        self.assertEqual(result.status, T.ParseStatus.PARSED)
        self.assertEqual(result.session_uuid, UUID_A)
        self.assertEqual(result.metrics.tokens_in, 99)
        self.assertEqual(result.metrics.models, ("openai/gpt",))
        self.assertNotIn("CUSTOMER PROMPT", result.to_json())
        self.assertNotIn("SECRET DIFF", result.to_json())

    def test_hermes_request_dump_json(self) -> None:
        """Hermes IS implemented -- the gap flagged since P1-PRE is closed for it."""
        record = {"session_id": UUID_A, "timestamp": STAMP, "request_id": "r1",
                  "model": "claude-sonnet-5",
                  "body": {"messages": [{"role": "user", "content": "CUSTOMER CHAT TEXT"}]},
                  "phone": "+447700900000"}
        rel = write_lines(self.root, "request_dump_1.json", [record])
        with T.ConfinedStore(self.root) as store:
            result = T.TranscriptIndexer().poll(
                store, rel, T.TranscriptFormat.HERMES_REQUEST_DUMP_V1
            )
        self.assertEqual(result.status, T.ParseStatus.PARSED)
        self.assertEqual(result.session_uuid, UUID_A)
        self.assertEqual(result.harness, Harness.HERMES)
        self.assertNotIn("CUSTOMER CHAT TEXT", result.to_json())
        self.assertNotIn("447700900000", result.to_json())


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
