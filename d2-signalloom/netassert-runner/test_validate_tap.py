import subprocess
import tempfile
import unittest
from pathlib import Path


VALIDATOR = Path(__file__).with_name("validate-tap.sh")


class TapValidatorTest(unittest.TestCase):
    def validate(self, content):
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8") as tap:
            tap.write(content)
            tap.flush()
            return subprocess.run(
                ["sh", str(VALIDATOR), tap.name], text=True, capture_output=True
            )

    def assert_invalid(self, content, message):
        result = self.validate(content)
        self.assertEqual(2, result.returncode)
        self.assertIn(message, result.stderr)

    def test_accepts_complete_passing_tap(self):
        result = self.validate("TAP version 14\n1..2\nok 1 - first\nok 2 - second\n")
        self.assertEqual(0, result.returncode, result.stderr)

    def test_accepts_complete_failed_assertion_as_valid_tap(self):
        result = self.validate(
            "TAP version 14\n1..1\nnot ok 1 - denied mismatch\n"
            "  ---\n  reason: scanner exited 0\n  ...\n"
        )
        self.assertEqual(0, result.returncode, result.stderr)

    def test_rejects_missing_plan(self):
        self.assert_invalid("TAP version 14\nok 1 - first\n", "exactly one plan")

    def test_rejects_missing_tap_file(self):
        result = subprocess.run(
            ["sh", str(VALIDATOR), "/definitely/missing/results.tap"],
            text=True,
            capture_output=True,
        )
        self.assertEqual(2, result.returncode)
        self.assertIn("does not exist", result.stderr)

    def test_rejects_plan_count_mismatch(self):
        self.assert_invalid("TAP version 14\n1..2\nok 1 - first\n", "result count")

    def test_rejects_duplicate_numbering(self):
        self.assert_invalid(
            "TAP version 14\n1..2\nok 1 - first\nok 1 - duplicate\n", "duplicate result"
        )

    def test_rejects_noncontiguous_numbering(self):
        self.assert_invalid(
            "TAP version 14\n1..2\nok 1 - first\nok 3 - third\n", "outside plan"
        )

    def test_rejects_malformed_result(self):
        self.assert_invalid("TAP version 14\n1..1\nokay 1 - first\n", "malformed top-level")

    def test_rejects_bailout(self):
        self.assert_invalid("TAP version 14\n1..1\nBail out! crashed\n", "bailout")


if __name__ == "__main__":
    unittest.main()
