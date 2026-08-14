"""Canonical serialisation of an audit row.

This module is the contract.  Everything else -- the tree, the checkpoint, the
signature, the transparency log -- is standard machinery that only means
anything if two independent implementations, on different machines, years
apart, turn the same rows into the same bytes.  Get this wrong and the control
does not fail loudly; it fails by reporting an intact log as tampered, which is
how verifiers get switched off.

The rules, in full, so that a Go or Rust verifier can be written from this
docstring alone:

ROW ENCODING
    encode(row) = F(ROW_ENCODING_VERSION) || F(id) || F(tenant_id) || F(ts)
                  || F(event_type) || F(agent_id) || F(agent_name)
                  || F(actor) || F(canonical_json(detail))

    where F(NULL)  = 0x00
          F(value) = 0x01 || uint64_be(len(utf8(value))) || utf8(value)

    The tag byte keeps NULL distinct from the empty string: ``agent_name`` is
    nullable free text, so both are reachable, and a schema that renders NULL as
    "" cannot tell "no agent was named" from "an agent was named ''".

    The length prefix is what stops field-boundary forgery.  ``actor`` and
    ``agent_name`` carry attacker-influenced text.  Under a delimiter-joined
    encoding, an actor who can choose their own name can move the boundary and
    make a tampered row serialise identically to an honest one -- the signature
    still verifies and the tamper is invisible.  Length-prefixing makes the
    parse unambiguous, which is the same reason DSSE uses PAE rather than
    concatenating its fields with a separator.

    The version tag is inside the digest.  When a column is added to
    audit_events, the encoding version changes, every digest changes, and the
    change is visible and explicable -- rather than a silent mismatch that reads
    exactly like tampering.

FIELD RENDERING
    Every field is extracted as text in SQL (see reader.CANONICAL_ROW_SQL) so
    that no client driver sits inside the trust chain.  A Go verifier using pgx
    and a Python one using asyncpg must not have to agree about decoder
    behaviour; they only have to agree about SQL.

    id, agent_id   uuid::text -- lowercase, hyphenated, 8-4-4-4-12 (uuid_out).
    ts             to_char(timestamp AT TIME ZONE 'UTC',
                           'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
                   TIMESTAMPTZ::text is rendered in the session's TimeZone and
                   DateStyle, so two verifiers with different session settings
                   read one row and serialise different bytes.  UTC, ISO 8601,
                   always exactly six fractional digits -- which is the full
                   stored resolution, so nothing is rounded away and there are
                   no trailing-zero variants.
    tenant_id,     text, as stored.  Deliberately NOT Unicode-normalised:
    event_type,    normalisation would map two distinct stored values onto one
    agent_name,    digest, which is a collision we would be introducing
    actor          ourselves.  The bytes are the bytes.
    detail         jsonb::text, then canonicalised (below).

CANONICAL JSON
    Derived from RFC 8785 (JCS), with one deliberate deviation, below.

      * Object keys sorted by UTF-16 code unit.  This is the JCS rule and it is
        NOT the same as Python's default code-point sort: U+10000 encodes as the
        surrogate pair D800 DC00, so it sorts before U+FFFD by code unit and
        after it by code point.  An implementation that reaches for
        ``sort_keys=True`` is not conformant and will disagree with a Go
        verifier using a conformant library.
      * No insignificant whitespace; ',' and ':' separators.
      * Strings: escape only what must be escaped -- '"', '\\', and C0 controls,
        using the short forms \\b \\f \\n \\r \\t where they exist and \\uXXXX
        otherwise.  Everything else, including all non-ASCII, is literal UTF-8.
      * Arrays keep their order.  Order is meaning in JSON.

    DEVIATION -- numbers are preserved as their literal source token rather
    than re-formatted as ECMAScript doubles.  JCS mandates the double
    formatting, and for this data that is actively harmful:

      * jsonb stores numbers as ``numeric``, so 1.0 and 1.00 are different
        stored values.  Both parse to the float 1.0, so a JCS round-trip
        collapses two distinct database states onto one digest.
      * ``numeric`` is arbitrary precision.  Any integer above 2^53 is silently
        corrupted by a double round-trip.  A digest that quietly rewrites the
        numbers it attests to is the same failure mode as the VaR95-to-ALE
        clamp that fabricated risk figures in the FAIR engine: the output stays
        plausible, so nobody looks.

    Taking the token verbatim is both more faithful and still fully
    deterministic, because the token comes from ``jsonb_out``, which renders
    ``numeric`` canonically for a given value.  A verifier in another language
    must do the same: parse the JSON without coercing numbers to a native float
    type, and re-emit the original token.

WHAT THIS DOES NOT COVER
    Row ordering within a window is (ts, id), compared bytewise on the canonical
    text and sorted in the client -- never by SQL ORDER BY, whose result for
    ``text`` depends on the database's collation, which is an environment
    setting rather than a property of the data.
"""
import hashlib
import json
from typing import Any, Mapping

# Bump when the encoding changes. The tag is inside every digest, so a bump
# produces an obviously different digest rather than a silent mismatch.
ROW_ENCODING_VERSION = "signalloom.audit.row/v1"

# Locked to the declaration order of public.audit_events (migration 004). A
# future column is an encoding-version change, not a quiet reordering of every
# digest ever published.
ROW_FIELD_ORDER = (
    "id",
    "tenant_id",
    "ts",
    "event_type",
    "agent_id",
    "agent_name",
    "actor",
    "detail",
)

# The only two columns the schema declares nullable. None in any other field
# means the extraction is broken, and encoding it would bake that bug into a
# signed artefact.
NULLABLE_FIELDS = frozenset({"agent_id", "agent_name"})

_NULL_TAG = b"\x00"
_PRESENT_TAG = b"\x01"

# RFC 6962 domain separation. Reused here so a leaf can never be presented as
# an internal node.
_LEAF_PREFIX = b"\x00"


class _RawNumber(str):
    """A JSON number kept as its literal source token.

    Subclasses ``str`` so json.loads can hand it back through parse_int and
    parse_float without a custom decoder, but it must be tested for BEFORE
    ``str`` anywhere it is dispatched on, or numbers would be emitted quoted.
    """

    __slots__ = ()


def _reject_constant(name: str) -> None:
    raise ValueError(
        f"{name} is not representable in jsonb and cannot appear in an audit "
        "detail payload; refusing to place a non-round-trippable value inside "
        "a digest that claims to be reproducible"
    )


_SHORT_ESCAPES = {
    '"': '\\"',
    "\\": "\\\\",
    "\b": "\\b",
    "\f": "\\f",
    "\n": "\\n",
    "\r": "\\r",
    "\t": "\\t",
}


def _emit_string(value: str) -> str:
    out = ['"']
    for ch in value:
        escape = _SHORT_ESCAPES.get(ch)
        if escape is not None:
            out.append(escape)
        elif ch < "\x20":
            out.append("\\u%04x" % ord(ch))
        else:
            # Everything else literal, including DEL and all non-ASCII. RFC 8785
            # escapes the minimum; \u-escaping more would still be valid JSON but
            # would not match a conformant implementation.
            out.append(ch)
    out.append('"')
    return "".join(out)


def _sort_key(key: str) -> bytes:
    """RFC 8785 orders object keys by their UTF-16 code unit sequence."""
    return key.encode("utf-16-be")


def _emit(value: Any, out: list) -> None:
    if isinstance(value, _RawNumber):
        out.append(str(value))
    elif value is None:
        out.append("null")
    elif isinstance(value, bool):
        out.append("true" if value else "false")
    elif isinstance(value, str):
        out.append(_emit_string(value))
    elif isinstance(value, list):
        out.append("[")
        for i, item in enumerate(value):
            if i:
                out.append(",")
            _emit(item, out)
        out.append("]")
    elif isinstance(value, dict):
        out.append("{")
        for i, key in enumerate(sorted(value, key=_sort_key)):
            if i:
                out.append(",")
            out.append(_emit_string(key))
            out.append(":")
            _emit(value[key], out)
        out.append("}")
    else:  # pragma: no cover - unreachable for anything json.loads produces
        raise TypeError(f"cannot canonicalise {type(value).__name__}")


def canonical_json(raw: str) -> str:
    """Canonicalise the text Postgres renders for a jsonb value.

    Input is ``jsonb::text``; output is the RFC 8785-derived form described in
    the module docstring.  Idempotent: canonical output re-canonicalises to
    itself.
    """
    parsed = json.loads(
        raw,
        parse_int=_RawNumber,
        parse_float=_RawNumber,
        parse_constant=_reject_constant,
    )
    out: list = []
    _emit(parsed, out)
    return "".join(out)


def encode_field(value: str | None) -> bytes:
    """Tag-and-length framing for one field. See the module docstring."""
    if value is None:
        return _NULL_TAG
    encoded = value.encode("utf-8")
    # Length is over UTF-8 BYTES, not characters: a character count lets
    # multi-byte text desynchronise the framing, which is the same forgery the
    # length prefix exists to prevent.
    return _PRESENT_TAG + len(encoded).to_bytes(8, "big") + encoded


def encode_row(row: Mapping[str, str | None]) -> bytes:
    """Deterministic byte encoding of one audit row.

    ``row`` is the text projection returned by reader.CANONICAL_ROW_SQL. A
    missing key raises KeyError rather than encoding a silent NULL -- a row that
    lost a column on the way here is a broken extraction, not a row with a null.
    """
    parts = [encode_field(ROW_ENCODING_VERSION)]
    for name in ROW_FIELD_ORDER:
        value = row[name]
        if value is None and name not in NULLABLE_FIELDS:
            raise ValueError(
                f"{name} is NOT NULL in public.audit_events but arrived as None; "
                "the extraction is wrong and encoding it would bake that into a "
                "signed artefact"
            )
        if name == "detail":
            value = canonical_json(value)
        parts.append(encode_field(value))
    return b"".join(parts)


def leaf_hash(encoded_row: bytes) -> bytes:
    """RFC 6962 leaf hash: SHA256(0x00 || record)."""
    return hashlib.sha256(_LEAF_PREFIX + encoded_row).digest()


def row_sort_key(row: Mapping[str, str | None]) -> tuple:
    """Canonical ordering: timestamp, then id, compared bytewise.

    Sorted in the client rather than with SQL ORDER BY because ``text``
    comparison in Postgres follows the database collation, which is an
    environment setting -- two verifiers against replicas with different
    collations would build different trees over identical rows.

    ``ts`` is fixed-width ISO 8601 and ``id`` is fixed-width lowercase hex, so
    bytewise order is chronological then lexicographic with no special casing.
    The id tiebreak is required, not decorative: NOW() is transaction start
    time, so every row written by one transaction shares a timestamp.
    """
    return (row["ts"].encode("utf-8"), row["id"].encode("utf-8"))
