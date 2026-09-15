"""SLCD-P1-GOV: the lawful-basis gate is a control, not a note.

Every test here is non-vacuous today. Each one reads either the live gate or the
live assessment document, so none of them can pass by describing a thing that is
absent — the failure mode the assessment itself warns a Governor against at §0.3.
"""
from __future__ import annotations

from pathlib import Path
import re
import unittest

import lawful_basis

SENSOR_DIR = Path(__file__).resolve().parent
REPO_ROOT = SENSOR_DIR.parents[2]
ASSESSMENT = REPO_ROOT / lawful_basis.ASSESSMENT_PATH


class GateIsClosed(unittest.TestCase):
    """The gate refuses today, and says why."""

    def test_collection_is_not_permitted(self) -> None:
        self.assertFalse(lawful_basis.workstation_collection_permitted())

    def test_assert_raises_and_names_the_call_site(self) -> None:
        with self.assertRaises(lawful_basis.LawfulBasisBlocked) as ctx:
            lawful_basis.assert_workstation_collection_permitted("p5-1-dispatcher")
        msg = str(ctx.exception)
        self.assertIn("p5-1-dispatcher", msg)
        self.assertIn("OPEN-SLCD", msg)
        self.assertIn(lawful_basis.ASSESSMENT_PATH, msg)

    def test_no_environment_override_exists(self) -> None:
        """A gate with a runtime bypass is not a gate.

        Asserted against the module source so that adding an env read later fails
        here rather than being discovered after collection has already run.
        """
        src = (SENSOR_DIR / "lawful_basis.py").read_text(encoding="utf-8")
        body = src.split('"""', 2)[-1]  # drop the module docstring
        for bypass in ("os.environ", "getenv", "os.getenv"):
            self.assertNotIn(bypass, body, f"lawful-basis gate exposes a runtime bypass: {bypass}")

    def test_state_only_opens_on_the_exact_permitted_token(self) -> None:
        self.assertNotEqual(lawful_basis.COLLECTION_STATE, "ENABLED")
        self.assertTrue(lawful_basis.OPEN_ITEMS, "gate must not open while items are carried forward")


class GateAgreesWithTheAssessment(unittest.TestCase):
    """Code and document cannot drift apart silently, in either direction."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.text = ASSESSMENT.read_text(encoding="utf-8")

    def test_assessment_exists_where_the_gate_says_it_does(self) -> None:
        self.assertTrue(ASSESSMENT.is_file(), f"assessment missing at {ASSESSMENT}")

    def test_frontmatter_collection_state_matches_code(self) -> None:
        m = re.search(r"^collection_state:\s*(\S+)", self.text, re.M)
        self.assertIsNotNone(m, "assessment frontmatter has no collection_state")
        self.assertEqual(m.group(1), lawful_basis.COLLECTION_STATE)

    def test_open_item_count_matches_code(self) -> None:
        ids = {int(n) for n in re.findall(r"OPEN-SLCD-(\d+)", self.text)}
        self.assertEqual(
            len(ids),
            lawful_basis.OPEN_ITEMS_TOTAL,
            "assessment OPEN-SLCD count drifted from lawful_basis.OPEN_ITEMS_TOTAL",
        )
        self.assertEqual(ids, set(range(1, lawful_basis.OPEN_ITEMS_TOTAL + 1)), "OPEN-SLCD ids are not contiguous")

    def test_blocking_count_matches_code(self) -> None:
        m = re.search(r"(\d+)\s+items are OPEN, of which\s+(\d+)\s+block", self.text)
        self.assertIsNotNone(m, "assessment no longer states its open/blocking totals")
        self.assertEqual(int(m.group(1)), lawful_basis.OPEN_ITEMS_TOTAL)
        self.assertEqual(int(m.group(2)), lawful_basis.OPEN_ITEMS_BLOCKING)


class NoUngatedTransmissionPath(unittest.TestCase):
    """The first module that tries to send without gating fails the build.

    Non-vacuous today: it asserts the *current* referencing set equals the frozen
    allow-list, so both an addition and a removal are caught.
    """

    def test_endpoint_reference_set_is_exactly_the_allowlist(self) -> None:
        endpoint = "/api/v1/telemetry/coding-agents"
        found = set()
        for path in list(SENSOR_DIR.glob("*.py")) + list((SENSOR_DIR / "scripts").glob("*.py")):
            rel = path.name if path.parent == SENSOR_DIR else f"scripts/{path.name}"
            if endpoint in path.read_text(encoding="utf-8"):
                found.add(rel)
        self.assertEqual(
            found,
            set(lawful_basis.ENDPOINT_REFERENCE_ALLOWLIST),
            "a module gained or lost a reference to the coding-agent transmission endpoint; "
            "any new sender must call lawful_basis.assert_workstation_collection_permitted()",
        )

    def test_allowlist_is_not_empty(self) -> None:
        """Guards the guard: an empty allow-list would make the pin vacuous."""
        self.assertTrue(lawful_basis.ENDPOINT_REFERENCE_ALLOWLIST)


if __name__ == "__main__":
    unittest.main()
