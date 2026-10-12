"""Static contract for the evidence-backed ownership backfill migration."""
from __future__ import annotations

from pathlib import Path


MIGRATION = (
    Path(__file__).resolve().parents[1]
    / "db"
    / "migrations"
    / "064_backfill_claimed_agent_ownership.sql"
)


SQL = MIGRATION.read_text(encoding="utf-8")
EXECUTABLE_SQL = "\n".join(line.split("--", 1)[0] for line in SQL.splitlines())


def test_backfill_contract_is_exact_evidence_backed_and_tenant_scoped() -> None:
    required = (
        "ae.agent_id = ac.agent_id",
        "ae.tenant_id = ac.tenant_id",
        "ar.id = evidence.agent_id",
        "ar.tenant_id = evidence.tenant_id",
        "NULLIF(BTRIM(ac.tenant_id), '') IS NOT NULL",
        "NULLIF(BTRIM(ar.tenant_id), '') IS NOT NULL",
        "ae.event_type = 'agent.created'",
        "ae.detail->>'action' = 'claimed'",
        "ae.event_type = 'agent.claimed'",
        "ae.detail->>'assigned_owner'",
        "ae.detail->>'owner'",
        "pu.tenant_id = evidence.tenant_id",
        "SET owner = pu.email",
        "owner_id = pu.id",
        "ar.owner_id IS NULL",
        "FROM ownership_evidence evidence",
    )
    forbidden = (
        "demo-user@signalloom.local",
        "pu.tenant_id = 'tenant-demo'",
        "evidence.actor",
        "ae.actor",
        "LIKE",
    )

    assert all(clause in EXECUTABLE_SQL for clause in required)
    assert all(clause.upper() not in EXECUTABLE_SQL.upper() for clause in forbidden)
