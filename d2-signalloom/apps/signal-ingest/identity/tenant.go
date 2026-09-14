package identity

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"strings"
)

// SLDP-P2-2: transaction-local tenant claims over the identity graph.
//
// The database half of this control lives in migrations/006_tenant_isolation_rls.sql. This file is
// the application half, and the division of labour is deliberate: the Go layer refuses first so the
// caller gets an error that names the problem, and the database refuses regardless so that a caller
// who skips the Go layer entirely -- a raw psql session, an injected statement, a repository method
// written next year by someone who never read this file -- still reads nothing.
//
// A control that only the application enforces is a convention. The reason this package now has a
// live-Postgres test suite is that the difference between the two is not observable from the SQL
// text, only from a server.

const (
	// TenantSettingName is the PostgreSQL run-time parameter carrying the tenant claim. Fixed by
	// the P1-GOV tenant-binding contract as restated in SLDP-P2-PRE section 5. The row-level
	// security policies in migration 006 read this and nothing else.
	TenantSettingName = "app.current_tenant"

	// MaintenanceReasonSettingName carries the declared reason for a cross-tenant maintenance
	// session. The maintenance policies deny until it is set.
	MaintenanceReasonSettingName = "app.maintenance_reason"

	// QuarantineTenant is the reserved tenant assigned to rows that predate tenant attribution.
	// No principal binding may map to it; a claim naming it is rejected at construction.
	QuarantineTenant = "__unattributed__"

	// resetOnRelease is the statement issued before a leased connection returns to the pool.
	//
	// RESET ALL rather than DISCARD ALL: DISCARD ALL also drops prepared statements, and
	// database/sql caches prepared statements per connection, so discarding them out from under
	// the pool turns the next reuse into an error. RESET ALL clears run-time parameters, which is
	// the whole of what a leaked tenant claim is.
	//
	// Measured on PostgreSQL 16.14: RESET ALL restores a custom GUC to the EMPTY STRING, not to
	// NULL. app_current_tenant() maps empty to NULL for exactly this reason -- see 006.
	resetOnRelease = "RESET ALL"
)

var (
	// ErrNoTenantClaim is returned when a tenant-scoped operation is attempted on a context that
	// carries no claim. It is a refusal, never a fallback: there is no "default tenant".
	ErrNoTenantClaim = errors.New("identity: no tenant claim on context")

	// ErrInvalidTenantClaim is returned when a claim is missing its tenant or its principal, or
	// names a reserved tenant.
	ErrInvalidTenantClaim = errors.New("identity: invalid tenant claim")

	// ErrTenantIsolationPosture is returned when the live database does not actually enforce the
	// isolation this package assumes. It is deliberately distinct from a query error: a posture
	// failure means the control is absent, not that a statement went wrong.
	ErrTenantIsolationPosture = errors.New("identity: tenant isolation posture assertion failed")

	// ErrEmptyMaintenanceReason is returned when a cross-tenant maintenance session is opened
	// without declaring why.
	ErrEmptyMaintenanceReason = errors.New("identity: maintenance session requires a non-empty reason")
)

// TenantClaim is the authenticated tenancy of the caller.
//
// It carries the principal subject alongside the tenant identifier and not merely the tenant,
// because the two together are what makes the claim auditable: a tenant identifier on its own
// cannot be traced back to the authentication that produced it. The subject is the verified
// SPIFFE identity or JWT subject established upstream; nothing in this package derives a tenant
// from a request header, a query parameter, or any other caller-supplied field.
type TenantClaim struct {
	TenantID         string
	PrincipalSubject string
}

// NewTenantClaim validates and constructs a claim.
//
// Both fields are required. An empty tenant would be written into the GUC as the empty string,
// which app_current_tenant() maps to NULL -- so it would not silently match rows, but it would
// produce a confusing "no rows" instead of a clear refusal. Rejecting it here keeps the failure
// legible. A claim naming the quarantine tenant is refused because quarantined rows are, by
// construction, rows nobody is entitled to read through the ordinary path.
func NewTenantClaim(tenantID, principalSubject string) (TenantClaim, error) {
	if strings.TrimSpace(tenantID) == "" {
		return TenantClaim{}, fmt.Errorf("%w: tenant identifier is empty", ErrInvalidTenantClaim)
	}
	if strings.TrimSpace(principalSubject) == "" {
		return TenantClaim{}, fmt.Errorf("%w: principal subject is empty", ErrInvalidTenantClaim)
	}
	if tenantID == QuarantineTenant {
		return TenantClaim{}, fmt.Errorf("%w: %q is reserved for unattributed rows and no principal may claim it", ErrInvalidTenantClaim, QuarantineTenant)
	}
	return TenantClaim{TenantID: tenantID, PrincipalSubject: principalSubject}, nil
}

type tenantClaimKey struct{}

// WithTenantClaim returns a context carrying the claim.
func WithTenantClaim(ctx context.Context, claim TenantClaim) context.Context {
	return context.WithValue(ctx, tenantClaimKey{}, claim)
}

// TenantClaimFromContext retrieves the claim, reporting whether one was present.
func TenantClaimFromContext(ctx context.Context) (TenantClaim, bool) {
	claim, ok := ctx.Value(tenantClaimKey{}).(TenantClaim)
	if !ok || claim.TenantID == "" {
		return TenantClaim{}, false
	}
	return claim, true
}

// tenantQuerier is the subset of database/sql that the repository's query methods actually use.
//
// *sql.DB, *sql.Conn and *sql.Tx all satisfy it. Introducing it is what lets WithTenant hand the
// repository a single transaction instead of the pool, without rewriting seventeen query methods:
// a tenant claim set on the pool would land on an arbitrary connection and be invisible to the
// next statement.
//
// BeginTx is deliberately NOT part of this interface, because *sql.Tx does not have it. The one
// repository method that needs a transaction of its own goes through begin() below, which either
// opens a real one or recognises that it is already inside WithTenant's.
type tenantQuerier interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// txLike is the transaction surface RevokeActiveDelegations needs.
type txLike interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	Commit() error
	Rollback() error
}

// nestedTx makes an already-open transaction safe to "commit" and "roll back" from inner code.
//
// When a repository method that manages its own transaction is called from inside WithTenant, the
// outer transaction already owns the connection and the tenant claim. Opening a second one would
// take a different connection with no claim; committing the outer one early would discard the
// SET LOCAL under the remaining work. So the inner commit and rollback become no-ops and the outer
// WithTenant decides the outcome -- if the inner work returns an error, WithTenant rolls back.
type nestedTx struct{ *sql.Tx }

func (nestedTx) Commit() error   { return nil }
func (nestedTx) Rollback() error { return nil }

// begin opens a transaction, or joins the enclosing one.
func (r *PostgresRepository) begin(ctx context.Context) (txLike, error) {
	if tx, ok := r.db.(*sql.Tx); ok {
		return nestedTx{tx}, nil
	}
	beginner, ok := r.db.(interface {
		BeginTx(ctx context.Context, opts *sql.TxOptions) (*sql.Tx, error)
	})
	if !ok {
		return nil, fmt.Errorf("identity: querier %T cannot begin a transaction", r.db)
	}
	return beginner.BeginTx(ctx, nil)
}

// WithTenant runs fn inside a single transaction on a single leased connection, with the caller's
// tenant claim set transaction-locally, and resets the connection before returning it to the pool.
//
// Three properties, each answering a distinct failure:
//
//   - The claim is set with set_config(..., is_local => true). PostgreSQL discards a local setting
//     at COMMIT or ROLLBACK without being asked, so the claim cannot outlive the work even if this
//     function panics or the process is killed mid-call.
//   - The work runs on a connection leased with pool.Conn, not on the pool. Setting a claim on
//     *sql.DB sets it on whichever connection the pool happened to hand out, and the following
//     statement may run on a different one.
//   - RESET ALL is issued on release. The local setting above makes a stale claim structurally
//     impossible for code that goes through this function; the reset is what defends against code
//     that does not -- a session-level SET issued by some future caller, or by a statement that
//     reached the connection another way.
//
// The scoped repository passed to fn shares this repository's encryptor and pool but issues its
// statements on the leased connection. Using the outer repository inside fn is a mistake the type
// system cannot catch: it would run on a different connection with no claim, and return no rows.
func (r *PostgresRepository) WithTenant(ctx context.Context, fn func(ctx context.Context, scoped *PostgresRepository) error) error {
	claim, ok := TenantClaimFromContext(ctx)
	if !ok {
		return ErrNoTenantClaim
	}
	if r.pool == nil {
		return fmt.Errorf("identity: WithTenant requires a pooled repository")
	}

	conn, err := r.pool.Conn(ctx)
	if err != nil {
		return fmt.Errorf("identity: lease connection for tenant %q: %w", claim.TenantID, err)
	}
	defer func() {
		// context.WithoutCancel so the reset still runs when the caller's context has been
		// cancelled -- which is precisely the case where a claim would otherwise be left behind.
		if _, resetErr := conn.ExecContext(context.WithoutCancel(ctx), resetOnRelease); resetErr != nil {
			// A connection that could not be reset must not go back to the pool carrying state.
			// (*sql.Conn).Close RETURNS the connection to the pool; returning driver.ErrBadConn
			// from Raw is what marks it unusable so the pool discards it and opens a fresh one.
			_ = conn.Raw(func(any) error { return driver.ErrBadConn })
		}
		_ = conn.Close()
	}()

	tx, err := conn.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("identity: begin tenant transaction: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback()
		}
	}()

	if _, err := tx.ExecContext(ctx, "SELECT set_config($1, $2, true)", TenantSettingName, claim.TenantID); err != nil {
		return fmt.Errorf("identity: set tenant claim %q: %w", claim.TenantID, err)
	}

	scoped := &PostgresRepository{db: tx, pool: r.pool, encryptor: r.encryptor}
	if err := fn(ctx, scoped); err != nil {
		return err
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("identity: commit tenant transaction: %w", err)
	}
	committed = true
	return nil
}

// MaintenanceSession runs fn as an explicit, reason-bearing cross-tenant session.
//
// This exists because the alternative is worse. Some operations legitimately cross tenants --
// resolving the backfill quarantine, investigating a reported leak, answering a regulator -- and
// if there is no sanctioned way to do them, they get done as a superuser, which reintroduces the
// hole this card closes under a different name and leaves no trace.
//
// The crossing is explicit on two axes at once. The connection must authenticate as
// signal_identity_maintenance, which the migration's maintenance policies are scoped to; and the
// reason must be declared transaction-locally before anything is readable. A maintenance session
// that forgets the reason reads zero rows, exactly like an unclaimed application session -- the
// failure mode of the maintenance path is the same fail-closed silence as the ordinary path, not
// an open door.
//
// It takes its own pool rather than reusing the application pool, because the application pool
// authenticates as signal_identity_app and that role is not a member of the maintenance role.
func MaintenanceSession(ctx context.Context, pool *sql.DB, reason string, fn func(ctx context.Context, tx *sql.Tx) error) error {
	if strings.TrimSpace(reason) == "" {
		return ErrEmptyMaintenanceReason
	}
	if pool == nil {
		return fmt.Errorf("identity: maintenance session requires a pool")
	}

	conn, err := pool.Conn(ctx)
	if err != nil {
		return fmt.Errorf("identity: lease maintenance connection: %w", err)
	}
	defer func() {
		_, _ = conn.ExecContext(context.WithoutCancel(ctx), resetOnRelease)
		_ = conn.Close()
	}()

	tx, err := conn.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("identity: begin maintenance transaction: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback()
		}
	}()

	if _, err := tx.ExecContext(ctx, "SELECT set_config($1, $2, true)", MaintenanceReasonSettingName, reason); err != nil {
		return fmt.Errorf("identity: declare maintenance reason: %w", err)
	}

	if err := fn(ctx, tx); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("identity: commit maintenance transaction: %w", err)
	}
	committed = true
	return nil
}

// TenantIsolationPosture is the observed enforcement state of the live database.
//
// Every field is read from the server, not from the migration text. The distinction is the point
// of the type: the migration proves what was requested once, and this proves what is true now. A
// later ALTER ROLE ... BYPASSRLS, a table restored from a dump without its policies, or a
// connection authenticating as the owner would all leave the SQL file unchanged and the control
// gone.
type TenantIsolationPosture struct {
	CurrentUser      string
	IsSuperuser      bool
	HasBypassRLS     bool
	Tables           map[string]TableRLSPosture
	OwnedTables      []string
	TenantPolicies   int
	MaintenanceRoles []string
}

// TableRLSPosture records per-table enforcement.
type TableRLSPosture struct {
	RowSecurityEnabled bool
	RowSecurityForced  bool
	Owner              string
	PolicyCount        int
}

// rlsTables are the tables this card places under row-level security.
var rlsTables = []string{"actors", "aliases", "delegations"}

// AssertTenantIsolationPosture reads the live enforcement state and returns an error naming every
// way in which the connected role could see across tenants.
//
// It is written as an assertion rather than a getter because the three conditions it checks are
// each individually sufficient to make every policy in migration 006 decorative:
//
//   - a SUPERUSER ignores row-level security entirely;
//   - a role with BYPASSRLS ignores it entirely;
//   - the table OWNER ignores it unless FORCE ROW LEVEL SECURITY is set, which is why the forced
//     flag is checked per table rather than assumed from the migration having run.
//
// Callers should run this at start-up against the connection the application will actually use.
// Running it as the migration role proves nothing about the application role.
func AssertTenantIsolationPosture(ctx context.Context, db *sql.DB) (TenantIsolationPosture, error) {
	posture := TenantIsolationPosture{Tables: map[string]TableRLSPosture{}}
	if db == nil {
		return posture, fmt.Errorf("%w: nil database handle", ErrTenantIsolationPosture)
	}

	const roleQuery = `
		SELECT current_user, r.rolsuper, r.rolbypassrls
		FROM pg_roles r
		WHERE r.rolname = current_user`
	if err := db.QueryRowContext(ctx, roleQuery).Scan(&posture.CurrentUser, &posture.IsSuperuser, &posture.HasBypassRLS); err != nil {
		return posture, fmt.Errorf("%w: read role attributes: %v", ErrTenantIsolationPosture, err)
	}

	const tableQuery = `
		SELECT c.relname,
		       c.relrowsecurity,
		       c.relforcerowsecurity,
		       pg_get_userbyid(c.relowner) AS owner,
		       (SELECT count(*) FROM pg_policies p WHERE p.tablename = c.relname) AS policy_count
		FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE c.relname = ANY($1) AND n.nspname = current_schema()`
	rows, err := db.QueryContext(ctx, tableQuery, pqStringArray(rlsTables))
	if err != nil {
		return posture, fmt.Errorf("%w: read table posture: %v", ErrTenantIsolationPosture, err)
	}
	defer rows.Close()
	for rows.Next() {
		var (
			name string
			tp   TableRLSPosture
		)
		if err := rows.Scan(&name, &tp.RowSecurityEnabled, &tp.RowSecurityForced, &tp.Owner, &tp.PolicyCount); err != nil {
			return posture, fmt.Errorf("%w: scan table posture: %v", ErrTenantIsolationPosture, err)
		}
		posture.Tables[name] = tp
		posture.TenantPolicies += tp.PolicyCount
		if tp.Owner == posture.CurrentUser {
			posture.OwnedTables = append(posture.OwnedTables, name)
		}
	}
	if err := rows.Err(); err != nil {
		return posture, fmt.Errorf("%w: iterate table posture: %v", ErrTenantIsolationPosture, err)
	}

	var problems []string
	if posture.IsSuperuser {
		problems = append(problems, fmt.Sprintf("role %q is SUPERUSER and ignores row-level security", posture.CurrentUser))
	}
	if posture.HasBypassRLS {
		problems = append(problems, fmt.Sprintf("role %q has BYPASSRLS and ignores row-level security", posture.CurrentUser))
	}
	for _, name := range rlsTables {
		tp, ok := posture.Tables[name]
		if !ok {
			problems = append(problems, fmt.Sprintf("table %q not found in current schema", name))
			continue
		}
		if !tp.RowSecurityEnabled {
			problems = append(problems, fmt.Sprintf("table %q does not have row-level security enabled", name))
		}
		if !tp.RowSecurityForced {
			problems = append(problems, fmt.Sprintf("table %q does not FORCE row-level security, so its owner %q bypasses every policy", name, tp.Owner))
		}
		if tp.PolicyCount == 0 {
			problems = append(problems, fmt.Sprintf("table %q has row-level security enabled but no policy, which denies everything and is almost certainly not intended", name))
		}
		if tp.Owner == posture.CurrentUser && !tp.RowSecurityForced {
			problems = append(problems, fmt.Sprintf("role %q owns table %q", posture.CurrentUser, name))
		}
	}

	if len(problems) > 0 {
		return posture, fmt.Errorf("%w: %s", ErrTenantIsolationPosture, strings.Join(problems, "; "))
	}
	return posture, nil
}

// pqStringArray renders a Go slice as a PostgreSQL text array literal.
//
// lib/pq does not convert []string for an `= ANY($1)` parameter, and pulling in pq.Array would put
// a driver import into this file for one call site. The elements here are compile-time constants,
// but the quoting is done properly anyway rather than relying on that staying true.
func pqStringArray(values []string) string {
	quoted := make([]string, 0, len(values))
	for _, v := range values {
		quoted = append(quoted, `"`+strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(v)+`"`)
	}
	return "{" + strings.Join(quoted, ",") + "}"
}
