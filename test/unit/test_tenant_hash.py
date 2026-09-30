"""SLDC-P3-1: canonical tenant hash vectors, salt resolution, kurasi rejection.

Run: SIGNAL_LOOM_EAP_SALT="signalloom-eap-salt-2026-q3" \
       python3 -m unittest discover -s test/unit -p "test_tenant_hash*.py"

Hermetic: OpenBao is replaced by an injected fetch function or an unroutable
address, so no test touches a live cluster.

@id     test-tenant-hash
@target scripts/derive_tenant_hash.py
@doc    docs/eap/SLDC-P3-TENANT-INVENTORY.md
@task   SLDC-P3-1
"""

import hashlib
import hmac
import importlib.util
import json
import os
import subprocess
import sys
import time
import unittest
import urllib.error
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "derive_tenant_hash.py"
PILOT_SALT = "signalloom-eap-salt-2026-q3"

_spec = importlib.util.spec_from_file_location("derive_tenant_hash", SCRIPT)
dth = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(dth)


def _bao_payload(salt):
    return {"data": {"data": {"salt": salt}, "metadata": {"version": 1}}}


def _run(*args, env=None):
    base = {k: v for k, v in os.environ.items()
            if k not in ("SIGNAL_LOOM_EAP_SALT", "BAO_ADDR", "VAULT_ADDR",
                         "OPENBAO_ADDR", "BAO_TOKEN", "VAULT_TOKEN")}
    base.update(env or {})
    return subprocess.run([sys.executable, str(SCRIPT), *args], env=base,
                          capture_output=True, text=True, timeout=30)


class CanonicalVectors(unittest.TestCase):
    def test_kusari_is_4b53ab6b(self):
        self.assertEqual(dth.derive_tenant_hash("kusari", salt=PILOT_SALT), "4b53ab6b")

    def test_matches_salted_concatenation_formula(self):
        for tenant in ("kusari", "acme", "a", "tenant-01", "x" * 63):
            want = hashlib.sha256(f"{PILOT_SALT}:{tenant}".encode()).hexdigest()[:8]
            self.assertEqual(dth.derive_tenant_hash(tenant, salt=PILOT_SALT), want, tenant)

    def test_custom_tenant_vector(self):
        self.assertEqual(dth.derive_tenant_hash("acme", salt=PILOT_SALT),
                         hashlib.sha256(b"signalloom-eap-salt-2026-q3:acme").hexdigest()[:8])

    def test_not_unsalted_digest(self):
        got = dth.derive_tenant_hash("kusari", salt=PILOT_SALT)
        self.assertEqual(hashlib.sha256(b"kusari").hexdigest()[:8], "d9d69501")
        self.assertNotEqual(got, "d9d69501")

    def test_not_hmac(self):
        # Governor G1: HMAC-SHA256(salt, kusari) is 4a89f30d, never canonical.
        mac = hmac.new(PILOT_SALT.encode(), b"kusari", hashlib.sha256).hexdigest()[:8]
        self.assertEqual(mac, "4a89f30d")
        self.assertNotEqual(dth.derive_tenant_hash("kusari", salt=PILOT_SALT), mac)

    def test_output_is_eight_lowercase_hex(self):
        for tenant in ("kusari", "acme", "zz-top"):
            got = dth.derive_tenant_hash(tenant, salt=PILOT_SALT)
            self.assertRegex(got, r"^[0-9a-f]{8}$")

    def test_normalises_case_and_whitespace(self):
        self.assertEqual(dth.derive_tenant_hash("  KuSaRi \n", salt=PILOT_SALT), "4b53ab6b")

    def test_salt_changes_hash(self):
        self.assertNotEqual(dth.derive_tenant_hash("kusari", salt="rotated-salt"), "4b53ab6b")

    def test_env_salt_used_when_no_explicit_salt(self):
        r = _run("--quiet", "kusari", env={"SIGNAL_LOOM_EAP_SALT": PILOT_SALT})
        self.assertEqual((r.returncode, r.stdout), (0, "4b53ab6b\n"), r.stderr)


class SharedVectors(unittest.TestCase):
    """The cross-language table Go and TypeScript also run."""

    ERRORS = {"retired": dth.RetiredTenantError, "salt": dth.SaltUnavailableError,
              "empty": dth.TenantHashError, "invalid": dth.TenantHashError}

    def test_shared_vectors(self):
        table = json.loads((ROOT / "test/fixtures/tenant/hash-vectors.json").read_text("utf-8"))
        for v in table["vectors"]:
            tenant = v["input"] * v.get("repeat", 1)
            salt = v.get("salt", table["salt"])
            with self.subTest(v["name"]):
                if "want" in v:
                    self.assertEqual(dth.derive_tenant_hash(tenant, salt=salt), v["want"])
                    continue
                with self.assertRaises(self.ERRORS[v["error"]]) as ctx:
                    dth.derive_tenant_hash(tenant, salt=salt)
                if v["error"] in ("empty", "invalid"):
                    self.assertNotIsInstance(ctx.exception, dth.RetiredTenantError)
                    self.assertEqual("cannot be empty" in str(ctx.exception),
                                     v["error"] == "empty")


class RejectedInputs(unittest.TestCase):
    def test_kurasi_rejected(self):
        for variant in ("kurasi", "KURASI", " kurasi "):
            with self.assertRaises(dth.RetiredTenantError, msg=variant):
                dth.derive_tenant_hash(variant, salt=PILOT_SALT)

    def test_empty_rejected(self):
        for bad in ("", "   ", "\t\n"):
            with self.assertRaises(dth.TenantHashError):
                dth.derive_tenant_hash(bad, salt=PILOT_SALT)

    def test_invalid_charset_rejected(self):
        for bad in ("-kusari", "kus ari", "kusari.io", "x" * 64, "kusari/../x"):
            with self.assertRaises(dth.TenantHashError, msg=bad):
                dth.derive_tenant_hash(bad, salt=PILOT_SALT)

    def test_empty_salt_rejected(self):
        with self.assertRaises(dth.SaltUnavailableError):
            dth.derive_tenant_hash("kusari", salt="")


class SaltResolution(unittest.TestCase):
    BAO = {"BAO_ADDR": "http://bao.test:8200", "BAO_TOKEN": "t"}

    def test_openbao_salt_preferred(self):
        seen = {}

        def fetch(url, token, timeout):
            seen.update(url=url, token=token, timeout=timeout)
            return _bao_payload(PILOT_SALT)

        env = dict(self.BAO, SIGNAL_LOOM_EAP_SALT="env-salt")
        self.assertEqual(dth.resolve_salt(env, fetch), PILOT_SALT)
        self.assertEqual(seen["url"], "http://bao.test:8200/v1/secret/data/signalloom/eap")
        self.assertEqual(seen["token"], "t")
        self.assertLessEqual(seen["timeout"], 2.0)

    def test_vault_addr_and_token_accepted(self):
        env = {"VAULT_ADDR": "http://v:8200/", "VAULT_TOKEN": "vt"}
        self.assertEqual(dth.resolve_salt(env, lambda u, t, s: _bao_payload("vs")), "vs")

    def test_openbao_consistent_with_env_fallback(self):
        via_bao = dth.resolve_salt(self.BAO, lambda u, t, s: _bao_payload(PILOT_SALT))
        via_env = dth.resolve_salt({"SIGNAL_LOOM_EAP_SALT": PILOT_SALT})
        self.assertEqual(dth.derive_tenant_hash("kusari", salt=via_bao),
                         dth.derive_tenant_hash("kusari", salt=via_env))

    def test_unreachable_openbao_falls_back_to_env(self):
        def fetch(url, token, timeout):
            raise urllib.error.URLError("connection refused")

        env = dict(self.BAO, SIGNAL_LOOM_EAP_SALT=PILOT_SALT)
        self.assertEqual(dth.resolve_salt(env, fetch), PILOT_SALT)

    def test_invalid_token_falls_back_to_env(self):
        def fetch(url, token, timeout):
            raise urllib.error.HTTPError(url, 403, "permission denied", {}, None)

        env = dict(self.BAO, SIGNAL_LOOM_EAP_SALT=PILOT_SALT)
        self.assertEqual(dth.resolve_salt(env, fetch), PILOT_SALT)

    def test_missing_token_skips_openbao(self):
        def fetch(url, token, timeout):
            raise AssertionError("must not call OpenBao without a token")

        env = {"BAO_ADDR": "http://bao.test:8200", "SIGNAL_LOOM_EAP_SALT": PILOT_SALT}
        self.assertEqual(dth.resolve_salt(env, fetch), PILOT_SALT)

    def test_unprovisioned_secret_falls_back_to_env(self):
        env = dict(self.BAO, SIGNAL_LOOM_EAP_SALT=PILOT_SALT)
        self.assertEqual(dth.resolve_salt(env, lambda u, t, s: {"data": {"data": {}}}),
                         PILOT_SALT)

    def test_no_salt_anywhere_fails_closed(self):
        with self.assertRaises(dth.SaltUnavailableError):
            dth.resolve_salt({}, lambda u, t, s: _bao_payload("never"))
        with self.assertRaises(dth.SaltUnavailableError):
            dth.resolve_salt(self.BAO, lambda u, t, s: {"errors": []})


class Cli(unittest.TestCase):
    def test_kusari_cli(self):
        r = _run("kusari", env={"SIGNAL_LOOM_EAP_SALT": PILOT_SALT})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "Tenant: kusari -> Hash: 4b53ab6b")

    def test_quiet_prints_bare_hash(self):
        r = _run("--quiet", "kusari", env={"SIGNAL_LOOM_EAP_SALT": PILOT_SALT})
        self.assertEqual((r.returncode, r.stdout), (0, "4b53ab6b\n"))

    def test_kurasi_cli_exit_1(self):
        r = _run("kurasi", env={"SIGNAL_LOOM_EAP_SALT": PILOT_SALT})
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stdout, "")
        self.assertIn("kurasi", r.stderr)
        self.assertIn("retired legacy typo", r.stderr)

    def test_missing_salt_cli_exit_1(self):
        r = _run("kusari")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stdout, "")
        self.assertIn("salt unavailable", r.stderr)

    def test_self_test_no_args(self):
        r = _run()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("ok: kusari -> 4b53ab6b", r.stdout)
        self.assertIn("ok: kurasi fails closed", r.stdout)

    def test_usage_error_exit_2(self):
        self.assertEqual(_run("a", "b", env={"SIGNAL_LOOM_EAP_SALT": PILOT_SALT}).returncode, 2)

    def test_unreachable_openbao_does_not_hang(self):
        # 192.0.2.0/24 is TEST-NET-1: never routed, so this exercises the timeout.
        env = {"BAO_ADDR": "http://192.0.2.1:8200", "BAO_TOKEN": "bogus",
               "SIGNAL_LOOM_EAP_SALT": PILOT_SALT}
        start = time.monotonic()
        r = _run("kusari", env=env)
        self.assertLess(time.monotonic() - start, 10)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Hash: 4b53ab6b", r.stdout)


if __name__ == "__main__":
    unittest.main()
