#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
"""Single-source generator for the codingagent.v1 wire contract (SLCD-P1-3).

The JSON Schema at ``schemas/coding-agent-telemetry.v1.schema.json`` is the only
place the shape of a coding-agent telemetry record is written down. This script
is the only thing allowed to turn that shape into code. It emits three
artefacts, all marked DO NOT EDIT:

  1. ``signal-ingest/codingagent/wire_gen.go``          -- Go wire type + closed-world decoder
  2. ``agentmaxxing-host-sensor/coding_agent_wire.py``  -- Python wire type + closed-world decoder
  3. ``schemas/codingagent.v1.openapi.json``            -- frozen transport document

Why this exists. Before SLCD-P1-3 the Go struct and the Python model were
hand-written from the same schema and connected to it only by
``sync_coding_agent_schema.py``, which greps each language's source for the
literal ``"pid"``. That probe is satisfiable by a comment, cannot see a field
present in code but absent from the schema, and never parses either language.
The measured consequence was that BOTH consumers accepted
``process.cmdline = "--api-key sk-ant-XXXX"`` -- a nested key outside the
allow-list -- and silently dropped it.

Modes
-----
``--emit``      write all three artefacts
``--check``     regenerate in memory and diff against disk; non-zero on drift
``--classify``  classify a schema pair as compatible / incompatible

Dependencies: standard library only. ``jsonschema`` is not installed on the
target hosts and python3 here is 3.14.4, so the generated Python validator is
emitted rather than delegated.
"""
from __future__ import annotations

import argparse
import ast
import hashlib
import json
from pathlib import Path
import re
import sys
from typing import Any, Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
SENSOR_DIR = HERE.parent
APPS_DIR = SENSOR_DIR.parent

SCHEMA_PATH = SENSOR_DIR / "schemas" / "coding-agent-telemetry.v1.schema.json"
VALIDATOR_PATH = SENSOR_DIR / "payload_validator.py"
GO_OUT = APPS_DIR / "signal-ingest" / "codingagent" / "wire_gen.go"
PY_OUT = SENSOR_DIR / "coding_agent_wire.py"
OPENAPI_OUT = SENSOR_DIR / "schemas" / "codingagent.v1.openapi.json"

GENERATOR_ID = "agentmaxxing-host-sensor/scripts/gen_wire_contract.py"
SCHEMA_REL = "d2-signalloom/apps/agentmaxxing-host-sensor/schemas/coding-agent-telemetry.v1.schema.json"

CONTRACT_LABEL_RE = re.compile(r"^codingagent\.v[1-9][0-9]*$")

# Go initialisms. Applied per underscore-delimited word so `session_id` -> SessionID
# and `read_url_content` -> ReadURLContent without a per-field lookup table.
INITIALISMS = {
    "id": "ID",
    "pid": "PID",
    "ppid": "PPID",
    "cpu": "CPU",
    "rss": "RSS",
    "url": "URL",
    "api": "API",
    "json": "JSON",
    "http": "HTTP",
}

MAX_SAFE_INT = 9007199254740991


class ContractError(Exception):
    """Raised when the schema cannot lawfully produce a frozen contract."""


# --------------------------------------------------------------------------
# Schema -> intermediate representation
# --------------------------------------------------------------------------


def go_name(snake: str) -> str:
    parts = [p for p in snake.split("_") if p]
    out = []
    for p in parts:
        low = p.lower()
        out.append(INITIALISMS.get(low, low[:1].upper() + low[1:]))
    return "".join(out)


def py_type_name(def_key: str) -> str:
    # process_info -> WireProcessInfo
    return "Wire" + "".join(w[:1].upper() + w[1:] for w in def_key.split("_"))


class Field:
    __slots__ = ("name", "spec", "required", "ref")

    def __init__(self, name: str, spec: Dict[str, Any], required: bool) -> None:
        self.name = name
        self.spec = spec
        self.required = required
        self.ref = spec.get("$ref", "").rsplit("/", 1)[-1] if "$ref" in spec else None

    @property
    def kind(self) -> str:
        if self.ref:
            return "object"
        t = self.spec.get("type")
        if t == "integer":
            return "integer"
        if t == "string":
            return "string"
        raise ContractError(f"field {self.name!r}: unsupported type {t!r}")

    @property
    def go_field(self) -> str:
        return go_name(self.name)

    @property
    def go_base_type(self) -> str:
        if self.ref:
            return py_type_name(self.ref)
        return "int64" if self.kind == "integer" else "string"

    @property
    def go_type(self) -> str:
        """Optional fields are pointers so that absent and zero stay distinct.

        A non-pointer optional field cannot express "not sent": an optional
        integer would canonicalise as 0 in Go and be omitted in Python, diverging
        the canonical bytes, and `omitempty` would drop a legitimate zero. v1 has
        no optional integers, but x-version-policy permits adding one, so the
        representation is made correct before that happens rather than after.
        """
        base = self.go_base_type
        return base if self.required else "*" + base

    @property
    def enum(self) -> Optional[List[str]]:
        return self.spec.get("enum")

    def bounds(self) -> Dict[str, Any]:
        s = self.spec
        b: Dict[str, Any] = {}
        for k in ("minimum", "maximum", "minLength", "maxLength", "pattern", "const"):
            if k in s:
                b[k] = s[k]
        if "enum" in s:
            b["enum"] = list(s["enum"])
        return b


class Obj:
    __slots__ = ("key", "go_type", "fields")

    def __init__(self, key: str, go_type: str, fields: List[Field]) -> None:
        self.key = key
        self.go_type = go_type
        self.fields = fields

    @property
    def required_names(self) -> List[str]:
        return [f.name for f in self.fields if f.required]

    @property
    def all_names(self) -> List[str]:
        return [f.name for f in self.fields]


def validate_schema(schema: Dict[str, Any]) -> None:
    """Refuse to emit from a schema that cannot support a closed-world contract."""
    label = schema.get("x-contract-label")
    if not isinstance(label, str) or not CONTRACT_LABEL_RE.match(label):
        raise ContractError(
            f"x-contract-label missing or malformed: {label!r} "
            "(expected e.g. 'codingagent.v1')"
        )
    if schema.get("additionalProperties") is not False:
        raise ContractError("envelope is missing additionalProperties:false")
    for key, sub in schema.get("$defs", {}).items():
        if sub.get("additionalProperties") is not False:
            raise ContractError(f"$defs.{key} is missing additionalProperties:false")
        if not sub.get("required"):
            raise ContractError(f"$defs.{key} declares no required fields")
    if schema.get("x-content-type") != "application/json":
        raise ContractError("x-content-type must be application/json")
    if not schema.get("x-endpoint-path", "").startswith("/"):
        raise ContractError("x-endpoint-path missing or not absolute")
    tc = schema.get("x-tenant-context") or {}
    if not tc.get("header") or tc.get("trusted") is not False:
        raise ContractError("x-tenant-context must declare a header and trusted:false")


def build_ir(schema: Dict[str, Any]) -> Tuple[Obj, List[Obj]]:
    validate_schema(schema)
    defs: List[Obj] = []
    for key in schema["$defs"]:  # insertion order, which is schema order
        sub = schema["$defs"][key]
        req = set(sub.get("required", []))
        fields = [Field(n, s, n in req) for n, s in sub["properties"].items()]
        defs.append(Obj(key, py_type_name(key), fields))
    req = set(schema["required"])
    env_fields = [Field(n, s, n in req) for n, s in schema["properties"].items()]
    envelope = Obj("envelope", "WireEnvelope", env_fields)
    return envelope, defs


# --------------------------------------------------------------------------
# P1-2 DetectionReport shape, derived from payload_validator.py rather than copied
# --------------------------------------------------------------------------


def detection_report_shape(path: Path) -> Tuple[List[str], List[str]]:
    """Return (provider values, DetectionReport.to_dict keys) parsed from source.

    Parsed with ``ast`` rather than restated here so that the 422 body in the
    frozen OpenAPI is P1-2's actual shape. A hand-copy would drift the moment
    P1-2 adds a provider, which is exactly the failure this card removes.
    """
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    providers: List[str] = []
    keys: List[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef) and node.name == "CredentialProvider":
            for stmt in node.body:
                if isinstance(stmt, ast.Assign) and isinstance(stmt.value, ast.Constant):
                    if isinstance(stmt.value.value, str):
                        providers.append(stmt.value.value)
        if isinstance(node, ast.ClassDef) and node.name == "DetectionReport":
            for stmt in node.body:
                if isinstance(stmt, ast.FunctionDef) and stmt.name == "to_dict":
                    for inner in ast.walk(stmt):
                        if isinstance(inner, ast.Return) and isinstance(inner.value, ast.Dict):
                            keys = [
                                k.value
                                for k in inner.value.keys
                                if isinstance(k, ast.Constant) and isinstance(k.value, str)
                            ]
    if not providers:
        raise ContractError("could not parse CredentialProvider members from payload_validator.py")
    if not keys:
        raise ContractError("could not parse DetectionReport.to_dict keys from payload_validator.py")
    return providers, keys


# --------------------------------------------------------------------------
# Go emitter
# --------------------------------------------------------------------------


def go_quote(s: str) -> str:
    return json.dumps(s)


def emit_go(schema: Dict[str, Any], digest: str) -> str:
    envelope, defs = build_ir(schema)
    label = schema["x-contract-label"]
    L: List[str] = []
    a = L.append

    a("// Code generated by " + GENERATOR_ID + "; DO NOT EDIT.")
    a("//")
    a("// Source of truth: " + SCHEMA_REL)
    a("// Contract label:  " + label)
    a("// Schema SHA-256:  " + digest)
    a("//")
    a("// Regenerate with:  make signalloom-wire-contract-emit")
    a("// Verify with:      make signalloom-wire-contract-check")
    a("//")
    a("// Hand-editing this file is detected two ways: gen_wire_contract.py --check")
    a("// diffs it against a fresh generation, and TestCodingAgentWireContract_SchemaDigest")
    a("// recomputes the schema digest above from the canonical schema on disk.")
    a("")
    a("package codingagent")
    a("")
    a("import (")
    a('\t"bytes"')
    a('\t"encoding/json"')
    a('\t"fmt"')
    a('\t"io"')
    a('\t"regexp"')
    a('\t"sort"')
    a('\t"unicode/utf8"')
    a(")")
    a("")
    a("// WireContractLabel is the structural version carried on the wire. A consumer")
    a("// branches on this value; it is never inferred from the shape of the payload.")
    a("const WireContractLabel = " + go_quote(label))
    a("")
    a("// WireSchemaSHA256 is the SHA-256 of the canonical schema this file was generated")
    a("// from. A schema edit without a regeneration changes the file and not this constant.")
    a("const WireSchemaSHA256 = " + go_quote(digest))
    a("")
    a("// WireSchemaRelPath locates the canonical schema relative to the repository root.")
    a("const WireSchemaRelPath = " + go_quote(SCHEMA_REL))
    a("")
    a("// WireEndpointPath is the frozen transport path. NOTE: it does not route to")
    a("// signal-ingest today -- see docs/signalloom/slcd-p1-3-wire-contract.md.")
    a("const WireEndpointPath = " + go_quote(schema["x-endpoint-path"]))
    a("")
    a("// WireContractHeader carries the contract label on every request.")
    a('const WireContractHeader = "X-SignalLoom-Contract"')
    a("")
    a("// WireTenantHeader is reserved and deliberately NOT trusted. Tenancy is derived")
    a("// from the verified principal by ProtectedRouter.authorize; see api/tenant_bridge.go.")
    a("const WireTenantHeader = " + go_quote(schema["x-tenant-context"]["header"]))
    a("")

    # regexes
    a("// Generated validation patterns, one per bounded string in the schema.")
    a("var (")
    for obj in [envelope] + defs:
        for f in obj.fields:
            if f.kind == "string" and "pattern" in f.spec:
                a(
                    "\tre%s%s = regexp.MustCompile(`%s`)"
                    % (go_name(obj.key), f.go_field, f.spec["pattern"])
                )
    a(")")
    a("")

    # enums
    for obj in [envelope] + defs:
        for f in obj.fields:
            if f.enum:
                var = "wireAllowed" + go_name(obj.key) + f.go_field
                a("// %s is the frozen enum for %s." % (var, f.name))
                a("var %s = map[string]struct{}{" % var)
                for m in f.enum:
                    a("\t%s: {}," % go_quote(m))
                a("}")
                a("")

    # key sets
    for obj in [envelope] + defs:
        a("// wireKeys%s is the closed key set for the %s object." % (go_name(obj.key), obj.key))
        a("var wireKeys%s = map[string]struct{}{" % go_name(obj.key))
        for n in obj.all_names:
            a("\t%s: {}," % go_quote(n))
        a("}")
        a("")
        a("// wireRequired%s is the required key set for the %s object." % (go_name(obj.key), obj.key))
        a("var wireRequired%s = []string{" % go_name(obj.key))
        for n in obj.required_names:
            a("\t%s," % go_quote(n))
        a("}")
        a("")

    # structs
    for obj in defs + [envelope]:
        a("// %s is generated from $defs.%s." % (obj.go_type, obj.key))
        a("type %s struct {" % obj.go_type)
        for f in obj.fields:
            tag = f.name if f.required else f.name + ",omitempty"  # pointer => nil is genuinely absent
            a("\t%s %s `json:\"%s\"`" % (f.go_field, f.go_type, tag))
        a("}")
        a("")

    # generic object splitter with duplicate-key rejection
    a(GO_HELPERS)

    # per-object decoders
    for obj in defs + [envelope]:
        fn = "decodeWire" + go_name(obj.key)
        a("// %s decodes the %s object under closed-world rules." % (fn, obj.key))
        a("func %s(raw []byte, path string) (%s, error) {" % (fn, obj.go_type))
        a("\tvar out %s" % obj.go_type)
        a("\tm, err := wireSplitObject(raw, path)")
        a("\tif err != nil {")
        a("\t\treturn out, err")
        a("\t}")
        a("\tfor k := range m {")
        a("\t\tif _, ok := wireKeys%s[k]; !ok {" % go_name(obj.key))
        a("\t\t\treturn out, fmt.Errorf(\"codingagent/wire: %s: unlisted field is not in the codingagent.v1 allow-list\", wireJoin(path, k))")
        a("\t\t}")
        a("\t}")
        a("\tfor _, k := range wireRequired%s {" % go_name(obj.key))
        a("\t\tif _, ok := m[k]; !ok {")
        a("\t\t\treturn out, fmt.Errorf(\"codingagent/wire: %s: required field is missing\", wireJoin(path, k))")
        a("\t\t}")
        a("\t}")
        for f in obj.fields:
            a("\tif v, ok := m[%s]; ok {" % go_quote(f.name))
            fp = "wireJoin(path, %s)" % go_quote(f.name)
            if f.kind == "object":
                sub = "decodeWire" + go_name(f.ref)
                a("\t\tsv, err := %s(v, %s)" % (sub, fp))
                a("\t\tif err != nil {")
                a("\t\t\treturn out, err")
                a("\t\t}")
                a("\t\tout.%s = %ssv" % (f.go_field, "" if f.required else "&"))
            elif f.kind == "integer":
                a("\t\tn, err := wireInt(v, %s)" % fp)
                a("\t\tif err != nil {")
                a("\t\t\treturn out, err")
                a("\t\t}")
                lo = f.spec.get("minimum")
                hi = f.spec.get("maximum")
                if lo is not None or hi is not None:
                    lo = 0 if lo is None else lo
                    hi = MAX_SAFE_INT if hi is None else hi
                    a("\t\tif n < %d || n > %d {" % (lo, hi))
                    a("\t\t\treturn out, fmt.Errorf(\"codingagent/wire: %%s: integer out of bounds [%d, %d]\", %s)" % (lo, hi, fp))
                    a("\t\t}")
                a("\t\tout.%s = %sn" % (f.go_field, "" if f.required else "&"))
            else:
                a("\t\ts, err := wireString(v, %s)" % fp)
                a("\t\tif err != nil {")
                a("\t\t\treturn out, err")
                a("\t\t}")
                if "const" in f.spec:
                    a("\t\tif s != %s {" % go_quote(f.spec["const"]))
                    a("\t\t\treturn out, fmt.Errorf(\"codingagent/wire: %%s: must equal %s\", %s)" % (f.spec["const"], fp))
                    a("\t\t}")
                mn = f.spec.get("minLength")
                mx = f.spec.get("maxLength")
                if mn is not None or mx is not None:
                    mn = 0 if mn is None else mn
                    mx = 0 if mx is None else mx
                    if mx:
                        a("\t\tif wireLen(s) < %d || wireLen(s) > %d {" % (mn, mx))
                    else:
                        a("\t\tif wireLen(s) < %d {" % mn)
                    a("\t\t\treturn out, fmt.Errorf(\"codingagent/wire: %%s: length %%d outside [%d, %d]\", %s, wireLen(s))" % (mn, mx, fp))
                    a("\t\t}")
                if "pattern" in f.spec:
                    a("\t\tif !re%s%s.MatchString(s) {" % (go_name(obj.key), f.go_field))
                    a("\t\t\treturn out, fmt.Errorf(\"codingagent/wire: %%s: value does not match the frozen pattern\", %s)" % fp)
                    a("\t\t}")
                if f.enum:
                    var = "wireAllowed" + go_name(obj.key) + f.go_field
                    a("\t\tif _, ok := %s[s]; !ok {" % var)
                    a("\t\t\treturn out, fmt.Errorf(\"codingagent/wire: %%s: value is outside the frozen enum\", %s)" % fp)
                    a("\t\t}")
                a("\t\tout.%s = %ss" % (f.go_field, "" if f.required else "&"))
            a("\t}")
        a("\treturn out, nil")
        a("}")
        a("")

    # public decode
    a("// DecodeWire decodes a codingagent.v1 payload under closed-world rules: every")
    a("// object rejects a key outside its frozen set at every nesting depth, a")
    a("// duplicate key is an error rather than last-wins, and no error message ever")
    a("// quotes a rejected value.")
    a("func DecodeWire(data []byte) (*WireEnvelope, error) {")
    a("\tev, err := decodeWireEnvelope(data, \"\")")
    a("\tif err != nil {")
    a("\t\treturn nil, err")
    a("\t}")
    a("\treturn &ev, nil")
    a("}")
    a("")

    # canonical maps
    for obj in defs + [envelope]:
        a("// canonicalMap renders %s as the canonical key/value map." % obj.go_type)
        a("func (v %s) canonicalMap() map[string]any {" % obj.go_type)
        a("\tm := map[string]any{}")
        for f in obj.fields:
            if f.required:
                if f.kind == "object":
                    a("\tm[%s] = v.%s.canonicalMap()" % (go_quote(f.name), f.go_field))
                else:
                    a("\tm[%s] = v.%s" % (go_quote(f.name), f.go_field))
            else:
                # One nil test for every optional kind. Anything kind-specific
                # here is how Go and Python drift on a field neither has yet.
                a("\tif v.%s != nil {" % f.go_field)
                if f.kind == "object":
                    a("\t\tm[%s] = v.%s.canonicalMap()" % (go_quote(f.name), f.go_field))
                else:
                    a("\t\tm[%s] = *v.%s" % (go_quote(f.name), f.go_field))
                a("\t}")
        a("\treturn m")
        a("}")
        a("")

    a(GO_CANONICAL)
    return "\n".join(L) + "\n"


GO_HELPERS = '''// wireJoin builds a dotted field path for error messages. It never carries a value.
func wireJoin(path, key string) string {
	if path == "" {
		return key
	}
	return path + "." + key
}

// wireSplitObject splits one JSON object into its immediate members, rejecting a
// duplicate key rather than silently taking the last one. Both encoding/json and
// Python's json module are last-wins by default, so a key-set check over a parsed
// map cannot see that two values were sent for one field.
func wireSplitObject(raw []byte, path string) (map[string]json.RawMessage, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	tok, err := dec.Token()
	if err != nil {
		return nil, fmt.Errorf("codingagent/wire: %s: not valid JSON", wireWhere(path))
	}
	d, ok := tok.(json.Delim)
	if !ok || d != '{' {
		return nil, fmt.Errorf("codingagent/wire: %s: expected a JSON object", wireWhere(path))
	}
	out := map[string]json.RawMessage{}
	for dec.More() {
		kt, err := dec.Token()
		if err != nil {
			return nil, fmt.Errorf("codingagent/wire: %s: malformed object key", wireWhere(path))
		}
		key, ok := kt.(string)
		if !ok {
			return nil, fmt.Errorf("codingagent/wire: %s: non-string object key", wireWhere(path))
		}
		if _, dup := out[key]; dup {
			return nil, fmt.Errorf("codingagent/wire: %s: duplicate key %q", wireWhere(path), wireJoin(path, key))
		}
		var val json.RawMessage
		if err := dec.Decode(&val); err != nil {
			return nil, fmt.Errorf("codingagent/wire: %s: malformed value", wireJoin(path, key))
		}
		out[key] = val
	}
	if _, err := dec.Token(); err != nil {
		return nil, fmt.Errorf("codingagent/wire: %s: unterminated object", wireWhere(path))
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, fmt.Errorf("codingagent/wire: %s: trailing content after the object", wireWhere(path))
	}
	return out, nil
}

// wireWhere names the object under inspection without quoting any value.
func wireWhere(path string) string {
	if path == "" {
		return "envelope"
	}
	return path
}

// wireIsNull reports whether the raw token is a JSON null.
//
// encoding/json treats null as a documented no-op for most destinations: it
// leaves a string as "" and a struct zeroed, returning no error. Python's
// isinstance checks reject it. Left alone that is a decoder asymmetry, and in v1
// it is masked only by the accident that every optional string carries a pattern
// which refuses the empty string.
func wireIsNull(raw json.RawMessage) bool {
	return bytes.Equal(bytes.TrimSpace(raw), []byte("null"))
}

// wireInt decodes a JSON integer, refusing a float, a quoted number, or a null.
//
// The quoted-number case is an encoding/json quirk rather than an oversight:
// unmarshalling into json.Number accepts "5" as readily as 5, so without the
// leading-quote guard Go would take a string where the contract says integer and
// Python would refuse it.
func wireInt(raw json.RawMessage, path string) (int64, error) {
	if wireIsNull(raw) {
		return 0, fmt.Errorf("codingagent/wire: %s: expected an integer, got null", path)
	}
	if t := bytes.TrimSpace(raw); len(t) > 0 && t[0] == '"' {
		return 0, fmt.Errorf("codingagent/wire: %s: expected an integer, not a quoted number", path)
	}
	var n json.Number
	if err := json.Unmarshal(raw, &n); err != nil {
		return 0, fmt.Errorf("codingagent/wire: %s: expected an integer", path)
	}
	i, err := n.Int64()
	if err != nil {
		return 0, fmt.Errorf("codingagent/wire: %s: expected an integer, not a fractional number", path)
	}
	return i, nil
}

// wireString decodes a JSON string, refusing any other type including null.
func wireString(raw json.RawMessage, path string) (string, error) {
	if wireIsNull(raw) {
		return "", fmt.Errorf("codingagent/wire: %s: expected a string, got null", path)
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return "", fmt.Errorf("codingagent/wire: %s: expected a string", path)
	}
	return s, nil
}

// wireLen counts CODEPOINTS, not bytes.
//
// JSON Schema minLength/maxLength are defined over characters and Python's len()
// counts codepoints, but Go's len() counts UTF-8 bytes. On a multi-byte value the
// two decoders would disagree about the same bound.
func wireLen(s string) int {
	return utf8.RuneCountInString(s)
}
'''

GO_CANONICAL = '''// CanonicalJSON renders the envelope in the frozen canonical form: UTF-8, keys
// sorted lexicographically at every level, no insignificant whitespace, no HTML
// escaping and no trailing newline.
//
// encoding/json sorts map keys and escapes <, > and & by default; Python's
// json.dumps sorts only on request and escapes non-ASCII by default. Neither
// default matches the other, so both sides are configured explicitly rather than
// relied upon to agree.
func (v WireEnvelope) CanonicalJSON() ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v.canonicalMap()); err != nil {
		return nil, err
	}
	return bytes.TrimRight(buf.Bytes(), "\\n"), nil
}

// WireAllowedKeys returns every field name the contract admits, as dotted paths,
// sorted. Derived from the generated key sets so a test cannot drift from the
// decoder it is checking.
func WireAllowedKeys() []string {
	var out []string
	add := func(prefix string, set map[string]struct{}) {
		for k := range set {
			out = append(out, wireJoin(prefix, k))
		}
	}
	add("", wireKeysEnvelope)
	add("process", wireKeysProcessInfo)
	add("kanban", wireKeysKanbanInfo)
	add("metrics", wireKeysMetricsInfo)
	add("metrics.tool_counts", wireKeysToolCounts)
	add("network", wireKeysNetworkInfo)
	sort.Strings(out)
	return out
}
'''


# --------------------------------------------------------------------------
# Python emitter
# --------------------------------------------------------------------------


def emit_py(schema: Dict[str, Any], digest: str) -> str:
    envelope, defs = build_ir(schema)
    label = schema["x-contract-label"]
    L: List[str] = []
    a = L.append

    a("# SPDX-License-Identifier: Apache-2.0")
    a("# Copyright 2026 ControlPlane Security Authors")
    a('"""Generated by ' + GENERATOR_ID + "; DO NOT EDIT.")
    a("")
    a("Source of truth: " + SCHEMA_REL)
    a("Contract label:  " + label)
    a("Schema SHA-256:  " + digest)
    a("")
    a("Regenerate with:  make signalloom-wire-contract-emit")
    a("Verify with:      make signalloom-wire-contract-check")
    a("")
    a("Hand-editing this file is detected two ways: gen_wire_contract.py --check")
    a("diffs it against a fresh generation, and test_coding_agent_wire_contract.py")
    a("recomputes the schema digest above from the canonical schema on disk.")
    a('"""')
    a("from __future__ import annotations")
    a("")
    a("import json")
    a("import re")
    a("from typing import Any, Dict, List, Tuple")
    a("")
    a("CONTRACT_LABEL = " + json.dumps(label))
    a("SCHEMA_SHA256 = " + json.dumps(digest))
    a("SCHEMA_REL_PATH = " + json.dumps(SCHEMA_REL))
    a("ENDPOINT_PATH = " + json.dumps(schema["x-endpoint-path"]))
    a('CONTRACT_HEADER = "X-SignalLoom-Contract"')
    a("# Reserved and deliberately NOT trusted. Tenancy is derived server-side from the")
    a("# verified principal; a client-supplied value influences nothing.")
    a("TENANT_HEADER = " + json.dumps(schema["x-tenant-context"]["header"]))
    a("")
    a("")
    a("class WireContractError(ValueError):")
    a('    """Raised when a payload departs from the frozen contract.')
    a("")
    a("    The message names the field path and the rule broken. It never quotes the")
    a("    rejected value, because a rejection message is an export surface too.")
    a('    """')
    a("")
    a("")
    a("def _join(path: str, key: str) -> str:")
    a('    return key if not path else path + "." + key')
    a("")
    a("")
    a("def _where(path: str) -> str:")
    a('    return path or "envelope"')
    a("")
    a("")
    a("def _no_duplicates(pairs: List[Tuple[str, Any]]) -> Dict[str, Any]:")
    a('    """object_pairs_hook rejecting a duplicate key rather than taking the last.')
    a("")
    a("    json.loads is last-wins by default, so a key-set check over the parsed dict")
    a("    cannot see that two values were sent for one field. Go is configured the")
    a("    same way in wire_gen.go.")
    a('    """')
    a("    seen: Dict[str, Any] = {}")
    a("    for k, v in pairs:")
    a("        if k in seen:")
    a('            raise WireContractError(f"codingagent/wire: duplicate key {k!r}")')
    a("        seen[k] = v")
    a("    return seen")
    a("")
    a("")
    a("def _reject_constant(token: str) -> Any:")
    a('    """Refuse NaN, Infinity and -Infinity.')
    a("")
    a("    json.loads accepts all three by default; Go's encoding/json rejects them")
    a("    as invalid JSON. Left alone that is a parse-layer asymmetry -- and none of")
    a("    them is a value the contract has any use for.")
    a('    """')
    a("    raise WireContractError(")
    a('        f"codingagent/wire: envelope: {token} is not a value this contract accepts"')
    a("    )")
    a("")
    a("")
    a("def loads_strict(data: Any) -> Any:")
    a('    """json.loads with duplicate-key rejection and a single error type.')
    a("")
    a("    Every parse failure is re-raised as WireContractError. A bare")
    a("    json.JSONDecodeError escaping this function would reach a caller that")
    a("    catches only the contract error, turning a malformed body into a 500")
    a("    where Go returns a 400 -- an asymmetry in the error contract, which is")
    a("    still an asymmetry. The original message is discarded rather than")
    a("    chained, because a decoder error can quote the bytes that caused it.")
    a('    """')
    a("    if isinstance(data, (bytes, bytearray)):")
    a("        try:")
    a('            data = bytes(data).decode("utf-8")')
    a("        except UnicodeDecodeError:")
    a("            raise WireContractError(")
    a('                "codingagent/wire: envelope: body is not valid UTF-8"')
    a("            ) from None")
    a("    try:")
    a("        return json.loads(")
    a("            data,")
    a("            object_pairs_hook=_no_duplicates,")
    a("            parse_constant=_reject_constant,")
    a("        )")
    a("    except WireContractError:")
    a("        raise")
    a("    except json.JSONDecodeError:")
    a("        raise WireContractError(")
    a('            "codingagent/wire: envelope: body is not a single valid JSON document"')
    a("        ) from None")
    a("")
    a("")

    # patterns
    a("# Generated validation patterns, one per bounded string in the schema.")
    for obj in [envelope] + defs:
        for f in obj.fields:
            if f.kind == "string" and "pattern" in f.spec:
                # json.dumps already emits a correctly-escaped Python string
                # literal. Adding an r prefix on top would turn \. into a literal
                # backslash followed by any character -- which silently widens
                # every pattern containing an escape.
                a(
                    "_RE_%s_%s = re.compile(%s)"
                    % (obj.key.upper(), f.name.upper(), json.dumps(f.spec["pattern"]))
                )
    a("")

    # key sets and enums
    for obj in [envelope] + defs:
        a("KEYS_%s: Tuple[str, ...] = (" % obj.key.upper())
        for n in obj.all_names:
            a("    %s," % json.dumps(n))
        a(")")
        a("REQUIRED_%s: Tuple[str, ...] = (" % obj.key.upper())
        for n in obj.required_names:
            a("    %s," % json.dumps(n))
        a(")")
        a("")
    for obj in [envelope] + defs:
        for f in obj.fields:
            if f.enum:
                a("ENUM_%s_%s: Tuple[str, ...] = (" % (obj.key.upper(), f.name.upper()))
                for m in f.enum:
                    a("    %s," % json.dumps(m))
                a(")")
                a("")

    # classes
    for obj in defs + [envelope]:
        a("class %s:" % obj.go_type)
        a('    """Generated from $defs.%s."""' % obj.key)
        a("")
        a("    __slots__ = (")
        for f in obj.fields:
            a("        %s," % json.dumps(f.name))
        a("    )")
        a("")
        a("    def __init__(self, **kw: Any) -> None:")
        a("        for k in self.__slots__:")
        a("            setattr(self, k, kw.get(k))")
        a("")
        a("    def to_canonical(self) -> Dict[str, Any]:")
        a("        out: Dict[str, Any] = {}")
        for f in obj.fields:
            if f.required:
                if f.kind == "object":
                    a("        out[%s] = self.%s.to_canonical()" % (json.dumps(f.name), f.name))
                else:
                    a("        out[%s] = self.%s" % (json.dumps(f.name), f.name))
            else:
                # Absent is None, never "" -- an empty string is a value the
                # contract may one day admit, and conflating the two is how an
                # optional field stops round-tripping.
                a("        if self.%s is not None:" % f.name)
                if f.kind == "object":
                    a("            out[%s] = self.%s.to_canonical()" % (json.dumps(f.name), f.name))
                else:
                    a("            out[%s] = self.%s" % (json.dumps(f.name), f.name))
        a("        return out")
        a("")
        a("    def __eq__(self, other: Any) -> bool:")
        a("        if not isinstance(other, %s):" % obj.go_type)
        a("            return NotImplemented")
        a("        return self.to_canonical() == other.to_canonical()")
        a("")
        a("    def __repr__(self) -> str:")
        a('        return "%s(...)"' % obj.go_type)
        a("")
        a("")

    # decoders
    for obj in defs + [envelope]:
        a("def _decode_%s(raw: Any, path: str) -> %s:" % (obj.key, obj.go_type))
        a("    if not isinstance(raw, dict):")
        a('        raise WireContractError(f"codingagent/wire: {_where(path)}: expected a JSON object")')
        a("    allowed = set(KEYS_%s)" % obj.key.upper())
        a("    for k in raw:")
        a("        if k not in allowed:")
        a("            raise WireContractError(")
        a('                f"codingagent/wire: {_join(path, k)}: unlisted field is not in the codingagent.v1 allow-list"')
        a("            )")
        a("    for k in REQUIRED_%s:" % obj.key.upper())
        a("        if k not in raw:")
        a("            raise WireContractError(")
        a('                f"codingagent/wire: {_join(path, k)}: required field is missing"')
        a("            )")
        a("    kw: Dict[str, Any] = {}")
        for f in obj.fields:
            a("    if %s in raw:" % json.dumps(f.name))
            a("        _v = raw[%s]" % json.dumps(f.name))
            a("        _p = _join(path, %s)" % json.dumps(f.name))
            if f.kind == "object":
                a("        kw[%s] = _decode_%s(_v, _p)" % (json.dumps(f.name), f.ref))
            elif f.kind == "integer":
                a("        if isinstance(_v, bool) or not isinstance(_v, int):")
                a('            raise WireContractError(f"codingagent/wire: {_p}: expected an integer")')
                lo = f.spec.get("minimum", 0)
                hi = f.spec.get("maximum", MAX_SAFE_INT)
                a("        if _v < %d or _v > %d:" % (lo, hi))
                a('            raise WireContractError(f"codingagent/wire: {_p}: integer out of bounds [%d, %d]")' % (lo, hi))
                a("        kw[%s] = _v" % json.dumps(f.name))
            else:
                a("        if not isinstance(_v, str):")
                a('            raise WireContractError(f"codingagent/wire: {_p}: expected a string")')
                if "const" in f.spec:
                    a("        if _v != %s:" % json.dumps(f.spec["const"]))
                    a('            raise WireContractError(f"codingagent/wire: {_p}: must equal %s")' % f.spec["const"])
                mn = f.spec.get("minLength", 0)
                mx = f.spec.get("maxLength")
                if mx is not None:
                    a("        if len(_v) < %d or len(_v) > %d:" % (mn, mx))
                    a('            raise WireContractError(f"codingagent/wire: {_p}: length {len(_v)} outside [%d, %d]")' % (mn, mx))
                elif mn:
                    a("        if len(_v) < %d:" % mn)
                    a('            raise WireContractError(f"codingagent/wire: {_p}: length {len(_v)} below %d")' % mn)
                if "pattern" in f.spec:
                    a("        if not _RE_%s_%s.fullmatch(_v):" % (obj.key.upper(), f.name.upper()))
                    a('            raise WireContractError(f"codingagent/wire: {_p}: value does not match the frozen pattern")')
                if f.enum:
                    a("        if _v not in ENUM_%s_%s:" % (obj.key.upper(), f.name.upper()))
                    a('            raise WireContractError(f"codingagent/wire: {_p}: value is outside the frozen enum")')
                a("        kw[%s] = _v" % json.dumps(f.name))
        a("    return %s(**kw)" % obj.go_type)
        a("")
        a("")

    a("def decode_wire(data: Any) -> WireEnvelope:")
    a('    """Decode a codingagent.v1 payload under closed-world rules.')
    a("")
    a("    Every object rejects a key outside its frozen set at every nesting depth, a")
    a("    duplicate key is an error rather than last-wins, and no error message ever")
    a("    quotes a rejected value.")
    a('    """')
    a("    if isinstance(data, (str, bytes, bytearray)):")
    a("        data = loads_strict(data)")
    a('    return _decode_envelope(data, "")')
    a("")
    a("")
    a("def canonical_json(envelope: WireEnvelope) -> bytes:")
    a('    """Render the frozen canonical form.')
    a("")
    a("    UTF-8, keys sorted lexicographically at every level, no insignificant")
    a("    whitespace, no non-ASCII escaping and no trailing newline. Go is configured")
    a("    identically in wire_gen.go; neither language's default matches the other's.")
    a('    """')
    a("    return json.dumps(")
    a("        envelope.to_canonical(),")
    a("        sort_keys=True,")
    a('        separators=(",", ":"),')
    a("        ensure_ascii=False,")
    a('    ).encode("utf-8")')
    a("")
    a("")
    a("def allowed_keys() -> List[str]:")
    a('    """Every admitted field name as a dotted path, sorted.')
    a("")
    a("    Derived from the generated key sets so a test cannot drift from the decoder")
    a("    it is checking.")
    a('    """')
    a("    out: List[str] = []")
    a("    for prefix, keys in (")
    a('        ("", KEYS_ENVELOPE),')
    a('        ("process", KEYS_PROCESS_INFO),')
    a('        ("kanban", KEYS_KANBAN_INFO),')
    a('        ("metrics", KEYS_METRICS_INFO),')
    a('        ("metrics.tool_counts", KEYS_TOOL_COUNTS),')
    a('        ("network", KEYS_NETWORK_INFO),')
    a("    ):")
    a("        out.extend(_join(prefix, k) for k in keys)")
    a("    return sorted(out)")
    return "\n".join(L) + "\n"


# --------------------------------------------------------------------------
# OpenAPI emitter
# --------------------------------------------------------------------------


def _oas_schema_from(spec: Dict[str, Any], defs_map: Dict[str, str]) -> Dict[str, Any]:
    if "$ref" in spec:
        return {"$ref": "#/components/schemas/" + defs_map[spec["$ref"].rsplit("/", 1)[-1]]}
    out: Dict[str, Any] = {}
    for k in ("type", "format", "enum", "const", "minimum", "maximum", "minLength", "maxLength", "pattern"):
        if k in spec:
            out[k] = spec[k]
    return out


def emit_openapi(schema: Dict[str, Any], digest: str) -> str:
    envelope, defs = build_ir(schema)
    label = schema["x-contract-label"]
    providers, report_keys = detection_report_shape(VALIDATOR_PATH)
    defs_map = {d.key: d.go_type for d in defs}

    components: Dict[str, Any] = {}
    for d in defs:
        components[d.go_type] = {
            "type": "object",
            "additionalProperties": False,
            "required": d.required_names,
            "properties": {
                f.name: _oas_schema_from(f.spec, defs_map) for f in d.fields
            },
        }
    components["WireEnvelope"] = {
        "type": "object",
        "additionalProperties": False,
        "required": envelope.required_names,
        "properties": {
            f.name: _oas_schema_from(f.spec, defs_map) for f in envelope.fields
        },
    }

    # 422 body: P1-2's DetectionReport, parsed from payload_validator.py.
    # Bounded here because a rejection body is a string-carrying export surface.
    report_props: Dict[str, Any] = {}
    for k in report_keys:
        if k == "detected":
            report_props[k] = {"type": "boolean"}
        elif k == "provider_counts":
            report_props[k] = {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    p: {"type": "integer", "minimum": 0, "maximum": MAX_SAFE_INT}
                    for p in providers
                },
            }
        elif k == "fingerprints":
            report_props[k] = {
                "type": "array",
                "maxItems": 256,
                "items": {
                    "type": "string",
                    "minLength": 64,
                    "maxLength": 64,
                    "pattern": "^[a-f0-9]{64}$",
                    "description": "Keyed HMAC-SHA256 from the SLDP pseudonym primitive. Never a credential value.",
                },
            }
        elif k == "reasons":
            report_props[k] = {
                "type": "array",
                "maxItems": 64,
                "items": {
                    "type": "string",
                    "maxLength": 128,
                    "pattern": "^[a-z0-9_()=. ]{1,128}$",
                    "description": "Structural classification only, e.g. high_entropy_token_shape(entropy=4.21). Never a fragment of the matched text.",
                },
            }
        else:
            raise ContractError(f"unmapped DetectionReport key {k!r}")

    components["ZeroPayloadRejection"] = {
        "type": "object",
        "additionalProperties": False,
        "required": report_keys,
        "properties": report_props,
        "description": (
            "P1-2 DetectionReport, parsed from payload_validator.py by the generator "
            "rather than restated. Emitted when the pre-export gate refuses a record. "
            "Carries provider classification, keyed fingerprints and structural reasons "
            "only -- never the matched value."
        ),
    }
    components["Error"] = {
        "type": "object",
        "additionalProperties": False,
        "required": ["error"],
        "properties": {"error": {"type": "string", "maxLength": 256}},
    }

    tc = schema["x-tenant-context"]
    doc = {
        "openapi": "3.1.0",
        "info": {
            "title": "Signal Loom coding-agent detective telemetry",
            "version": "1.0.0",
            "x-contract-label": label,
            "x-schema-sha256": digest,
            "x-generated-by": GENERATOR_ID,
            "description": (
                "FROZEN by SLCD-P1-3. Generated from " + SCHEMA_REL + "; DO NOT EDIT. "
                "Any change classified incompatible by gen_wire_contract.py --classify "
                "takes the label codingagent.v2.\n\n"
                "ROUTING GAP: this path does not reach signal-ingest today. "
                "dashboard-signalloom/nginx.conf:102-104 proxies location /api/ to "
                "fe-signalloom-api.fe-signalloom.svc.cluster.local:8000, a different "
                "service. A request to this path resolves to the wrong backend, not to "
                "nowhere. Owned by SLCD-P5-1."
            ),
        },
        "servers": [{"url": "https://dashboard.osramp.acme.local", "description": "Dashboard gateway (see routing gap)"}],
        "paths": {
            schema["x-endpoint-path"]: {
                "post": {
                    "operationId": "ingestCodingAgentTelemetry",
                    "summary": "Ingest one allow-listed coding-agent telemetry record",
                    "security": [{"bearerAuth": []}],
                    "parameters": [
                        {
                            "name": "Content-Type",
                            "in": "header",
                            "required": True,
                            "schema": {"type": "string", "const": "application/json"},
                        },
                        {
                            "name": "X-SignalLoom-Contract",
                            "in": "header",
                            "required": True,
                            "schema": {"type": "string", "const": label},
                            "description": "Structural contract version. A consumer branches on this, never on payload shape.",
                        },
                        {
                            "name": tc["header"],
                            "in": "header",
                            "required": False,
                            "schema": {"type": "string", "minLength": 3, "maxLength": 63, "pattern": "^[a-z][a-z0-9-]{2,63}$"},
                            "description": (
                                "RESERVED, NOT TRUSTED. " + tc["note"] + " Declared in v1 so a "
                                "consumer written today needs no rewrite when SLCD-P2-2 lands."
                            ),
                        },
                    ],
                    "requestBody": {
                        "required": True,
                        "content": {
                            "application/json": {
                                "schema": {"$ref": "#/components/schemas/WireEnvelope"}
                            }
                        },
                    },
                    "responses": {
                        "202": {"description": "Record accepted for ingestion."},
                        "400": {
                            "description": "Payload departs from the frozen contract: unlisted field at any depth, missing required field, duplicate key, bound or pattern violation.",
                            "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Error"}}},
                        },
                        "401": {
                            "description": "No verified principal.",
                            "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Error"}}},
                        },
                        "403": {
                            "description": "Principal is not authorised for this tenancy.",
                            "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Error"}}},
                        },
                        "422": {
                            "description": "Zero-Customer-Payload pre-export gate refused the record.",
                            "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ZeroPayloadRejection"}}},
                        },
                    },
                }
            }
        },
        "components": {
            "securitySchemes": {"bearerAuth": {"type": "http", "scheme": "bearer"}},
            "schemas": components,
        },
    }
    return json.dumps(doc, indent=2, sort_keys=False, ensure_ascii=False) + "\n"


# --------------------------------------------------------------------------
# Compatibility classifier
# --------------------------------------------------------------------------

COMPATIBLE = "compatible"
INCOMPATIBLE = "incompatible"


def _flatten(schema: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    """Flatten envelope + $defs into dotted-path -> spec, ignoring x- roots."""
    out: Dict[str, Dict[str, Any]] = {}
    ref_names = {"process": "process_info", "kanban": "kanban_info", "metrics": "metrics_info", "network": "network_info"}
    for n, s in schema["properties"].items():
        out[n] = s
    for key, sub in schema.get("$defs", {}).items():
        prefix = next((k for k, v in ref_names.items() if v == key), key)
        if key == "tool_counts":
            prefix = "metrics.tool_counts"
        for n, s in sub["properties"].items():
            out[prefix + "." + n] = s
    return out


def _required(schema: Dict[str, Any]) -> set:
    out = set(schema.get("required", []))
    ref_names = {"process": "process_info", "kanban": "kanban_info", "metrics": "metrics_info", "network": "network_info"}
    for key, sub in schema.get("$defs", {}).items():
        prefix = next((k for k, v in ref_names.items() if v == key), key)
        if key == "tool_counts":
            prefix = "metrics.tool_counts"
        for n in sub.get("required", []):
            out.add(prefix + "." + n)
    return out


# Keys that describe a value's admissible set. Any difference in any of them
# changes what a decoder accepts. Compared as a whole rather than from a fixed
# list, so a keyword nobody thought of (exclusiveMinimum, multipleOf, format)
# cannot slip through classified as no change.
_COSMETIC_KEYS = frozenset({"description", "title", "$comment", "examples", "default", "deprecated"})


def _constraint_view(spec: Dict[str, Any]) -> Dict[str, Any]:
    """Everything in a property spec that affects what a decoder admits."""
    return {k: v for k, v in spec.items() if k not in _COSMETIC_KEYS}


def classify_change(old: Dict[str, Any], new: Dict[str, Any]) -> Tuple[str, List[str]]:
    """Decide whether `new` may keep `old`'s label, or needs the next one.

    THE PREDICATE, in one sentence:

        A change is `compatible` iff every payload a deployed v1 producer can
        emit is still accepted by a deployed v1 consumer, AND every payload a
        deployed v1 consumer accepts is still accepted by a regenerated consumer.

    Every verdict below is derived from that sentence rather than listed. A
    classifier that cannot state its rule in one sentence is a table of opinions
    and drifts on the first case nobody anticipated.

    Applying it:

    - Adding an OPTIONAL property is `compatible`: the existing payload set is
      untouched in both directions. It nonetheless carries a rollout constraint,
      because with additionalProperties:false a producer that actually emits the
      new property is refused by every consumer not yet regenerated. That is a
      deployment ordering requirement (consumers first), not a version break, and
      it is stated in the reasons rather than left for someone to discover.
    - Dropping a property from `required` is `compatible` with the same rollout
      constraint, in the same direction: a producer that omits it is refused by a
      consumer that still requires it.
    - Adding a REQUIRED property, or making an existing one required, breaks the
      first limb immediately -- every current producer omits it.
    - Removing a property breaks the second limb: payloads a v1 consumer accepts
      today are refused after regeneration.
    - Narrowing a bound breaks the second limb; WIDENING breaks the first, because
      an un-regenerated consumer refuses what the widened producer now considers
      legal. Widening reads like a relaxation and is a break.
    - Any enum change is one of those two in disguise.
    """
    reasons: List[str] = []
    rollout: List[str] = []
    of, nf = _flatten(old), _flatten(new)
    oreq, nreq = _required(old), _required(new)

    for name in sorted(set(of) - set(nf)):
        reasons.append(
            f"property removed: {name} -- payloads a v1 consumer accepts today would be refused"
        )
    for name in sorted(set(nf) - set(of)):
        if name in nreq:
            reasons.append(
                f"required property added: {name} -- every deployed v1 producer omits it"
            )
        else:
            rollout.append(
                f"optional property added: {name} -- consumers must be regenerated BEFORE any "
                "producer emits it, or a closed-world v1 consumer refuses the record"
            )
    for name in sorted(set(of) & set(nf)):
        ov, nv = _constraint_view(of[name]), _constraint_view(nf[name])
        if ov != nv:
            changed = sorted(set(ov) | set(nv))
            for k in changed:
                if ov.get(k) == nv.get(k):
                    continue
                if k == "enum":
                    added = set(nv.get(k, [])) - set(ov.get(k, []))
                    removed = set(ov.get(k, [])) - set(nv.get(k, []))
                    if added:
                        reasons.append(
                            f"enum widened: {name} gained {sorted(added)} -- an un-regenerated "
                            "v1 consumer refuses a value the new producer considers legal"
                        )
                    if removed:
                        reasons.append(
                            f"enum narrowed: {name} lost {sorted(removed)} -- payloads a v1 "
                            "consumer accepts today would be refused"
                        )
                else:
                    reasons.append(
                        f"constraint changed: {name}.{k} -- the admissible value set moved, so "
                        "producer and consumer disagree about validity at any deployment skew"
                    )
    for name in sorted(nreq - oreq):
        if name in of:
            reasons.append(
                f"property became required: {name} -- every deployed v1 producer may omit it"
            )
    for name in sorted(oreq - nreq):
        if name in nf:
            rollout.append(
                f"property no longer required: {name} -- consumers must be regenerated BEFORE "
                "any producer omits it"
            )

    if reasons:
        cur = old.get("x-contract-label", "codingagent.v1")
        m = re.match(r"^(.*)\.v(\d+)$", cur)
        nxt = f"{m.group(1)}.v{int(m.group(2)) + 1}" if m else "codingagent.v2"
        reasons.append(f"a new contract label is required: {nxt}")
        return INCOMPATIBLE, reasons + rollout
    if rollout:
        return COMPATIBLE, [
            "no breaking change; the existing label may be kept"
        ] + rollout
    return COMPATIBLE, ["no breaking change; the existing label may be kept"]


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------


def render_all() -> Dict[Path, str]:
    raw = SCHEMA_PATH.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    schema = json.loads(raw)
    return {
        GO_OUT: emit_go(schema, digest),
        PY_OUT: emit_py(schema, digest),
        OPENAPI_OUT: emit_openapi(schema, digest),
    }


def cmd_emit() -> int:
    for path, body in render_all().items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
        print(f"wrote {path.relative_to(APPS_DIR.parent.parent)}")
    return 0


def cmd_check() -> int:
    bad = 0
    for path, body in render_all().items():
        rel = path.relative_to(APPS_DIR.parent.parent)
        if not path.exists():
            print(f"DRIFT: {rel} is missing; run --emit", file=sys.stderr)
            bad += 1
            continue
        on_disk = path.read_text(encoding="utf-8")
        if on_disk != body:
            print(
                f"DRIFT: {rel} does not match a fresh generation from {SCHEMA_REL}. "
                "Either it was hand-edited, or the schema changed without a regeneration. "
                "Run: make signalloom-wire-contract-emit",
                file=sys.stderr,
            )
            bad += 1
    if bad:
        print(f"FAIL: {bad} generated artefact(s) drifted from the schema", file=sys.stderr)
        return 1
    print("PASS: all generated artefacts match a fresh generation from the frozen schema")
    return 0


def cmd_classify(old_path: str, new_path: str) -> int:
    old = json.loads(Path(old_path).read_bytes())
    new = json.loads(Path(new_path).read_bytes())
    verdict, reasons = classify_change(old, new)
    print(json.dumps({"verdict": verdict, "reasons": reasons}, indent=2))
    return 0 if verdict == COMPATIBLE else 2


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--emit", action="store_true", help="write all generated artefacts")
    g.add_argument("--check", action="store_true", help="fail if any artefact drifted")
    g.add_argument("--classify", nargs=2, metavar=("OLD", "NEW"), help="classify a schema pair")
    args = ap.parse_args(argv)
    try:
        if args.emit:
            return cmd_emit()
        if args.check:
            return cmd_check()
        return cmd_classify(*args.classify)
    except ContractError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
