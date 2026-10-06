// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package subjectkey

import (
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
	"time"

	"github.com/lib/pq"
)

// setTenantClaimSQL installs the transaction-local tenant claim migration 006's row-level security
// policies read. is_local=true scopes it to the enclosing transaction so it cannot leak onto the
// next borrower of a pooled connection.
//
// THE TRANSACTION IS NOT OPTIONAL, for the reason privacy/postgres.go documents at length: migration
// 009 puts ENABLE plus FORCE ROW LEVEL SECURITY on both tables, and app_current_tenant() is NULL
// when the claim is unset. `tenant_id = NULL` is NULL, a policy predicate that is not TRUE denies,
// so a query on a bare pooled connection SUCCEEDS and returns ZERO ROWS.
//
// For a legal-hold reader that shape is catastrophic (every hold becomes invisible, every erasure
// permitted). For a KEY STORE it is differently bad but still bad: zero rows reads as "this subject
// has no keys", so an erasure would report success having destroyed nothing. Both tables are always
// read and written inside a transaction that has set the claim.
const setTenantClaimSQL = `SELECT set_config('app.current_tenant', $1, true)`

// PostgresStore is the durable KeyStore backed by migration 009.
type PostgresStore struct {
	db *sql.DB
}

var _ KeyStore = (*PostgresStore)(nil)

// NewPostgresStore constructs a database-backed key store.
func NewPostgresStore(db *sql.DB) (*PostgresStore, error) {
	if db == nil {
		return nil, errors.New("subjectkey: database handle is required")
	}
	return &PostgresStore{db: db}, nil
}

// withTenantTx runs fn inside a transaction that has the tenant claim set.
func (p *PostgresStore) withTenantTx(ctx context.Context, tenantID string, readOnly bool, fn func(tx *sql.Tx) error) error {
	if tenantID == "" {
		return ErrTenantRequired
	}
	tx, err := p.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: readOnly})
	if err != nil {
		return fmt.Errorf("subjectkey: begin transaction: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback()
		}
	}()
	if _, err := tx.ExecContext(ctx, setTenantClaimSQL, tenantID); err != nil {
		return fmt.Errorf("subjectkey: set tenant claim: %w", err)
	}
	if err := fn(tx); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("subjectkey: commit: %w", err)
	}
	committed = true
	return nil
}

const selectVersionsSQL = `
	SELECT tenant_id, subject_pseudonym, key_epoch, key_version, wrapped_dek,
	       prior_wrapped_digest, created_at, destroyed_at
	  FROM subject_keys
	 WHERE tenant_id = $1 AND subject_pseudonym = $2
	 ORDER BY key_version`

// Provision appends a new key version.
//
// The version number is allocated with SELECT ... FOR UPDATE over the subject's existing rows rather
// than max()+1 on a bare read. Two concurrent provisions on a bare read both compute the same next
// version and the second violates the primary key — which is at least loud, but the lock turns a
// retryable error into no error at all. The lock is taken on the subject's rows, so it does not
// serialise provisioning across subjects.
func (p *PostgresStore) Provision(ctx context.Context, tenantID, pseudonym string, epoch uint32, wrap func(KeyScope) ([]byte, error), now time.Time) (KeyRecord, error) {
	if pseudonym == "" {
		return KeyRecord{}, ErrSubjectRequired
	}
	var out KeyRecord
	err := p.withTenantTx(ctx, tenantID, false, func(tx *sql.Tx) error {
		rows, err := tx.QueryContext(ctx, selectVersionsSQL+" FOR UPDATE", tenantID, pseudonym)
		if err != nil {
			return fmt.Errorf("subjectkey: lock subject key versions: %w", err)
		}
		existing, err := scanRecords(rows)
		if err != nil {
			return err
		}

		next := 1
		var liveSameEpoch []KeyRecord
		for _, r := range existing {
			if r.KeyVersion >= next {
				next = r.KeyVersion + 1
			}
			if !r.Destroyed() && r.KeyEpoch == epoch {
				liveSameEpoch = append(liveSameEpoch, r)
			}
		}

		scope := KeyScope{TenantID: tenantID, SubjectPseudonym: pseudonym, KeyEpoch: epoch, KeyVersion: next}
		wrapped, err := wrap(scope)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO subject_keys (tenant_id, subject_pseudonym, key_epoch, key_version, wrapped_dek, created_at)
			VALUES ($1, $2, $3, $4, $5, $6)`,
			tenantID, pseudonym, int64(epoch), next, wrapped, now.UTC()); err != nil {
			return fmt.Errorf("subjectkey: insert key version: %w", err)
		}

		// Bound the version history in the same transaction that grew it, so the invariant cannot be
		// observed violated between the insert and the trim.
		if len(liveSameEpoch)+1 > MaxKeyVersionsPerSubject {
			sort.Slice(liveSameEpoch, func(i, j int) bool { return liveSameEpoch[i].KeyVersion < liveSameEpoch[j].KeyVersion })
			surplus := len(liveSameEpoch) + 1 - MaxKeyVersionsPerSubject
			for i := 0; i < surplus && i < len(liveSameEpoch); i++ {
				if _, err := destroyInTx(ctx, tx, liveSameEpoch[i].Scope(), now); err != nil {
					return err
				}
			}
		}

		out = KeyRecord{
			TenantID:         tenantID,
			SubjectPseudonym: pseudonym,
			KeyEpoch:         epoch,
			KeyVersion:       next,
			WrappedDEK:       wrapped,
			CreatedAt:        now.UTC(),
		}
		return nil
	})
	return out, err
}

// ListVersions returns every version for a subject.
func (p *PostgresStore) ListVersions(ctx context.Context, tenantID, pseudonym string) ([]KeyRecord, error) {
	if pseudonym == "" {
		return nil, ErrSubjectRequired
	}
	var out []KeyRecord
	err := p.withTenantTx(ctx, tenantID, true, func(tx *sql.Tx) error {
		rows, err := tx.QueryContext(ctx, selectVersionsSQL, tenantID, pseudonym)
		if err != nil {
			return fmt.Errorf("subjectkey: query key versions: %w", err)
		}
		out, err = scanRecords(rows)
		return err
	})
	return out, err
}

// GetVersion returns one version.
func (p *PostgresStore) GetVersion(ctx context.Context, scope KeyScope) (KeyRecord, error) {
	if err := scope.Validate(); err != nil {
		return KeyRecord{}, err
	}
	recs, err := p.ListVersions(ctx, scope.TenantID, scope.SubjectPseudonym)
	if err != nil {
		return KeyRecord{}, err
	}
	return findVersion(recs, scope.KeyVersion)
}

// destroyInTx performs the idempotent overwrite inside an open transaction.
//
// The UPDATE carries `AND destroyed_at IS NULL`, so a repeat matches zero rows and the original
// timestamp and digest survive. The read-back afterwards is what distinguishes "already destroyed"
// from "no such row" — without it, zero rows affected means both, and reporting a typo'd subject as
// already-erased is exactly the wrong answer.
func destroyInTx(ctx context.Context, tx *sql.Tx, scope KeyScope, now time.Time) (DestroyResult, error) {
	overwrite := make([]byte, wrappedDEKLen)
	if _, err := io.ReadFull(rand.Reader, overwrite); err != nil {
		// Zeroes still destroy the key, so this is a safe degradation — but it is explicit rather
		// than an ignored error, because a silent CSPRNG failure in a destruction path is exactly
		// the kind of thing that should be visible in a code read.
		Zero(overwrite)
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE subject_keys
		   SET prior_wrapped_digest = encode(sha256(wrapped_dek), 'hex'),
		       wrapped_dek          = $5,
		       destroyed_at         = $6
		 WHERE tenant_id = $1 AND subject_pseudonym = $2 AND key_epoch = $3 AND key_version = $4
		   AND destroyed_at IS NULL`,
		scope.TenantID, scope.SubjectPseudonym, int64(scope.KeyEpoch), scope.KeyVersion,
		overwrite, now.UTC()); err != nil {
		return DestroyResult{}, fmt.Errorf("subjectkey: destroy key version %d: %w", scope.KeyVersion, err)
	}

	var (
		digest  string
		destroy sql.NullTime
	)
	if err := tx.QueryRowContext(ctx, `
		SELECT prior_wrapped_digest, destroyed_at
		  FROM subject_keys
		 WHERE tenant_id = $1 AND subject_pseudonym = $2 AND key_epoch = $3 AND key_version = $4`,
		scope.TenantID, scope.SubjectPseudonym, int64(scope.KeyEpoch), scope.KeyVersion,
	).Scan(&digest, &destroy); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return DestroyResult{}, fmt.Errorf("%w: %s v%d", ErrKeyNotFound, scope.SubjectPseudonym, scope.KeyVersion)
		}
		return DestroyResult{}, fmt.Errorf("subjectkey: read back destruction: %w", err)
	}
	if !destroy.Valid {
		return DestroyResult{}, fmt.Errorf("subjectkey: version %d has no destroyed_at after the destroy UPDATE", scope.KeyVersion)
	}
	return DestroyResult{
		Scope:              scope,
		PriorWrappedDigest: digest,
		DestroyedAt:        destroy.Time.UTC(),
		// The caller cannot tell first-destroy from repeat by rows-affected alone once the read-back
		// exists; whether it is a repeat is decided by comparing the stored timestamp with now, which
		// is not reliable. It is reported as AlreadyDestroyed=false and the saga does not depend on
		// the distinction: it certifies by read-back, and the receipt uses the stored timestamp.
		AlreadyDestroyed: false,
	}, nil
}

// DestroyVersion is idempotent.
func (p *PostgresStore) DestroyVersion(ctx context.Context, scope KeyScope, now time.Time) (DestroyResult, error) {
	if err := scope.Validate(); err != nil {
		return DestroyResult{}, err
	}
	var out DestroyResult
	err := p.withTenantTx(ctx, scope.TenantID, false, func(tx *sql.Tx) error {
		var err error
		out, err = destroyInTx(ctx, tx, scope, now)
		return err
	})
	return out, err
}

// BeginSaga inserts the journal row if absent.
//
// ON CONFLICT DO NOTHING followed by a read is the whole idempotency primitive at this layer: two
// concurrent first-calls both attempt the insert, one wins, and BOTH then read the SAME row —
// including the SAME nonce, which is what makes their eventual receipt digests agree.
func (p *PostgresStore) BeginSaga(ctx context.Context, rec SagaRecord) (SagaRecord, bool, error) {
	if rec.OperationID == "" {
		return SagaRecord{}, false, errors.New("subjectkey: operation id is required")
	}
	var (
		out     SagaRecord
		created bool
	)
	err := p.withTenantTx(ctx, rec.TenantID, false, func(tx *sql.Tx) error {
		res, err := tx.ExecContext(ctx, `
			INSERT INTO subject_key_erasures
			       (operation_id, tenant_id, subject_pseudonym, state, target_versions, nonce,
			        caches_purged, started_at, updated_at)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $8)
			ON CONFLICT (operation_id) DO NOTHING`,
			rec.OperationID, rec.TenantID, rec.SubjectPseudonym, string(StatePending),
			pq.Array(nonNilInts(rec.TargetVersions)), rec.Nonce, pq.Array(nonNilStrings(rec.CachesPurged)), rec.StartedAt.UTC())
		if err != nil {
			return fmt.Errorf("subjectkey: insert saga journal row: %w", err)
		}
		n, err := res.RowsAffected()
		if err != nil {
			return fmt.Errorf("subjectkey: rows affected: %w", err)
		}
		created = n == 1
		out, err = loadSagaInTx(ctx, tx, rec.OperationID)
		return err
	})
	return out, created, err
}

// LoadSaga returns the journal row, scoped to tenantID.
//
// THE TENANT PARAMETER IS THE WHOLE POINT, and its absence was a CRITICAL defect. Migration 009 puts
// ENABLE plus FORCE ROW LEVEL SECURITY on subject_key_erasures, and app_current_tenant() is NULL
// when the transaction-local claim is unset -- so a claim-less SELECT SUCCEEDS and returns ZERO ROWS.
// The previous signature took only an operation id and tried to discover the tenant from the row it
// could not see, which is circular: it worked only against a role holding BYPASSRLS.
//
// That is exactly what happened. Every live test ran as the container's POSTGRES_USER, a SUPERUSER
// with rolbypassrls, so the whole suite passed while a correctly-configured deployment -- the
// non-owner, non-superuser app role migration 008's comment explicitly requires -- would write the
// journal row and then FAIL EVERY ADVANCE, leaving the saga at `pending` forever with no key
// destroyed and every Article 17 request erroring. Proven against a NOSUPERUSER NOBYPASSRLS role.
func (p *PostgresStore) LoadSaga(ctx context.Context, tenantID, operationID string) (SagaRecord, error) {
	var out SagaRecord
	err := p.withTenantTx(ctx, tenantID, true, func(tx *sql.Tx) error {
		var ierr error
		out, ierr = loadSagaInTx(ctx, tx, operationID)
		return ierr
	})
	return out, err
}

func loadSagaInTx(ctx context.Context, tx *sql.Tx, operationID string) (SagaRecord, error) {
	var out SagaRecord
	row := tx.QueryRowContext(ctx, `
		SELECT operation_id, tenant_id, subject_pseudonym, state, target_versions, nonce,
		       caches_purged, receipt_digest, started_at, updated_at, completed_at
		  FROM subject_key_erasures WHERE operation_id = $1`, operationID)
	if err := scanSaga(row, &out); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return SagaRecord{}, fmt.Errorf("%w: %s", ErrSagaNotFound, operationID)
		}
		return SagaRecord{}, err
	}
	return out, nil
}

type rowScanner interface{ Scan(dest ...any) error }

func scanSaga(row rowScanner, out *SagaRecord) error {
	var (
		state     string
		versions  pq.Int64Array
		caches    pq.StringArray
		completed sql.NullTime
	)
	if err := row.Scan(&out.OperationID, &out.TenantID, &out.SubjectPseudonym, &state,
		&versions, &out.Nonce, &caches, &out.ReceiptDigest, &out.StartedAt, &out.UpdatedAt, &completed); err != nil {
		return err
	}
	out.CachesPurged = append([]string(nil), caches...)
	out.State = SagaState(state)
	out.TargetVersions = make([]int, 0, len(versions))
	for _, v := range versions {
		out.TargetVersions = append(out.TargetVersions, int(v))
	}
	if completed.Valid {
		t := completed.Time.UTC()
		out.CompletedAt = &t
	}
	return nil
}

// AdvanceSaga performs a compare-and-swap on the state.
//
// The `AND state = $from` predicate IS the concurrency control. Two invocations racing on the same
// operation both read the same state; one UPDATE matches and the other matches zero rows and gets
// ErrStateConflict, rather than both proceeding to apply the same irreversible step twice.
func (p *PostgresStore) AdvanceSaga(ctx context.Context, tenantID, operationID string, from SagaState, mutate func(*SagaRecord)) (SagaRecord, error) {
	to, ok := NextState(from)
	if !ok {
		return SagaRecord{}, fmt.Errorf("%w: %q has no successor", ErrIllegalTransition, from)
	}
	var out SagaRecord
	// One transaction, claim set from the CALLER's tenant. There is deliberately no pre-read to
	// discover the tenant: that read would itself need the claim, which is the circularity that made
	// this path work only under BYPASSRLS.
	err := p.withTenantTx(ctx, tenantID, false, func(tx *sql.Tx) error {
		cur, err := loadSagaInTx(ctx, tx, operationID)
		if err != nil {
			return err
		}
		if cur.State != from {
			return fmt.Errorf("%w: expected %q, found %q", ErrStateConflict, from, cur.State)
		}
		if mutate != nil {
			mutate(&cur)
		}
		res, err := tx.ExecContext(ctx, `
			UPDATE subject_key_erasures
			   SET state           = $2,
			       target_versions = $3,
			       receipt_digest  = $4,
			       caches_purged   = $5,
			       completed_at    = COALESCE(subject_key_erasures.completed_at, $6),
			       updated_at      = now()
			 WHERE operation_id = $1 AND state = $7`,
			operationID, string(to), pq.Array(nonNilInts(cur.TargetVersions)), cur.ReceiptDigest,
			pq.Array(nonNilStrings(cur.CachesPurged)), nullTime(cur.CompletedAt), string(from))
		if err != nil {
			return fmt.Errorf("subjectkey: advance saga state: %w", err)
		}
		n, err := res.RowsAffected()
		if err != nil {
			return fmt.Errorf("subjectkey: rows affected: %w", err)
		}
		if n != 1 {
			return fmt.Errorf("%w: state changed between read and update", ErrStateConflict)
		}
		out, err = loadSagaInTx(ctx, tx, operationID)
		return err
	})
	return out, err
}

// nonNilStrings normalises a nil slice to an empty one.
//
// pq.Array(nil) renders as SQL NULL, not as '{}', so a nil CachesPurged violated the NOT NULL
// constraint on subject_key_erasures.caches_purged. The saga always populates it, but the store must
// not depend on its only caller being careful -- a direct BeginSaga from operator tooling or a test
// would otherwise fail with a constraint error that says nothing about the real cause. Caught by
// TestSubjectKeyPG_SagaJournalIsIdempotentAndCompareAndSwapped against live PostgreSQL 16.
func nonNilStrings(in []string) []string {
	if in == nil {
		return []string{}
	}
	return in
}

// nonNilInts is the same normalisation for target_versions, which carries the same NOT NULL.
func nonNilInts(in []int) []int {
	if in == nil {
		return []int{}
	}
	return in
}

func nullTime(t *time.Time) any {
	if t == nil {
		return nil
	}
	return t.UTC()
}

func scanRecords(rows *sql.Rows) ([]KeyRecord, error) {
	defer rows.Close()
	var out []KeyRecord
	for rows.Next() {
		var (
			r         KeyRecord
			epoch     int64
			destroyed sql.NullTime
		)
		if err := rows.Scan(&r.TenantID, &r.SubjectPseudonym, &epoch, &r.KeyVersion,
			&r.WrappedDEK, &r.PriorWrappedDigest, &r.CreatedAt, &destroyed); err != nil {
			return nil, fmt.Errorf("subjectkey: scan key version: %w", err)
		}
		r.KeyEpoch = uint32(epoch)
		if destroyed.Valid {
			t := destroyed.Time.UTC()
			r.DestroyedAt = &t
		}
		out = append(out, r)
	}
	// rows.Err() is checked because a mid-iteration failure otherwise ends the loop normally and
	// yields a SHORT version list presented as a complete one — which for an erasure sweep means
	// silently skipping live keys and reporting the subject erased.
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("subjectkey: iterate key versions: %w", err)
	}
	return out, nil
}

// MigrationTableNames lists the tables migration 009 creates, for tests that assert the migration
// text rather than guessing at names.
func MigrationTableNames() []string { return []string{"subject_keys", "subject_key_erasures"} }

// SagaStateSQLList renders the Go state enumeration as the SQL IN-list literal migration 009 must
// contain. TestMigration009_StateCheckMatchesGo compares the migration text against THIS, so the
// SQL constraint and the Go enumeration cannot drift apart without a test going red.
func SagaStateSQLList() string {
	parts := make([]string, 0, len(SagaStates))
	for _, s := range SagaStates {
		parts = append(parts, "'"+string(s)+"'")
	}
	return strings.Join(parts, ", ")
}
