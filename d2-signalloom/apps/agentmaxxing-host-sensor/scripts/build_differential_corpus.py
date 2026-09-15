#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
"""Build the codingagent.v1 cross-language differential corpus (SLCD-P1-3).

The hand-written rejection corpus in ``fixtures/reject/MANIFEST.json`` is a fixed
list of cases someone thought of. It cannot catch a Go-vs-Python disagreement
nobody predicted -- and every real defect found on this card was exactly that:

  * Python's ``$`` matches before a trailing newline, so ``comm = "claude\\n"``
    was accepted by Python and rejected by Go.
  * Go's ``json.Number`` accepts a quoted number, so ``rss_bytes = "5"`` was
    accepted by Go and rejected by Python.
  * ``encoding/json`` treats ``null`` as a no-op, so a null string decoded to
    ``""`` in Go and raised in Python.

None of the three had a case in the manifest, because a reject-list encodes
predictions. This script instead enumerates the input space *systematically*:
for every field in the contract, every adversarial value class. Each case is
emitted with its EXPECTED verdict, and both suites assert
``actual == expected`` -- not ``go_verdict == py_verdict``, which would score
mutual wrongness as agreement.

Deterministic: no randomness, no dict-order dependence, sorted throughout. Run
``--check`` to fail when the committed corpus no longer matches a fresh build.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
SENSOR_DIR = HERE.parent
SCHEMA_PATH = SENSOR_DIR / "schemas" / "coding-agent-telemetry.v1.schema.json"
BASE_PATH = SENSOR_DIR / "schemas" / "fixtures" / "valid" / "claude.json"
OUT_PATH = SENSOR_DIR / "schemas" / "fixtures" / "differential" / "CORPUS.json"

ACCEPT = "accept"
REJECT = "reject"

# Value classes applied to every string field. Each one is a real divergence
# mechanism between the two standard libraries, not an arbitrary bad value.
STRING_PROBES = [
    ("trailing-newline", "{v}\n", REJECT, "Python re.match + $ matches before a final newline; Go's $ is end-of-text"),
    ("leading-newline", "\n{v}", REJECT, "same anchor asymmetry from the other end"),
    ("embedded-nul", "{v}\x00", REJECT, "NUL is outside every frozen pattern but is a legal JSON string char"),
    ("multibyte", "\u00e9{v}", REJECT, "Go len() counts bytes, Python len() counts codepoints"),
    ("astral", "\U0001f600{v}", REJECT, "surrogate-pair handling differs; both must still refuse it"),
    ("nbsp", "\u00a0{v}", REJECT, "non-breaking space is not whitespace to a pattern but looks like one"),
    ("bom", "\ufeff{v}", REJECT, "a BOM inside a value, not at document start"),
    ("null-value", None, REJECT, "encoding/json treats null as a no-op leaving \"\"; Python raises"),
    ("int-value", 12345, REJECT, "type confusion: Python len(int) raises TypeError, not a contract error"),
    ("bool-value", True, REJECT, "bool is a subclass of int in Python"),
    ("empty", "", REJECT, "empty string against a minLength or a pattern that refuses it"),
]

# Value classes applied to every integer field.
INT_PROBES = [
    ("quoted-number", "5", REJECT, "Go json.Number accepts a quoted number; Python isinstance does not"),
    ("quoted-max", "9007199254740991", REJECT, "same, at the boundary"),
    ("float-whole", 1.0, REJECT, "Go refuses a fractional token into int64; a naive Python <= check would pass it"),
    ("float-exp", 1e3, REJECT, "exponent notation is a float in both"),
    ("bool-value", True, REJECT, "isinstance(True, int) is True in Python; Go refuses"),
    ("null-value", None, REJECT, "null is a no-op for encoding/json"),
    ("string-value", "abc", REJECT, "plain type confusion"),
    ("beyond-int64", 9223372036854775808, REJECT, "one past int64; Python ints are unbounded"),
    ("negative", -1, REJECT, "below every frozen minimum"),
    ("leading-zero-string", "05", REJECT, "not a valid JSON number, and a string besides"),
]

# Whole-document probes that no per-field mutation can express.
RAW_PROBES = [
    ("raw-nan", '{"schema_version":"1.0.0","harness":NaN}', REJECT,
     "json.loads accepts NaN by default; Go rejects it as invalid JSON"),
    ("raw-infinity", '{"schema_version":"1.0.0","harness":Infinity}', REJECT,
     "same for Infinity and -Infinity"),
    ("raw-body-null", "null", REJECT, "Unmarshal of null into a struct is a no-op returning no error"),
    ("raw-body-array", "[]", REJECT, "an array where the contract requires an object"),
    ("raw-body-number", "42", REJECT, "a bare number as the whole body"),
    ("raw-body-string", '"claude"', REJECT, "a bare string as the whole body"),
    ("raw-empty", "", REJECT, "an empty body"),
    ("raw-whitespace", "   ", REJECT, "whitespace only"),
    ("raw-trailing-object", '{"a":1} {"b":2}', REJECT, "request smuggling: a second document after the first"),
    ("raw-unterminated", '{"schema_version":"1.0.0"', REJECT, "truncated mid-object"),
    ("raw-unicode-escaped-key", '{"\\u0070id":1}', REJECT,
     "an escaped key spelling of an otherwise-legal name, to prove key matching happens after unescaping"),
]


def string_fields(schema):
    out = []
    for n, s in schema["properties"].items():
        if s.get("type") == "string":
            out.append(([n], s))
    prefix = {"process_info": "process", "kanban_info": "kanban",
              "metrics_info": "metrics", "tool_counts": "metrics.tool_counts",
              "network_info": "network"}
    for key, sub in schema["$defs"].items():
        for n, s in sub["properties"].items():
            if s.get("type") == "string":
                out.append((prefix[key].split(".") + [n], s))
    return out


def int_fields(schema):
    out = []
    prefix = {"process_info": "process", "kanban_info": "kanban",
              "metrics_info": "metrics", "tool_counts": "metrics.tool_counts",
              "network_info": "network"}
    for key, sub in schema["$defs"].items():
        for n, s in sub["properties"].items():
            if s.get("type") == "integer":
                out.append((prefix[key].split(".") + [n], s))
    return out


def get_at(doc, path):
    cur = doc
    for p in path:
        cur = cur[p]
    return cur


def build():
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    base = json.loads(BASE_PATH.read_text(encoding="utf-8"))
    cases = []

    # The positive control. If this is not accepted, every reject below is
    # passing for the wrong reason.
    cases.append({
        "id": "control-base-accepted",
        "op": "set",
        "path": "schema_version",
        "value": "1.0.0",
        "expect": ACCEPT,
        "why": "positive control -- the unmutated base must decode on both sides",
    })

    for path, spec in sorted(string_fields(schema)):
        dotted = ".".join(path)
        current = get_at(base, path)
        for pid, tmpl, expect, why in STRING_PROBES:
            if isinstance(tmpl, str):
                value = tmpl.replace("{v}", str(current))
            else:
                value = tmpl
            cases.append({
                "id": f"{dotted}::{pid}",
                "op": "set", "path": dotted, "value": value,
                "expect": expect, "why": why,
            })

    for path, spec in sorted(int_fields(schema)):
        dotted = ".".join(path)
        for pid, value, expect, why in INT_PROBES:
            cases.append({
                "id": f"{dotted}::{pid}",
                "op": "set", "path": dotted, "value": value,
                "expect": expect, "why": why,
            })

    # Case-variant spellings of every legal key. encoding/json matches struct
    # tags case-insensitively, so a decoder built on struct decode rather than an
    # explicit key set would treat these as known fields and never fire its
    # unknown-field guard.
    for path, _ in sorted(string_fields(schema)) + sorted(int_fields(schema)):
        dotted = ".".join(path)
        leaf = path[-1]
        for variant in sorted({leaf.upper(), leaf.capitalize()} - {leaf}):
            cases.append({
                "id": f"{dotted}::case-variant-{variant}",
                "op": "set",
                "path": ".".join(path[:-1] + [variant]),
                "value": 1,
                "expect": REJECT,
                "why": "encoding/json matches struct tags case-insensitively; an exact key set must not",
            })

    for rid, raw, expect, why in RAW_PROBES:
        cases.append({"id": rid, "op": "raw", "raw": raw, "expect": expect, "why": why})

    cases.sort(key=lambda c: c["id"])

    # Materialise every case into the COMPLETE payload text, and drop the
    # mutation instructions entirely.
    #
    # This is not a convenience. The first run of this corpus reported 46 Go
    # "mismatches" that were an artefact of the harnesses, not the decoders: the
    # Python side passed a parsed dict straight to decode_wire while the Go side
    # unmarshalled into `any` and re-marshalled, which renders float64(1.0) as
    # `1`. The two languages were being handed different bytes for the same case
    # -- the same blind spot this whole card exists to remove, wearing a test
    # harness as a disguise. Emitting the payload as text means both sides
    # decode identical bytes by construction, and neither can build them wrong.
    materialised = []
    for c in cases:
        if c["op"] == "raw":
            payload = c["raw"]
        else:
            doc = json.loads(json.dumps(base))
            parts = c["path"].split(".")
            cur = doc
            for i, p in enumerate(parts):
                if i == len(parts) - 1:
                    cur[p] = c["value"]
                    break
                cur = cur.setdefault(p, {})
            payload = json.dumps(doc, sort_keys=True, separators=(",", ":"))
        materialised.append({
            "id": c["id"],
            "expect": c["expect"],
            "why": c["why"],
            "payload": payload,
        })

    return {
        "_comment": [
            "GENERATED by scripts/build_differential_corpus.py -- DO NOT EDIT.",
            "",
            "Systematic cross-language differential corpus. Every case carries the",
            "COMPLETE payload text and its EXPECTED verdict. Both suites decode the",
            "same bytes and assert actual == expected -- never go_verdict ==",
            "py_verdict, because mutual wrongness is not agreement.",
            "",
            "Payload is text, not a mutation recipe, so neither language can",
            "construct the input differently from the other. That failure mode was",
            "observed while building this file and is the reason for the shape.",
            "",
            "Rebuild:  python3 scripts/build_differential_corpus.py --emit",
            "Verify:   python3 scripts/build_differential_corpus.py --check",
        ],
        "case_count": len(materialised),
        "cases": materialised,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--emit", action="store_true")
    g.add_argument("--check", action="store_true")
    args = ap.parse_args(argv)
    body = json.dumps(build(), indent=2, sort_keys=False, ensure_ascii=True) + "\n"
    if args.emit:
        OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
        OUT_PATH.write_text(body, encoding="utf-8")
        print(f"wrote {OUT_PATH} ({json.loads(body)['case_count']} cases)")
        return 0
    if not OUT_PATH.exists():
        print(f"DRIFT: {OUT_PATH} is missing; run --emit", file=sys.stderr)
        return 1
    if OUT_PATH.read_text(encoding="utf-8") != body:
        print(f"DRIFT: {OUT_PATH} does not match a fresh build", file=sys.stderr)
        return 1
    print(f"PASS: differential corpus matches a fresh build")
    return 0


if __name__ == "__main__":
    sys.exit(main())
