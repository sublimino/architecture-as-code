# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
"""SLCD-P1-3: the Python half of the codingagent.v1 contract freeze.

Every test runs against the GENERATED decoder in coding_agent_wire.py, and every
rejection case comes from schemas/fixtures/reject/MANIFEST.json which the Go
suite also reads. That sharing is the point: two suites each testing their own
half of a contract go green while holding one blind spot between them.

The suite also owns the drift check. Go asserts the generator still declares
--check; here we actually run it, because this side already has an interpreter.
"""
from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import unittest

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

import coding_agent_wire as wire  # noqa: E402

SCHEMA_PATH = PKG_DIR / "schemas" / "coding-agent-telemetry.v1.schema.json"
FIXTURES = PKG_DIR / "schemas" / "fixtures"
GENERATOR = PKG_DIR / "scripts" / "gen_wire_contract.py"
GO_GEN = PKG_DIR.parent / "signal-ingest" / "codingagent" / "wire_gen.go"
OPENAPI = PKG_DIR / "schemas" / "codingagent.v1.openapi.json"


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


class SchemaBinding(unittest.TestCase):
    """The digest is what catches a schema edit that forgot to regenerate."""

    def test_schema_is_readable(self) -> None:
        # Fail, never skip. A skip on a missing system-under-test turns a build
        # failure into a silent pass.
        self.assertTrue(SCHEMA_PATH.is_file(), f"canonical schema missing at {SCHEMA_PATH}")

    def test_generated_digest_matches_schema(self) -> None:
        got = hashlib.sha256(SCHEMA_PATH.read_bytes()).hexdigest()
        self.assertEqual(
            got,
            wire.SCHEMA_SHA256,
            "schema digest drift: the schema changed without a regeneration. "
            "Run: make signalloom-wire-contract-emit",
        )

    def test_go_and_python_record_the_same_digest(self) -> None:
        go_src = GO_GEN.read_text(encoding="utf-8")
        self.assertIn(
            f'const WireSchemaSHA256 = "{wire.SCHEMA_SHA256}"',
            go_src,
            "the two generated artefacts disagree about which schema they came from",
        )

    def test_contract_label_is_structural(self) -> None:
        schema = load_json(SCHEMA_PATH)
        self.assertEqual(wire.CONTRACT_LABEL, "codingagent.v1")
        self.assertEqual(schema["x-contract-label"], wire.CONTRACT_LABEL)
        self.assertEqual(wire.CONTRACT_HEADER, "X-SignalLoom-Contract")

    def test_tenant_header_is_reserved_and_untrusted(self) -> None:
        tc = load_json(SCHEMA_PATH)["x-tenant-context"]
        self.assertEqual(wire.TENANT_HEADER, tc["header"])
        self.assertIs(tc["trusted"], False)


class AllowList(unittest.TestCase):
    def test_allow_list_matches_schema_exactly(self) -> None:
        schema = load_json(SCHEMA_PATH)
        prefixes = {
            "process_info": "process",
            "kanban_info": "kanban",
            "metrics_info": "metrics",
            "tool_counts": "metrics.tool_counts",
            "network_info": "network",
        }
        want = list(schema["properties"])
        for key, sub in schema["$defs"].items():
            self.assertIs(
                sub.get("additionalProperties"),
                False,
                f"$defs.{key} must declare additionalProperties:false",
            )
            want += [f"{prefixes[key]}.{n}" for n in sub["properties"]]
        self.assertIs(schema.get("additionalProperties"), False)
        self.assertEqual(sorted(want), wire.allowed_keys())
        self.assertEqual(
            len(wire.allowed_keys()), 41, "a field was added or removed at freeze time"
        )


class ValidFixtures(unittest.TestCase):
    def fixtures(self):
        files = sorted((FIXTURES / "valid").glob("*.json"))
        self.assertGreaterEqual(
            len(files), 2, "a loader matching fewer than 2 fixtures reads as a pass"
        )
        return files

    def test_valid_fixtures_decode(self) -> None:
        for f in self.fixtures():
            with self.subTest(fixture=f.name):
                ev = wire.decode_wire(load_json(f))
                self.assertEqual(ev.schema_version, "1.0.0")
                self.assertTrue(ev.harness)
                self.assertEqual(len(ev.session_id), 64)

    def test_comm_is_not_the_harness(self) -> None:
        # P1-PRE F1: comm is 15-byte truncated and is not a harness discriminator.
        ev = wire.decode_wire(load_json(FIXTURES / "valid" / "antigravity-agy.json"))
        self.assertEqual(ev.harness, "antigravity")
        self.assertEqual(ev.process.comm, "agy")


def apply_mutation(base: dict, case: dict):
    """Apply one declarative corpus mutation. Mirrors applyMutation in Go."""
    if case["op"] == "raw":
        return case["raw"]
    doc = copy.deepcopy(base)
    parts = case["path"].split(".")
    cur = doc
    for i, p in enumerate(parts):
        if i == len(parts) - 1:
            if case["op"] == "delete":
                cur.pop(p, None)
            elif case["op"] == "set":
                v = case["value"]
                if isinstance(v, str) and case.get("repeat"):
                    v = v * int(case["repeat"])
                cur[p] = v
            else:
                raise AssertionError(f"unknown op {case['op']!r}")
            break
        cur = cur[p]
    return doc


class RejectionCorpus(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = load_json(FIXTURES / "reject" / "MANIFEST.json")
        self.cases = self.manifest["cases"]
        self.assertGreater(
            len(self.cases),
            0,
            "rejection corpus is empty -- a green run over zero cases is "
            "indistinguishable from a green run over passing ones",
        )
        self.base = load_json((FIXTURES / "reject" / self.manifest["base"]).resolve())

    def test_positive_control_base_is_accepted(self) -> None:
        # Without this every rejection below could pass for the wrong reason.
        ev = wire.decode_wire(copy.deepcopy(self.base))
        self.assertEqual(ev.harness, "claude")

    def test_every_case_is_rejected(self) -> None:
        for case in self.cases:
            with self.subTest(case=case["id"]):
                payload = apply_mutation(self.base, case)
                with self.assertRaises(
                    wire.WireContractError,
                    msg=f"ACCEPTED but must be rejected ({case['why']})",
                ):
                    wire.decode_wire(payload)

    def test_rejection_messages_do_not_quote_the_value(self) -> None:
        for case in self.cases:
            with self.subTest(case=case["id"]):
                payload = apply_mutation(self.base, case)
                # The `else: fail` is load-bearing. Without it every assertion
                # below lives inside the except branch, so neutering the decoder
                # to accept everything makes this test PASS while its sibling
                # fails -- which is exactly what a falsification run showed.
                try:
                    wire.decode_wire(payload)
                except wire.WireContractError as exc:
                    msg = str(exc)
                    for needle in ("REDACTED", "sk-ant-", "leak="):
                        self.assertNotIn(
                            needle, msg, f"rejection message quotes the refused value: {msg}"
                        )
                    self.assertTrue(msg.startswith("codingagent/wire:"), msg)
                else:
                    self.fail(
                        f"case {case['id']} was ACCEPTED, so this test asserted nothing "
                        f"({case['why']})"
                    )


class DifferentialCorpus(unittest.TestCase):
    """What a hand-written reject-list structurally cannot cover.

    MANIFEST.json is a list of cases someone thought of. Every real asymmetry
    found on this card was one nobody thought of: Python's `$` matching before a
    trailing newline, Go's json.Number accepting a quoted number, encoding/json
    treating null as a no-op. None of the three had a manifest case.

    This corpus enumerates every field against every adversarial value class,
    carries the COMPLETE payload text, and records the EXPECTED verdict. Both
    languages decode identical bytes and assert actual == expected -- deliberately
    NOT go_verdict == py_verdict, because two decoders agreeing to accept
    something they should refuse is a shared defect, not agreement.
    """

    CORPUS = FIXTURES / "differential" / "CORPUS.json"
    BUILDER = PKG_DIR / "scripts" / "build_differential_corpus.py"

    def setUp(self) -> None:
        self.corpus = load_json(self.CORPUS)
        self.cases = self.corpus["cases"]

    def test_corpus_is_populated(self) -> None:
        self.assertGreater(len(self.cases), 0, "a green run over zero cases proves nothing")
        self.assertEqual(len(self.cases), self.corpus["case_count"])
        self.assertGreaterEqual(
            len(self.cases),
            400,
            "the corpus enumerates every field against every value class and should not "
            "shrink without a field being removed",
        )

    def test_every_case_matches_its_expected_verdict(self) -> None:
        accepted = 0
        for case in self.cases:
            with self.subTest(case=case["id"]):
                try:
                    wire.decode_wire(case["payload"])
                    actual = "accept"
                except wire.WireContractError:
                    actual = "reject"
                except Exception as exc:  # noqa: BLE001
                    actual = f"WRONG-EXCEPTION-TYPE:{type(exc).__name__}"
                if actual == "accept":
                    accepted += 1
                self.assertEqual(actual, case["expect"], case["why"])
        self.assertGreater(
            accepted,
            0,
            "no case was accepted, not even the positive control -- every rejection "
            "assertion passed for the wrong reason",
        )

    def test_corpus_matches_a_fresh_build(self) -> None:
        r = subprocess.run(
            [sys.executable, str(self.BUILDER), "--check"], capture_output=True, text=True
        )
        self.assertEqual(r.returncode, 0, r.stderr)


class CanonicalEncoding(unittest.TestCase):
    """Byte-for-byte equivalence, pinned to a recorded digest.

    Comparing Go to Python only would pass if both were wrong in the same way.
    Both sides compare against the SAME recorded constants instead.
    """

    def test_canonical_digests_match_the_recorded_table(self) -> None:
        table = load_json(FIXTURES / "canonical-digests.json")
        self.assertGreaterEqual(len(table), 2)
        for f in sorted((FIXTURES / "valid").glob("*.json")):
            with self.subTest(fixture=f.name):
                ev = wire.decode_wire(load_json(f))
                canon = wire.canonical_json(ev)
                got = hashlib.sha256(canon).hexdigest()
                self.assertIn(f.name, table, "fixture has no recorded canonical digest")
                self.assertEqual(got, table[f.name], f"canonical drift: {canon!r}")

    def test_canonical_form_properties(self) -> None:
        for f in sorted((FIXTURES / "valid").glob("*.json")):
            with self.subTest(fixture=f.name):
                canon = wire.canonical_json(wire.decode_wire(load_json(f)))
                self.assertFalse(canon.endswith(b"\n"))
                self.assertNotIn(b": ", canon)
                self.assertNotIn(b", ", canon)
                self.assertEqual(canon, canon.decode("utf-8").encode("utf-8"))

    def test_committed_canonical_files_match_this_encoder(self) -> None:
        files = sorted((FIXTURES / "canonical").glob("*.canonical.json"))
        self.assertGreaterEqual(len(files), 2)
        for cf in files:
            with self.subTest(fixture=cf.name):
                src = FIXTURES / "valid" / cf.name.replace(".canonical.json", ".json")
                canon = wire.canonical_json(wire.decode_wire(load_json(src)))
                self.assertEqual(canon, cf.read_bytes())

    def test_go_encoded_bytes_decode_here(self) -> None:
        """The direction Python cannot check alone.

        Bytes produced by the Go encoder are committed under fixtures/go-encoded/
        and must decode here to a value whose re-encoding is identical.
        """
        files = sorted((FIXTURES / "go-encoded").glob("*.canonical.json"))
        self.assertGreaterEqual(
            len(files), 2, "no Go-encoded bytes committed; the round trip is one-directional"
        )
        for gf in files:
            with self.subTest(fixture=gf.name):
                body = gf.read_bytes()
                ev = wire.decode_wire(body)
                self.assertEqual(wire.canonical_json(ev), body)


class DriftCheck(unittest.TestCase):
    """The check that makes 'frozen' mean something. Run here, not only by make."""

    def test_generator_check_passes_on_a_clean_tree(self) -> None:
        r = subprocess.run(
            [sys.executable, str(GENERATOR), "--check"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            r.returncode, 0, f"generated artefacts drifted from the schema:\n{r.stderr}"
        )

    def test_generator_check_fails_on_a_hand_edit(self) -> None:
        original = GO_GEN.read_bytes()
        try:
            GO_GEN.write_bytes(original + b"\n// hand-edited\n")
            r = subprocess.run(
                [sys.executable, str(GENERATOR), "--check"],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(
                r.returncode, 0, "a hand-edit of a generated file was not detected"
            )
            self.assertIn("wire_gen.go", r.stderr, "the failure does not name the file")
        finally:
            GO_GEN.write_bytes(original)

    def test_generated_files_declare_do_not_edit(self) -> None:
        self.assertIn("DO NOT EDIT", GO_GEN.read_text(encoding="utf-8"))
        self.assertIn("DO NOT EDIT", (PKG_DIR / "coding_agent_wire.py").read_text(encoding="utf-8"))
        self.assertIn("DO NOT EDIT", OPENAPI.read_text(encoding="utf-8"))

    def test_emit_is_deterministic(self) -> None:
        sys.path.insert(0, str(PKG_DIR / "scripts"))
        import gen_wire_contract as gen  # noqa: PLC0415

        a = gen.render_all()
        b = gen.render_all()
        self.assertEqual({k: v for k, v in a.items()}, {k: v for k, v in b.items()})

    def test_generator_refuses_an_open_schema(self) -> None:
        sys.path.insert(0, str(PKG_DIR / "scripts"))
        import gen_wire_contract as gen  # noqa: PLC0415

        bad = load_json(SCHEMA_PATH)
        bad["$defs"]["process_info"]["additionalProperties"] = True
        with self.assertRaises(gen.ContractError):
            gen.validate_schema(bad)

    def test_generation_actually_derives_from_the_schema(self) -> None:
        """Prove derivation by mutation, not by grepping for absent literals.

        "The generator has no hardcoded bounds" can only be checked by changing a
        bound in the schema and asserting the artefacts change to match. Grepping
        the generator for the absence of the literal `4194304` is a presence probe
        -- it passes while blind, and it would keep passing if the generator read
        the value from somewhere else entirely.
        """
        sys.path.insert(0, str(PKG_DIR / "scripts"))
        import gen_wire_contract as gen  # noqa: PLC0415

        schema = load_json(SCHEMA_PATH)
        before_go = gen.emit_go(schema, "0" * 64)
        before_py = gen.emit_py(schema, "0" * 64)
        before_oas = gen.emit_openapi(schema, "0" * 64)

        mutated = copy.deepcopy(schema)
        mutated["$defs"]["process_info"]["properties"]["pid"]["maximum"] = 777777
        mutated["$defs"]["process_info"]["properties"]["comm"]["maxLength"] = 9
        mutated["properties"]["harness"]["enum"] = ["claude", "aider"]

        after_go = gen.emit_go(mutated, "0" * 64)
        after_py = gen.emit_py(mutated, "0" * 64)
        after_oas = gen.emit_openapi(mutated, "0" * 64)

        for label, before, after, needle in (
            ("Go", before_go, after_go, "777777"),
            ("Python", before_py, after_py, "777777"),
            ("OpenAPI", before_oas, after_oas, "777777"),
        ):
            self.assertNotEqual(before, after, f"{label} artefact ignored a schema bound change")
            self.assertIn(needle, after, f"{label} did not pick up the new numeric bound")
            self.assertNotIn(needle, before, f"{label} contained the new bound before the change")

        # The enum must be enforced from the schema, not from a baked-in list.
        self.assertIn('"antigravity"', before_go)
        self.assertNotIn('"antigravity"', after_go)
        self.assertIn('"antigravity"', before_py)
        self.assertNotIn('"antigravity"', after_py)

        # And the length bound must travel too.
        self.assertIn("wireLen(s) < 1 || wireLen(s) > 9", after_go)
        self.assertIn("len(_v) < 1 or len(_v) > 9", after_py)

    def test_go_length_checks_count_codepoints_not_bytes(self) -> None:
        """JSON Schema maxLength is codepoints; Go's len() is bytes.

        Without this the two decoders measure different things and disagree on
        any multi-byte value.
        """
        go_src = GO_GEN.read_text(encoding="utf-8")
        self.assertIn("utf8.RuneCountInString", go_src)
        self.assertNotIn("if len(s) <", go_src, "a byte-length bound check survived")

    def test_generator_refuses_a_missing_label(self) -> None:
        sys.path.insert(0, str(PKG_DIR / "scripts"))
        import gen_wire_contract as gen  # noqa: PLC0415

        bad = load_json(SCHEMA_PATH)
        bad.pop("x-contract-label")
        with self.assertRaises(gen.ContractError):
            gen.validate_schema(bad)


class OpenAPIFreeze(unittest.TestCase):
    """The transport document must not drift from the schema it froze."""

    def setUp(self) -> None:
        self.doc = load_json(OPENAPI)
        self.schema = load_json(SCHEMA_PATH)

    def test_version_and_label(self) -> None:
        self.assertEqual(self.doc["info"]["version"], "1.0.0")
        self.assertEqual(self.doc["info"]["x-contract-label"], "codingagent.v1")
        self.assertEqual(self.doc["info"]["x-schema-sha256"], wire.SCHEMA_SHA256)

    def test_single_path_single_verb(self) -> None:
        paths = self.doc["paths"]
        self.assertEqual(list(paths), ["/api/v1/telemetry/coding-agents"])
        self.assertEqual(list(paths["/api/v1/telemetry/coding-agents"]), ["post"])

    def test_request_media_type_is_pinned(self) -> None:
        op = self.doc["paths"]["/api/v1/telemetry/coding-agents"]["post"]
        self.assertEqual(list(op["requestBody"]["content"]), ["application/json"])

    def test_required_headers_are_declared(self) -> None:
        op = self.doc["paths"]["/api/v1/telemetry/coding-agents"]["post"]
        by_name = {p["name"]: p for p in op["parameters"]}
        self.assertEqual(by_name["Content-Type"]["schema"]["const"], "application/json")
        self.assertTrue(by_name["Content-Type"]["required"])
        self.assertEqual(by_name["X-SignalLoom-Contract"]["schema"]["const"], "codingagent.v1")
        self.assertTrue(by_name["X-SignalLoom-Contract"]["required"])
        self.assertIn(wire.TENANT_HEADER, by_name)
        self.assertFalse(
            by_name[wire.TENANT_HEADER]["required"],
            "the tenant header is reserved, not required, because the server does not read it",
        )
        self.assertIn("NOT TRUSTED", by_name[wire.TENANT_HEADER]["description"])
        self.assertEqual(op["security"], [{"bearerAuth": []}])

    def test_envelope_schema_matches_the_json_schema(self) -> None:
        env = self.doc["components"]["schemas"]["WireEnvelope"]
        self.assertIs(env["additionalProperties"], False)
        self.assertEqual(sorted(env["properties"]), sorted(self.schema["properties"]))
        self.assertEqual(sorted(env["required"]), sorted(self.schema["required"]))

    def test_every_bound_matches_the_json_schema(self) -> None:
        comps = self.doc["components"]["schemas"]
        pairs = [("WireEnvelope", self.schema["properties"])]
        name_map = {
            "process_info": "WireProcessInfo",
            "kanban_info": "WireKanbanInfo",
            "metrics_info": "WireMetricsInfo",
            "tool_counts": "WireToolCounts",
            "network_info": "WireNetworkInfo",
        }
        for key, sub in self.schema["$defs"].items():
            pairs.append((name_map[key], sub["properties"]))
        checked = 0
        for comp_name, props in pairs:
            comp = comps[comp_name]
            self.assertIs(comp["additionalProperties"], False)
            for field, spec in props.items():
                if "$ref" in spec:
                    continue
                oas = comp["properties"][field]
                for bound in ("type", "enum", "const", "minimum", "maximum",
                              "minLength", "maxLength", "pattern"):
                    self.assertEqual(
                        spec.get(bound),
                        oas.get(bound),
                        f"{comp_name}.{field}.{bound} drifted from the JSON Schema",
                    )
                    checked += 1
        self.assertGreater(checked, 200, "the bound comparison covered implausibly little")

    def test_rejection_body_is_p1_2_detection_report_exactly(self) -> None:
        sys.path.insert(0, str(PKG_DIR / "scripts"))
        import gen_wire_contract as gen  # noqa: PLC0415

        providers, keys = gen.detection_report_shape(PKG_DIR / "payload_validator.py")
        rej = self.doc["components"]["schemas"]["ZeroPayloadRejection"]
        self.assertEqual(sorted(rej["properties"]), sorted(keys))
        self.assertEqual(sorted(rej["required"]), sorted(keys))
        self.assertEqual(
            sorted(rej["properties"]["provider_counts"]["properties"]), sorted(providers)
        )
        # Derived, not restated: the live class must agree with the frozen doc.
        from payload_validator import CredentialProvider, DetectionReport  # noqa: PLC0415

        self.assertEqual(
            sorted(p.value for p in CredentialProvider), sorted(providers)
        )
        self.assertEqual(sorted(DetectionReport().to_dict()), sorted(keys))

    def test_rejection_body_strings_are_bounded(self) -> None:
        rej = self.doc["components"]["schemas"]["ZeroPayloadRejection"]["properties"]
        fp = rej["fingerprints"]["items"]
        self.assertEqual((fp["minLength"], fp["maxLength"]), (64, 64))
        self.assertEqual(fp["pattern"], "^[a-f0-9]{64}$")
        self.assertLessEqual(rej["reasons"]["items"]["maxLength"], 128)
        self.assertIn("maxItems", rej["reasons"])
        self.assertIn("maxItems", rej["fingerprints"])

    def test_routing_gap_is_recorded_in_the_frozen_document(self) -> None:
        desc = self.doc["info"]["description"]
        self.assertIn("ROUTING GAP", desc)
        self.assertIn("nginx.conf:102-104", desc)
        self.assertIn("fe-signalloom-api", desc)
        self.assertIn("SLCD-P5-1", desc)


class Compatibility(unittest.TestCase):
    """Compatible vs requires-v2, decided by code rather than by judgement."""

    def setUp(self) -> None:
        sys.path.insert(0, str(PKG_DIR / "scripts"))
        import gen_wire_contract as gen  # noqa: PLC0415

        self.gen = gen
        self.base = load_json(SCHEMA_PATH)

    def variant(self, mutate) -> dict:
        v = copy.deepcopy(self.base)
        mutate(v)
        return v

    def test_adding_an_optional_property_is_compatible(self) -> None:
        def m(s):
            s["properties"]["cgroup_id"] = {
                "type": "string", "minLength": 1, "maxLength": 64,
                "pattern": "^[a-z0-9/_.-]{1,64}$",
            }
        verdict, reasons = self.gen.classify_change(self.base, self.variant(m))
        self.assertEqual(verdict, self.gen.COMPATIBLE, reasons)

    def test_dropping_a_property_from_required_is_compatible(self) -> None:
        def m(s):
            s["required"] = [r for r in s["required"] if r != "network"]
        verdict, _ = self.gen.classify_change(self.base, self.variant(m))
        self.assertEqual(verdict, self.gen.COMPATIBLE)

    def test_adding_a_required_property_is_incompatible(self) -> None:
        def m(s):
            s["properties"]["cgroup_id"] = {"type": "string", "maxLength": 64}
            s["required"].append("cgroup_id")
        verdict, reasons = self.gen.classify_change(self.base, self.variant(m))
        self.assertEqual(verdict, self.gen.INCOMPATIBLE)
        self.assertTrue(any("required property added" in r for r in reasons))

    def test_removing_a_property_is_incompatible(self) -> None:
        def m(s):
            s["properties"].pop("observed_at")
        verdict, reasons = self.gen.classify_change(self.base, self.variant(m))
        self.assertEqual(verdict, self.gen.INCOMPATIBLE)
        self.assertTrue(any("property removed" in r for r in reasons))

    def test_making_an_existing_property_required_is_incompatible(self) -> None:
        def m(s):
            s["required"].append("tenant_id")
        verdict, reasons = self.gen.classify_change(self.base, self.variant(m))
        self.assertEqual(verdict, self.gen.INCOMPATIBLE)
        self.assertTrue(any("became required" in r for r in reasons))

    def test_narrowing_a_numeric_bound_is_incompatible(self) -> None:
        def m(s):
            s["$defs"]["process_info"]["properties"]["pid"]["maximum"] = 65535
        verdict, _ = self.gen.classify_change(self.base, self.variant(m))
        self.assertEqual(verdict, self.gen.INCOMPATIBLE)

    def test_widening_a_numeric_bound_is_incompatible(self) -> None:
        # Widening reads like a relaxation but is a break: a v1 consumer still
        # refuses what the widened producer now considers legal.
        def m(s):
            s["$defs"]["process_info"]["properties"]["pid"]["maximum"] = 99999999
        verdict, _ = self.gen.classify_change(self.base, self.variant(m))
        self.assertEqual(verdict, self.gen.INCOMPATIBLE)

    def test_narrowing_a_string_length_is_incompatible(self) -> None:
        def m(s):
            s["$defs"]["network_info"]["properties"]["inference_endpoint"]["maxLength"] = 64
        verdict, _ = self.gen.classify_change(self.base, self.variant(m))
        self.assertEqual(verdict, self.gen.INCOMPATIBLE)

    def test_removing_an_enum_member_is_incompatible(self) -> None:
        def m(s):
            s["properties"]["harness"]["enum"] = [
                h for h in s["properties"]["harness"]["enum"] if h != "aider"
            ]
        verdict, _ = self.gen.classify_change(self.base, self.variant(m))
        self.assertEqual(verdict, self.gen.INCOMPATIBLE)

    def test_adding_an_enum_member_is_incompatible(self) -> None:
        def m(s):
            s["properties"]["harness"]["enum"].append("kpai")
        verdict, _ = self.gen.classify_change(self.base, self.variant(m))
        self.assertEqual(verdict, self.gen.INCOMPATIBLE)

    def test_incompatible_verdict_names_the_next_label(self) -> None:
        def m(s):
            s["properties"].pop("host_id")
        _, reasons = self.gen.classify_change(self.base, self.variant(m))
        self.assertTrue(
            any("codingagent.v2" in r for r in reasons),
            "an incompatible verdict must name the label the change requires",
        )

    def test_identical_schemas_classify_compatible(self) -> None:
        verdict, _ = self.gen.classify_change(self.base, copy.deepcopy(self.base))
        self.assertEqual(verdict, self.gen.COMPATIBLE)

    def test_a_v1_decoder_regenerated_with_an_optional_field_still_decodes_v1(self) -> None:
        """The forward-compatibility property, stated honestly.

        Closed-world decoding and 'new fields never break old consumers' are in
        direct opposition. The testable form is: an OPTIONAL addition to v1 leaves
        every previously-valid payload valid and leaves `required` unchanged, so a
        decoder regenerated from the extended schema still accepts the original
        fixture. Anything else takes a v2 label.
        """
        extended = self.variant(
            lambda s: s["properties"].update(
                cgroup_id={"type": "string", "minLength": 1, "maxLength": 64,
                           "pattern": "^[a-z0-9/_.-]{1,64}$"}
            )
        )
        verdict, _ = self.gen.classify_change(self.base, extended)
        self.assertEqual(verdict, self.gen.COMPATIBLE)
        self.assertEqual(self.base["required"], extended["required"])

        src = self.gen.emit_py(extended, "0" * 64)
        ns: dict = {}
        exec(compile(src, "<regenerated_v1_plus_optional>", "exec"), ns)  # noqa: S102

        original = load_json(FIXTURES / "valid" / "claude.json")
        ev = ns["decode_wire"](copy.deepcopy(original))
        self.assertEqual(ev.harness, "claude")

        with_new = copy.deepcopy(original)
        with_new["cgroup_id"] = "system.slice/claude.service"
        ev2 = ns["decode_wire"](with_new)
        self.assertEqual(ev2.cgroup_id, "system.slice/claude.service")

        # And the old decoder still refuses it, which is why the addition needs a
        # regeneration rather than being silently tolerated.
        with self.assertRaises(wire.WireContractError):
            wire.decode_wire(with_new)


class ZeroPayloadInvariant(unittest.TestCase):
    """The allow-list is structural, not a deny-list."""

    @staticmethod
    def _string_fields(schema):
        """Yield (dotted name, spec) for every string field in the contract."""
        for name, spec in schema["properties"].items():
            if spec.get("type") == "string":
                yield name, spec
        for key, sub in schema["$defs"].items():
            for n, spec in sub["properties"].items():
                if spec.get("type") == "string":
                    yield f"{key}.{n}", spec

    def test_no_frozen_field_can_carry_free_text(self) -> None:
        schema = load_json(SCHEMA_PATH)
        unbounded = [
            name
            for name, spec in self._string_fields(schema)
            if "maxLength" not in spec and "const" not in spec
        ]
        self.assertEqual(unbounded, [], f"unbounded string fields in the contract: {unbounded}")

    def test_every_string_field_is_pattern_restricted(self) -> None:
        """A length bound alone is not a content bound.

        Every bounded string must also carry a pattern, or its bytes are
        attacker-chosen across the full character range.
        """
        schema = load_json(SCHEMA_PATH)
        unpatterned = [
            name
            for name, spec in self._string_fields(schema)
            if "pattern" not in spec and "const" not in spec
        ]
        self.assertEqual(unpatterned, [], f"length-bounded but content-unbounded: {unpatterned}")

    def test_total_string_budget_is_bounded_and_known(self) -> None:
        """The honest statement of what this mission changed.

        Before SLCD the widest field that could reach a persisted record was a
        bounded integer (filter.py:34-48, zero free-text fields). This asserts the
        exact free-text budget the contract opens, so a later widening shows up as
        a failing number rather than as prose nobody re-reads.
        """
        schema = load_json(SCHEMA_PATH)
        total = sum(
            len(spec["const"]) if "const" in spec else spec["maxLength"]
            for _, spec in self._string_fields(schema)
        )
        self.assertEqual(
            total,
            616,
            "the per-record free-text budget changed; update "
            "docs/signalloom/slcd-p1-3-wire-contract.md and justify it to P1-GOV",
        )

    def test_widest_single_string_channel_is_the_inference_endpoint(self) -> None:
        """Named so P1-GOV inherits it explicitly rather than silently.

        network.inference_endpoint is 128 bytes of ^[a-zA-Z0-9.-]$ -- ample to
        carry a 64-byte secret shaped as a hostname. The bound is P1-1's and this
        card may not narrow it; naming it is what this card can do.
        """
        schema = load_json(SCHEMA_PATH)
        widest = max(
            ((n, s["maxLength"]) for n, s in self._string_fields(schema) if "maxLength" in s),
            key=lambda kv: kv[1],
        )
        self.assertEqual(widest, ("network_info.inference_endpoint", 128))

    def test_prohibited_procfs_entries_are_untouched(self) -> None:
        from proc import PROHIBITED_PROC_ENTRIES  # noqa: PLC0415

        for entry in ("mem", "environ", "cmdline", "maps", "smaps", "stack", "fd", "net"):
            self.assertIn(entry, PROHIBITED_PROC_ENTRIES)

    def test_no_contract_field_names_a_prohibited_procfs_entry(self) -> None:
        from proc import PROHIBITED_PROC_ENTRIES  # noqa: PLC0415

        leaves = {k.rsplit(".", 1)[-1] for k in wire.allowed_keys()}
        overlap = leaves & set(PROHIBITED_PROC_ENTRIES)
        self.assertEqual(overlap, set(), f"contract field names a prohibited procfs entry: {overlap}")


if __name__ == "__main__":
    unittest.main()
