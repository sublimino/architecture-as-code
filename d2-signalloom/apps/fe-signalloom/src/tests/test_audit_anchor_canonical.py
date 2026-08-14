"""The canonical serialisation is the whole control. These tests are the spec.

If two honest verifiers disagree about the bytes, the digest disagrees, the
anchor mismatches, and an intact log reports as tampered -- which is worse than
having no verifier at all, because a verifier that cries wolf gets switched off.
Every test below pins down one ambiguity that would otherwise let two correct
implementations produce different digests over the same rows.

The ambiguities, and why each one is real:

  * JSONB key order.  Postgres jsonb is a parsed representation, not the text
    that was inserted.  ``jsonb_out`` emits keys in the internal order (by key
    length, then bytewise), which is neither insertion order nor sorted order,
    and is not contractually stable across major versions.  We re-sort.
  * JSONB number scale.  jsonb stores numbers as ``numeric``, so ``1.0`` and
    ``1.00`` are DIFFERENT stored values that both parse to the float 1.0.
    Round-tripping through a float would collapse them to one digest, and would
    corrupt any integer above 2^53.  We preserve the literal token.
  * TIMESTAMPTZ rendering.  ``timestamptz::text`` is rendered in the session's
    TimeZone and DateStyle.  Two verifiers with different session settings read
    the same row and serialise different bytes.  We pin UTC, ISO 8601, exactly
    six fractional digits.
  * NULL versus empty string.  ``agent_name`` is nullable and is also free text,
    so NULL and '' are both reachable.  A naive "" encoding makes them identical.
  * Field delimiters.  ``actor`` and ``agent_name`` are free text.  Joining
    fields with a separator lets an attacker who controls one field forge a
    different row that serialises identically.  We length-prefix.
"""
import json

import pytest

from audit_anchor.canonical import (
    ROW_FIELD_ORDER,
    canonical_json,
    encode_row,
    leaf_hash,
    row_sort_key,
)


def _row(**overrides):
    """A complete row in the shape the canonical extraction SQL returns.

    Every value is text (or None) because the extraction projects every column
    to text in SQL -- see reader.CANONICAL_ROW_SQL.  Keeping the driver out
    of the rendering is deliberate: a verifier written in Go with pgx must be
    able to produce identical bytes without reimplementing asyncpg's decoders.
    """
    row = {
        "id": "d9ffcfc7-d712-4860-b999-f2a82e0faf05",
        "tenant_id": "tenant-demo",
        "ts": "2026-08-13T22:55:26.756846Z",
        "event_type": "agent.stunned",
        "agent_id": None,
        "agent_name": "Cardvault Agent",
        "actor": "demo-actor",
        "detail": '{"outcome": "stunned", "agent_ref": "agent-cardvault"}',
    }
    row.update(overrides)
    return row


# ══════════════════════════════════════════════════════════════════════════════
# Determinism
# ══════════════════════════════════════════════════════════════════════════════


def test_encoding_is_stable_across_calls():
    assert encode_row(_row()) == encode_row(_row())


def test_field_order_is_fixed_and_matches_the_table_declaration():
    # Locked so that a future column addition is a deliberate, versioned change
    # rather than something that silently reorders every historical digest.
    assert ROW_FIELD_ORDER == (
        "id",
        "tenant_id",
        "ts",
        "event_type",
        "agent_id",
        "agent_name",
        "actor",
        "detail",
    )


def test_dict_iteration_order_does_not_affect_the_encoding():
    forward = _row()
    reversed_row = dict(reversed(list(forward.items())))
    assert encode_row(forward) == encode_row(reversed_row)


# ══════════════════════════════════════════════════════════════════════════════
# JSONB canonicalisation
# ══════════════════════════════════════════════════════════════════════════════


def test_jsonb_key_order_does_not_affect_the_digest():
    """Postgres does not promise a key order, so we must not depend on one."""
    a = _row(detail='{"alpha": 1, "beta": 2, "gamma": 3}')
    b = _row(detail='{"gamma": 3, "beta": 2, "alpha": 1}')
    assert encode_row(a) == encode_row(b)


def test_nested_object_keys_are_sorted_too():
    a = _row(detail='{"outer": {"z": 1, "a": 2}}')
    b = _row(detail='{"outer": {"a": 2, "z": 1}}')
    assert encode_row(a) == encode_row(b)


def test_array_order_is_preserved():
    """Arrays are ordered in JSON. Sorting them would erase real information."""
    a = _row(detail='{"list": [1, 2, 3]}')
    b = _row(detail='{"list": [3, 2, 1]}')
    assert encode_row(a) != encode_row(b)


def test_keys_sort_by_utf16_code_units_not_code_points():
    """RFC 8785 sorts by UTF-16 code unit, which differs from code-point order.

    U+FFFD sorts AFTER U+10000 by code point but BEFORE it by UTF-16 code unit
    (U+10000 encodes as the surrogate pair D800 DC00, and 0xD800 < 0xFFFD).
    Python's default string sort is by code point, so an implementation that
    just calls sort_keys=True is not RFC 8785 conformant.  Pinned here because a
    Go verifier using a conformant library would then disagree with us.
    """
    bmp = "�"  # UTF-16: FFFD
    astral = "\U00010000"  # UTF-16: D800 DC00 -- surrogate pair, so it sorts first
    out = canonical_json('{"%s": 1, "%s": 2}' % (bmp, astral))
    assert out.index('"%s"' % astral) < out.index('"%s"' % bmp)
    # Guard the premise: Python's own sort puts them the other way round, which
    # is exactly why sort_keys=True is not good enough here.
    assert sorted([bmp, astral]) == [bmp, astral]


def test_number_scale_is_preserved_verbatim():
    """1.0 and 1.00 are different jsonb values and must hash differently."""
    a = _row(detail='{"amount": 1.0}')
    b = _row(detail='{"amount": 1.00}')
    assert encode_row(a) != encode_row(b)


def test_large_integers_survive_intact():
    """A float round-trip silently corrupts anything past 2^53.

    An audit digest that quietly rewrites the numbers it is attesting to is the
    same class of defect as the VaR95-to-ALE clamp that fabricated risk figures
    in the FAIR engine: the output stays plausible, so nobody looks.
    """
    big = "123456789012345678901234567890"
    assert big in canonical_json('{"n": %s}' % big)


def test_canonical_json_emits_no_insignificant_whitespace():
    assert canonical_json('{"a": 1, "b": [1, 2]}') == '{"a":1,"b":[1,2]}'


def test_non_ascii_is_emitted_literally_not_escaped():
    # RFC 8785: only the characters that MUST be escaped are escaped.
    assert canonical_json('{"k": "caf\\u00e9"}') == '{"k":"café"}'


def test_control_characters_use_the_short_escape_forms():
    assert canonical_json('{"k": "a\\nb\\tc"}') == '{"k":"a\\nb\\tc"}'
    assert canonical_json('{"k": "\\u0001"}') == '{"k":"\\u0001"}'


def test_quote_and_backslash_are_escaped():
    assert canonical_json('{"k": "he said \\"hi\\" \\\\ done"}') == (
        '{"k":"he said \\"hi\\" \\\\ done"}'
    )


def test_canonical_json_rejects_nan_and_infinity():
    """jsonb cannot hold them; accepting them would admit a non-round-trippable
    value into a digest that claims to be reproducible."""
    with pytest.raises(ValueError):
        canonical_json('{"k": NaN}')


def test_detail_may_be_any_json_value_not_only_an_object():
    # The column is JSONB NOT NULL, not "JSONB object". Every call site writes an
    # object today, but the encoding must not depend on a convention the schema
    # does not enforce.
    assert canonical_json("[1,2]") == "[1,2]"
    assert canonical_json("null") == "null"


# ══════════════════════════════════════════════════════════════════════════════
# NULL handling
# ══════════════════════════════════════════════════════════════════════════════


def test_null_and_empty_string_are_distinguishable():
    """agent_name is nullable free text, so both values are reachable."""
    assert encode_row(_row(agent_name=None)) != encode_row(_row(agent_name=""))


def test_null_in_one_field_does_not_alias_null_in_another():
    a = _row(agent_id=None, agent_name="x")
    b = _row(agent_id="x", agent_name=None)
    assert encode_row(a) != encode_row(b)


def test_a_non_nullable_field_being_none_is_an_error():
    """NOT NULL in the schema means None here is a bug in the extraction, not a
    value to be silently encoded."""
    with pytest.raises(ValueError):
        encode_row(_row(actor=None))


# ══════════════════════════════════════════════════════════════════════════════
# Delimiter injection
# ══════════════════════════════════════════════════════════════════════════════


def test_free_text_cannot_forge_a_neighbouring_field():
    """The classic length-prefix argument, made concrete.

    With a delimiter-joined encoding, an actor who can name themselves can move
    the field boundary and make row A serialise exactly like row B -- so a
    tampered row would verify.  actor is VARCHAR(255) of attacker-influenced
    text, so this is not hypothetical.
    """
    a = _row(agent_name="alice", actor="bob")
    b = _row(agent_name="alice\x00bob", actor="")
    c = _row(agent_name="alice", actor="|bob")
    d = _row(agent_name="alice|", actor="bob")
    encodings = {encode_row(r) for r in (a, b, c, d)}
    assert len(encodings) == 4


def test_length_prefix_is_over_utf8_bytes_not_characters():
    """A character count would let multi-byte text desynchronise the framing."""
    row = _row(agent_name="é")  # 1 character, 2 UTF-8 bytes
    assert b"\x00\x00\x00\x00\x00\x00\x00\x02" in encode_row(row)


# ══════════════════════════════════════════════════════════════════════════════
# Leaf hashing and ordering
# ══════════════════════════════════════════════════════════════════════════════


def test_leaf_hash_is_domain_separated_from_internal_nodes():
    """RFC 6962 prefixes leaves with 0x00 and internal nodes with 0x01 so that a
    leaf can never be presented as a subtree. Without it, a second-preimage
    attack on the tree is trivial."""
    import hashlib

    encoded = encode_row(_row())
    assert leaf_hash(encoded) == hashlib.sha256(b"\x00" + encoded).digest()


def test_rows_sort_by_timestamp_then_id_bytewise():
    """Sorting happens on the canonical text, in the client, so that no database
    collation setting can reorder a tree."""
    early = _row(ts="2026-08-13T22:00:00.000000Z", id="ffffffff-0000-0000-0000-000000000000")
    late = _row(ts="2026-08-13T23:00:00.000000Z", id="00000000-0000-0000-0000-000000000000")
    assert row_sort_key(early) < row_sort_key(late)


def test_identical_timestamps_are_broken_by_id():
    """Two rows can share a timestamp: NOW() is transaction start time, so every
    row written by one transaction carries the same value."""
    a = _row(ts="2026-08-13T22:00:00.000000Z", id="00000000-0000-0000-0000-000000000001")
    b = _row(ts="2026-08-13T22:00:00.000000Z", id="00000000-0000-0000-0000-000000000002")
    assert row_sort_key(a) < row_sort_key(b)


def test_encoding_is_versioned():
    """The schema tag is inside the digest, so a future encoding change cannot
    be mistaken for tampering -- it produces an obviously different digest with
    a recorded reason, rather than a silent mismatch."""
    from audit_anchor.canonical import ROW_ENCODING_VERSION

    assert ROW_ENCODING_VERSION.encode() in encode_row(_row())


# ══════════════════════════════════════════════════════════════════════════════
# Cross-check against the live rendering
# ══════════════════════════════════════════════════════════════════════════════


def test_canonicalisation_is_idempotent():
    """Canonical output re-canonicalises to itself. Cheap property, and it
    catches escaping bugs that would otherwise only appear on re-verification."""
    raw = '{"z": "caf\\u00e9", "a": [1, 2.50, {"y": null, "x": true}]}'
    once = canonical_json(raw)
    assert canonical_json(once) == once


def test_canonical_output_is_parseable_json_with_equal_meaning():
    raw = '{"b": 2, "a": {"d": [1, 2], "c": "x"}}'
    assert json.loads(canonical_json(raw)) == json.loads(raw)
