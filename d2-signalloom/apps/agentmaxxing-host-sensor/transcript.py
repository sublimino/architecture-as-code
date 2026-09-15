# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors

"""
Zero-payload transcript metadata parser (SLCD-P4-1).

Streams coding-agent transcripts from the on-disk stores confirmed by SLCD-P4-PRE
and extracts ONLY allowlisted metadata -- step counts, token totals, a fixed-arity
tool histogram, an enumerated model family, a session UUID and a timestamp.

Why this module is shaped the way it is
---------------------------------------
"Never extract ``content``/``text``/``prompt``" is a **deny-list**, and a deny-list
cannot be falsified: it quantifies over the bad keys, which are unbounded. This
module quantifies the other way round -- over the keys it *does* read, which are
finite and frozen in ``FORMAT_RULES``. An unrecognised key is not "skipped"; it is
never addressed at all, because extraction is a walk over the rule table and never
an iteration over the record.

Three layers enforce the Absolute Zero-Customer-Payload invariant, each independently
falsifiable:

1. **Positive field table.** ``FieldRule`` entries name an exact JSON path. The
   record dict is *indexed*, never iterated. See ``_read_path``.
2. **Type funnel.** Every rule declares a coercion whose codomain is ``int``,
   ``ModelFamily``, or one of three shape-validated strings (UUID / RFC3339 /
   canonical tool key). **No rule has codomain ``str``.** A payload therefore cannot
   be the *output* of any rule regardless of what it was given as input.
3. **Constructor-time predicate.** ``assert_zero_payload`` runs inside the single
   output-construction path (``TranscriptExtract.__post_init__``) and rejects any
   string leaf -- key or value, at any depth -- that does not satisfy one of four
   closed shape predicates.

What this module does NOT claim
-------------------------------
A JSONL record's payload shares a physical line with its metadata, so payload bytes
necessarily cross ``read(2)`` and one decoded line is transiently resident while
``json.loads`` runs. That is a property of the format, not a design choice, and it
is bounded (never the whole file: chunked reads, ``READ_CHUNK_BYTES``; never an
unbounded line: ``MAX_LINE_BYTES``). The falsifiable claim -- and the one the KPI
names -- is that **zero bytes of prompt or generated text reach the extracted
structure**.

Module boundary
---------------
This module deliberately shares no helper with ``proc.py`` / the P2-1 procfs
scanner. A future refactor of one must not be able to hand the other a read path it
should never have. ``test_transcript_parser.TranscriptModuleBoundaryTests`` pins it.

Grounding: ``docs/signalloom/slcd-p4-pre-transcript-stores-socket-permissions.md``
"""
from __future__ import annotations

import dataclasses
import datetime
import enum
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
from typing import Any, Callable, Dict, FrozenSet, List, Mapping, Optional, Sequence, Tuple, Union

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:  # pragma: no cover - import style shim, exercised by both paths in CI
    from .coding_agent_models import (
        CANONICAL_TOOL_KEYS,
        Harness,
        MetricsInfo,
        ToolCounts,
        normalize_tool_name,
    )
    from .openat2 import open_beneath
except (ImportError, ValueError):  # pragma: no cover - flat-module import path
    from coding_agent_models import (
        CANONICAL_TOOL_KEYS,
        Harness,
        MetricsInfo,
        ToolCounts,
        normalize_tool_name,
    )
    from openat2 import open_beneath


# ---------------------------------------------------------------------------
# Bounds. Reused from P1-1 rather than redefined -- see MetricsInfo.validate().
# ---------------------------------------------------------------------------

#: 2**53 - 1. Identical to the bound MetricsInfo enforces, so a value this module
#: produces can never be rejected downstream, and a session exceeding 2**31
#: cumulative tokens accumulates exactly instead of wrapping. See ISC-47..49.
MAX_COUNT = 9007199254740991

#: Chunk size for the streaming reader. The parser's working set is a small
#: multiple of this, never the file size.
READ_CHUNK_BYTES = 64 * 1024

#: A single JSONL line above this is skipped unparsed and counted. Bounds the
#: transient residency described in the module docstring.
MAX_LINE_BYTES = 4 * 1024 * 1024

#: Hard ceiling on records consumed in one poll, so a pathological append cannot
#: stall the sensor's duty cycle.
MAX_RECORDS_PER_POLL = 200_000


class TranscriptPayloadViolation(Exception):
    """Raised when a value failing every allowlist shape predicate reaches the output.

    Security guarantee: the message carries ONLY a field path, a type name and a
    length. It never carries a fragment, prefix, suffix or slice of the offending
    value -- the same discipline ``payload_validator.ZeroPayloadSecurityException``
    already applies. Pinned by ISC-20.
    """

    def __init__(self, field_path: str, value_type: str, value_length: int) -> None:
        self.field_path = str(field_path)
        self.value_type = str(value_type)
        self.value_length = int(value_length)
        super().__init__(
            "Zero-Customer-Payload boundary violation in transcript extract: "
            f"field_path={self.field_path!s} type={self.value_type!s} "
            f"length={self.value_length:d} (value withheld)"
        )


# ---------------------------------------------------------------------------
# Closed enumerations
# ---------------------------------------------------------------------------


class TranscriptFormat(str, enum.Enum):
    """Closed enum of transcript formats confirmed on-disk by SLCD-P4-PRE.

    A format not in this enum is never parsed. There is deliberately no
    "best effort" or "generic JSONL" member: guessing a field mapping can misroute
    payload-shaped content into a metadata field the allowlist was not designed to
    scrutinise, which is precisely the failure this card must not ship.
    """

    CLAUDE_JSONL_V1 = "claude_jsonl_v1"
    ANTIGRAVITY_CLI_JSONL_V1 = "antigravity_cli_jsonl_v1"
    CODEX_ROLLOUT_JSONL_V1 = "codex_rollout_jsonl_v1"
    HERMES_REQUEST_DUMP_V1 = "hermes_request_dump_v1"
    ANTIGRAVITY_IDE_SQLITE_V1 = "antigravity_ide_sqlite_v1"
    OPENCODE_SQLITE_V1 = "opencode_sqlite_v1"
    UNRECOGNISED = "unrecognised"


class ParseStatus(str, enum.Enum):
    """Closed enum of poll outcomes. Every path returns one; none returns silence."""

    PARSED = "parsed"
    NO_NEW_DATA = "no_new_data"
    SKIPPED_UNRECOGNISED_FORMAT = "skipped_unrecognised_format"
    SKIPPED_UNSUPPORTED_HARNESS = "skipped_unsupported_harness"
    SKIPPED_PATH_REFUSED = "skipped_path_refused"
    SKIPPED_STORE_ABSENT = "skipped_store_absent"
    #: The zero-payload invariant tripped. Layers 1 and 2 should make this
    #: unreachable; if it is ever observed, a rule has been mis-wired and the whole
    #: poll is discarded rather than partially emitted.
    SKIPPED_PAYLOAD_GUARD_TRIPPED = "skipped_payload_guard_tripped"


class ModelFamily(str, enum.Enum):
    """Closed enum of model families.

    A harness writes its model identifier as free text. An unenumerated string is
    an unbounded field, and an unbounded field reopens P1-1's core risk, so the raw
    identifier is never carried: it is matched against MODEL_MATCH_RULES and the
    *enum member* is what leaves this module. No branch returns the input.
    """

    ANTHROPIC_CLAUDE_OPUS = "anthropic/claude-opus"
    ANTHROPIC_CLAUDE_SONNET = "anthropic/claude-sonnet"
    ANTHROPIC_CLAUDE_HAIKU = "anthropic/claude-haiku"
    ANTHROPIC_CLAUDE_OTHER = "anthropic/claude-other"
    OPENAI_GPT = "openai/gpt"
    OPENAI_O_SERIES = "openai/o-series"
    OPENAI_CODEX = "openai/codex"
    GOOGLE_GEMINI = "google/gemini"
    MOONSHOT_KIMI = "moonshot/kimi"
    XAI_GROK = "xai/grok"
    META_LLAMA = "meta/llama"
    MISTRAL = "mistral/mistral"
    DEEPSEEK = "deepseek/deepseek"
    ALIBABA_QWEN = "alibaba/qwen"
    UNKNOWN = "unknown"


#: Ordered (substring, family) rules. First match wins, so more specific tokens
#: precede their families. The matched substring is discarded; only the family
#: leaves. Order matters: "claude-opus" must precede the bare "claude" fallback.
MODEL_MATCH_RULES: Tuple[Tuple[str, ModelFamily], ...] = (
    ("claude-opus", ModelFamily.ANTHROPIC_CLAUDE_OPUS),
    ("claude-4-opus", ModelFamily.ANTHROPIC_CLAUDE_OPUS),
    ("opus", ModelFamily.ANTHROPIC_CLAUDE_OPUS),
    ("claude-sonnet", ModelFamily.ANTHROPIC_CLAUDE_SONNET),
    ("sonnet", ModelFamily.ANTHROPIC_CLAUDE_SONNET),
    ("claude-haiku", ModelFamily.ANTHROPIC_CLAUDE_HAIKU),
    ("haiku", ModelFamily.ANTHROPIC_CLAUDE_HAIKU),
    ("claude", ModelFamily.ANTHROPIC_CLAUDE_OTHER),
    ("codex", ModelFamily.OPENAI_CODEX),
    ("gpt-", ModelFamily.OPENAI_GPT),
    ("gpt", ModelFamily.OPENAI_GPT),
    ("o1-", ModelFamily.OPENAI_O_SERIES),
    ("o3-", ModelFamily.OPENAI_O_SERIES),
    ("o4-", ModelFamily.OPENAI_O_SERIES),
    ("gemini", ModelFamily.GOOGLE_GEMINI),
    ("kimi", ModelFamily.MOONSHOT_KIMI),
    ("grok", ModelFamily.XAI_GROK),
    ("llama", ModelFamily.META_LLAMA),
    ("mistral", ModelFamily.MISTRAL),
    ("codestral", ModelFamily.MISTRAL),
    ("deepseek", ModelFamily.DEEPSEEK),
    ("qwen", ModelFamily.ALIBABA_QWEN),
)

#: A model identifier longer than this is not a model identifier. Matching is
#: skipped entirely rather than scanning attacker-controlled text of any length.
MAX_MODEL_ID_CHARS = 128


def map_model_identifier(raw: Any) -> ModelFamily:
    """Map an arbitrary source value to a closed ModelFamily member.

    Total function: every input, including non-strings, oversized strings and a
    4 KiB prompt smuggled into a ``model`` field, returns a member of the enum.
    The input is never stored, returned, logged or embedded in an exception.
    """
    if not isinstance(raw, str):
        return ModelFamily.UNKNOWN
    if len(raw) > MAX_MODEL_ID_CHARS:
        # Oversized: refuse to scan. A long value is not a model id, and scanning
        # it would be the only place this module touches unbounded text.
        return ModelFamily.UNKNOWN
    cleaned = raw.strip().lower()
    if not cleaned:
        return ModelFamily.UNKNOWN
    for token, family in MODEL_MATCH_RULES:
        if token in cleaned:
            return family
    return ModelFamily.UNKNOWN


# ---------------------------------------------------------------------------
# Shape predicates. These four closed predicates define every string that is
# permitted to exist anywhere inside a TranscriptExtract.
# ---------------------------------------------------------------------------

UUID_SHAPE_REGEX = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
HEX64_SHAPE_REGEX = re.compile(r"^[0-9a-f]{64}$")
RFC3339_SHAPE_REGEX = re.compile(
    r"^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])"
    r"T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]{1,9})?"
    r"(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"
)

#: Values of every closed enum this module can emit. Membership in this set is the
#: first of the four permitted string shapes.
_ENUM_VALUE_ALLOWLIST: FrozenSet[str] = frozenset(
    [m.value for m in TranscriptFormat]
    + [m.value for m in ParseStatus]
    + [m.value for m in ModelFamily]
    + [m.value for m in Harness]
)

#: The fixed-arity tool vector's keys. Fourth permitted shape.
_TOOL_KEY_ALLOWLIST: FrozenSet[str] = frozenset(CANONICAL_TOOL_KEYS)

#: Structural field names of the output dataclasses. A dict *key* inside the output
#: must be one of these, a canonical tool key, or an enum value -- so a payload
#: cannot ride in as a key either (ISC-22).
_STRUCTURAL_KEY_ALLOWLIST: FrozenSet[str] = frozenset(
    {
        "format",
        "status",
        "harness",
        "session_uuid",
        "first_timestamp",
        "last_timestamp",
        "step_count",
        "tokens_in",
        "tokens_out",
        "tool_counts",
        "models",
        "records_parsed",
        "records_skipped_malformed",
        "records_skipped_oversize",
        "bytes_consumed",
        "skip_reason",
    }
)

#: Human-readable reasons emitted on skip paths. A closed set, so ``skip_reason``
#: is still a shape-validated string and not a free-text channel.
SKIP_REASONS: FrozenSet[str] = frozenset(
    {
        "no confirmed transcript store for this harness on this host",
        "transcript store directory is absent",
        "path refused by openat2 confinement",
        "record discriminators do not match any known format version",
        "format not recognised from confirmed store path layout",
        "sqlite schema does not match the confirmed format version",
        "zero-payload invariant tripped; poll discarded",
    }
)


def is_allowlisted_string(value: str) -> bool:
    """Return True iff ``value`` satisfies one of the four closed shape predicates.

    ``fullmatch``, never ``match``: Python's ``$`` matches immediately before a
    *trailing* newline, so ``re.match(r"^[0-9a-f-]{36}$", uuid + "\\n")`` succeeds and
    admits a one-byte channel. ``fullmatch`` has no such exception. Every character
    class is written ``[0-9]`` rather than ``\\d`` for the same reason in reverse:
    ``\\d`` is Unicode-aware and would admit Arabic-Indic and fullwidth digits into
    something claiming to be a timestamp.
    """
    return (
        value in _ENUM_VALUE_ALLOWLIST
        or value in _TOOL_KEY_ALLOWLIST
        or value in _STRUCTURAL_KEY_ALLOWLIST
        or value in SKIP_REASONS
        or bool(UUID_SHAPE_REGEX.fullmatch(value))
        or bool(HEX64_SHAPE_REGEX.fullmatch(value))
        or bool(RFC3339_SHAPE_REGEX.fullmatch(value))
    )


def assert_zero_payload(obj: Any, _path: str = "$") -> None:
    """Recursively assert every string leaf and every dict key is allowlisted.

    This is the chokepoint. It is invoked from ``TranscriptExtract.__post_init__``
    -- the single construction path for the output struct -- rather than from any
    caller, so no future call site can bypass it.

    Raises ``TranscriptPayloadViolation`` naming only the path, the type and the
    length.
    """
    if obj is None or isinstance(obj, (bool, int, float)):
        return
    if isinstance(obj, enum.Enum):
        assert_zero_payload(obj.value, _path)
        return
    if isinstance(obj, str):
        if not is_allowlisted_string(obj):
            raise TranscriptPayloadViolation(_path, "str", len(obj))
        return
    if isinstance(obj, Mapping):
        for key, val in obj.items():
            if not isinstance(key, str):
                raise TranscriptPayloadViolation(f"{_path}.<key>", type(key).__name__, 0)
            if not is_allowlisted_string(key):
                raise TranscriptPayloadViolation(f"{_path}.<key>", "str", len(key))
            assert_zero_payload(val, f"{_path}.{key}")
        return
    if isinstance(obj, (list, tuple, set, frozenset)):
        for idx, item in enumerate(obj):
            assert_zero_payload(item, f"{_path}[{idx}]")
        return
    if dataclasses.is_dataclass(obj) and not isinstance(obj, type):
        for field in dataclasses.fields(obj):
            assert_zero_payload(getattr(obj, field.name), f"{_path}.{field.name}")
        return
    raise TranscriptPayloadViolation(_path, type(obj).__name__, 0)


# ---------------------------------------------------------------------------
# Bounded coercions. Every FieldRule's codomain is one of these return types.
# ---------------------------------------------------------------------------


def coerce_count(raw: Any) -> int:
    """Coerce to a non-negative integer bounded by MAX_COUNT. Never stringifies.

    A bool is a shape error, not a 1. A NaN/inf float is 0. A string that is not a
    decimal integer is 0 -- crucially the string itself is never retained, so a
    prompt smuggled into ``input_tokens`` becomes the integer 0, not a leak.
    """
    if isinstance(raw, bool):
        return 0
    if isinstance(raw, int):
        return min(max(0, raw), MAX_COUNT)
    if isinstance(raw, float):
        if raw != raw or raw in (float("inf"), float("-inf")):
            return 0
        return min(max(0, int(raw)), MAX_COUNT)
    if isinstance(raw, str):
        if len(raw) > 32:
            return 0
        try:
            return min(max(0, int(raw.strip())), MAX_COUNT)
        except (ValueError, TypeError):
            return 0
    return 0


def coerce_session_uuid(raw: Any) -> Optional[str]:
    """Return ``raw`` iff it is exactly a lowercase UUID or 64-hex string, else None.

    Shape allowlist, not sanitisation: a value that is not already the right shape
    is discarded whole, never trimmed or repaired into one.
    """
    if not isinstance(raw, str):
        return None
    if len(raw) not in (36, 64):
        return None
    candidate = raw.lower()
    if UUID_SHAPE_REGEX.fullmatch(candidate) or HEX64_SHAPE_REGEX.fullmatch(candidate):
        return candidate
    return None


def coerce_rfc3339(raw: Any) -> Optional[str]:
    """Return a CANONICAL RFC3339 timestamp derived from ``raw``, else None.

    Validation is not sanitisation. Accepting ``raw`` verbatim once it matches would
    pass through the source's formatting choices -- ``Z`` versus ``+00:00``, zero to
    nine fractional digits -- and formatting choices an attacker controls are a
    covert channel, however narrow. So the value is *parsed and re-emitted* in one
    canonical form (UTC, whole seconds, ``Z``). The channel then carries semantic
    content only.
    """
    if not isinstance(raw, str):
        return None
    if len(raw) > 40:
        return None
    if not RFC3339_SHAPE_REGEX.fullmatch(raw):
        return None
    try:
        parsed = datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.timezone.utc)
    canonical = parsed.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    # Belt and braces: the re-emitted form must itself satisfy the shape predicate.
    if not RFC3339_SHAPE_REGEX.fullmatch(canonical):
        return None
    return canonical


def coerce_tool_key(raw: Any) -> Optional[str]:
    """Map a raw tool name to one of P1-1's canonical keys, or None.

    Routed through P1-1's ``normalize_tool_name`` rather than a second scheme, so
    transcripts and the procfs path can never produce two different tool_count
    shapes in the same telemetry record. Unknown and customer-defined MCP tool
    names land in ``other_count``.
    """
    if not isinstance(raw, str):
        return None
    if len(raw) > 128:
        # An over-long "tool name" is not a tool name. Route to the overflow bucket
        # without passing the string to the alias table.
        return "other_count"
    return normalize_tool_name(raw)


# ---------------------------------------------------------------------------
# The positive field table
# ---------------------------------------------------------------------------


class FieldKind(str, enum.Enum):
    """What an extracted field contributes to the accumulator."""

    SESSION_UUID = "session_uuid"
    TIMESTAMP = "timestamp"
    MODEL = "model"
    TOKENS_IN = "tokens_in"
    TOKENS_OUT = "tokens_out"
    STEP_INDEX = "step_index"
    TOOL_NAME = "tool_name"
    TOOL_NAME_LIST = "tool_name_list"


@dataclasses.dataclass(frozen=True)
class FieldRule:
    """One allowlisted extraction: an exact JSON path and what it contributes.

    ``path`` is a tuple of dict keys. ``list_path`` (when set) names a key holding a
    list; the rule is then applied once per element, addressing ``path`` *within*
    each element. No rule can express "iterate this record's keys".
    """

    kind: FieldKind
    path: Tuple[str, ...]
    list_path: Tuple[str, ...] = ()
    #: When set, the list element is only read if ``element[type_key] == type_value``.
    type_key: str = ""
    type_value: str = ""


@dataclasses.dataclass(frozen=True)
class FormatSpec:
    """Everything known about one confirmed transcript format."""

    fmt: TranscriptFormat
    harness: Harness
    #: A record must carry at least one of these top-level keys, else the file is
    #: treated as an unrecognised format version and skipped (never guessed at).
    discriminators: Tuple[str, ...]
    rules: Tuple[FieldRule, ...]
    #: Rule contributing +1 to step_count per matching record; empty means "every
    #: record is one step".
    step_per_record: bool = True


#: Frozen, exhaustive. Grounding for every path: SLCD-P4-PRE section 2.
FORMAT_RULES: Dict[TranscriptFormat, FormatSpec] = {
    TranscriptFormat.CLAUDE_JSONL_V1: FormatSpec(
        fmt=TranscriptFormat.CLAUDE_JSONL_V1,
        harness=Harness.CLAUDE,
        discriminators=("sessionId", "session_id", "uuid", "type"),
        rules=(
            FieldRule(FieldKind.SESSION_UUID, ("sessionId",)),
            FieldRule(FieldKind.TIMESTAMP, ("timestamp",)),
            FieldRule(FieldKind.MODEL, ("message", "model")),
            FieldRule(FieldKind.TOKENS_IN, ("message", "usage", "input_tokens")),
            FieldRule(FieldKind.TOKENS_IN, ("message", "usage", "cache_read_input_tokens")),
            FieldRule(FieldKind.TOKENS_OUT, ("message", "usage", "output_tokens")),
            FieldRule(
                FieldKind.TOOL_NAME,
                path=("name",),
                list_path=("message", "content"),
                type_key="type",
                type_value="tool_use",
            ),
        ),
    ),
    TranscriptFormat.ANTIGRAVITY_CLI_JSONL_V1: FormatSpec(
        fmt=TranscriptFormat.ANTIGRAVITY_CLI_JSONL_V1,
        harness=Harness.ANTIGRAVITY,
        discriminators=("step_index", "tool_calls", "source"),
        rules=(
            FieldRule(FieldKind.SESSION_UUID, ("session_id",)),
            FieldRule(FieldKind.TIMESTAMP, ("timestamp",)),
            FieldRule(FieldKind.MODEL, ("model",)),
            FieldRule(FieldKind.STEP_INDEX, ("step_index",)),
            FieldRule(FieldKind.TOKENS_IN, ("usage", "input_tokens")),
            FieldRule(FieldKind.TOKENS_OUT, ("usage", "output_tokens")),
            FieldRule(FieldKind.TOOL_NAME, path=("name",), list_path=("tool_calls",)),
        ),
    ),
    TranscriptFormat.CODEX_ROLLOUT_JSONL_V1: FormatSpec(
        fmt=TranscriptFormat.CODEX_ROLLOUT_JSONL_V1,
        harness=Harness.CODEX,
        discriminators=("payload", "type", "timestamp"),
        rules=(
            FieldRule(FieldKind.SESSION_UUID, ("payload", "session_id")),
            FieldRule(FieldKind.SESSION_UUID, ("payload", "id")),
            FieldRule(FieldKind.TIMESTAMP, ("timestamp",)),
            FieldRule(FieldKind.MODEL, ("payload", "model")),
            FieldRule(FieldKind.TOKENS_IN, ("payload", "info", "total_token_usage", "input_tokens")),
            FieldRule(
                FieldKind.TOKENS_OUT, ("payload", "info", "total_token_usage", "output_tokens")
            ),
            FieldRule(FieldKind.TOOL_NAME, ("payload", "name")),
        ),
    ),
    TranscriptFormat.HERMES_REQUEST_DUMP_V1: FormatSpec(
        fmt=TranscriptFormat.HERMES_REQUEST_DUMP_V1,
        harness=Harness.HERMES,
        discriminators=("session_id", "sessions", "request_id"),
        rules=(
            FieldRule(FieldKind.SESSION_UUID, ("session_id",)),
            FieldRule(FieldKind.TIMESTAMP, ("timestamp",)),
            FieldRule(FieldKind.MODEL, ("model",)),
        ),
    ),
}

#: Harnesses P4-PRE confirmed have no parseable on-disk transcript store on this
#: host class. Declared explicitly with a reason so the gap is a tested outcome,
#: not silence -- the "Aider/Hermes silently unimplemented" failure mode named
#: since P1-PRE. Hermes IS implemented above; only these two are declared absent.
UNSUPPORTED_HARNESSES: Dict[Harness, str] = {
    Harness.AIDER: "no confirmed transcript store for this harness on this host",
    Harness.CPAI: "no confirmed transcript store for this harness on this host",
}


# ---------------------------------------------------------------------------
# SQLite formats. Statements are literals in a frozen table; nothing is composed
# from a record, a path or any caller-supplied string.
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class SqliteSpec:
    """Read-only, count-only SQLite metadata extraction.

    Every statement is a literal here. None selects a content column; ISC-69 pins
    that by scanning this table for prohibited column names.
    """

    fmt: TranscriptFormat
    harness: Harness
    #: Tables that must all exist, else the schema is treated as an unrecognised
    #: format version and the store is skipped (fail closed, never guessed at).
    required_tables: Tuple[str, ...]
    #: (kind, literal SQL). Only COUNT(*) and id/model projections.
    statements: Tuple[Tuple[FieldKind, str], ...]


SQLITE_RULES: Dict[TranscriptFormat, SqliteSpec] = {
    TranscriptFormat.ANTIGRAVITY_IDE_SQLITE_V1: SqliteSpec(
        fmt=TranscriptFormat.ANTIGRAVITY_IDE_SQLITE_V1,
        harness=Harness.ANTIGRAVITY,
        required_tables=("steps",),
        statements=((FieldKind.STEP_INDEX, "SELECT COUNT(*) FROM steps"),),
    ),
    TranscriptFormat.OPENCODE_SQLITE_V1: SqliteSpec(
        fmt=TranscriptFormat.OPENCODE_SQLITE_V1,
        harness=Harness.OPENCODE,
        required_tables=("session", "message"),
        statements=(
            (FieldKind.STEP_INDEX, "SELECT COUNT(*) FROM message"),
            (FieldKind.SESSION_UUID, "SELECT id FROM session ORDER BY id LIMIT 1"),
        ),
    ),
}

#: Column/keyword names that must never appear in any statement above. Used by
#: ISC-69 as a scan over SQLITE_RULES. This is a *test oracle*, not the mechanism:
#: the mechanism is that the statements are frozen literals.
PROHIBITED_SQL_TOKENS: FrozenSet[str] = frozenset(
    {
        "content",
        "text",
        "prompt",
        "response",
        "body",
        "diff",
        "thinking",
        "arguments",
        "payload",
        "blob",
        "insert",
        "update",
        "delete",
        "drop",
        "attach",
        "begin exclusive",
    }
)


# ---------------------------------------------------------------------------
# Output structures
# ---------------------------------------------------------------------------


class TranscriptMetrics(tuple):
    """Allowlisted session metrics, exactly the shape SLCD-P4-PRE section 6.1 froze.

    ``NamedTuple``-shaped by hand so ``tool_counts`` can be returned as a fresh dict
    per access without a mutable default sneaking into the frozen struct.
    """

    __slots__ = ()

    def __new__(
        cls,
        step_count: int = 0,
        tokens_in: int = 0,
        tokens_out: int = 0,
        tool_counts: Optional[Dict[str, int]] = None,
        models: Tuple[str, ...] = (),
    ) -> "TranscriptMetrics":
        counts = dict(tool_counts) if tool_counts else {k: 0 for k in CANONICAL_TOOL_KEYS}
        for key in CANONICAL_TOOL_KEYS:
            counts.setdefault(key, 0)
        # Fixed arity: no key outside P1-1's vector may exist.
        extra = set(counts) - set(CANONICAL_TOOL_KEYS)
        if extra:
            raise ValueError(f"tool_counts carries {len(extra)} non-canonical keys")
        ordered = {k: int(counts[k]) for k in CANONICAL_TOOL_KEYS}
        return tuple.__new__(
            cls,
            (int(step_count), int(tokens_in), int(tokens_out), ordered, tuple(models)),
        )

    @property
    def step_count(self) -> int:
        return self[0]

    @property
    def tokens_in(self) -> int:
        return self[1]

    @property
    def tokens_out(self) -> int:
        return self[2]

    @property
    def tool_counts(self) -> Dict[str, int]:
        return dict(self[3])

    @property
    def models(self) -> Tuple[str, ...]:
        return self[4]

    def to_dict(self) -> Dict[str, Any]:
        return {
            "step_count": self.step_count,
            "tokens_in": self.tokens_in,
            "tokens_out": self.tokens_out,
            "tool_counts": self.tool_counts,
            "models": list(self.models),
        }

    def to_metrics_info(self) -> MetricsInfo:
        """Convert to P1-1's MetricsInfo. Conformance to the frozen schema, ISC-4."""
        return MetricsInfo(
            step_count=self.step_count,
            tokens_in=self.tokens_in,
            tokens_out=self.tokens_out,
            tool_counts=ToolCounts.from_dict(self.tool_counts),
        )


@dataclasses.dataclass(frozen=True)
class TranscriptExtract:
    """The parser's output struct. THE chokepoint: nothing else constructs one.

    ``__post_init__`` runs ``assert_zero_payload`` over the whole object, so the
    struct cannot exist in a state that violates the invariant. That is what makes
    the zero-payload claim a property of the type rather than a claim about the
    author's care.
    """

    fmt: TranscriptFormat
    status: ParseStatus
    harness: Harness
    metrics: TranscriptMetrics
    session_uuid: Optional[str] = None
    first_timestamp: Optional[str] = None
    last_timestamp: Optional[str] = None
    records_parsed: int = 0
    records_skipped_malformed: int = 0
    records_skipped_oversize: int = 0
    bytes_consumed: int = 0
    skip_reason: Optional[str] = None

    def __post_init__(self) -> None:
        assert_zero_payload(self)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "format": self.fmt.value,
            "status": self.status.value,
            "harness": self.harness.value,
            "session_uuid": self.session_uuid,
            "first_timestamp": self.first_timestamp,
            "last_timestamp": self.last_timestamp,
            "step_count": self.metrics.step_count,
            "tokens_in": self.metrics.tokens_in,
            "tokens_out": self.metrics.tokens_out,
            "tool_counts": self.metrics.tool_counts,
            "models": list(self.metrics.models),
            "records_parsed": self.records_parsed,
            "records_skipped_malformed": self.records_skipped_malformed,
            "records_skipped_oversize": self.records_skipped_oversize,
            "bytes_consumed": self.bytes_consumed,
            "skip_reason": self.skip_reason,
        }

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), sort_keys=True)


@dataclasses.dataclass
class TranscriptBookmark:
    """Stateful tail position for one transcript file.

    Per SLCD-P4-PRE section 3.1: re-reading a whole actively-written transcript on
    every poll wastes I/O and risks re-parsing a line truncated mid-write. This
    holds the offset, the inode and a partial-line buffer so a torn trailing line
    survives to the next poll instead of being misparsed or dropped.
    """

    last_offset: int = 0
    last_size: int = 0
    last_mtime_ns: int = 0
    inode: int = 0
    #: Bytes after the final newline seen so far. Never parsed until terminated.
    partial: bytes = b""
    step_count: int = 0
    tokens_in: int = 0
    tokens_out: int = 0
    tool_counts: Dict[str, int] = dataclasses.field(
        default_factory=lambda: {k: 0 for k in CANONICAL_TOOL_KEYS}
    )
    models: set = dataclasses.field(default_factory=set)
    session_uuid: Optional[str] = None
    first_timestamp: Optional[str] = None
    last_timestamp: Optional[str] = None
    records_parsed: int = 0
    records_skipped_malformed: int = 0
    records_skipped_oversize: int = 0
    max_step_index: int = 0

    def reset_position(self) -> None:
        """Rewind to the head of the file, discarding the partial-line buffer.

        Used on truncation and on rotation. Accumulated metrics are intentionally
        NOT reset: the caller decides whether a rotated file is the same session.
        """
        self.last_offset = 0
        self.partial = b""


# ---------------------------------------------------------------------------
# Extraction. The record dict is indexed, never iterated.
# ---------------------------------------------------------------------------


def _read_path(record: Any, path: Sequence[str]) -> Any:
    """Follow an exact key path through nested mappings. Returns None on any miss.

    This is the ONLY function in the module that reads a value out of a decoded
    record, and it can only ever address the keys it is handed. It cannot enumerate
    ``record.keys()``, cannot recurse on discovery, and cannot widen its own path --
    which is what makes the extraction allowlist-based rather than
    "we did not see anything sensitive in the fields we happened to check".
    """
    node = record
    for key in path:
        if not isinstance(node, Mapping):
            return None
        if key not in node:
            return None
        node = node[key]
    return node


def _apply_rule(rule: FieldRule, record: Any, acc: TranscriptBookmark) -> None:
    """Apply one allowlisted rule, folding its bounded value into the accumulator."""
    if rule.list_path:
        container = _read_path(record, rule.list_path)
        if not isinstance(container, list):
            return
        for element in container:
            if not isinstance(element, Mapping):
                continue
            if rule.type_key:
                if element.get(rule.type_key) != rule.type_value:
                    continue
            _fold(rule.kind, _read_path(element, rule.path), acc)
        return
    _fold(rule.kind, _read_path(record, rule.path), acc)


def _fold(kind: FieldKind, raw: Any, acc: TranscriptBookmark) -> None:
    """Fold one raw value into the accumulator through its bounded coercion.

    Note the codomains: int, ModelFamily, or a shape-validated string. There is no
    branch here whose result is the input value itself except where that input has
    already been proven to match a closed shape regex.
    """
    if raw is None:
        return
    if kind is FieldKind.SESSION_UUID:
        if acc.session_uuid is None:
            acc.session_uuid = coerce_session_uuid(raw)
        return
    if kind is FieldKind.TIMESTAMP:
        stamp = coerce_rfc3339(raw)
        if stamp is not None:
            if acc.first_timestamp is None:
                acc.first_timestamp = stamp
            acc.last_timestamp = stamp
        return
    if kind is FieldKind.MODEL:
        family = map_model_identifier(raw)
        if family is not ModelFamily.UNKNOWN:
            acc.models.add(family.value)
        return
    if kind is FieldKind.TOKENS_IN:
        acc.tokens_in = min(acc.tokens_in + coerce_count(raw), MAX_COUNT)
        return
    if kind is FieldKind.TOKENS_OUT:
        acc.tokens_out = min(acc.tokens_out + coerce_count(raw), MAX_COUNT)
        return
    if kind is FieldKind.STEP_INDEX:
        acc.max_step_index = max(acc.max_step_index, coerce_count(raw))
        return
    if kind is FieldKind.TOOL_NAME:
        key = coerce_tool_key(raw)
        if key is not None:
            acc.tool_counts[key] = min(acc.tool_counts.get(key, 0) + 1, MAX_COUNT)
        return
    if kind is FieldKind.TOOL_NAME_LIST:
        if isinstance(raw, list):
            for item in raw:
                key = coerce_tool_key(item)
                if key is not None:
                    acc.tool_counts[key] = min(acc.tool_counts.get(key, 0) + 1, MAX_COUNT)
        return


def extract_record(spec: FormatSpec, record: Any, acc: TranscriptBookmark) -> bool:
    """Project one decoded record onto the accumulator through ``spec.rules``.

    Returns True if the record was recognised as belonging to ``spec``. The record
    object is not retained: the caller drops its only reference immediately after
    this returns, and nothing here stores a reference to it or to any sub-object.
    """
    if not isinstance(record, Mapping):
        return False
    if not any(d in record for d in spec.discriminators):
        return False
    for rule in spec.rules:
        _apply_rule(rule, record, acc)
    if spec.step_per_record:
        acc.step_count = min(acc.step_count + 1, MAX_COUNT)
    acc.records_parsed += 1
    return True


# ---------------------------------------------------------------------------
# Store confinement + format classification
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class TranscriptStore:
    """One SLCD-P4-PRE-confirmed store root, with the formats it may contain."""

    harness: Harness
    #: Path relative to the user's home directory.
    relative_root: str
    fmt: TranscriptFormat
    #: Filename suffix a candidate must carry to be considered at all.
    suffix: str


CONFIRMED_STORES: Tuple[TranscriptStore, ...] = (
    TranscriptStore(Harness.CLAUDE, ".claude/projects", TranscriptFormat.CLAUDE_JSONL_V1, ".jsonl"),
    TranscriptStore(
        Harness.ANTIGRAVITY,
        ".gemini/antigravity-cli/brain",
        TranscriptFormat.ANTIGRAVITY_CLI_JSONL_V1,
        ".jsonl",
    ),
    TranscriptStore(
        Harness.CODEX, ".codex/sessions", TranscriptFormat.CODEX_ROLLOUT_JSONL_V1, ".jsonl"
    ),
    TranscriptStore(
        Harness.HERMES, ".hermes/sessions", TranscriptFormat.HERMES_REQUEST_DUMP_V1, ".json"
    ),
    TranscriptStore(
        Harness.ANTIGRAVITY,
        ".gemini/antigravity/conversations",
        TranscriptFormat.ANTIGRAVITY_IDE_SQLITE_V1,
        ".db",
    ),
    TranscriptStore(
        Harness.OPENCODE,
        ".local/share/opencode",
        TranscriptFormat.OPENCODE_SQLITE_V1,
        ".db",
    ),
)


class ConfinedStore:
    """A pinned store root. Every open goes through openat2 beneath this directory.

    ``open_beneath`` passes ``RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_XDEV``,
    so a symlink anywhere in the relative path -- including one planted inside a
    confirmed store pointing at ``/etc/shadow`` or at an unconfirmed transcript
    directory -- is refused by the kernel, not by a check this module could get
    wrong. Absolute paths and ``..`` traversals are refused for the same reason.
    """

    def __init__(self, root_path: Union[str, Path]) -> None:
        self.root_path = str(root_path)
        self._dirfd = os.open(self.root_path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        self._closed = False

    @property
    def dirfd(self) -> int:
        if self._closed:
            raise ValueError("ConfinedStore descriptor is closed")
        return self._dirfd

    def close(self) -> None:
        if not self._closed:
            self._closed = True
            try:
                os.close(self._dirfd)
            except OSError:
                pass

    def __enter__(self) -> "ConfinedStore":
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        self.close()

    def open_relative(self, relative_path: str) -> int:
        """Open a file beneath the pinned root. Raises OSError if confinement fails."""
        if not relative_path or "\0" in relative_path:
            raise OSError(22, "invalid relative path")
        if os.path.isabs(relative_path):
            raise OSError(13, "absolute paths are refused")
        return open_beneath(self.dirfd, relative_path)


def classify_format(store: TranscriptStore, relative_path: str) -> TranscriptFormat:
    """Classify by confirmed store layout, never by sniffing file contents.

    Content sniffing is how a wrong guess gets made; the store a file lives in is
    what P4-PRE actually verified, so that is the only classifier input.
    """
    if not relative_path.endswith(store.suffix):
        return TranscriptFormat.UNRECOGNISED
    return store.fmt


# ---------------------------------------------------------------------------
# Streaming reader
# ---------------------------------------------------------------------------


def _iter_complete_lines(fd: int, bookmark: TranscriptBookmark) -> Any:
    """Yield complete lines from ``fd`` at ``bookmark.last_offset``, chunk by chunk.

    Never materialises the file. The trailing fragment after the last newline is
    stored in ``bookmark.partial`` and NOT yielded -- a line truncated mid-write is
    buffered for the next poll rather than misparsed as a malformed record or
    silently dropping the whole cycle's data. ``bookmark.last_offset`` advances only
    over bytes that have been consumed as complete lines *or* retained in
    ``partial``, so nothing is read twice and nothing is skipped.
    """
    os.lseek(fd, bookmark.last_offset, os.SEEK_SET)
    buffer = bookmark.partial
    bookmark.partial = b""
    consumed = bookmark.last_offset
    while True:
        chunk = os.read(fd, READ_CHUNK_BYTES)
        if not chunk:
            break
        consumed += len(chunk)
        buffer += chunk
        while True:
            nl = buffer.find(b"\n")
            if nl < 0:
                break
            line = buffer[:nl]
            buffer = buffer[nl + 1 :]
            yield line
        if len(buffer) > MAX_LINE_BYTES:
            # An unterminated run longer than the cap is not a line we will ever
            # parse. Drop it, count it, and resynchronise at the next newline.
            bookmark.records_skipped_oversize += 1
            buffer = b""
    bookmark.partial = buffer
    bookmark.last_offset = consumed


def _decode_line(line: bytes, bookmark: TranscriptBookmark) -> Any:
    """Decode one JSONL line. Returns None and counts on any failure.

    ``json.JSONDecodeError.msg``/``.doc`` embed document text, so the exception is
    caught and discarded whole -- never formatted, logged or attached to a counter.
    """
    if not line.strip():
        return None
    if len(line) > MAX_LINE_BYTES:
        bookmark.records_skipped_oversize += 1
        return None
    try:
        return json.loads(line)
    except (ValueError, UnicodeDecodeError):
        bookmark.records_skipped_malformed += 1
        return None


def _finalise(
    spec_fmt: TranscriptFormat,
    harness: Harness,
    status: ParseStatus,
    bookmark: TranscriptBookmark,
) -> TranscriptExtract:
    """Build the output struct. Runs the invariant via TranscriptExtract.__post_init__."""
    step_count = max(bookmark.step_count, bookmark.max_step_index)
    metrics = TranscriptMetrics(
        step_count=step_count,
        tokens_in=bookmark.tokens_in,
        tokens_out=bookmark.tokens_out,
        tool_counts=bookmark.tool_counts,
        models=tuple(sorted(bookmark.models)),
    )
    return TranscriptExtract(
        fmt=spec_fmt,
        status=status,
        harness=harness,
        metrics=metrics,
        session_uuid=bookmark.session_uuid,
        first_timestamp=bookmark.first_timestamp,
        last_timestamp=bookmark.last_timestamp,
        records_parsed=bookmark.records_parsed,
        records_skipped_malformed=bookmark.records_skipped_malformed,
        records_skipped_oversize=bookmark.records_skipped_oversize,
        bytes_consumed=bookmark.last_offset,
    )


def _skipped(
    fmt: TranscriptFormat, harness: Harness, status: ParseStatus, reason: str
) -> TranscriptExtract:
    """Build an explicit skip outcome. Every refusal path returns one of these."""
    if reason not in SKIP_REASONS:
        raise ValueError("skip reason must come from the closed SKIP_REASONS set")
    return TranscriptExtract(
        fmt=fmt,
        status=status,
        harness=harness,
        metrics=TranscriptMetrics(),
        skip_reason=reason,
    )


class TranscriptIndexer:
    """Stateful, tailing, allowlist-only transcript metadata indexer.

    Usage::

        indexer = TranscriptIndexer()
        with ConfinedStore(store_root) as store:
            extract = indexer.poll(store, "abc/session.jsonl",
                                   TranscriptFormat.CLAUDE_JSONL_V1)

    Re-polling the same (store, relative_path) resumes from the bookmark: unchanged
    files read zero new bytes, appends are counted exactly once, truncation and
    rotation rewind.
    """

    def __init__(self) -> None:
        self._bookmarks: Dict[Tuple[str, str], TranscriptBookmark] = {}
        #: Count of polls discarded because the zero-payload invariant tripped.
        #: Should stay 0 forever; a non-zero value means a rule is mis-wired.
        self.payload_guard_trips: int = 0

    def bookmark_for(self, store_root: str, relative_path: str) -> TranscriptBookmark:
        key = (str(store_root), str(relative_path))
        if key not in self._bookmarks:
            self._bookmarks[key] = TranscriptBookmark()
        return self._bookmarks[key]

    def poll(
        self,
        store: ConfinedStore,
        relative_path: str,
        fmt: TranscriptFormat,
    ) -> TranscriptExtract:
        """Read newly appended records and return the cumulative extract.

        Fail-closed per poll, fail-open per process. Every ambiguity -- an
        unrecognised format, a confinement refusal, an absent store, a tripped
        invariant -- returns an explicit ``ParseStatus`` with a reason from the
        closed ``SKIP_REASONS`` set. Never a guess, never silence, and **never an
        exception across this boundary**.

        The last part is a deployment property, not tidiness. This is a strictly
        passive detective sensor: it must never interfere with the agent it
        observes, so an invariant trip must not propagate out and take down the
        sensor's poll loop. It is contained here, counted in
        ``payload_guard_trips``, and the whole poll is discarded -- discarded rather
        than partially emitted, because a tripped invariant means a rule is
        mis-wired and the *other* fields in that struct are no longer trustworthy
        either. Discarding is fail-closed; skipping silently would be the failure
        mode the invariant exists to prevent.
        """
        try:
            return self._poll_inner(store, relative_path, fmt)
        except TranscriptPayloadViolation:
            # Deliberately re-raised nothing and logged nothing: the exception
            # carries only a path/type/length, but even that is not worth
            # propagating into a caller that may format it. Count and move on.
            self.payload_guard_trips += 1
            self._bookmarks.pop((store.root_path, relative_path), None)
            return _skipped(
                fmt if (fmt in FORMAT_RULES or fmt in SQLITE_RULES)
                else TranscriptFormat.UNRECOGNISED,
                Harness.UNKNOWN,
                ParseStatus.SKIPPED_PAYLOAD_GUARD_TRIPPED,
                "zero-payload invariant tripped; poll discarded",
            )

    def _poll_inner(
        self,
        store: ConfinedStore,
        relative_path: str,
        fmt: TranscriptFormat,
    ) -> TranscriptExtract:
        if fmt in SQLITE_RULES:
            return self._poll_sqlite(store, relative_path, fmt)

        spec = FORMAT_RULES.get(fmt)
        if spec is None:
            return _skipped(
                TranscriptFormat.UNRECOGNISED,
                Harness.UNKNOWN,
                ParseStatus.SKIPPED_UNRECOGNISED_FORMAT,
                "format not recognised from confirmed store path layout",
            )

        try:
            fd = store.open_relative(relative_path)
        except OSError:
            return _skipped(
                fmt,
                spec.harness,
                ParseStatus.SKIPPED_PATH_REFUSED,
                "path refused by openat2 confinement",
            )

        bookmark = self.bookmark_for(store.root_path, relative_path)
        try:
            st = os.fstat(fd)
            if bookmark.inode and st.st_ino != bookmark.inode:
                bookmark.reset_position()  # rotation
            bookmark.inode = st.st_ino
            if st.st_size < bookmark.last_offset:
                bookmark.reset_position()  # truncation
            if st.st_size == bookmark.last_offset and bookmark.records_parsed:
                return _finalise(fmt, spec.harness, ParseStatus.NO_NEW_DATA, bookmark)

            recognised_any = bookmark.records_parsed > 0
            budget = MAX_RECORDS_PER_POLL
            for line in _iter_complete_lines(fd, bookmark):
                if budget <= 0:
                    break
                budget -= 1
                record = _decode_line(line, bookmark)
                if record is None:
                    continue
                if extract_record(spec, record, bookmark):
                    recognised_any = True
                # The only reference to ``record`` dies here, at the end of this
                # iteration. Nothing above retained one.
                record = None

            bookmark.last_size = st.st_size
            bookmark.last_mtime_ns = st.st_mtime_ns

            if not recognised_any and bookmark.records_parsed == 0:
                # Nothing in this file carried any discriminator for the claimed
                # format. Do NOT guess at a field mapping: skip.
                return _skipped(
                    fmt,
                    spec.harness,
                    ParseStatus.SKIPPED_UNRECOGNISED_FORMAT,
                    "record discriminators do not match any known format version",
                )
            return _finalise(fmt, spec.harness, ParseStatus.PARSED, bookmark)
        finally:
            os.close(fd)

    def _poll_sqlite(
        self, store: ConfinedStore, relative_path: str, fmt: TranscriptFormat
    ) -> TranscriptExtract:
        """Count-only, read-only SQLite extraction. Never opens a write transaction."""
        spec = SQLITE_RULES[fmt]
        try:
            fd = store.open_relative(relative_path)
        except OSError:
            return _skipped(
                fmt,
                spec.harness,
                ParseStatus.SKIPPED_PATH_REFUSED,
                "path refused by openat2 confinement",
            )
        os.close(fd)  # confinement proven; sqlite3 needs a path, not an fd

        db_path = os.path.join(store.root_path, relative_path)
        bookmark = self.bookmark_for(store.root_path, relative_path)
        conn = None
        try:
            conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
            present = {
                row[0]
                for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")
            }
            if not set(spec.required_tables).issubset(present):
                return _skipped(
                    fmt,
                    spec.harness,
                    ParseStatus.SKIPPED_UNRECOGNISED_FORMAT,
                    "sqlite schema does not match the confirmed format version",
                )
            for kind, statement in spec.statements:
                row = conn.execute(statement).fetchone()
                if row is None:
                    continue
                _fold(kind, row[0], bookmark)
            bookmark.records_parsed = bookmark.max_step_index
            return _finalise(fmt, spec.harness, ParseStatus.PARSED, bookmark)
        except sqlite3.Error:
            return _skipped(
                fmt,
                spec.harness,
                ParseStatus.SKIPPED_UNRECOGNISED_FORMAT,
                "sqlite schema does not match the confirmed format version",
            )
        finally:
            if conn is not None:
                conn.close()


def poll_unsupported_harness(harness: Harness) -> TranscriptExtract:
    """Explicit declared outcome for a harness with no confirmed store.

    Aider and CPAI have no parseable transcript store confirmed by P4-PRE on this
    host class. Returning a named outcome rather than nothing converts a known gap
    into a tested one -- the "silently unimplemented since P1-PRE" failure mode.
    """
    reason = UNSUPPORTED_HARNESSES.get(harness)
    if reason is None:
        raise ValueError("harness is not in the declared-unsupported set")
    return _skipped(
        TranscriptFormat.UNRECOGNISED,
        harness,
        ParseStatus.SKIPPED_UNSUPPORTED_HARNESS,
        reason,
    )


__all__ = [
    "CONFIRMED_STORES",
    "FORMAT_RULES",
    "MAX_COUNT",
    "MAX_LINE_BYTES",
    "MODEL_MATCH_RULES",
    "PROHIBITED_SQL_TOKENS",
    "READ_CHUNK_BYTES",
    "SKIP_REASONS",
    "SQLITE_RULES",
    "UNSUPPORTED_HARNESSES",
    "ConfinedStore",
    "FieldKind",
    "FieldRule",
    "FormatSpec",
    "ModelFamily",
    "ParseStatus",
    "SqliteSpec",
    "TranscriptBookmark",
    "TranscriptExtract",
    "TranscriptFormat",
    "TranscriptIndexer",
    "TranscriptMetrics",
    "TranscriptPayloadViolation",
    "TranscriptStore",
    "assert_zero_payload",
    "classify_format",
    "coerce_count",
    "coerce_rfc3339",
    "coerce_session_uuid",
    "coerce_tool_key",
    "extract_record",
    "is_allowlisted_string",
    "map_model_identifier",
    "poll_unsupported_harness",
]
