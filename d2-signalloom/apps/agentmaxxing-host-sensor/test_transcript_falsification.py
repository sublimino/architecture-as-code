# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors

"""
Adversarial falsification suite for the SLCD-P4-1 transcript metadata parser.

Two independent falsification arguments, because they refute different claims:

* ``CorePayloadFalsificationTests`` refutes "payload reaches the output" for
  payload in the OBVIOUS place -- ``message.content[].text``, the assistant turn,
  the user prompt. This is the KPI the proposal states: exactly 0 bytes.

* ``StructuralAllowlistFalsificationTests`` refutes the weaker claim the core
  suite alone would license. Passing the core suite is consistent with
  "we did not see anything sensitive in the fields we happened to check"; it is
  NOT evidence that extraction is allowlist-based. So this suite plants the same
  payload in six placements the parser has no rule for -- including as a *field
  name*, inside an allowlisted subtree, and adjacent to a legitimate value -- and
  asserts all six are equally invisible.

Fixture-hostility discipline (learned from prior osramp-demo defects, see
MEMORY feedback ``a-regression-test-fixture-can-be-blind-to-its-own-bug`` and
``positive-control-sharing-a-constant-is-a-tautology``):

1. The payload sentinels are built from a constant defined HERE and used nowhere
   in ``transcript.py``, so a control can never pass by sharing the code's inputs.
2. Every falsification test asserts its own fixture is hostile (``_assert_hostile``)
   -- non-empty, long, and genuinely present in the raw fixture bytes -- so a later
   edit cannot silently disarm it by making the payload absent.
3. Every falsification test asserts the parse produced NON-ZERO metrics, so it
   cannot pass vacuously by parsing nothing.
4. ``GuardMutationFalsificationTests`` performs the mutation in-process: it swaps
   the guard for a pass-through and asserts the suite's own assertion goes red.
   A guard never observed failing is an untested claim.
"""
from __future__ import annotations

import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from . import transcript as T
except (ImportError, ValueError):
    import transcript as T


# ---------------------------------------------------------------------------
# Payload sentinels. Deliberately built from a constant that appears NOWHERE in
# transcript.py -- verified by test_sentinel_is_not_a_parser_constant below.
# ---------------------------------------------------------------------------

SENTINEL = "Zq7xKf3Rm9Wb2Nv5"

PROMPT_TEXT = (
    f"{SENTINEL}-PROMPT Please refactor the payment reconciliation service so it "
    "retries idempotently, and use the staging credential from the vault."
)
RESPONSE_TEXT = (
    f"{SENTINEL}-RESPONSE I have updated `reconcile.go` to wrap the settlement call "
    "in a bounded retry with a jittered backoff. Here is the diff."
)
DIFF_TEXT = f"{SENTINEL}-DIFF\n--- a/reconcile.go\n+++ b/reconcile.go\n-\told := 1\n+\tnew := 2\n"
THINKING_TEXT = f"{SENTINEL}-THINKING The customer's ledger schema implies a race here."

ALL_PAYLOADS = (PROMPT_TEXT, RESPONSE_TEXT, DIFF_TEXT, THINKING_TEXT)

SESSION_UUID = "3f2a1b4c-5d6e-4f70-8a9b-0c1d2e3f4a5b"
STAMP_A = "2026-09-15T08:00:00.000Z"
STAMP_B = "2026-09-15T08:05:30Z"

# ---------------------------------------------------------------------------
# Fixture inputs that reach the FAILING REGION of the two pass-through defects.
#
# Discovered by the out-of-process mutation run during SLCD-P4-1 (2026-09-15): with
# a legitimate ``sessionId`` and a legitimate ``model``, a raw-pass-through mutant
# produces byte-identical output, so the core falsification suite passed against
# BOTH mutants. It was proving the property only for inputs on which the property
# cannot fail. These two values fix that:
#
#   * SHORT_UNKNOWN_MODEL is under MAX_MODEL_ID_CHARS (so the oversize guard does
#     NOT short-circuit it) and matches no MODEL_MATCH_RULES token, so it lands on
#     exactly the return statement a pass-through defect would corrupt.
#   * MALFORMED_SESSION_ID is a non-UUID string, so it lands on exactly the return
#     that ``coerce_session_uuid``'s shape check would otherwise let through.
#
# ``test_fixture_reaches_the_pass_through_failing_region`` asserts both properties
# in the test body, so a later edit cannot silently disarm them.
# ---------------------------------------------------------------------------

SHORT_UNKNOWN_MODEL = f"{SENTINEL}-internal-model-v9"
MALFORMED_SESSION_ID = f"{SENTINEL}-not-a-uuid-at-all"


def _claude_record_with_payload_everywhere_obvious() -> dict:
    """A realistically-shaped Claude Code transcript record carrying real payload."""
    return {
        "sessionId": SESSION_UUID,
        "timestamp": STAMP_A,
        "type": "assistant",
        "uuid": "11111111-2222-4333-8444-555555555555",
        "cwd": "/home/operator/customer-repo",
        "message": {
            "id": "msg_01ABCDEF",
            "model": "claude-opus-5-20260101",
            "role": "assistant",
            "usage": {
                "input_tokens": 125000,
                "output_tokens": 4200,
                "cache_read_input_tokens": 900,
            },
            "content": [
                {"type": "text", "text": RESPONSE_TEXT},
                {"type": "thinking", "thinking": THINKING_TEXT},
                {
                    "type": "tool_use",
                    "id": "toolu_01",
                    "name": "Read",
                    "input": {"file_path": "/home/operator/customer-repo/reconcile.go"},
                },
                {
                    "type": "tool_use",
                    "id": "toolu_02",
                    "name": "Edit",
                    "input": {"old_string": DIFF_TEXT, "new_string": DIFF_TEXT},
                },
            ],
        },
        "lastPrompt": PROMPT_TEXT,
    }


def _claude_user_record() -> dict:
    return {
        "sessionId": SESSION_UUID,
        "timestamp": STAMP_B,
        "type": "user",
        "message": {
            "role": "user",
            "content": [{"type": "text", "text": PROMPT_TEXT}],
        },
    }


def _pass_through_trap_record() -> dict:
    """A record whose model and sessionId reach the pass-through failing region.

    Ordered FIRST in the core fixture so its malformed sessionId is the first one
    ``_fold`` sees: a shape-checking parser discards it and the valid UUID from the
    next record wins, while a pass-through parser stores this one and trips the
    invariant. Without this record the core suite is blind to both defects.
    """
    return {
        "sessionId": MALFORMED_SESSION_ID,
        "timestamp": STAMP_A,
        "type": "assistant",
        "message": {
            "model": SHORT_UNKNOWN_MODEL,
            "role": "assistant",
            "usage": {"input_tokens": 1, "output_tokens": 1},
            "content": [{"type": "tool_use", "name": "Bash"}],
        },
    }


def _write_jsonl(directory: Path, name: str, records) -> str:
    path = directory / name
    with open(path, "w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record) + "\n")
    return name


class _FalsificationMixin:
    """Shared hostility and leak assertions."""

    def _assert_hostile(self, raw_bytes: bytes, payloads) -> None:
        """Assert the fixture actually carries what the test claims it carries.

        A regression test whose fixture does not contain the hostile value passes
        for the wrong reason. This asserts the property of the fixture itself, in
        the test body, so a later edit cannot silently disarm it.
        """
        for payload in payloads:
            self.assertGreaterEqual(
                len(payload), 40, "fixture payload must be long enough to be findable"
            )
            self.assertIn(
                payload.encode("utf-8").split(b"\n")[0],
                raw_bytes,
                "fixture does not actually contain the payload it claims to -- "
                "this test would pass for the wrong reason",
            )

    def _assert_no_leak(self, extract, payloads) -> None:
        """Search the WHOLE serialised output, plus repr(), for any payload byte.

        Searching only the fields the parser meant to fill would beg the question.
        ``to_json()`` covers the wire shape; ``repr()`` covers attributes that never
        reach the wire shape; the per-token scan covers a payload chopped at a
        serialisation boundary.
        """
        haystacks = {
            "to_json": extract.to_json(),
            "repr": repr(extract),
            "to_dict": json.dumps(extract.to_dict(), sort_keys=True, default=str),
            "metrics_repr": repr(extract.metrics),
        }
        for label, haystack in haystacks.items():
            self.assertNotIn(
                SENTINEL, haystack, f"sentinel leaked into {label}"
            )
            for payload in payloads:
                for token in payload.replace("\n", " ").split():
                    if len(token) < 8:
                        continue
                    self.assertNotIn(
                        token,
                        haystack,
                        f"payload token {token[:4]}... (len {len(token)}) leaked into {label}",
                    )

    def _assert_non_vacuous(self, extract) -> None:
        """The parse must have produced real metrics, or the leak test proves nothing."""
        self.assertEqual(extract.status, T.ParseStatus.PARSED)
        self.assertGreater(extract.records_parsed, 0, "parsed nothing -- test is vacuous")
        self.assertGreater(extract.metrics.step_count, 0)
        self.assertGreater(
            sum(extract.metrics.tool_counts.values()), 0, "no tools counted -- test is vacuous"
        )


class CorePayloadFalsificationTests(_FalsificationMixin, unittest.TestCase):
    """ISC-24..30: zero payload bytes reach the output struct, obvious placement."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.rel = _write_jsonl(
            self.root,
            "session.jsonl",
            [
                _pass_through_trap_record(),
                _claude_user_record(),
                _claude_record_with_payload_everywhere_obvious(),
            ],
        )
        self.raw = (self.root / self.rel).read_bytes()

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_sentinel_is_not_a_parser_constant(self) -> None:
        """The control's inputs must be independent of the code under test.

        A positive control built from the same literal the production path uses is
        a tautology: it verifies self-consistency, not detection.
        """
        source = (PKG_DIR / "transcript.py").read_text(encoding="utf-8")
        self.assertNotIn(SENTINEL, source)
        for payload in ALL_PAYLOADS:
            first_word = payload.split()[0]
            self.assertNotIn(first_word, source)

    def test_fixture_is_hostile(self) -> None:
        """ISC-29: the fixture genuinely carries prompt and response text."""
        self._assert_hostile(self.raw, ALL_PAYLOADS)

    def test_fixture_reaches_the_pass_through_failing_region(self) -> None:
        """Assert the fixture's hostile INPUTS, not just its assertions.

        Checking that a test asserts the right property is not the same as checking
        that its inputs reach the region where that property can fail. Both values
        below are asserted here in the test body so an edit to the fixture cannot
        silently move them out of the failing region and leave a test that passes
        for the wrong reason.
        """
        # (a) Short enough that map_model_identifier does NOT short-circuit on size.
        self.assertLess(
            len(SHORT_UNKNOWN_MODEL), T.MAX_MODEL_ID_CHARS,
            "model fixture is oversize -- it would hit the size guard and never reach "
            "the rule loop, making the pass-through mutant invisible",
        )
        # (b) Matches no rule, so it lands on the final return -- the mutated line.
        cleaned = SHORT_UNKNOWN_MODEL.lower()
        for token, _family in T.MODEL_MATCH_RULES:
            self.assertNotIn(
                token, cleaned,
                f"model fixture matches rule {token!r} -- it would return early and "
                "never reach the pass-through branch",
            )
        self.assertEqual(T.map_model_identifier(SHORT_UNKNOWN_MODEL), T.ModelFamily.UNKNOWN)

        # (c) The session id fails the UUID shape check, so it reaches the branch a
        #     pass-through defect would corrupt.
        self.assertIsNone(T.coerce_session_uuid(MALFORMED_SESSION_ID))
        self.assertIn(SENTINEL, MALFORMED_SESSION_ID)
        self.assertIn(SENTINEL, SHORT_UNKNOWN_MODEL)

        # (d) Both actually appear in the fixture bytes.
        self.assertIn(MALFORMED_SESSION_ID.encode(), self.raw)
        self.assertIn(SHORT_UNKNOWN_MODEL.encode(), self.raw)

    def test_zero_payload_bytes_in_output_struct(self) -> None:
        """ISC-24..28: the headline KPI -- exactly 0 bytes of payload in the output."""
        indexer = T.TranscriptIndexer()
        with T.ConfinedStore(self.root) as store:
            extract = indexer.poll(store, self.rel, T.TranscriptFormat.CLAUDE_JSONL_V1)
        self._assert_hostile(self.raw, ALL_PAYLOADS)
        self._assert_non_vacuous(extract)
        self._assert_no_leak(extract, ALL_PAYLOADS)

    def test_parse_is_correct_not_merely_empty(self) -> None:
        """ISC-30: the leak test above is not passing by parsing nothing."""
        indexer = T.TranscriptIndexer()
        with T.ConfinedStore(self.root) as store:
            extract = indexer.poll(store, self.rel, T.TranscriptFormat.CLAUDE_JSONL_V1)
        self.assertEqual(extract.records_parsed, 3)
        self.assertEqual(extract.metrics.step_count, 3)
        # 125000 input + 900 cache_read, per SLCD-P4-PRE section 2, +1 from the trap.
        self.assertEqual(extract.metrics.tokens_in, 125901)
        self.assertEqual(extract.metrics.tokens_out, 4201)
        self.assertEqual(extract.metrics.tool_counts["view_file"], 1)
        self.assertEqual(extract.metrics.tool_counts["replace_file_content"], 1)
        self.assertEqual(extract.session_uuid, SESSION_UUID)
        self.assertEqual(extract.metrics.models, ("anthropic/claude-opus",))

    def test_byte_level_zero_payload_kpi(self) -> None:
        """The proposal's KPI is literally 0 bytes. Count them, do not infer them."""
        indexer = T.TranscriptIndexer()
        with T.ConfinedStore(self.root) as store:
            extract = indexer.poll(store, self.rel, T.TranscriptFormat.CLAUDE_JSONL_V1)
        serialised = extract.to_json().encode("utf-8") + repr(extract).encode("utf-8")
        leaked = 0
        for payload in ALL_PAYLOADS:
            blob = payload.encode("utf-8")
            for window in range(0, max(1, len(blob) - 16)):
                if blob[window : window + 16] in serialised:
                    leaked += 16
        self.assertEqual(leaked, 0, f"{leaked} payload bytes reached the output struct")


class StructuralAllowlistFalsificationTests(_FalsificationMixin, unittest.TestCase):
    """ISC-31..38: extraction is allowlist-based, not 'nothing sensitive found'.

    Six placements the parser has no rule for. If extraction were a deny-list over
    known-bad key names, at least one of these would survive: none of them uses a
    key name a deny-list would have thought to block.
    """

    def _placements(self):
        """Six adversarial records. Each keeps the legitimate fields intact so the
        parse stays non-vacuous while the payload sits somewhere unexpected."""
        base_usage = {"input_tokens": 700, "output_tokens": 300}

        # 1. Payload as a FIELD NAME at top level.
        as_field_name = {
            "sessionId": SESSION_UUID,
            "timestamp": STAMP_A,
            "type": "assistant",
            PROMPT_TEXT: "irrelevant",
            "message": {"model": "claude-sonnet-5", "usage": dict(base_usage),
                        "content": [{"type": "tool_use", "name": "Bash"}]},
        }

        # 2. Payload five levels deep under a key the parser never reads.
        deeply_nested = {
            "sessionId": SESSION_UUID,
            "timestamp": STAMP_A,
            "type": "assistant",
            "toolUseResult": {"a": {"b": {"c": {"d": {"e": RESPONSE_TEXT}}}}},
            "message": {"model": "claude-sonnet-5", "usage": dict(base_usage),
                        "content": [{"type": "tool_use", "name": "Bash"}]},
        }

        # 3. Payload INSIDE an allowlisted subtree, at an unexpected sibling key.
        #    ``message.usage`` is allowlisted; ``message.usage.server_note`` is not.
        inside_allowlisted_subtree = {
            "sessionId": SESSION_UUID,
            "timestamp": STAMP_A,
            "type": "assistant",
            "message": {
                "model": "claude-sonnet-5",
                "usage": {**base_usage, "server_note": DIFF_TEXT, "trace": {"raw": PROMPT_TEXT}},
                "content": [{"type": "tool_use", "name": "Bash"}],
            },
        }

        # 4. Payload in an array element ALONGSIDE a legitimate tool_use block.
        array_sibling = {
            "sessionId": SESSION_UUID,
            "timestamp": STAMP_A,
            "type": "assistant",
            "message": {
                "model": "claude-sonnet-5",
                "usage": dict(base_usage),
                "content": [
                    {"type": "tool_use", "name": "Bash", "verbatim": PROMPT_TEXT},
                    {"type": "tool_result", "name": RESPONSE_TEXT},
                    {"type": "text", "text": THINKING_TEXT},
                ],
            },
        }

        # 5. Payload where a MODEL identifier is expected -- an unbounded string in
        #    the one field that is nominally free text in the source.
        payload_as_model = {
            "sessionId": SESSION_UUID,
            "timestamp": STAMP_A,
            "type": "assistant",
            "message": {
                "model": PROMPT_TEXT + " " + RESPONSE_TEXT,
                "usage": dict(base_usage),
                "content": [{"type": "tool_use", "name": "Bash"}],
            },
        }

        # 6. Payload where a token COUNT is expected -- a string that must not be
        #    retained when it fails to coerce.
        payload_as_count = {
            "sessionId": SESSION_UUID,
            "timestamp": STAMP_A,
            "type": "assistant",
            "message": {
                "model": "claude-sonnet-5",
                "usage": {"input_tokens": DIFF_TEXT, "output_tokens": 300},
                "content": [{"type": "tool_use", "name": "Bash"}],
            },
        }

        # Each entry names the payloads that placement actually plants, so the
        # per-placement hostility assertion checks the right strings rather than a
        # blanket list that would fail for the wrong reason.
        return [
            ("payload_as_field_name", as_field_name, [PROMPT_TEXT]),
            ("payload_five_levels_deep", deeply_nested, [RESPONSE_TEXT]),
            (
                "payload_inside_allowlisted_subtree",
                inside_allowlisted_subtree,
                [DIFF_TEXT, PROMPT_TEXT],
            ),
            (
                "payload_beside_legitimate_tool_use",
                array_sibling,
                [PROMPT_TEXT, RESPONSE_TEXT, THINKING_TEXT],
            ),
            ("payload_in_model_field", payload_as_model, [PROMPT_TEXT, RESPONSE_TEXT]),
            ("payload_in_token_count_field", payload_as_count, [DIFF_TEXT]),
        ]

    def test_all_six_placements_leak_nothing(self) -> None:
        """ISC-31..37: none of the six unexpected placements reaches the output."""
        seen_placements = 0
        for label, record, planted in self._placements():
            with self.subTest(placement=label):
                with tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    rel = _write_jsonl(root, "s.jsonl", [record])
                    raw = (root / rel).read_bytes()
                    # Hostility is asserted per placement against what it planted.
                    self._assert_hostile(raw, planted)
                    indexer = T.TranscriptIndexer()
                    with T.ConfinedStore(root) as store:
                        extract = indexer.poll(store, rel, T.TranscriptFormat.CLAUDE_JSONL_V1)
                    self._assert_non_vacuous(extract)
                    # The leak search covers ALL payloads, not just the planted
                    # ones -- a cross-contamination would be a finding too.
                    self._assert_no_leak(extract, ALL_PAYLOADS)
            seen_placements += 1
        self.assertEqual(seen_placements, 6, "all six placements must have run")

    def test_all_six_placements_still_extract_the_legitimate_fields(self) -> None:
        """ISC-38: the parser is not passing the leak test by refusing to parse."""
        for label, record, _planted in self._placements():
            with self.subTest(placement=label):
                with tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    rel = _write_jsonl(root, "s.jsonl", [record])
                    indexer = T.TranscriptIndexer()
                    with T.ConfinedStore(root) as store:
                        extract = indexer.poll(store, rel, T.TranscriptFormat.CLAUDE_JSONL_V1)
                    self.assertEqual(extract.records_parsed, 1)
                    self.assertEqual(extract.session_uuid, SESSION_UUID)
                    self.assertEqual(extract.metrics.tokens_out, 300)
                    self.assertEqual(extract.metrics.tool_counts["run_command"], 1)
                    if label == "payload_in_token_count_field":
                        # The un-coercible string became 0, not a retained value.
                        self.assertEqual(extract.metrics.tokens_in, 0)
                    elif label == "payload_in_model_field":
                        self.assertEqual(extract.metrics.tokens_in, 700)
                        self.assertEqual(extract.metrics.models, ())
                    else:
                        self.assertEqual(extract.metrics.tokens_in, 700)

    def test_unknown_top_level_key_changes_no_output_field(self) -> None:
        """ISC-12: an unknown top-level key is not read, so it changes nothing."""
        clean = {
            "sessionId": SESSION_UUID, "timestamp": STAMP_A, "type": "assistant",
            "message": {"model": "claude-sonnet-5", "usage": {"input_tokens": 5, "output_tokens": 6},
                        "content": [{"type": "tool_use", "name": "Bash"}]},
        }
        dirty = dict(clean)
        dirty["someCustomerField"] = PROMPT_TEXT
        dirty["anotherOne"] = {"nested": RESPONSE_TEXT}
        self.assertEqual(self._extract_dict(clean), self._extract_dict(dirty))

    def test_unknown_nested_key_under_allowlisted_path_changes_no_output_field(self) -> None:
        """ISC-13: an unknown key *inside* an allowlisted subtree changes nothing."""
        clean = {
            "sessionId": SESSION_UUID, "timestamp": STAMP_A, "type": "assistant",
            "message": {"model": "claude-sonnet-5", "usage": {"input_tokens": 5, "output_tokens": 6},
                        "content": [{"type": "tool_use", "name": "Bash"}]},
        }
        dirty = json.loads(json.dumps(clean))
        dirty["message"]["usage"]["leak_here"] = PROMPT_TEXT
        dirty["message"]["hidden"] = RESPONSE_TEXT
        dirty["message"]["content"][0]["input"] = {"cmd": DIFF_TEXT}
        self.assertEqual(self._extract_dict(clean), self._extract_dict(dirty))

    def _extract_dict(self, record) -> dict:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rel = _write_jsonl(root, "s.jsonl", [record])
            indexer = T.TranscriptIndexer()
            with T.ConfinedStore(root) as store:
                extract = indexer.poll(store, rel, T.TranscriptFormat.CLAUDE_JSONL_V1)
            out = extract.to_dict()
            out.pop("bytes_consumed", None)  # differs with record length, by design
            return out


class PropertyBasedLeakTests(_FalsificationMixin, unittest.TestCase):
    """The six hand-written placements are chosen by the same author as the parser.

    That bounds coverage by my imagination, which is the ``positive-control-sharing-
    a-constant-is-a-tautology`` failure at the level of experiment design rather than
    fixture values. This removes that bound: payload sentinels are injected at random
    depths under randomly-generated key names, and the leak assertion runs over every
    generated document. Deterministic seed, so a failure is reproducible.
    """

    DOCUMENTS = 2000
    SEED = 20260915

    def _random_key(self, rng) -> str:
        alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789"
        return "".join(rng.choice(alphabet) for _ in range(rng.randint(1, 12)))

    def _random_value(self, rng, depth, payload):
        """Randomly nested JSON, guaranteed to contain ``payload`` somewhere."""
        if depth <= 0 or rng.random() < 0.25:
            return rng.choice([payload, payload, rng.randint(-(2 ** 40), 2 ** 40),
                               rng.random(), None, True, payload])
        if rng.random() < 0.5:
            return [self._random_value(rng, depth - 1, payload)
                    for _ in range(rng.randint(1, 3))]
        return {self._random_key(rng): self._random_value(rng, depth - 1, payload)
                for _ in range(rng.randint(1, 3))}

    def test_randomised_payload_injection_never_leaks(self) -> None:
        """ISC-37 generalised: no generated document leaks a sentinel byte."""
        import random

        rng = random.Random(self.SEED)
        injected_at_least_once = 0
        parsed_at_least_once = 0

        for _ in range(self.DOCUMENTS):
            record = {
                "sessionId": SESSION_UUID,
                "timestamp": STAMP_A,
                "type": "assistant",
                "message": {
                    "model": "claude-sonnet-5",
                    "usage": {"input_tokens": 11, "output_tokens": 13},
                    "content": [{"type": "tool_use", "name": "Bash"}],
                },
            }
            payload = rng.choice(ALL_PAYLOADS)
            # Inject into a random location: top level, inside message, inside the
            # allowlisted usage object, or inside the content array's element.
            target = rng.choice(["top", "message", "usage", "content_element"])
            blob = self._random_value(rng, rng.randint(1, 4), payload)
            if SENTINEL not in json.dumps(blob):
                # The random walk can terminate on a non-payload leaf. Force the
                # injection rather than letting the document be a silent no-op:
                # a document without the sentinel proves nothing when we then
                # assert the sentinel is absent from the output.
                blob = {self._random_key(rng): payload}
            # Insertion ORDER matters, not just location: a deny-list fallback that
            # returns "the first key that is not obviously bad" picks whichever key
            # was inserted first. Injecting only at the end would leave that defect
            # invisible, so the position is randomised too.
            key = self._random_key(rng)
            first = rng.random() < 0.5

            def _inject(container):
                if first:
                    merged = {key: blob}
                    merged.update(container)
                    container.clear()
                    container.update(merged)
                else:
                    container[key] = blob

            if target == "top":
                _inject(record)
            elif target == "message":
                _inject(record["message"])
            elif target == "usage":
                _inject(record["message"]["usage"])
            else:
                _inject(record["message"]["content"][0])

            serialised = json.dumps(record)
            if SENTINEL in serialised:
                injected_at_least_once += 1

            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / "s.jsonl").write_text(serialised + "\n", encoding="utf-8")
                with T.ConfinedStore(root) as store:
                    extract = T.TranscriptIndexer().poll(
                        store, "s.jsonl", T.TranscriptFormat.CLAUDE_JSONL_V1
                    )
            if extract.records_parsed:
                parsed_at_least_once += 1
            self.assertNotIn(SENTINEL, extract.to_json())
            self.assertNotIn(SENTINEL, repr(extract))

        # Non-vacuity, both directions: the generator really injected, and the
        # parser really parsed. Either being zero would make the loop meaningless.
        self.assertEqual(
            injected_at_least_once, self.DOCUMENTS,
            "generator failed to inject the sentinel into every document -- "
            "the property test would be partly vacuous",
        )
        self.assertEqual(
            parsed_at_least_once, self.DOCUMENTS,
            "parser skipped documents -- the property test proves nothing about parsing",
        )


class GuardMutationFalsificationTests(unittest.TestCase):
    """ISC-72: observe each guard FAIL. A guard never seen failing is untested.

    Each test swaps one guard for a pass-through in-process, drives the same input,
    and asserts the falsification assertion goes RED. Then restores. If any of these
    passes with the mutation applied, the corresponding guard is decorative.
    """

    def setUp(self) -> None:
        self._saved_allow = T.is_allowlisted_string
        self._saved_model = T.map_model_identifier
        self._saved_uuid = T.coerce_session_uuid

    def tearDown(self) -> None:
        T.is_allowlisted_string = self._saved_allow
        T.map_model_identifier = self._saved_model
        T.coerce_session_uuid = self._saved_uuid

    def test_mutating_the_shape_predicate_makes_the_invariant_accept_payload(self) -> None:
        """Mutant: is_allowlisted_string always True. The invariant must stop firing."""
        with self.assertRaises(T.TranscriptPayloadViolation):
            T.assert_zero_payload({"session_uuid": PROMPT_TEXT})

        T.is_allowlisted_string = lambda value: True  # the mutation
        try:
            T.assert_zero_payload({"session_uuid": PROMPT_TEXT})  # now accepted
        except T.TranscriptPayloadViolation:  # pragma: no cover
            self.fail("mutation did not take effect -- the mutation test is not testing")
        finally:
            T.is_allowlisted_string = self._saved_allow

        # And with the guard restored, it fires again.
        with self.assertRaises(T.TranscriptPayloadViolation):
            T.assert_zero_payload({"session_uuid": PROMPT_TEXT})

    def test_mutating_the_model_enum_would_leak_and_the_invariant_catches_it(self) -> None:
        """Mutant: model mapper passes the raw string through.

        This is the exact defect the card names -- "passing a harness's free-text
        model identifier through verbatim because it seems safe". With the mutation
        applied the struct must REFUSE to construct, proving the invariant is the
        backstop and not decoration.
        """
        record = {
            "sessionId": SESSION_UUID, "timestamp": STAMP_A, "type": "assistant",
            "message": {"model": PROMPT_TEXT, "usage": {"input_tokens": 1, "output_tokens": 1},
                        "content": [{"type": "tool_use", "name": "Bash"}]},
        }

        # Unmutated: maps to UNKNOWN, nothing recorded, no exception.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rel = _write_jsonl(root, "s.jsonl", [record])
            with T.ConfinedStore(root) as store:
                clean = T.TranscriptIndexer().poll(store, rel, T.TranscriptFormat.CLAUDE_JSONL_V1)
        self.assertEqual(clean.metrics.models, ())
        self.assertNotIn(SENTINEL, clean.to_json())

        # Mutated: raw pass-through. The chokepoint must refuse the construction.
        class _PassThrough:
            def __init__(self, value: str) -> None:
                self.value = value

        T.map_model_identifier = lambda raw: _PassThrough(str(raw))
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rel = _write_jsonl(root, "s.jsonl", [record])
            indexer = T.TranscriptIndexer()
            with T.ConfinedStore(root) as store:
                # The invariant is CONTAINED, not propagated: a passive detective
                # sensor must not let a guard trip take down its poll loop. The
                # observable is the discarded poll plus the counter, not a traceback.
                leaked = indexer.poll(store, rel, T.TranscriptFormat.CLAUDE_JSONL_V1)
        self.assertEqual(leaked.status, T.ParseStatus.SKIPPED_PAYLOAD_GUARD_TRIPPED)
        self.assertEqual(indexer.payload_guard_trips, 1)
        self.assertNotIn(SENTINEL, leaked.to_json())
        self.assertEqual(leaked.metrics.step_count, 0)

    def test_mutating_the_uuid_shape_check_is_caught_by_the_invariant(self) -> None:
        """Mutant: session uuid coercion returns whatever it was given."""
        record = {
            "sessionId": PROMPT_TEXT, "timestamp": STAMP_A, "type": "assistant",
            "message": {"model": "claude-sonnet-5", "usage": {"input_tokens": 1, "output_tokens": 1},
                        "content": [{"type": "tool_use", "name": "Bash"}]},
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rel = _write_jsonl(root, "s.jsonl", [record])
            with T.ConfinedStore(root) as store:
                clean = T.TranscriptIndexer().poll(store, rel, T.TranscriptFormat.CLAUDE_JSONL_V1)
        self.assertIsNone(clean.session_uuid)

        T.coerce_session_uuid = lambda raw: raw if isinstance(raw, str) else None
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rel = _write_jsonl(root, "s.jsonl", [record])
            indexer = T.TranscriptIndexer()
            with T.ConfinedStore(root) as store:
                leaked = indexer.poll(store, rel, T.TranscriptFormat.CLAUDE_JSONL_V1)
        self.assertEqual(leaked.status, T.ParseStatus.SKIPPED_PAYLOAD_GUARD_TRIPPED)
        self.assertEqual(indexer.payload_guard_trips, 1)
        self.assertNotIn(SENTINEL, leaked.to_json())
        self.assertIsNone(leaked.session_uuid)

    def test_guard_trip_is_contained_and_the_sensor_stays_live(self) -> None:
        """Containment, not just detection.

        Every other test here exercises the GUARD. This one exercises what happens
        after it fires, which is a different property and the one that matters for a
        passive sensor: a tripped invariant must not escape the poll boundary, must
        not kill the poll loop, and must not stop a subsequent clean poll from
        working. Without this, "fail closed" would mean "fail the whole sensor",
        which is interference with the agent it promised only to observe.
        """
        poison = {
            "sessionId": PROMPT_TEXT, "timestamp": STAMP_A, "type": "assistant",
            "message": {"model": "claude-sonnet-5",
                        "usage": {"input_tokens": 1, "output_tokens": 1},
                        "content": [{"type": "tool_use", "name": "Bash"}]},
        }
        clean = {
            "sessionId": SESSION_UUID, "timestamp": STAMP_A, "type": "assistant",
            "message": {"model": "claude-sonnet-5",
                        "usage": {"input_tokens": 5, "output_tokens": 5},
                        "content": [{"type": "tool_use", "name": "Bash"}]},
        }
        # Mutate so the poison record actually trips the guard.
        T.coerce_session_uuid = lambda raw: raw if isinstance(raw, str) else None

        indexer = T.TranscriptIndexer()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            # 1000 records with the poison one FIRST. Not cosmetic: ``_fold``
            # takes the first non-None session_uuid it sees, so a poison record
            # placed mid-stream is shadowed by the clean records before it and
            # never reaches the guard -- the test would then pass for the wrong
            # reason. ``test_the_containment_test_is_not_vacuous`` pins the
            # complementary half.
            records = [poison] + [clean] * 999
            rel = _write_jsonl(root, "poisoned.jsonl", records)
            _write_jsonl(root, "healthy.jsonl", [clean] * 10)

            with T.ConfinedStore(root) as store:
                # No exception crosses this boundary.
                tripped = indexer.poll(store, rel, T.TranscriptFormat.CLAUDE_JSONL_V1)
                # And the sensor is still live for an unrelated file afterwards.
                healthy = indexer.poll(
                    store, "healthy.jsonl", T.TranscriptFormat.CLAUDE_JSONL_V1
                )

        self.assertEqual(tripped.status, T.ParseStatus.SKIPPED_PAYLOAD_GUARD_TRIPPED)
        self.assertEqual(indexer.payload_guard_trips, 1)
        self.assertNotIn(SENTINEL, tripped.to_json())
        self.assertNotIn(SENTINEL, repr(tripped))
        # Fail-closed: the whole poll is discarded, not partially emitted. A
        # mis-wired rule makes the other fields untrustworthy too.
        self.assertEqual(tripped.metrics.step_count, 0)
        self.assertEqual(tripped.records_parsed, 0)
        # Fail-open per process: the next poll works normally.
        self.assertEqual(healthy.status, T.ParseStatus.PARSED)
        self.assertEqual(healthy.records_parsed, 10)
        self.assertEqual(indexer.payload_guard_trips, 1, "clean poll must not trip")

    def test_the_containment_test_is_not_vacuous(self) -> None:
        """Without the mutation the poison record does NOT trip the guard.

        If it tripped anyway, the containment test above would be observing
        something other than what it claims, so assert the unmutated behaviour.
        """
        poison = {
            "sessionId": PROMPT_TEXT, "timestamp": STAMP_A, "type": "assistant",
            "message": {"model": "claude-sonnet-5",
                        "usage": {"input_tokens": 1, "output_tokens": 1},
                        "content": [{"type": "tool_use", "name": "Bash"}]},
        }
        indexer = T.TranscriptIndexer()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rel = _write_jsonl(root, "s.jsonl", [poison])
            with T.ConfinedStore(root) as store:
                result = indexer.poll(store, rel, T.TranscriptFormat.CLAUDE_JSONL_V1)
        self.assertEqual(result.status, T.ParseStatus.PARSED)
        self.assertEqual(indexer.payload_guard_trips, 0)
        self.assertIsNone(result.session_uuid)
        self.assertNotIn(SENTINEL, result.to_json())

    def test_violation_message_carries_no_payload_fragment(self) -> None:
        """ISC-20: the exception that reports a leak must not itself be one."""
        try:
            T.assert_zero_payload({"session_uuid": PROMPT_TEXT})
            self.fail("expected TranscriptPayloadViolation")
        except T.TranscriptPayloadViolation as exc:
            rendered = str(exc) + repr(exc)
            self.assertNotIn(SENTINEL, rendered)
            for token in PROMPT_TEXT.split():
                if len(token) >= 8:
                    self.assertNotIn(token, rendered)
            self.assertIn("length=", rendered)
            self.assertIn("value withheld", rendered)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
