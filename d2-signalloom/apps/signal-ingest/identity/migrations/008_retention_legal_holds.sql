-- Migration: 008_retention_legal_holds.sql
-- Card: SLDP-P3-2 -- durable Article 17(3) legal holds.
-- Sequence 008, NOT 007.
--
-- SLDP-P3-1 ran concurrently with this card and also claimed 007 for its schema_version work; its
-- errata assigns 008 here by card order. Neither worktree could see the other's migration, so the
-- collision was only visible in the proposal's errata section -- which is exactly why the card lists
-- identity/migrations/ as a shared-file collision risk and why a sequence number must be claimed in
-- writing, not inferred from the tree. 005 is SLDP-P2-1, 006 is SLDP-P2-2, 007 is SLDP-P3-1.
--
-- Purpose: give legal holds somewhere durable to live.
--
-- Why this migration exists at all, since the gate itself is pure Go:
--   An in-memory hold register releases every hold on process restart. That is not a lesser form of
--   persistence, it is the fail-open defect with extra steps -- and a restart during an incident is
--   exactly when a hold is load-bearing and exactly when restarts happen. The Go control refuses to
--   act on undetermined incident state; this table is what stops "determined: no holds" from
--   quietly becoming true because a pod was rescheduled.
--
-- ONE table, and deliberately only one.
--
--   An earlier draft of this migration also created retention_exceptions and erasure_decisions,
--   carrying CHECK constraints described in the comments as "a database backstop against a row
--   arriving by a path that bypasses the Go validation". Adversarial review found that claim was
--   false: NOTHING in the Go tree writes either table. Every constraint on them was unreachable
--   through the application, and a reader would have cited them as defence in depth that did not
--   exist. Shipping unreachable constraints is worse than not having them, so both tables are gone
--   rather than decorated with a caveat.
--
--   The same review found that retention_exceptions' dual-operator CHECK could never have been
--   applied at all: PostgreSQL forbids subqueries in CHECK constraints, and
--   `count(DISTINCT ...) FROM unnest(...)` is one. Proven against PostgreSQL 16 --
--   `ERROR: cannot use subquery in check constraint` -- which, because ApplyMigrations runs 007 in
--   a single transaction, would have aborted the WHOLE migration and left retention_legal_holds
--   uncreated too. Every test passed regardless, because they were all strings.Contains over the
--   SQL text and nothing applied it to a real database. That is recorded in the card's proof
--   document as the sharpest lesson of this card.
--
--   Retention exceptions remain fully modelled and validated in Go (privacy.RetentionException);
--   they are carried in the erasure request and bound to a single request id, so they are not
--   long-lived state. Erasure decisions go to the tamper-evident signal_audit_trail. Neither needs
--   a table here, and persisting them belongs to SLDP-P6-1's retention controller.
--
-- Ordering note, inherited from 006: every data-modifying step precedes ENABLE/FORCE ROW LEVEL
-- SECURITY, because FORCE binds the table owner too.
--
-- Idempotency: every object is created IF NOT EXISTS, and every policy is dropped before being
-- created, so re-running ApplyMigrations leaves the schema identical. This migration creates only
-- new objects and modifies no existing table's data or definition.

-- ---------------------------------------------------------------------------
-- 1. Legal holds.
--
-- released_at IS NULL is the open-ended case and is the DEFAULT. A hold whose release was never
-- considered is indefinite, not instantly expired -- the Go Hold.Active() zero-value semantics and
-- this column default are the same decision expressed twice, and they must not drift.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS retention_legal_holds (
    id              TEXT        PRIMARY KEY,
    tenant_id       TEXT        NOT NULL DEFAULT app_current_tenant(),
    subject_id      TEXT        NOT NULL,
    kind            TEXT        NOT NULL,
    incident_ref    TEXT        NOT NULL DEFAULT '',
    opened_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    released_at     TIMESTAMPTZ NULL,
    placed_by       TEXT        NOT NULL DEFAULT '',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT retention_legal_holds_kind_enumerated
        CHECK (kind IN ('unresolved_incident', 'active_containment', 'operator_placed')),
    CONSTRAINT retention_legal_holds_release_after_open
        CHECK (released_at IS NULL OR released_at > opened_at)
);

CREATE INDEX IF NOT EXISTS idx_retention_legal_holds_subject
    ON retention_legal_holds (tenant_id, subject_id)
    WHERE released_at IS NULL;

-- ---------------------------------------------------------------------------
-- 3. Row-level security, matching the 006 pattern exactly.
--
-- FORCE removes the TABLE OWNER's exemption, so an owner connection with no app.current_tenant
-- claim reads zero rows rather than every tenant's. Policies are dropped before creation so this
-- block is re-runnable.
--
-- FORCE does NOT bind a SUPERUSER or a role with BYPASSRLS -- those bypass row-level security
-- entirely, and an earlier version of this comment claimed otherwise. The distinction decides which
-- way a misconfiguration fails: connecting as the owner makes holds invisible unless the claim is
-- set (fail-closed for erasure, because the reader refuses on zero rows only if it also sets the
-- claim -- see privacy/postgres.go), whereas connecting as a superuser voids 006's tenant isolation
-- across the whole identity graph. The application role must be neither owner nor superuser;
-- identity/tenant_live_test.go:TestTenantIsolationPosture_AppRoleIsNeitherOwnerNorBypass asserts
-- exactly that against a live database.
-- ---------------------------------------------------------------------------

ALTER TABLE retention_legal_holds ENABLE ROW LEVEL SECURITY;
ALTER TABLE retention_legal_holds FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS retention_legal_holds_tenant_isolation ON retention_legal_holds;
CREATE POLICY retention_legal_holds_tenant_isolation ON retention_legal_holds
    USING (tenant_id = app_current_tenant())
    WITH CHECK (tenant_id = app_current_tenant());


