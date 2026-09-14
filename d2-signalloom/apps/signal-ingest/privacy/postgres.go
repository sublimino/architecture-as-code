package privacy

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// PostgresIncidentSource reads operator-placed and incident-derived holds from
// retention_legal_holds (migration 008).
//
// Why this type exists rather than an in-memory hold register: an in-memory register releases every
// hold on process restart, and a restart during an incident is both when a hold is most load-bearing
// and when restarts are most likely. That is the fail-open defect with extra steps. It also means
// migration 008 has a reader, so the schema is not declared-and-never-called — the exact shape of
// audit.EventPartitionDropped before this card gave it its first call site.
//
// Tenant scoping is enforced twice: the WHERE clause below, and the row-level security policy
// migration 008 installs. The belt-and-braces is deliberate, because SLDP-P2-2's whole finding was
// that WHERE-clause-only isolation has no database backstop.
type PostgresIncidentSource struct {
	db *sql.DB
}

// NewPostgresIncidentSource constructs a database-backed hold source.
func NewPostgresIncidentSource(db *sql.DB) (*PostgresIncidentSource, error) {
	if db == nil {
		return nil, errors.New("database handle is required")
	}
	return &PostgresIncidentSource{db: db}, nil
}

// activeHoldQuery selects holds that are open as of the supplied instant.
//
// The released_at predicate mirrors Hold.Active exactly: NULL is indefinite, a future release is
// still in effect, and only a release at or before now clears the hold. Expressing the same rule in
// two languages is a drift risk, so TestPostgresIncidentSource_QueryMirrorsHoldActive asserts the
// query text still carries both arms.
const activeHoldQuery = `
	SELECT id, subject_id, tenant_id, kind, incident_ref, opened_at, released_at
	  FROM retention_legal_holds
	 WHERE tenant_id = $1
	   AND subject_id = $2
	   AND (released_at IS NULL OR released_at > $3)
	 ORDER BY id`

// setTenantClaimSQL installs the transaction-local tenant claim that migration 006's row-level
// security policies read.
//
// The third argument to set_config is is_local=true, so the setting is scoped to the enclosing
// transaction and cannot leak onto the next borrower of a pooled connection.
const setTenantClaimSQL = `SELECT set_config('app.current_tenant', $1, true)`

// ActiveHolds implements IncidentSource.
//
// THE TRANSACTION IS NOT OPTIONAL, and omitting it was a real defect in the first version of this
// file — found by adversarial review against a live PostgreSQL 16, not by any test here.
//
// Migration 008 puts ENABLE plus FORCE ROW LEVEL SECURITY on retention_legal_holds with
// USING (tenant_id = app_current_tenant()), and app_current_tenant() is
// nullif(current_setting('app.current_tenant', true), ”) — NULL when the claim is unset. Since
// `tenant_id = NULL` is NULL and a policy predicate that is not TRUE denies, a query on a bare
// pooled connection SUCCEEDS and returns ZERO ROWS.
//
// That is the worst possible shape for this package: the query did not fail, so Jurisdiction is
// honestly true, and zero rows is the wire encoding of "determined: no holds". Every durable legal
// hold becomes invisible and every erasure is permitted — the exact fail-open the HoldQueryResult
// type was introduced to make unrepresentable, reintroduced one layer beneath it. The claim must be
// set, and it is transaction-local, so there must be a transaction.
//
// Note what is also NOT here: no path converts a query error into an empty result. Every failure
// wraps ErrIncidentStateUnavailable, because a database that cannot be read has not demonstrated
// the absence of a hold.
func (p *PostgresIncidentSource) ActiveHolds(ctx context.Context, tenantID, subjectID string) (HoldQueryResult, error) {
	if p.db == nil {
		return HoldQueryResult{}, fmt.Errorf("%w: database handle is nil", ErrIncidentStateUnavailable)
	}
	if tenantID == "" || subjectID == "" {
		return HoldQueryResult{}, fmt.Errorf("%w: tenant id and subject id are required", ErrIncidentStateUnavailable)
	}

	tx, err := p.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return HoldQueryResult{}, fmt.Errorf("%w: begin legal-hold transaction: %v", ErrIncidentStateUnavailable, err)
	}
	// Rollback on every path. A read-only transaction has nothing to commit, and an error from
	// Rollback after a successful read is not a reason to report the holds as unreadable.
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.ExecContext(ctx, setTenantClaimSQL, tenantID); err != nil {
		return HoldQueryResult{}, fmt.Errorf("%w: set tenant claim: %v", ErrIncidentStateUnavailable, err)
	}

	rows, err := tx.QueryContext(ctx, activeHoldQuery, tenantID, subjectID, time.Now().UTC())
	if err != nil {
		return HoldQueryResult{}, fmt.Errorf("%w: query legal holds: %v", ErrIncidentStateUnavailable, err)
	}
	defer rows.Close()

	var holds []Hold
	for rows.Next() {
		var (
			h        Hold
			released sql.NullTime
		)
		if err := rows.Scan(&h.ID, &h.SubjectID, &h.TenantID, &h.Kind, &h.IncidentRef, &h.OpenedAt, &released); err != nil {
			return HoldQueryResult{}, fmt.Errorf("%w: scan legal hold: %v", ErrIncidentStateUnavailable, err)
		}
		if released.Valid {
			h.ReleasedAt = released.Time
		}
		holds = append(holds, h)
	}
	// rows.Err() is checked because a mid-iteration failure otherwise ends the loop normally and
	// yields a short, plausible-looking hold list — a partial view presented as a complete one,
	// which is the same class of defect as a composite source ignoring a failing constituent.
	if err := rows.Err(); err != nil {
		return HoldQueryResult{}, fmt.Errorf("%w: iterate legal holds: %v", ErrIncidentStateUnavailable, err)
	}
	return HoldQueryResult{Holds: holds, Jurisdiction: true}, nil
}
