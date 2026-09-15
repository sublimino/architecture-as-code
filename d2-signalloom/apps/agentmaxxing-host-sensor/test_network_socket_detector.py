"""SLCD-P4-2 — tests for the fd-free outbound inference socket detector.

Structure mirrors the card's deliverables: fd-avoidance (runtime AND static), artefact
contract, true positives, false positives, the measured false-positive rate over a committed
corpus of real host traffic, and conformance to P1-1's frozen network.* schema.
"""
from __future__ import annotations

import ipaddress
import json
import os
import socket
import struct
import sys
import unittest
from pathlib import Path

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .coding_agent_models import NetworkInfo
    from .network import (
        DEFAULT_PROVIDER_ARTEFACT,
        PROC_ENTRIES_READ_BY_NETWORK_MODULE,
        CgroupResolver,
        InferenceProviderRanges,
        NetlinkSockDiag,
        SocketDetector,
        SocketRecord,
    )
    from .proc import PROHIBITED_PROC_ENTRIES, ProcReader
except (ImportError, ValueError):
    from coding_agent_models import NetworkInfo
    from network import (
        DEFAULT_PROVIDER_ARTEFACT,
        PROC_ENTRIES_READ_BY_NETWORK_MODULE,
        CgroupResolver,
        InferenceProviderRanges,
        NetlinkSockDiag,
        SocketDetector,
        SocketRecord,
    )
    from proc import PROHIBITED_PROC_ENTRIES, ProcReader

CORPUS_PATH = PKG_DIR / "testdata" / "slcd_p4_2_observed_destinations.json"
NETWORK_SOURCE = PKG_DIR / "network.py"


def executable_symbols(path: Path):
    """Return (identifiers, string-literals) from a module's AST, excluding docstrings.

    Text scans over source files are unreliable in both directions: they miss a call built
    from a variable, and they fire on prose in a docstring. The AST sees neither problem --
    it carries exactly the names the interpreter will resolve and exactly the strings that
    reach runtime.
    """
    import ast

    tree = ast.parse(path.read_text(encoding="utf-8"))
    docstrings = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            body = getattr(node, "body", None)
            if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant):
                if isinstance(body[0].value.value, str):
                    docstrings.add(id(body[0].value))

    names = set()
    strings = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Name):
            names.add(node.id)
        elif isinstance(node, ast.Attribute):
            names.add(node.attr)
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            if isinstance(node, ast.ImportFrom) and node.module:
                names.update(node.module.split("."))
            for alias in node.names:
                names.update(alias.name.split("."))
        elif isinstance(node, ast.Constant) and isinstance(node.value, str):
            if id(node) not in docstrings:
                strings.add(node.value)
    return names, strings


def make_record(dst_ip: str, dst_port: int = 443, cgroup_id=None, bytes_sent: int = 0, state: int = 1):
    family = socket.AF_INET6 if ":" in dst_ip else socket.AF_INET
    return SocketRecord(
        family=family,
        state=state,
        src_port=50000,
        dst_port=dst_port,
        dst_ip=dst_ip,
        uid=1000,
        inode=1234,
        cgroup_id=cgroup_id,
        bytes_sent=bytes_sent,
    )


class _RecordingDiag:
    """Stands in for NetlinkSockDiag so a full detection cycle can run deterministically."""

    def __init__(self, records):
        self._records = list(records)
        self.last_restriction = "unset"

    def dump(self, families=None, restrict_to_cgroups=None):
        self.last_restriction = restrict_to_cgroups
        if restrict_to_cgroups is None:
            return list(self._records)
        return [r for r in self._records if r.cgroup_id in restrict_to_cgroups]


# ======================================================================================
# 1. fd-avoidance — the card's central constraint
# ======================================================================================
class FdAvoidanceTests(unittest.TestCase):
    """ISC-8..13. Proves the detector reaches no prohibited procfs entry.

    Tested twice, because each test alone is insufficient: the static scan cannot see a call
    built from a variable, and the runtime recorder cannot see a code path this cycle did not
    execute.
    """

    def test_module_declares_its_procfs_surface_as_an_allow_list(self) -> None:
        self.assertEqual(PROC_ENTRIES_READ_BY_NETWORK_MODULE, frozenset({"cgroup"}))

    def test_declared_surface_is_disjoint_from_the_prohibited_set(self) -> None:
        overlap = PROC_ENTRIES_READ_BY_NETWORK_MODULE & PROHIBITED_PROC_ENTRIES
        self.assertEqual(overlap, set(), f"network.py declares prohibited procfs entries: {overlap}")

    def test_runtime_tripwire_records_zero_prohibited_safe_proc_path_calls(self) -> None:
        """Patch _safe_proc_path to record every entry name, then run a whole cycle."""
        seen = []
        original = ProcReader._safe_proc_path

        def recorder(self, pid, entry_name):
            seen.append(entry_name)
            return original(self, pid, entry_name)

        ProcReader._safe_proc_path = recorder
        try:
            detector = SocketDetector(
                ranges=InferenceProviderRanges.load(),
                diag=_RecordingDiag(
                    [
                        make_record("160.79.104.10", 443, cgroup_id=999, bytes_sent=4096),
                        make_record("104.21.23.165", 443, cgroup_id=888),
                        make_record("8.8.8.8", 53, cgroup_id=777),
                    ]
                ),
            )
            detector.detect(harness_pids=[os.getpid()])
        finally:
            ProcReader._safe_proc_path = original

        prohibited_hits = [e for e in seen if e in PROHIBITED_PROC_ENTRIES]
        self.assertEqual(
            prohibited_hits,
            [],
            f"detection cycle reached prohibited procfs entries: {prohibited_hits}",
        )

    def test_static_scan_finds_no_fd_fdinfo_or_net_path_construction(self) -> None:
        """Scan the AST, not the text.

        A text scan over this file would match its own module docstring, which legitimately
        discusses fd at length. That is the 'guard satisfied by a comment' failure mode in
        reverse: prose triggering a guard that the code never violates. Working from the AST
        means only executable identifiers and real string literals are examined.
        """
        names, strings = executable_symbols(NETWORK_SOURCE)
        for entry in ("fd", "fdinfo", "net"):
            self.assertNotIn(
                entry,
                strings,
                f"network.py constructs a procfs path from the prohibited entry {entry!r}",
            )
        for literal in strings:
            self.assertNotRegex(
                literal,
                r"/proc/[^\s]*/(fd|fdinfo|net)\b",
                "network.py contains a prohibited procfs path literal",
            )

    def test_detector_does_not_shell_out_to_ss_or_lsof(self) -> None:
        """ss -p and lsof resolve PIDs by scanning /proc/<pid>/fd.

        A subprocess boundary would put the prohibited read one hop outside anything this
        repository's tests can observe, so the module must not create one at all.
        """
        names, strings = executable_symbols(NETWORK_SOURCE)
        for banned in ("subprocess", "system", "popen", "Popen", "fork", "execv", "spawn"):
            self.assertNotIn(banned, names, f"network.py references {banned!r} in executable code")
        for literal in strings:
            self.assertNotRegex(literal, r"\b(ss|lsof|netstat)\b", f"command literal {literal!r}")


# ======================================================================================
# 2. Provider artefact contract
# ======================================================================================
class ProviderArtefactTests(unittest.TestCase):
    """ISC-16..21."""

    def setUp(self) -> None:
        self.raw = json.loads(DEFAULT_PROVIDER_ARTEFACT.read_text(encoding="utf-8"))
        self.ranges = InferenceProviderRanges.load()

    def test_artefact_is_versioned_and_dated(self) -> None:
        self.assertIn("list_version", self.raw)
        self.assertIn("generated", self.raw)
        self.assertNotEqual(self.ranges.list_version, "unknown")

    def test_every_provider_carries_provenance_and_a_source(self) -> None:
        for provider in self.raw["providers"]:
            with self.subTest(provider=provider["id"]):
                self.assertTrue(provider.get("provenance", "").strip())
                self.assertTrue(provider.get("source", "").strip())

    def test_every_range_declares_an_attribution_tier(self) -> None:
        for provider in self.raw["providers"]:
            for entry in provider["ranges"]:
                with self.subTest(provider=provider["id"], cidr=entry["cidr"]):
                    self.assertIn(entry["attribution"], {"dedicated", "loopback", "shared"})

    def test_all_card_named_providers_are_present(self) -> None:
        ids = {p["id"] for p in self.raw["providers"]}
        for required in ("anthropic", "openai", "google-vertex", "ollama", "openbao"):
            self.assertIn(required, ids)

    def test_openbao_is_control_plane_and_never_an_inference_endpoint(self) -> None:
        openbao = next(p for p in self.raw["providers"] if p["id"] == "openbao")
        self.assertEqual(openbao["kind"], "control-plane")
        self.assertNotIn(openbao["endpoint"], self.ranges.inference_endpoints)

    def test_every_cidr_parses(self) -> None:
        for provider in self.raw["providers"]:
            for entry in provider["ranges"]:
                ipaddress.ip_network(entry["cidr"])

    def test_loader_rejects_an_unknown_attribution_tier(self) -> None:
        bad = {
            "list_version": "test",
            "providers": [
                {
                    "id": "x",
                    "endpoint": "x.example",
                    "ports": [443],
                    "ranges": [{"cidr": "10.0.0.0/8", "attribution": "probably"}],
                }
            ],
        }
        with self.assertRaises(ValueError):
            InferenceProviderRanges.from_dict(bad)


# ======================================================================================
# 3. True positives
# ======================================================================================
class TruePositiveTests(unittest.TestCase):
    """ISC-30, ISC-31."""

    def setUp(self) -> None:
        self.detector = SocketDetector(ranges=InferenceProviderRanges.load(), diag=_RecordingDiag([]))

    def test_anthropic_dedicated_range_classifies_without_corroboration(self) -> None:
        result = self.detector.classify(make_record("160.79.104.10", 443, cgroup_id=42, bytes_sent=90210))
        self.assertEqual(result.verdict, "inference")
        self.assertEqual(result.endpoint, "api.anthropic.com")
        self.assertEqual(result.attribution, "dedicated")
        self.assertEqual(result.egress_bytes, 90210)

    def test_google_shared_range_classifies_when_a_harness_shares_the_cgroup(self) -> None:
        index = {7000: {4242}}
        result = self.detector.classify(make_record("34.54.84.110", 443, cgroup_id=7000), index)
        self.assertEqual(result.verdict, "inference")
        self.assertEqual(result.endpoint, "aiplatform.googleapis.com")
        self.assertEqual(result.attribution, "shared")
        self.assertTrue(result.corroborated)
        self.assertEqual(result.candidate_pids, (4242,))

    def test_ollama_loopback_classifies_on_exact_port(self) -> None:
        result = self.detector.classify(make_record("127.0.0.1", 11434, cgroup_id=1))
        self.assertEqual(result.verdict, "inference")
        self.assertEqual(result.endpoint, "ollama.localhost")

    def test_ambiguity_is_reported_not_resolved(self) -> None:
        index = {7000: {111, 222, 333}}
        result = self.detector.classify(make_record("34.54.84.110", 443, cgroup_id=7000), index)
        self.assertTrue(result.ambiguous)
        self.assertEqual(result.candidate_pids, (111, 222, 333))


# ======================================================================================
# 4. False positives
# ======================================================================================
class FalsePositiveTests(unittest.TestCase):
    """ISC-22, ISC-23, ISC-32, ISC-33."""

    def setUp(self) -> None:
        self.detector = SocketDetector(ranges=InferenceProviderRanges.load(), diag=_RecordingDiag([]))

    def test_package_manager_download_over_a_cdn_range_is_not_inference(self) -> None:
        """registry.npmjs.org sits in Cloudflare space, same as api.openai.com."""
        result = self.detector.classify(make_record("104.16.24.10", 443, cgroup_id=5150))
        self.assertEqual(result.verdict, "unknown")
        self.assertIsNone(result.endpoint)
        self.assertIn("shared", result.reason)

    def test_git_fetch_to_github_is_not_inference(self) -> None:
        result = self.detector.classify(make_record("140.82.121.4", 443, cgroup_id=5151))
        self.assertEqual(result.verdict, "unknown")
        self.assertIsNone(result.endpoint)

    def test_music_client_inside_google_cloud_space_is_not_inference(self) -> None:
        """Measured live: 35.186.224.33:443 belonged to a Spotify cgroup on this host."""
        result = self.detector.classify(make_record("35.186.224.33", 443, cgroup_id=6000))
        self.assertEqual(result.verdict, "unknown")
        self.assertIsNone(result.endpoint)

    def test_unmatched_address_is_unknown_not_the_nearest_provider(self) -> None:
        result = self.detector.classify(make_record("203.0.113.7", 443, cgroup_id=1))
        self.assertEqual(result.verdict, "unknown")
        self.assertIsNone(result.provider_id)
        self.assertIsNone(result.endpoint)

    def test_openbao_connection_is_classified_control_plane_never_inference(self) -> None:
        result = self.detector.classify(make_record("127.0.0.1", 8200, cgroup_id=1))
        self.assertEqual(result.verdict, "control-plane")
        self.assertIsNone(result.endpoint)

    def test_wrong_port_inside_a_dedicated_range_does_not_match(self) -> None:
        result = self.detector.classify(make_record("160.79.104.10", 22, cgroup_id=1))
        self.assertEqual(result.verdict, "unknown")


# ======================================================================================
# 5. Anti-criteria — no DNS, no raw IP, schema conformance
# ======================================================================================
class AntiCriteriaTests(unittest.TestCase):
    """ISC-24..29."""

    def setUp(self) -> None:
        self.detector = SocketDetector(ranges=InferenceProviderRanges.load(), diag=_RecordingDiag([]))

    def test_module_source_contains_no_resolver_call(self) -> None:
        source = NETWORK_SOURCE.read_text(encoding="utf-8")
        for needle in ("gethostbyaddr", "getnameinfo", "getfqdn", "gethostbyname", "getaddrinfo"):
            self.assertNotIn(needle, source, f"network.py references resolver {needle!r}")

    def test_runtime_dns_tripwire_never_fires_during_a_detection_cycle(self) -> None:
        originals = {}
        names = ("gethostbyaddr", "getnameinfo", "getfqdn", "gethostbyname", "getaddrinfo")

        def boom(*args, **kwargs):
            raise AssertionError("detector performed DNS resolution")

        for name in names:
            originals[name] = getattr(socket, name)
            setattr(socket, name, boom)
        try:
            detector = SocketDetector(
                ranges=InferenceProviderRanges.load(),
                diag=_RecordingDiag(
                    [
                        make_record("160.79.104.10", 443, cgroup_id=1, bytes_sent=10),
                        make_record("104.21.23.165", 443, cgroup_id=2),
                        make_record("203.0.113.9", 443, cgroup_id=3),
                    ]
                ),
            )
            results = detector.detect(harness_pids=[])
        finally:
            for name, fn in originals.items():
                setattr(socket, name, fn)
        self.assertEqual(len(results), 3)

    def test_emitted_endpoint_is_never_a_raw_ip_literal(self) -> None:
        detector = SocketDetector(
            ranges=InferenceProviderRanges.load(),
            diag=_RecordingDiag([make_record("160.79.104.10", 443, cgroup_id=1, bytes_sent=7)]),
        )
        for classification in detector.detect_inference():
            payload = detector.to_network_info(classification)
            with self.assertRaises(ValueError):
                ipaddress.ip_address(payload["inference_endpoint"])

    def test_emit_rejects_an_endpoint_outside_the_committed_artefact(self) -> None:
        detector = SocketDetector(ranges=InferenceProviderRanges.load(), diag=_RecordingDiag([]))
        forged = detector.classify(make_record("160.79.104.10", 443, cgroup_id=1))
        forged = forged._replace(endpoint="evil.example.com")
        with self.assertRaises(ValueError) as ctx:
            detector.to_network_info(forged)
        self.assertIn("structural allow-list", str(ctx.exception))

    def test_emit_rejects_a_raw_ip_smuggled_into_the_endpoint_field(self) -> None:
        """The field regex ^[a-zA-Z0-9.-]{1,128}$ accepts '160.79.104.10'.

        NetworkInfo would therefore validate it happily. Only the membership check stops it.
        """
        NetworkInfo(inference_endpoint="160.79.104.10", egress_bytes=1)  # regex alone permits it
        detector = SocketDetector(ranges=InferenceProviderRanges.load(), diag=_RecordingDiag([]))
        smuggled = detector.classify(make_record("160.79.104.10", 443, cgroup_id=1))
        smuggled = smuggled._replace(endpoint="160.79.104.10")
        with self.assertRaises(ValueError):
            detector.to_network_info(smuggled)

    def test_exported_record_has_exactly_the_two_frozen_p1_1_fields(self) -> None:
        detector = SocketDetector(
            ranges=InferenceProviderRanges.load(),
            diag=_RecordingDiag([make_record("160.79.104.10", 443, cgroup_id=1, bytes_sent=45000)]),
        )
        payload = detector.to_network_info(detector.detect_inference()[0])
        self.assertEqual(set(payload.keys()), {"inference_endpoint", "egress_bytes"})

    def test_exported_record_round_trips_through_networkinfo(self) -> None:
        detector = SocketDetector(
            ranges=InferenceProviderRanges.load(),
            diag=_RecordingDiag([make_record("160.79.104.10", 443, cgroup_id=1, bytes_sent=45000)]),
        )
        payload = detector.to_network_info(detector.detect_inference()[0])
        info = NetworkInfo.from_dict(payload)
        self.assertEqual(info.to_dict(), payload)

    def test_refuses_to_export_an_unknown_classification(self) -> None:
        detector = SocketDetector(ranges=InferenceProviderRanges.load(), diag=_RecordingDiag([]))
        unknown = detector.classify(make_record("203.0.113.7", 443, cgroup_id=1))
        with self.assertRaises(ValueError):
            detector.to_network_info(unknown)


# ======================================================================================
# 6. Measured false-positive rate over the committed corpus
# ======================================================================================
class MeasuredFalsePositiveRateTests(unittest.TestCase):
    """ISC-34, ISC-35. Replaces the proposal's asserted zero-FP claim with a number.

    The corpus is real traffic from a working developer session. The detector is run over it
    twice: once WITHOUT harness corroboration (which is what a CIDR-only implementation --
    the one the proposal describes -- would do) and once WITH it. Reporting both is the
    point: the delta is the evidence that the shared tier is doing real work rather than
    being decorative metadata.
    """

    @classmethod
    def setUpClass(cls) -> None:
        cls.corpus = json.loads(CORPUS_PATH.read_text(encoding="utf-8"))
        cls.rows = cls.corpus["destinations"]
        cls.detector = SocketDetector(ranges=InferenceProviderRanges.load(), diag=_RecordingDiag([]))

    def _run_untiered_cidr(self):
        """Model the method the proposal describes: any CIDR match is an attribution.

        No attribution tiers, no corroboration -- exactly what 'match destination IPs against
        known inference provider CIDR ranges' means if taken literally.
        """
        tp = fp = 0
        fp_rows = []
        for row in self.rows:
            matched = self.detector.ranges.match(row["dst_ip"], row["dst_port"])
            if matched is None or matched[0].kind != "inference":
                continue
            if row["traffic_class"] == "coding-agent":
                tp += 1
            else:
                fp += 1
                fp_rows.append(row)
        return tp, fp, fp_rows

    def _run_tiered(self):
        """The shipped detector: tiers enforced, shared ranges require corroboration."""
        tp = fp = 0
        fp_rows = []
        for row in self.rows:
            index = {1: {4242}} if row["cgroup_has_harness"] else {}
            result = self.detector.classify(
                make_record(row["dst_ip"], row["dst_port"], cgroup_id=1), index
            )
            if result.verdict != "inference":
                continue
            if row["traffic_class"] == "coding-agent":
                tp += 1
            else:
                fp += 1
                fp_rows.append(row)
        return tp, fp, fp_rows

    def test_corpus_is_real_and_non_trivial(self) -> None:
        self.assertGreaterEqual(len(self.rows), 40)
        classes = {r["traffic_class"] for r in self.rows}
        self.assertIn("coding-agent", classes)
        self.assertGreater(
            len(classes - {"coding-agent"}), 2, "corpus must contain varied non-inference traffic"
        )

    def test_untiered_cidr_matching_has_a_high_false_positive_rate(self) -> None:
        """Falsifies the proposal's zero-false-positive KPI for the method it describes."""
        tp, fp, fp_rows = self._run_untiered_cidr()
        total = tp + fp
        self.assertGreater(total, 0, "matched nothing — the corpus or the list is wrong")
        print(
            f"\n[SLCD-P4-2] untiered CIDR matching (the proposal's method): "
            f"attributed={total} TP={tp} FP={fp} FP-rate={fp / total:.1%}"
        )
        self.assertGreater(
            fp, 0, "untiered CIDR matching must be shown to misfire on shared CDN/cloud space"
        )

    def test_tiered_matching_materially_reduces_the_false_positive_rate(self) -> None:
        base_tp, base_fp, _ = self._run_untiered_cidr()
        tp, fp, fp_rows = self._run_tiered()
        total = tp + fp
        rate = fp / total if total else 0.0
        print(
            f"[SLCD-P4-2] tiered + cgroup-corroborated (shipped): "
            f"attributed={total} TP={tp} FP={fp} FP-rate={rate:.1%}"
        )
        if fp_rows:
            print(
                "[SLCD-P4-2] residual false positives: "
                + ", ".join(
                    f"{r['dst_ip']}:{r['dst_port']}({r['traffic_class']})" for r in fp_rows
                )
            )
        self.assertLess(fp, base_fp, "tiering must reduce false positives")
        self.assertGreater(tp, 0, "tiering must not destroy true positives")
        self.assertLess(rate, 0.15, "shipped false-positive rate regressed above 15%")

    def test_full_confusion_matrix_is_reported_for_both_arms(self) -> None:
        """Precision alone cannot judge a filter whose whole operation is to attribute less.

        Without recall, a fall from 38.9% to 8.3% is equally consistent with 'the tiered arm
        also dropped half the true inference flows'. Both arms are scored over the identical
        destination set so the comparison means something.
        """

        def matrix(tiered):
            tp = fp = tn = fn = 0
            for row in self.rows:
                truth = row["traffic_class"] == "coding-agent"
                if tiered:
                    index = {1: {4242}} if row["cgroup_has_harness"] else {}
                    pred = (
                        self.detector.classify(
                            make_record(row["dst_ip"], row["dst_port"], cgroup_id=1), index
                        ).verdict
                        == "inference"
                    )
                else:
                    m = self.detector.ranges.match(row["dst_ip"], row["dst_port"])
                    pred = bool(m and m[0].kind == "inference")
                if pred and truth:
                    tp += 1
                elif pred:
                    fp += 1
                elif truth:
                    fn += 1
                else:
                    tn += 1
            return tp, fp, tn, fn

        base = matrix(False)
        tiered = matrix(True)
        for name, (tp, fp, tn, fn) in (("untiered CIDR", base), ("tiered", tiered)):
            precision = tp / (tp + fp) if tp + fp else 0.0
            recall = tp / (tp + fn) if tp + fn else 0.0
            print(
                f"[SLCD-P4-2] {name}: TP={tp} FP={fp} TN={tn} FN={fn} "
                f"precision={precision:.1%} recall={recall:.1%}"
            )
        self.assertEqual(
            base[0] + base[3],
            tiered[0] + tiered[3],
            "arms must be scored over the same positive class",
        )
        self.assertEqual(
            base[3], tiered[3], "tiering must not convert a true positive into a false negative"
        )
        self.assertEqual(base[0], tiered[0], "tiering must preserve every true positive")

    def test_the_improvement_comes_from_the_shared_tier_not_the_dedicated_ranges(self) -> None:
        """Mutation on the tier logic itself.

        The measured delta could in principle come entirely from the dedicated ranges. This
        disables the shared-tier corroboration requirement and asserts the false-positive
        count climbs, which is what proves the tier check is load-bearing.
        """
        shared_fps = 0
        for row in self.rows:
            match = self.detector.ranges.match(row["dst_ip"], row["dst_port"])
            if not match or match[0].kind != "inference":
                continue
            provider, tier = match
            if tier == "shared" and row["traffic_class"] != "coding-agent":
                shared_fps += 1
        _, tiered_fp, _ = self._run_tiered()
        print(
            f"[SLCD-P4-2] shared-tier check suppresses {shared_fps} false positives; "
            f"{tiered_fp} residual"
        )
        self.assertGreater(
            shared_fps, 0, "shared-tier check suppresses nothing — the delta is not from tiering"
        )
        self.assertGreaterEqual(shared_fps, tiered_fp * 2)

    def test_measured_rate_is_recorded_in_the_evidence_document(self) -> None:
        """The document must state the number this suite actually computes.

        Asserting the count rather than merely the phrase is what stops the doc drifting into
        a claim the code no longer supports.
        """
        doc = PKG_DIR.parents[2] / "docs" / "signalloom" / "slcd-p4-2-socket-detector.md"
        self.assertTrue(doc.exists(), f"missing evidence document at {doc}")
        text = doc.read_text(encoding="utf-8")
        self.assertIn("false-positive rate", text.lower())
        tp, fp, _ = self._run_tiered()
        base_tp, base_fp, _ = self._run_untiered_cidr()
        self.assertIn(
            f"{fp}/{tp + fp}", text, "document does not state the measured shipped FP count"
        )
        self.assertIn(
            f"{base_fp}/{base_tp + base_fp}",
            text,
            "document does not state the measured untiered-CIDR baseline FP count",
        )


# ======================================================================================
# 7. Live kernel correlation proof
# ======================================================================================
class ObservationApertureTests(unittest.TestCase):
    """Aperture control. A sock_diag dump is host-wide; descriptor scanning was not.

    Avoiding the prohibited entry while quietly reading every socket on the machine would be
    true in the letter and misleading in spirit. These tests pin the mitigation.
    """

    def _records(self):
        return [
            make_record("160.79.104.10", 443, cgroup_id=100, bytes_sent=10),  # harness
            make_record("104.21.23.165", 443, cgroup_id=200),  # somebody's browser
            make_record("162.125.21.3", 443, cgroup_id=300),  # somebody's file sync
        ]

    def test_restriction_discards_sockets_outside_the_harness_cgroups(self) -> None:
        diag = _RecordingDiag(self._records())
        detector = SocketDetector(ranges=InferenceProviderRanges.load(), diag=diag)
        detector.cgroups = _FakeCgroups({4242: 100})
        results = detector.detect(harness_pids=[4242], restrict_to_harness_cgroups=True)
        self.assertEqual(diag.last_restriction, {100})
        seen = {r.dst_ip for r in results}
        self.assertEqual(seen, {"160.79.104.10"})
        self.assertNotIn("104.21.23.165", seen, "unrelated destination survived the restriction")

    def test_unrelated_destination_is_dropped_before_its_address_is_decoded(self) -> None:
        """The privacy gate must sit before inet_ntop, not after classification."""
        body = bytearray(72 + 12)
        body[0] = socket.AF_INET
        body[1] = 1
        struct.pack_into("!HH", body, 4, 50000, 443)
        body[24:28] = socket.inet_aton("104.21.23.165")
        struct.pack_into("=HH", body, 72, 12, 21)
        struct.pack_into("=Q", body, 76, 999)
        kept = NetlinkSockDiag._parse_msg(socket.AF_INET, bytes(body), {111})
        self.assertIsNone(kept, "record outside the restriction was materialised")
        passed = NetlinkSockDiag._parse_msg(socket.AF_INET, bytes(body), {999})
        self.assertEqual(passed.dst_ip, "104.21.23.165")

    def test_no_cgroup_path_reaches_an_exception_message(self) -> None:
        """cgroup paths carry container and scope names chosen by users."""
        detector = SocketDetector(ranges=InferenceProviderRanges.load(), diag=_RecordingDiag([]))
        unknown = detector.classify(make_record("203.0.113.7", 443, cgroup_id=1))
        with self.assertRaises(ValueError) as ctx:
            detector.to_network_info(unknown)
        self.assertNotIn("/sys/fs/cgroup", str(ctx.exception))
        self.assertNotIn(".scope", str(ctx.exception))


class _FakeCgroups:
    def __init__(self, pid_to_cgid):
        self._m = dict(pid_to_cgid)
        self.cgroup_root = Path("/sys/fs/cgroup")

    def build_cgroup_index(self, pids):
        out = {}
        for pid in pids:
            cgid = self._m.get(pid)
            if cgid is not None:
                out.setdefault(cgid, set()).add(pid)
        return out

    def cgroup_id_for_path(self, path):
        return 1  # a root cgroup id that no fake harness uses


class OracleStatusTests(unittest.TestCase):
    """ISC: never degrade silently. A host without the oracle has a different FP profile."""

    def setUp(self) -> None:
        from network import ORACLE_AVAILABLE, ORACLE_NO_ATTRIBUTE, ORACLE_ROOT_ONLY

        self.AVAILABLE, self.NO_ATTR, self.ROOT = ORACLE_AVAILABLE, ORACLE_NO_ATTRIBUTE, ORACLE_ROOT_ONLY

    def test_no_resolvable_harness_cgroup_reports_unavailable(self) -> None:
        detector = SocketDetector(ranges=InferenceProviderRanges.load(), diag=_RecordingDiag([]))
        detector.cgroups = _FakeCgroups({})
        detector.detect(harness_pids=[4242])
        self.assertEqual(detector.last_oracle_status, self.NO_ATTR)

    def test_all_sockets_in_the_root_cgroup_reports_root_only(self) -> None:
        """cgroup v1 net_cls mounted => socket cgroup association disabled => everything matches."""
        detector = SocketDetector(ranges=InferenceProviderRanges.load(), diag=_RecordingDiag([]))
        detector.cgroups = _FakeCgroups({4242: 1})  # 1 is the fake root id
        detector.detect(harness_pids=[4242])
        self.assertEqual(detector.last_oracle_status, self.ROOT)

    def test_a_real_harness_cgroup_reports_available(self) -> None:
        detector = SocketDetector(ranges=InferenceProviderRanges.load(), diag=_RecordingDiag([]))
        detector.cgroups = _FakeCgroups({4242: 5551212})
        detector.detect(harness_pids=[4242])
        self.assertEqual(detector.last_oracle_status, self.AVAILABLE)


class EmitSurfaceSourceOfTruthTests(unittest.TestCase):
    """The allow-list must not be its own source of truth.

    If membership were evaluated only against the JSON that also defines the ranges, adding a
    provider to the JSON would widen the emit surface with no code change and no test
    movement. The frozen code constant is what stops that.
    """

    def test_artefact_cannot_introduce_an_endpoint_absent_from_the_code_constant(self) -> None:
        from network import ALLOWED_INFERENCE_ENDPOINTS

        rogue = {
            "list_version": "test",
            "providers": [
                {
                    "id": "rogue",
                    "endpoint": "exfil.example.com",
                    "kind": "inference",
                    "ports": [443],
                    "ranges": [{"cidr": "203.0.113.0/24", "attribution": "dedicated"}],
                }
            ],
        }
        with self.assertRaises(ValueError) as ctx:
            InferenceProviderRanges.from_dict(rogue)
        self.assertIn("ALLOWED_INFERENCE_ENDPOINTS", str(ctx.exception))
        self.assertNotIn("exfil.example.com", ALLOWED_INFERENCE_ENDPOINTS)

    def test_committed_artefact_agrees_with_the_code_constant(self) -> None:
        from network import ALLOWED_INFERENCE_ENDPOINTS

        loaded = InferenceProviderRanges.load().inference_endpoints
        self.assertTrue(
            loaded <= ALLOWED_INFERENCE_ENDPOINTS,
            f"artefact declares endpoints outside the frozen constant: "
            f"{loaded - ALLOWED_INFERENCE_ENDPOINTS}",
        )


class IndependentNegativeControlTests(unittest.TestCase):
    """Constants here are NOT drawn from the range artefact.

    A control built from the same table it is testing is a tautology: it passes because both
    sides share a constant, not because the logic is right.
    """

    def setUp(self) -> None:
        self.detector = SocketDetector(ranges=InferenceProviderRanges.load(), diag=_RecordingDiag([]))

    def test_documentation_range_never_attributes_however_corroborated(self) -> None:
        """TEST-NET-3 (RFC 5737) appears nowhere in the artefact, by construction."""
        index = {42: {4242}}
        result = self.detector.classify(make_record("203.0.113.42", 443, cgroup_id=42), index)
        self.assertEqual(result.verdict, "unknown")
        self.assertIsNone(result.endpoint)

    def test_non_harness_process_on_a_shared_range_does_not_attribute(self) -> None:
        """Same destination, same range, no harness in the cgroup => no attribution."""
        shared_dst = "104.21.23.165"
        with_harness = self.detector.classify(
            make_record(shared_dst, 443, cgroup_id=9), {9: {4242}}
        )
        without = self.detector.classify(make_record(shared_dst, 443, cgroup_id=9), {})
        self.assertEqual(with_harness.verdict, "inference")
        self.assertEqual(without.verdict, "unknown")


class LiveNetlinkCorrelationTests(unittest.TestCase):
    """ISC-2..7. Exercises the real kernel interface, not a fixture.

    Skips only when netlink genuinely cannot be opened, which on this mission is itself the
    stop-and-report condition rather than an acceptable silent pass.
    """

    def setUp(self) -> None:
        try:
            probe = socket.socket(socket.AF_NETLINK, socket.SOCK_DGRAM, 4)
        except OSError as exc:  # pragma: no cover
            self.skipTest(f"NETLINK_SOCK_DIAG unavailable: {exc}")
        probe.close()

    def test_netlink_dump_returns_sockets_with_cgroup_ids(self) -> None:
        records = NetlinkSockDiag().dump()
        self.assertGreater(len(records), 0, "no sockets returned by sock_diag")
        with_cgroup = [r for r in records if r.cgroup_id]
        self.assertGreater(
            len(with_cgroup), 0, "kernel returned no INET_DIAG_CGROUP_ID attributes"
        )

    def test_cgroup_bridge_resolves_this_process(self) -> None:
        resolver = CgroupResolver()
        cgid = resolver.cgroup_id_for_pid(os.getpid())
        self.assertIsNotNone(cgid, "could not resolve this process's cgroup id")
        self.assertGreater(cgid, 0)

    def test_end_to_end_socket_to_process_correlation_without_fd(self) -> None:
        """Open a real outbound socket, find it via netlink, match it back by cgroup id."""
        resolver = CgroupResolver()
        mine = resolver.cgroup_id_for_pid(os.getpid())
        self.assertIsNotNone(mine)

        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        client = socket.create_connection(listener.getsockname(), timeout=5)
        server, _ = listener.accept()
        try:
            client.sendall(b"x" * 64)
            local_port = client.getsockname()[1]
            match = None
            for record in NetlinkSockDiag().dump(families=(socket.AF_INET,)):
                if record.src_port == local_port and record.state == 1:
                    match = record
                    break
            self.assertIsNotNone(match, "netlink did not report the socket we just opened")
            self.assertEqual(
                match.cgroup_id,
                mine,
                "netlink cgroup id did not match the cgroup id derived from /proc/<pid>/cgroup",
            )
        finally:
            client.close()
            server.close()
            listener.close()


if __name__ == "__main__":  # pragma: no cover
    unittest.main(verbosity=2)
