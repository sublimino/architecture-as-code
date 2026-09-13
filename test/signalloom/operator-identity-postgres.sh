#!/usr/bin/env bash
# PostgreSQL-backed AMXO-P1-1 migration and concurrent-removal proof.
set -eo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
migrations="$repo_root/d2-signalloom/apps/fe-signalloom/src/db/migrations"
api_src="$repo_root/d2-signalloom/apps/fe-signalloom/src"
container="amxo-p1-1-postgres-$$"
log="$(mktemp)"

cleanup() {
  docker stop "$container" >/dev/null 2>&1 || true
  rm -f "$log"
}
trap cleanup EXIT

docker run -d --rm --name "$container" \
  -e POSTGRES_PASSWORD=amxo \
  -p 127.0.0.1::5432 \
  postgres:16-alpine >"$log"

source "$repo_root/scripts/lib/wait.sh"
export container
WAIT_QUIET=1 _wait_retry 60 "AMXO PostgreSQL readiness" \
  docker exec "$container" pg_isready -U postgres >/dev/null

migration_count=0
for migration in "$migrations"/*.sql; do
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
    <"$migration" >>"$log" 2>&1
  migration_count=$((migration_count + 1))
done

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
  <"$migrations/038_operator_identities.sql" >>"$log" 2>&1

mapped_port="$(docker port "$container" 5432/tcp)"
port="${mapped_port##*:}"
export DATABASE_URL="postgresql://postgres:amxo@127.0.0.1:${port}/postgres"
export PYTHONPATH="$api_src"

UV_CACHE_DIR="${UV_CACHE_DIR:-/tmp/uv-cache}" uv run --python 3.12 \
  --with asyncpg --with-requirements "$api_src/requirements.txt" python3 - <<'PY'
import asyncio
import os
import uuid

import asyncpg

import api_compat
import operator_identity

TENANT = "tenant-agentmaxxing"
ISSUER = "https://issuer.test/dex"
A_USER = uuid.UUID("a1000000-0000-0000-0000-000000000001")
B_USER = uuid.UUID("a1000000-0000-0000-0000-000000000002")
A_IDENTITY = uuid.UUID("b1000000-0000-0000-0000-000000000001")
B_IDENTITY = uuid.UUID("b1000000-0000-0000-0000-000000000002")


async def main() -> None:
    pool = await asyncpg.create_pool(os.environ["DATABASE_URL"], min_size=2, max_size=4)
    api_compat.settings.api_jwt_issuer = ISSUER
    api_compat.settings.api_attributable_operator_tenants = {TENANT}

    async def require_pool(_what: str) -> asyncpg.Pool:
        return pool

    api_compat._require_pool = require_pool
    async with pool.acquire() as connection:
        await connection.executemany(
            """INSERT INTO platform_users
                      (id, tenant_id, email, display_name, role, status)
                 VALUES ($1, $2, $3, $4, 'admin', 'active')""",
            [
                (A_USER, TENANT, "a@example.test", "Operator A"),
                (B_USER, TENANT, "b@example.test", "Operator B"),
            ],
        )
        await connection.executemany(
            """INSERT INTO operator_identities
                      (id, platform_user_id, tenant_id, issuer, subject)
                 VALUES ($1, $2, $3, $4, $5)""",
            [
                (A_IDENTITY, A_USER, TENANT, ISSUER, "operator-a"),
                (B_IDENTITY, B_USER, TENANT, ISSUER, "operator-b"),
            ],
        )

    async def remove(identity_id: uuid.UUID, subject: str, email: str) -> str:
        try:
            result = await operator_identity.remove_operator_identity(
                identity_id,
                operator_identity.OperatorIdentityRemovalRequest(reason="concurrency proof"),
                api_compat.Principal(tenant=TENANT, subject=subject, email=email),
            )
            return f"removed:{result.changed}"
        except api_compat.APIError as error:
            return f"refused:{error.code}"

    outcomes = sorted(
        await asyncio.gather(
            remove(A_IDENTITY, "operator-a", "a@example.test"),
            remove(B_IDENTITY, "operator-b", "b@example.test"),
        )
    )
    active = await pool.fetchval(
        "SELECT count(*) FROM operator_identities WHERE tenant_id=$1 AND status='active'",
        TENANT,
    )
    removed = await pool.fetchval(
        "SELECT count(*) FROM operator_identities WHERE tenant_id=$1 AND status='removed'",
        TENANT,
    )
    audits = await pool.fetchval(
        "SELECT count(*) FROM audit_events WHERE tenant_id=$1 AND event_type='operator.removed'",
        TENANT,
    )
    event_check = await pool.fetchval(
        """SELECT pg_get_constraintdef(oid) LIKE '%operator.sign_in_denied%'
                     AND pg_get_constraintdef(oid) LIKE '%agent.claimed%'
              FROM pg_constraint
             WHERE conrelid='public.audit_events'::regclass
               AND conname='audit_events_event_type_check'"""
    )
    actor_fk = await pool.fetchval(
        """SELECT pg_get_constraintdef(oid)
              FROM pg_constraint
             WHERE conrelid='public.audit_events'::regclass
               AND conname='audit_events_actor_user_tenant_fkey'"""
    )

    print("CONCURRENT_OUTCOMES=" + ",".join(outcomes))
    print(f"ACTIVE_ADMINS={active}")
    print(f"REMOVED_ADMINS={removed}")
    print(f"REMOVAL_AUDITS={audits}")
    print(f"EVENT_CHECK={str(event_check).lower()}")
    print(f"ACTOR_TENANT_FK={actor_fk}")

    assert outcomes == ["refused:last_operator_admin", "removed:True"]
    assert (active, removed, audits) == (1, 1, 1)
    assert event_check is True
    assert actor_fk == (
        "FOREIGN KEY (actor_user_id, tenant_id) "
        "REFERENCES platform_users(id, tenant_id) ON DELETE RESTRICT"
    )
    await pool.close()


asyncio.run(main())
PY

printf 'MIGRATIONS_APPLIED=%s\n' "$migration_count"
printf 'MIGRATION_038_RERUN=PASS\n'
