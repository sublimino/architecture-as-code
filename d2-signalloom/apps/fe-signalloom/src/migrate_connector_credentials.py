"""Move sealed connector credentials into OpenBao KV v2 (SA-TODO-003).

Run inside the fe-signalloom pod, which already has the database DSN, the old
sealing key (CONNECTOR_CREDENTIAL_KEY_FILE) and an OpenBao token from its bao
agent sidecar (BAO_ADDR, BAO_TOKEN_FILE):

    kubectl -n fe-signalloom exec deploy/fe-signalloom -c discovery-portal -- \\
        python -m migrate_connector_credentials            # dry run (default)
    ... python -m migrate_connector_credentials --apply    # move
    ... python -m migrate_connector_credentials --verify   # prove

For each row that still has ``credentials_ciphertext``, ``--apply``:

1. opens it with the old key (the tenant and connector are associated data,
   so a moved ciphertext does not open and the row is reported, not moved);
2. writes the value to ``kv/data/signalloom/tenants/<t>/connectors/<c>``;
3. reads the written version back and compares it with what it opened;
4. only then sets ``credentials_ref``/``credentials_version`` and nulls the
   ciphertext, with a compare-and-swap on the old ciphertext, so a row a user
   changed meanwhile is left for the next run.

A failure at any step leaves that row sealed and counts it. A second run
finds nothing sealed and changes nothing. ``--verify`` reads every reference
back and counts sealed rows left; it passes only when every reference reads
and none are left. Output is one JSON object of counts; it never carries a
credential value. Exit 0 on success, 1 when anything failed or is left,
2 on bad arguments.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from typing import Any

import connector_credentials
import connector_secret_store as css

_SQL_SEALED = (
    "/* cred_migrate:sealed */ SELECT tenant_id, connector_id, credentials_ciphertext "
    "FROM public.tenant_connectors WHERE credentials_ciphertext IS NOT NULL ORDER BY tenant_id, connector_id"
)
_SQL_REFERENCED = (
    "/* cred_migrate:referenced */ SELECT tenant_id, connector_id, credentials_ref, credentials_version "
    "FROM public.tenant_connectors WHERE credentials_ref IS NOT NULL ORDER BY tenant_id, connector_id"
)
_SQL_SWAP = (
    "/* cred_migrate:swap */ UPDATE public.tenant_connectors SET credentials_ref = $3, credentials_version = $4, "
    "credentials_ciphertext = NULL, updated_at = NOW() "
    "WHERE tenant_id = $1 AND connector_id = $2 AND credentials_ciphertext = $5"
)


async def run(pool: Any, store: Any, mode: str) -> dict[str, Any]:
    report: dict[str, Any] = {"mode": mode}
    sealed = await pool.fetch(_SQL_SEALED)
    referenced = await pool.fetch(_SQL_REFERENCED)
    report["sealed"] = len(sealed)

    if mode == "verify":
        readable = unreadable = 0
        for row in referenced:
            try:
                store.get(row["tenant_id"], row["connector_id"], row["credentials_ref"], row["credentials_version"])
                readable += 1
            except css.CredentialStoreUnavailable:
                unreadable += 1
        report.update(readable=readable, unreadable=unreadable,
                      ok=bool(unreadable == 0 and not sealed))
        return report

    report["already_migrated"] = len(referenced)
    migrated = failed = would = 0
    failures: list[dict[str, str]] = []
    for row in sealed:
        tenant, cid, ciphertext = row["tenant_id"], row["connector_id"], row["credentials_ciphertext"]
        try:
            creds = connector_credentials.open_credentials(tenant, cid, ciphertext)
        except (connector_credentials.CredentialStoreUnavailable, connector_credentials.CredentialDecryptError) as exc:
            failed += 1
            failures.append({"tenant_id": tenant, "connector_id": cid, "step": "open", "reason": type(exc).__name__})
            continue
        if mode != "apply":
            would += 1
            continue
        try:
            ref, version = store.put(tenant, cid, creds)
            back = store.get(tenant, cid, ref, version)
        except css.CredentialStoreUnavailable as exc:
            failed += 1
            failures.append({"tenant_id": tenant, "connector_id": cid, "step": "openbao", "reason": str(exc)})
            continue
        if back != creds:
            failed += 1
            failures.append({"tenant_id": tenant, "connector_id": cid, "step": "read-back", "reason": "mismatch"})
            continue
        status = await pool.execute(_SQL_SWAP, tenant, cid, ref, version, ciphertext)
        if str(status).endswith(" 1"):
            migrated += 1
        else:
            failed += 1
            failures.append({"tenant_id": tenant, "connector_id": cid, "step": "swap", "reason": "row changed"})
    report.update(would_migrate=would, migrated=migrated, failed=failed, failures=failures)
    return report


async def _connect() -> Any:
    import asyncpg

    dsn = os.environ.get("DATABASE_URL", "")
    if not dsn:
        raise SystemExit("DATABASE_URL is not set")
    return await asyncpg.create_pool(dsn, min_size=1, max_size=2)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m migrate_connector_credentials")
    parser.add_argument("--apply", action="store_true", help="move the credentials (default: dry run)")
    parser.add_argument("--verify", action="store_true", help="prove every reference reads and nothing is sealed")
    try:
        args = parser.parse_args(argv)
    except SystemExit:
        return 2
    if args.apply and args.verify:
        print(json.dumps({"error": "--apply and --verify are separate runs"}))
        return 2
    mode = "apply" if args.apply else "verify" if args.verify else "dry-run"

    async def _go() -> dict[str, Any]:
        pool = await _connect()
        try:
            return await run(pool, css.get_store(), mode)
        finally:
            close = getattr(pool, "close", None)
            if close is not None:
                await close()

    report = asyncio.run(_go())
    print(json.dumps(report, sort_keys=True))
    if mode == "verify":
        return 0 if report["ok"] else 1
    return 0 if report["failed"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
