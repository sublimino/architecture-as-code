"""SA-TODO-003: the one-shot move of sealed connector credentials into OpenBao.

``migrate_connector_credentials`` opens each sealed row with the old key,
writes the value to OpenBao KV v2, reads it back, and only then swaps the row
to the reference with the ciphertext nulled. Dry run is the default; a second
apply changes nothing; verify proves every reference reads and no sealed row
is left. Output carries counts, never a value.
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import secrets
from typing import Any

import pytest

import connector_credentials
import connector_secret_store as css
import migrate_connector_credentials as mcc
from tests.connector_secret_store_fake import FakeKvStore

SECRET = "sk-ant-MIGRATE-ME"
_TAG = re.compile(r"/\*\s*cred_migrate:([a-z_]+)\s*\*/")


class FakePool:
    """tenant_connectors rows, answering only the tagged migration statements."""

    def __init__(self) -> None:
        self.rows: dict[tuple[str, str], dict[str, Any]] = {}
        self.executed: list[tuple[str, tuple[Any, ...]]] = []

    def add(self, tenant: str, cid: str, ciphertext: str | None = None, ref: str | None = None,
            version: int | None = None) -> None:
        self.rows[(tenant, cid)] = {"tenant_id": tenant, "connector_id": cid, "credentials_ciphertext": ciphertext,
                                    "credentials_ref": ref, "credentials_version": version}

    async def fetch(self, sql: str, *args: Any) -> list[dict[str, Any]]:
        op = _TAG.search(sql).group(1)
        rows = sorted(self.rows.values(), key=lambda r: (r["tenant_id"], r["connector_id"]))
        if op == "sealed":
            return [dict(r) for r in rows if r["credentials_ciphertext"]]
        if op == "referenced":
            return [dict(r) for r in rows if r["credentials_ref"]]
        raise AssertionError(op)

    async def execute(self, sql: str, *args: Any) -> str:
        self.executed.append((sql, args))
        op = _TAG.search(sql).group(1)
        assert op == "swap", op
        assert "tenant_id = $1" in sql and "credentials_ciphertext = $5" in sql
        tenant, cid, ref, version, old = args
        row = self.rows.get((tenant, cid))
        if row is None or row["credentials_ciphertext"] != old:
            return "UPDATE 0"
        row.update(credentials_ref=ref, credentials_version=version, credentials_ciphertext=None)
        return "UPDATE 1"


@pytest.fixture
def key(monkeypatch, tmp_path):
    path = tmp_path / "k"
    path.write_text(secrets.token_hex(32))
    monkeypatch.setenv(connector_credentials.KEY_FILE_ENV, str(path))


def _sealed(tenant: str, cid: str, creds: dict[str, str]) -> str:
    return connector_credentials.seal_credentials(tenant, cid, creds)


def _run(pool, kv, mode):
    return asyncio.run(mcc.run(pool, kv, mode))


def test_dry_run_is_the_default_and_changes_nothing(key):
    pool, kv = FakePool(), FakeKvStore()
    pool.add("tenant-a", "conn-claude-01", _sealed("tenant-a", "conn-claude-01", {"api_key": SECRET}))
    report = _run(pool, kv, "dry-run")
    assert report["mode"] == "dry-run" and report["would_migrate"] == 1 and report["migrated"] == 0
    assert kv.secrets == {} and pool.executed == []
    assert pool.rows[("tenant-a", "conn-claude-01")]["credentials_ciphertext"]


def test_apply_moves_every_sealed_row_and_nulls_the_ciphertext(key):
    pool, kv = FakePool(), FakeKvStore()
    pool.add("tenant-a", "conn-claude-01", _sealed("tenant-a", "conn-claude-01", {"api_key": SECRET}))
    pool.add("tenant-b", "conn-github-01", _sealed("tenant-b", "conn-github-01", {"token": "ghp_b"}))
    pool.add("tenant-b", "conn-none-01")
    report = _run(pool, kv, "apply")
    assert (report["sealed"], report["migrated"], report["failed"]) == (2, 2, 0)
    a = pool.rows[("tenant-a", "conn-claude-01")]
    assert (a["credentials_ref"], a["credentials_version"], a["credentials_ciphertext"]) == (
        "signalloom/tenants/tenant-a/connectors/conn-claude-01", 1, None)
    assert kv.secrets["signalloom/tenants/tenant-a/connectors/conn-claude-01"] == [{"api_key": SECRET}]
    assert kv.secrets["signalloom/tenants/tenant-b/connectors/conn-github-01"] == [{"token": "ghp_b"}]


def test_a_second_apply_changes_nothing(key):
    pool, kv = FakePool(), FakeKvStore()
    pool.add("tenant-a", "conn-claude-01", _sealed("tenant-a", "conn-claude-01", {"api_key": SECRET}))
    _run(pool, kv, "apply")
    writes, executed = list(kv.calls), list(pool.executed)
    report = _run(pool, kv, "apply")
    assert (report["sealed"], report["migrated"], report["already_migrated"]) == (0, 0, 1)
    assert [c for c in kv.calls if c[0] == "put"] == [c for c in writes if c[0] == "put"]
    assert pool.executed == executed


def test_a_row_whose_read_back_differs_is_not_swapped(key):
    class Lossy(FakeKvStore):
        def get(self, *a, **k):
            return {"api_key": "something-else"}

    pool, kv = FakePool(), Lossy()
    pool.add("tenant-a", "conn-claude-01", _sealed("tenant-a", "conn-claude-01", {"api_key": SECRET}))
    report = _run(pool, kv, "apply")
    assert (report["migrated"], report["failed"]) == (0, 1)
    assert pool.rows[("tenant-a", "conn-claude-01")]["credentials_ciphertext"]
    assert pool.executed == []


def test_a_row_that_does_not_open_is_reported_and_left_alone(key):
    pool, kv = FakePool(), FakeKvStore()
    # Sealed for tenant-a, placed on tenant-b's row: the associated data refuses it.
    pool.add("tenant-b", "conn-claude-01", _sealed("tenant-a", "conn-claude-01", {"api_key": SECRET}))
    report = _run(pool, kv, "apply")
    assert (report["migrated"], report["failed"]) == (0, 1)
    assert kv.secrets == {}


def test_openbao_down_fails_the_row_and_keeps_the_ciphertext(key):
    pool, kv = FakePool(), FakeKvStore()
    kv.down = True
    pool.add("tenant-a", "conn-claude-01", _sealed("tenant-a", "conn-claude-01", {"api_key": SECRET}))
    report = _run(pool, kv, "apply")
    assert (report["migrated"], report["failed"]) == (0, 1)
    assert pool.rows[("tenant-a", "conn-claude-01")]["credentials_ciphertext"]


def test_verify_passes_only_when_every_reference_reads_and_no_sealed_row_is_left(key):
    pool, kv = FakePool(), FakeKvStore()
    pool.add("tenant-a", "conn-claude-01", _sealed("tenant-a", "conn-claude-01", {"api_key": SECRET}))
    assert _run(pool, kv, "verify")["ok"] is False
    _run(pool, kv, "apply")
    report = _run(pool, kv, "verify")
    assert (report["ok"], report["readable"], report["unreadable"], report["sealed"]) == (True, 1, 0, 0)
    kv.secrets.clear()
    assert _run(pool, kv, "verify")["ok"] is False


def test_the_report_never_carries_a_value(key):
    pool, kv = FakePool(), FakeKvStore()
    pool.add("tenant-a", "conn-claude-01", _sealed("tenant-a", "conn-claude-01", {"api_key": SECRET}))
    for mode in ("dry-run", "apply", "verify"):
        assert SECRET not in json.dumps(_run(pool, kv, mode))


def test_cli_exit_codes(key, monkeypatch, capsys):
    pool, kv = FakePool(), FakeKvStore()
    pool.add("tenant-a", "conn-claude-01", _sealed("tenant-a", "conn-claude-01", {"api_key": SECRET}))

    async def fake_pool():
        return pool

    monkeypatch.setattr(mcc, "_connect", fake_pool)
    css.set_store_for_testing(kv)
    try:
        assert mcc.main([]) == 0                 # dry run
        assert mcc.main(["--verify"]) == 1       # a sealed row is left
        assert mcc.main(["--apply"]) == 0
        assert mcc.main(["--verify"]) == 0
        assert mcc.main(["--apply", "--verify"]) == 2
    finally:
        css.set_store_for_testing(None)
    assert SECRET not in capsys.readouterr().out


@pytest.mark.skipif(not os.environ.get("DATABASE_URL"), reason="needs a disposable PostgreSQL (DATABASE_URL)")
def test_against_real_postgres_apply_is_idempotent_and_verify_passes(key):
    import asyncpg

    from db.migrate import apply_migrations

    async def go() -> list[Any]:
        pool = await asyncpg.create_pool(os.environ["DATABASE_URL"], min_size=1, max_size=2)
        try:
            await apply_migrations(pool)
            await pool.execute("DELETE FROM public.tenant_connectors WHERE tenant_id LIKE 'mig-%'")
            for tenant, cid in (("mig-a", "conn-claude-01"), ("mig-b", "conn-github-01")):
                await pool.execute(
                    "INSERT INTO public.tenant_connectors (tenant_id, connector_id, provider_id, status, "
                    "credentials_ciphertext) VALUES ($1, $2, $3, 'connected', $4)",
                    tenant, cid, cid.split("-")[1], _sealed(tenant, cid, {"api_key": SECRET + tenant}))
            kv = FakeKvStore()
            out: list[Any] = [await mcc.run(pool, kv, "apply"), await mcc.run(pool, kv, "apply"),
                              await mcc.run(pool, kv, "verify")]
            rows = await pool.fetch("SELECT credentials_ref, credentials_ciphertext FROM public.tenant_connectors "
                                    "WHERE tenant_id LIKE 'mig-%' ORDER BY tenant_id")
            out.append([dict(r) for r in rows])
            await pool.execute("DELETE FROM public.tenant_connectors WHERE tenant_id LIKE 'mig-%'")
            return out
        finally:
            await pool.close()

    first, second, verify, rows = asyncio.run(go())
    assert (first["migrated"], first["failed"]) == (2, 0)
    assert (second["sealed"], second["migrated"]) == (0, 0)
    assert verify["ok"] is True
    assert [r["credentials_ciphertext"] for r in rows] == [None, None]
    assert rows[0]["credentials_ref"] == "signalloom/tenants/mig-a/connectors/conn-claude-01"
