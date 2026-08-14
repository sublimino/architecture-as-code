-- ══════════════════════════════════════════════════════════════════════════════
-- 030 — make public.audit_events append-only
-- ══════════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DEFENDS AGAINST
-- -------------------------
-- Not a malicious DBA. The realistic threat to an audit trail in this system is
-- the application rewriting its own history: a compromised API process, an
-- injection that reaches the writer, or a well-meaning future migration with a
-- stray UPDATE in it. All three arrive over the application's own database
-- connection, so a control that refuses UPDATE and DELETE on that connection
-- stops all three regardless of how the compromise happened.
--
-- audit_events is written by exactly one function, _audit_log() in
-- api_compat.py, which only ever INSERTs. Nothing in this repository has ever
-- had a legitimate reason to UPDATE or DELETE an audit row. The one legitimate
-- destructive caller is the demo reset (db/data-reset.sql); see ESCAPE HATCH.
--
--
-- WHY NOT A REVOKE
-- ----------------
-- The obvious control is:
--
--     REVOKE UPDATE, DELETE, TRUNCATE ON public.audit_events FROM <app role>;
--
-- Against this deployment that statement is decoration. Measured on the live
-- cluster (PostgreSQL 16.14, inf-signalloom/postgresql):
--
--     current_user  = signalloom      -- DATABASE_URL in base/secrets.yaml
--     tableowner    = signalloom      -- migrations run as the same role
--     rolsuper      = true            -- POSTGRES_USER in the bitnami entrypoint
--
-- The app connects as the table owner AND that role is a superuser. Two
-- separate reasons the grant system cannot help here, and the second is fatal:
--
--   1. Ownership. An owner may revoke privileges from itself — PostgreSQL does
--      allow that, contrary to folklore — but it may re-grant them at any time
--      with a single statement. A guard the guarded party can lift is a speed
--      bump, not a control.
--   2. Superuser. A superuser bypasses ALL privilege checks. The REVOKE is
--      recorded and then ignored. Observed directly, inside a transaction that
--      was rolled back afterwards:
--
--        REVOKE UPDATE, DELETE, TRUNCATE ON public.audit_events FROM signalloom;
--        -- relacl becomes  signalloom=arxt/signalloom
--        --   a=INSERT r=SELECT x=REFERENCES t=TRIGGER
--        --   no w (UPDATE), no d (DELETE), no D (TRUNCATE)
--        SELECT has_table_privilege('signalloom','public.audit_events','UPDATE');
--        -- t
--        UPDATE public.audit_events SET actor = 'TAMPERED';
--        -- UPDATE 12    <- every row rewritten, with the privilege revoked
--
-- So: a REVOKE-only migration would have passed review, applied cleanly, shown
-- a correct-looking ACL in \dp, and blocked nothing at all.
--
--
-- WHAT THIS DOES INSTEAD
-- ----------------------
-- A BEFORE UPDATE OR DELETE OR TRUNCATE trigger that unconditionally raises.
-- Triggers are not privilege checks, so superuser does not bypass them; the
-- same statements that succeeded above are refused with the trigger in place.
--
-- Three deliberate choices:
--
--   * FOR EACH STATEMENT, not FOR EACH ROW. It is the statement that is
--     illegitimate, not the row. Statement level costs nothing per row, and it
--     refuses `UPDATE ... WHERE false` too — a caller that believes it can
--     update audit rows should find out on the first attempt, not on the first
--     attempt that happens to match something. TRUNCATE triggers must be
--     statement level in any case, so this keeps it to one trigger.
--
--   * ENABLE ALWAYS, not the default ENABLE (ORIGIN). A session that sets
--     `session_replication_role = replica` skips ORIGIN triggers entirely;
--     measured on the live cluster, a DELETE under replica mode removed all 12
--     rows through an ORIGIN trigger and was refused by an ALWAYS one. Setting
--     that GUC needs superuser — which is exactly what the app role has, so the
--     distinction is not academic here.
--
--   * SQLSTATE 42501 (insufficient_privilege). asyncpg surfaces it as
--     InsufficientPrivilegeError and psql prints "permission denied"-class
--     wording, which is what a caller needs to read. The alternative codes
--     (0A000 feature_not_supported, 2F003 prohibited_sql_statement_attempted)
--     are more literally accurate about the mechanism and less comprehensible
--     about the meaning.
--
-- The REVOKE ... FROM PUBLIC below is not the control. It is one line of
-- housekeeping for the day someone adds a genuine read-only reporting role:
-- that role should not inherit write access from PUBLIC's defaults. It has no
-- effect on the app role today.
--
--
-- THIS DOES NOT BLOCK DDL — DELIBERATELY
-- --------------------------------------
-- Row and statement triggers fire on DML only. ALTER TABLE does not fire them,
-- and neither does the table rewrite that some ALTER TABLE forms perform. The
-- established way to widen audit_events.event_type in this repo is the guarded
-- drop-and-recreate of the CHECK constraint used by 006, 007, 009, 010 and 011,
-- and more of those are in flight right now. Verified against the live cluster
-- with this trigger installed:
--
--     ALTER TABLE public.audit_events DROP CONSTRAINT audit_events_event_type_check;
--     ALTER TABLE public.audit_events ADD  CONSTRAINT audit_events_event_type_check
--       CHECK (event_type IN (...));
--     -- ALTER TABLE / ALTER TABLE, no trigger involvement
--
-- Migrations that evolve this table therefore need to know nothing about this
-- one. The exception is a migration that needs to REWRITE existing audit rows
-- (a backfill, a column renormalisation): that is DML, it will be refused, and
-- refusing it is the point. Such a migration must lift the guard explicitly and
-- put it back, the same way db/data-reset.sql does.
--
--
-- ESCAPE HATCH, AND WHY THERE HAS TO BE ONE
-- -----------------------------------------
-- db/data-reset.sql TRUNCATEs every governance table to return the demo to a
-- live-empty state, and tests/test_contract_tier2.py runs it after every
-- mutating test. It reaches audit_events twice: directly in the 'audit' focus,
-- and — less obviously — via `TRUNCATE public.agent_registry CASCADE` in the
-- 'agents' focus, because audit_events.agent_id carries an FK to it. Both fire
-- this trigger. data-reset.sql is amended in the same commit to disable the
-- trigger for the duration of its transaction and re-enable it before COMMIT.
--
-- That hatch is available to anything holding the owner role, which is the app
-- role. It is not a privilege boundary and is not claimed as one. Its value is
-- that rewriting audit history now takes a deliberate, greppable, reviewable
-- DDL statement instead of happening by accident in a WHERE clause.
--
--
-- WHAT THIS DOES NOT PROTECT AGAINST
-- ----------------------------------
-- Read this as "the application can no longer rewrite the audit log", NOT as
-- "the audit log is now immutable". Overclaiming a control is worse than not
-- having one, because it stops people asking the next question.
--
--   * Superuser or table owner deliberately lifting the guard:
--     ALTER TABLE ... DISABLE TRIGGER, DROP TRIGGER, or replacing the trigger
--     function body. The app role can do all three. Two statements instead of
--     one is the whole of the delta.
--   * Anything below SQL: filesystem access to the data directory, a modified
--     Postgres binary, a snapshot of the PV.
--   * pg_dump / restore into a fresh database. The dump is data; the restored
--     copy is whatever the restorer chose to put in it.
--   * A compromise upstream of the INSERT. Nothing here judges whether an audit
--     row is truthful, only that it cannot later be changed. A caller that logs
--     a lie logs a permanent lie.
--   * Backdating. audit_events.timestamp defaults to NOW() and _audit_log()
--     never supplies it, so today's writer cannot backdate. A future writer, or
--     an injection that names the column, can. Forcing NEW.timestamp = now() in
--     a BEFORE INSERT trigger was considered and rejected: db/data-mock.sql
--     seeds deliberately backdated rows for the demo timeline and a forcing
--     trigger would flatten them. A separate server-set recorded_at column
--     would make the divergence detectable, but NOW() is not a constant default
--     so adding it rewrites the whole table under ACCESS EXCLUSIVE — too
--     expensive to bundle here. Ordering integrity belongs with the audit
--     hash-chain work, which is where a backdated insert becomes detectable
--     rather than merely discouraged.
--   * Deletion of the whole table or database. DROP TABLE is DDL.
--
-- Retention: nothing in this repository prunes audit_events today, so no
-- retention job is broken by this migration. Anything added later that expects
-- to age rows out MUST go through the same explicit disable/re-enable dance —
-- it will fail loudly rather than silently, which is the correct failure mode.
--
--
-- Idempotent by construction: CREATE OR REPLACE FUNCTION, DROP TRIGGER IF
-- EXISTS before CREATE TRIGGER, and a REVOKE that is a no-op when repeated. The
-- whole file is one transaction, so a fresh bootstrap and a re-run of the
-- runner against an already-guarded database both converge on the same state.

BEGIN;

CREATE OR REPLACE FUNCTION public.audit_events_reject_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $body$
BEGIN
  RAISE EXCEPTION
    'audit_events is append-only: % is refused', TG_OP
    USING
      ERRCODE = '42501',
      DETAIL  = 'public.audit_events accepts INSERT only. Audit history is not '
                'rewritable over the application database connection.',
      HINT    = 'Record a compensating audit event instead. If this really is '
                'a sanctioned reset or backfill, lift the guard explicitly for '
                'the duration of the transaction: ALTER TABLE '
                'public.audit_events DISABLE TRIGGER audit_events_append_only; '
                '... ; ALTER TABLE public.audit_events ENABLE ALWAYS TRIGGER '
                'audit_events_append_only;';
END
$body$;

COMMENT ON FUNCTION public.audit_events_reject_mutation() IS
  'Refuses every UPDATE, DELETE and TRUNCATE against public.audit_events. '
  'Installed by migration 030. Stops the application rewriting its own audit '
  'history; does not constrain a superuser who deliberately disables it.';

-- DROP + CREATE rather than CREATE OR REPLACE TRIGGER: the latter is PG14+ and
-- this file also has to apply through the generated initdb bootstrap, whose
-- server version is not pinned here. DDL is transactional, so there is no
-- window in which the table is unguarded.
DROP TRIGGER IF EXISTS audit_events_append_only ON public.audit_events;

CREATE TRIGGER audit_events_append_only
  BEFORE UPDATE OR DELETE OR TRUNCATE ON public.audit_events
  FOR EACH STATEMENT
  EXECUTE FUNCTION public.audit_events_reject_mutation();

-- ORIGIN triggers are skipped when session_replication_role = 'replica'.
-- ALWAYS triggers are not. The app role is a superuser and can set that GUC.
ALTER TABLE public.audit_events
  ENABLE ALWAYS TRIGGER audit_events_append_only;

COMMENT ON TRIGGER audit_events_append_only ON public.audit_events IS
  'Append-only guard (migration 030). INSERT and DDL are unaffected; '
  'UPDATE, DELETE and TRUNCATE raise 42501. db/data-reset.sql is the only '
  'sanctioned caller that disables it, and re-enables it in the same '
  'transaction.';

-- Housekeeping only, for a future non-superuser role. The app role owns the
-- table and is a superuser, so this changes nothing about its access today.
REVOKE UPDATE, DELETE, TRUNCATE ON public.audit_events FROM PUBLIC;

COMMIT;
