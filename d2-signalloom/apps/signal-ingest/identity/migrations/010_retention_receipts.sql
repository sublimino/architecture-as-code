-- ---------------------------------------------------------------------------
-- SLDP-P6-1 — retention deletion-receipt ledger.
--
-- ADDITIVE ONLY. This migration creates one new table and touches nothing that exists: no prior
-- migration is edited, no column is dropped, no Parquet byte is rewritten. Sequence 010 was free
-- across every branch at the time of writing (009_subject_keys.sql was the highest).
--
-- WHY A LEDGER RATHER THAN A LOG LINE. Before this card there was no deletion code anywhere in
-- d2-signalloom: audit.EventPartitionDropped had one call site (privacy/erasure.go:495, an Article 17
-- decision), FrostDBStore.DropPartition moved an in-memory timestamp and unlinked nothing, and the
-- only reaper flipped delegations.status. So "retention configured" read as satisfied while expired
-- personal data survived. A ledger is what makes the opposite claim checkable: one row per COPY per
-- retention boundary, carrying the disposition, the propagation deadline and a digest over the whole
-- record. A sweep that skipped an unreachable sink cannot hide, because the absence of a complete row
-- for that sink is what the overdue-object metric counts.
--
-- WHY operation_id IS UNIQUE. It is SHA-256(tenant_id, sink_id, dropped_before) computed in Go by
-- retention.NewOperationID -- deliberately NOT including the nonce, so it is stable across retries.
-- The UNIQUE constraint is therefore not an optimisation, it is the idempotence guarantee enforced by
-- the database rather than by application bookkeeping: a sweep resumed after a partial run recomputes
-- the same identity and the ON CONFLICT upsert collapses it, so a copy is neither double-counted nor
-- skipped. A nonce-dependent identity would make every retry a fresh row and turn idempotence
-- silently into at-least-once.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS retention_deletion_receipts (
    operation_id         TEXT        PRIMARY KEY,
    schema_version       TEXT        NOT NULL,
    tenant_id            TEXT        NOT NULL DEFAULT app_current_tenant(),
    sink_id              TEXT        NOT NULL,
    sink_class           TEXT        NOT NULL,
    disposition          TEXT        NOT NULL,

    -- TIMESTAMPTZ throughout, and Go truncates to microseconds at the clock rather than at receipt
    -- construction. timestamptz holds microseconds while Go's time.Time holds nanoseconds, so a
    -- receipt digested in memory and re-digested after a round trip would differ in digits no call
    -- site can see -- and PostgreSQL rounds to nearest where Go truncates toward zero, so even the
    -- rounding directions disagree. subjectkey/receipt.go records the same defect and the same fix.
    dropped_before       TIMESTAMPTZ NOT NULL,
    propagation_deadline TIMESTAMPTZ NOT NULL,
    evaluated_at         TIMESTAMPTZ NOT NULL,
    completed_at         TIMESTAMPTZ NULL,

    records_removed      BIGINT      NOT NULL DEFAULT 0,
    partitions_dropped   INTEGER     NOT NULL DEFAULT 0,

    clock_source         TEXT        NOT NULL,
    hold_ids             TEXT[]      NOT NULL DEFAULT '{}',
    linkage_receipts     TEXT[]      NOT NULL DEFAULT '{}',

    receipt_nonce        TEXT        NOT NULL,
    receipt_digest       TEXT        NOT NULL,

    residual_state       TEXT        NOT NULL,
    compliance_note      TEXT        NOT NULL,

    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- The disposition enumeration is closed in the database as well as in Go. Both copies exist
    -- because an unknown disposition arriving from a future version must be refused at the boundary
    -- rather than stored and later read as something benign.
    CONSTRAINT retention_receipts_disposition_enumerated
        CHECK (disposition IN ('purged', 'already_absent', 'held', 'unreachable', 'retained_unresolvable_token')),

    -- A disposition that removed nothing must not claim to have. This is the database's copy of
    -- DeletionReceipt.Validate's anti-criterion, and it exists because the receipt is what reaches a
    -- regulator: an unreachable sink reporting rows removed would be a fabricated deletion claim.
    CONSTRAINT retention_receipts_no_removal_without_purge
        CHECK (
            disposition = 'purged'
            OR (records_removed = 0 AND partitions_dropped = 0)
        ),

    -- held must name what blocked it. A hold with no ID is an assertion an operator cannot act on.
    CONSTRAINT retention_receipts_held_names_holds
        CHECK (disposition <> 'held' OR array_length(hold_ids, 1) >= 1),

    -- The three complete dispositions must carry a completion instant; the two incomplete ones must
    -- not. This is what keeps "outstanding" computable in SQL: a copy is outstanding exactly when it
    -- has no row with a non-null completed_at, so the overdue metric cannot be fooled by a row that
    -- claims completion without one.
    CONSTRAINT retention_receipts_completion_matches_disposition
        CHECK (
            (disposition IN ('purged', 'already_absent', 'retained_unresolvable_token') AND completed_at IS NOT NULL)
            OR (disposition IN ('held', 'unreachable') AND completed_at IS NULL)
        ),

    -- A retained token is only defensible if the linkage purges that made it unresolvable are named.
    -- Without this, 'retained_unresolvable_token' would be a way to mark attested bytes done while
    -- their pseudonyms stayed fully resolvable -- indefinite retention with a compliant-sounding label.
    CONSTRAINT retention_receipts_retained_token_names_linkage
        CHECK (disposition <> 'retained_unresolvable_token' OR array_length(linkage_receipts, 1) >= 1),

    CONSTRAINT retention_receipts_deadline_after_boundary
        CHECK (propagation_deadline > dropped_before),

    CONSTRAINT retention_receipts_digest_is_sha256_hex
        CHECK (receipt_digest ~ '^[0-9a-f]{64}$'),

    CONSTRAINT retention_receipts_nonce_is_32_byte_hex
        CHECK (receipt_nonce ~ '^[0-9a-f]{64}$')
);

-- The outstanding query is "every expected sink with no complete receipt", so it filters on
-- (tenant_id, sink_id) and orders by evaluated_at to find the latest. Partial index on the incomplete
-- rows because those are the ones the overdue metric reads on every reconciliation.
CREATE INDEX IF NOT EXISTS idx_retention_receipts_sink_evaluated
    ON retention_deletion_receipts (tenant_id, sink_id, evaluated_at DESC);

CREATE INDEX IF NOT EXISTS idx_retention_receipts_outstanding
    ON retention_deletion_receipts (tenant_id, propagation_deadline)
    WHERE completed_at IS NULL;

-- ---------------------------------------------------------------------------
-- Row-level security, matching the 006/008 pattern exactly.
--
-- FORCE removes the TABLE OWNER's exemption, so an owner connection with no app.current_tenant claim
-- reads zero rows rather than every tenant's. Policies are dropped before creation so this block is
-- re-runnable. FORCE does NOT bind a SUPERUSER or a role with BYPASSRLS.
--
-- Note the direction this fails for THIS table specifically, which differs from 008. For holds,
-- reading zero rows is fail-closed only because the reader also sets the claim. Here, reading zero
-- receipt rows makes every copy look OUTSTANDING, not complete -- so a missing tenant claim inflates
-- the overdue gauge rather than clearing it. That is the correct direction for a retention metric: a
-- misconfiguration reads as "we cannot prove deletion", never as "everything is deleted".
-- ---------------------------------------------------------------------------

ALTER TABLE retention_deletion_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE retention_deletion_receipts FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS retention_deletion_receipts_tenant_isolation ON retention_deletion_receipts;
CREATE POLICY retention_deletion_receipts_tenant_isolation ON retention_deletion_receipts
    USING (tenant_id = app_current_tenant())
    WITH CHECK (tenant_id = app_current_tenant());
