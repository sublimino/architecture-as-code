package identity

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

var (
	// ErrActorNotFound is returned when an actor does not exist at the given timestamp.
	ErrActorNotFound = errors.New("actor not found")
	// ErrAliasNotFound is returned when no active alias matches the search criteria.
	ErrAliasNotFound = errors.New("alias not found")
	// ErrNeverMergeViolation is returned when a structural never-merge invariant is violated.
	ErrNeverMergeViolation = errors.New("structural never-merge invariant violated")
)

// Repository defines the contract for persisting and retrieving identity actors, aliases, and delegations.
type Repository interface {
	CreateActor(ctx context.Context, actor ActorRecord) error
	GetActor(ctx context.Context, actorID string) (*ActorRecord, error)
	GetActorAsOf(ctx context.Context, actorID string, asOf time.Time) (*ActorRecord, error)

	AddAlias(ctx context.Context, alias AliasRecord) error
	FindAliasesAsOf(ctx context.Context, aliasValue string, asOf time.Time) ([]AliasRecord, error)
	GetAliasesForActorAsOf(ctx context.Context, actorID string, asOf time.Time) ([]AliasRecord, error)

	AddDelegation(ctx context.Context, delegation DelegationRecord) error
	GetDelegationsForDelegateAsOf(ctx context.Context, delegateID string, asOf time.Time) ([]DelegationRecord, error)
	GetDelegationsForPrincipalAsOf(ctx context.Context, principalID string, asOf time.Time) ([]DelegationRecord, error)
	FindTransitiveDelegations(ctx context.Context, delegateID string, asOf time.Time, maxDepth int) ([]DelegationRecord, bool, error)
	ClampDelegation(ctx context.Context, delegateOrAuthzRef string, clampTime time.Time) error
	RevokeActiveDelegations(ctx context.Context, actorID string, timestamp time.Time) error
	SweepExpiredDelegations(ctx context.Context, now time.Time) (int64, error)

	GetActiveGraphForActorAsOf(ctx context.Context, actorID string, asOf time.Time) (*ActorGraphSnapshot, error)
}

// DefaultTenantID is the tenant scope applied when no per-record tenant is supplied.
//
// The identity schema has no tenant_id column yet — that is SLDP-P2-2, migration 006. Until it
// lands, the pseudonym key ring is scoped by a single deployment-level tenant read from
// IDENTITY_TENANT_ID. The key-derivation API is already per-tenant, so P2-2 wires per-row tenants
// with no change to the crypto.
const DefaultTenantID = "default"

// TenantIDFromEnv returns the configured deployment tenant, never the empty string.
// An empty tenant would collapse every tenant into one correlation domain, so it is not a
// reachable state: the fallback is DefaultTenantID, not "".
func TenantIDFromEnv() string {
	if v := os.Getenv("IDENTITY_TENANT_ID"); v != "" {
		return v
	}
	return DefaultTenantID
}

// PostgresRepository implements Repository on top of PostgreSQL.
type PostgresRepository struct {
	db        *sql.DB
	encryptor Encryptor
	tenantID  string
}

// NewPostgresRepository constructs a PostgresRepository sharing the provided sql.DB pool.
// If encryptor is nil, it requires explicit development opt-in via DevOptInAllowed()
// rather than silently defaulting to unencrypted cleartext storage in production.
func NewPostgresRepository(db *sql.DB, encryptor Encryptor) *PostgresRepository {
	return NewPostgresRepositoryWithTenant(db, encryptor, TenantIDFromEnv())
}

// NewPostgresRepositoryWithTenant constructs a PostgresRepository bound to an explicit tenant
// scope for pseudonymisation. An empty tenantID falls back to DefaultTenantID rather than
// producing an unscoped pseudonym.
func NewPostgresRepositoryWithTenant(db *sql.DB, encryptor Encryptor, tenantID string) *PostgresRepository {
	if encryptor == nil {
		if DevOptInAllowed() {
			encryptor = NewNoopEncryptor()
		} else {
			panic("identity: NewPostgresRepository requires a non-nil Encryptor in production mode (set IDENTITY_ENCRYPTION_KEY or INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR=true)")
		}
	}
	if tenantID == "" {
		tenantID = DefaultTenantID
	}
	return &PostgresRepository{
		db:        db,
		encryptor: encryptor,
		tenantID:  tenantID,
	}
}

// TenantID returns the tenant scope this repository pseudonymises under.
func (r *PostgresRepository) TenantID() string { return r.tenantID }

// tenantFor resolves the effective tenant for a record, preferring an explicit per-record scope.
func (r *PostgresRepository) tenantFor(recordTenant string) string {
	if recordTenant != "" {
		return recordTenant
	}
	return r.tenantID
}

// DB exposes the underlying *sql.DB connection pool.
func (r *PostgresRepository) DB() *sql.DB {
	return r.db
}

// CreateActor inserts or updates a canonical actor in the actors table.
func (r *PostgresRepository) CreateActor(ctx context.Context, actor ActorRecord) error {
	if actor.ActorID == "" {
		return fmt.Errorf("actor_id cannot be empty")
	}
	if actor.Status == "" {
		actor.Status = model.ActorProvisional
	}
	now := time.Now().UTC()
	if actor.CreatedAt.IsZero() {
		actor.CreatedAt = now
	}
	if actor.UpdatedAt.IsZero() {
		actor.UpdatedAt = now
	}

	metaBytes, err := json.Marshal(actor.Metadata)
	if err != nil {
		return fmt.Errorf("failed to marshal metadata: %w", err)
	}
	encryptedMeta, err := r.encryptor.Encrypt(metaBytes)
	if err != nil {
		return fmt.Errorf("failed to encrypt metadata: %w", err)
	}

	const q = `
		INSERT INTO actors (actor_id, status, metadata, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (actor_id) DO UPDATE SET
			status = EXCLUDED.status,
			metadata = EXCLUDED.metadata,
			updated_at = EXCLUDED.updated_at`

	_, err = r.db.ExecContext(ctx, q, actor.ActorID, string(actor.Status), encryptedMeta, actor.CreatedAt, actor.UpdatedAt)
	if err != nil {
		return fmt.Errorf("failed to create actor: %w", err)
	}
	return nil
}

// GetActor retrieves an actor by ID regardless of timestamp.
func (r *PostgresRepository) GetActor(ctx context.Context, actorID string) (*ActorRecord, error) {
	const q = `SELECT actor_id, status, metadata, created_at, updated_at FROM actors WHERE actor_id = $1`
	return r.scanActorRow(r.db.QueryRowContext(ctx, q, actorID))
}

// GetActorAsOf retrieves an actor valid as of the given timestamp.
func (r *PostgresRepository) GetActorAsOf(ctx context.Context, actorID string, asOf time.Time) (*ActorRecord, error) {
	const q = `SELECT actor_id, status, metadata, created_at, updated_at FROM actors WHERE actor_id = $1 AND created_at <= $2`
	return r.scanActorRow(r.db.QueryRowContext(ctx, q, actorID, asOf))
}

func (r *PostgresRepository) scanActorRow(row *sql.Row) (*ActorRecord, error) {
	var (
		rec           ActorRecord
		statusStr     string
		encryptedMeta []byte
	)
	err := row.Scan(&rec.ActorID, &statusStr, &encryptedMeta, &rec.CreatedAt, &rec.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrActorNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("scan actor error: %w", err)
	}

	rec.Status = model.ActorStatus(statusStr)
	if len(encryptedMeta) > 0 {
		metaBytes, err := r.encryptor.Decrypt(encryptedMeta)
		if err != nil {
			return nil, fmt.Errorf("decrypt metadata error: %w", err)
		}
		if len(metaBytes) > 0 && string(metaBytes) != "null" {
			_ = json.Unmarshal(metaBytes, &rec.Metadata)
		}
	}
	return &rec, nil
}

// AddAlias records a typed time-valid alias.
//
// The alias value is stored as AES-GCM envelope ciphertext in alias_value_encrypted. The cleartext
// alias_value column is never written. The only indexed representation of the identifier is the
// keyed pseudonym in alias_value_hash.
func (r *PostgresRepository) AddAlias(ctx context.Context, alias AliasRecord) error {
	if alias.ActorID == "" || alias.AliasValue == "" || alias.AliasType == "" {
		return fmt.Errorf("actor_id, alias_type, and alias_value are required")
	}
	if alias.EdgeFidelity == "" {
		alias.EdgeFidelity = model.FidelitySuggestive
	}
	if alias.ValidFrom.IsZero() {
		alias.ValidFrom = time.Now().UTC()
	}
	if alias.CreatedAt.IsZero() {
		alias.CreatedAt = time.Now().UTC()
	}

	tenant := r.tenantFor(alias.TenantID)
	pseudonym, err := r.encryptor.Pseudonym(tenant, alias.AliasValue)
	if err != nil {
		return fmt.Errorf("failed to pseudonymise alias value: %w", err)
	}
	alias.AliasValueHash = pseudonym

	// The ciphertext is bound to this row's actor, alias type and pseudonym. Copying it into a
	// different row fails the GCM tag rather than decrypting into a value that silently
	// contradicts that row's pseudonym.
	sealed, err := r.encryptor.EncryptEnvelope(
		[]byte(alias.AliasValue),
		AliasEnvelopeAAD(alias.ActorID, alias.AliasType, pseudonym),
	)
	if err != nil {
		return fmt.Errorf("failed to envelope-encrypt alias value: %w", err)
	}

	// The never-merge invariant is enforced by trg_aliases_never_merge inside this statement's
	// own transaction (migration 005 §6), comparing pseudonym to pseudonym. It is NOT enforced
	// here: a SELECT-then-INSERT pair in application code is a read-then-write race, and two
	// concurrent connections — one adding the alias, one adding the delegation — would each read
	// before the other wrote and both would be admitted.
	const q = `
		INSERT INTO aliases (actor_id, alias_type, alias_value_encrypted, alias_value_hash, edge_fidelity, valid_from, valid_to, created_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		ON CONFLICT (actor_id, alias_type, alias_value_hash, valid_from) DO NOTHING
		RETURNING id`

	err = r.db.QueryRowContext(ctx, q,
		alias.ActorID,
		alias.AliasType,
		sealed,
		alias.AliasValueHash,
		string(alias.EdgeFidelity),
		alias.ValidFrom,
		alias.ValidTo,
		alias.CreatedAt,
	).Scan(&alias.ID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		return fmt.Errorf("failed to add alias: %w", err)
	}
	return nil
}

// aliasSelectColumns is the single source of truth for the alias projection, so the SELECT list
// and scanAliases cannot drift apart.
const aliasSelectColumns = `id, actor_id, alias_type, alias_value_encrypted, alias_value_hash, edge_fidelity, valid_from, valid_to, created_at`

// FindAliasesAsOf finds active aliases matching aliasValue at asOf.
// Half-open interval predicate: valid_from <= asOf AND (valid_to IS NULL OR asOf < valid_to).
//
// The lookup matches on the keyed pseudonym only. The former `alias_value = $1` disjunct is gone:
// it required a cleartext column and a cleartext index, both of which migration 005 removes.
func (r *PostgresRepository) FindAliasesAsOf(ctx context.Context, aliasValue string, asOf time.Time) ([]AliasRecord, error) {
	pseudonym, err := r.encryptor.Pseudonym(r.tenantID, aliasValue)
	if err != nil {
		return nil, fmt.Errorf("failed to pseudonymise alias lookup value: %w", err)
	}
	q := `
		SELECT ` + aliasSelectColumns + `
		FROM aliases
		WHERE alias_value_hash = $1
		  AND valid_from <= $2
		  AND (valid_to IS NULL OR $2 < valid_to)
		ORDER BY valid_from DESC`

	rows, err := r.db.QueryContext(ctx, q, pseudonym, asOf)
	if err != nil {
		return nil, fmt.Errorf("failed to query aliases: %w", err)
	}
	defer rows.Close()

	return r.scanAliases(rows)
}

// GetAliasesForActorAsOf returns all aliases active for an actor at asOf.
func (r *PostgresRepository) GetAliasesForActorAsOf(ctx context.Context, actorID string, asOf time.Time) ([]AliasRecord, error) {
	q := `
		SELECT ` + aliasSelectColumns + `
		FROM aliases
		WHERE actor_id = $1
		  AND valid_from <= $2
		  AND (valid_to IS NULL OR $2 < valid_to)
		ORDER BY valid_from ASC`

	rows, err := r.db.QueryContext(ctx, q, actorID, asOf)
	if err != nil {
		return nil, fmt.Errorf("failed to query actor aliases: %w", err)
	}
	defer rows.Close()

	return r.scanAliases(rows)
}

func (r *PostgresRepository) scanAliases(rows *sql.Rows) ([]AliasRecord, error) {
	var aliases []AliasRecord
	for rows.Next() {
		var (
			rec         AliasRecord
			fidelityStr string
			sealed      []byte
		)
		if err := rows.Scan(
			&rec.ID,
			&rec.ActorID,
			&rec.AliasType,
			&sealed,
			&rec.AliasValueHash,
			&fidelityStr,
			&rec.ValidFrom,
			&rec.ValidTo,
			&rec.CreatedAt,
		); err != nil {
			return nil, fmt.Errorf("scan alias row error: %w", err)
		}
		if len(sealed) > 0 {
			plaintext, err := r.encryptor.DecryptEnvelope(
				sealed,
				AliasEnvelopeAAD(rec.ActorID, rec.AliasType, rec.AliasValueHash),
			)
			if err != nil {
				return nil, fmt.Errorf("decrypt alias value error: %w", err)
			}
			rec.AliasValue = string(plaintext)
		}
		rec.TenantID = r.tenantID
		rec.EdgeFidelity = model.FidelityTier(fidelityStr)
		aliases = append(aliases, rec)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("aliases rows iteration error: %w", err)
	}
	return aliases, nil
}

// AddDelegation persists an acts-on-behalf-of delegation relationship.
func (r *PostgresRepository) AddDelegation(ctx context.Context, delegation DelegationRecord) error {
	if delegation.DelegateActorID == "" || delegation.PrincipalActorID == "" {
		return fmt.Errorf("delegate_actor_id and principal_actor_id are required")
	}
	if delegation.DelegateActorID == delegation.PrincipalActorID {
		return fmt.Errorf("%w: delegate and principal cannot be identical", ErrNeverMergeViolation)
	}
	if delegation.ValidFrom.IsZero() {
		delegation.ValidFrom = time.Now().UTC()
	}
	if delegation.CreatedAt.IsZero() {
		delegation.CreatedAt = time.Now().UTC()
	}

	metaBytes, err := json.Marshal(delegation.Metadata)
	if err != nil {
		return fmt.Errorf("failed to marshal delegation metadata: %w", err)
	}
	encryptedMeta, err := r.encryptor.Encrypt(metaBytes)
	if err != nil {
		return fmt.Errorf("failed to encrypt delegation metadata: %w", err)
	}

	// Both counterparty pseudonyms are written so trg_delegations_never_merge can compare against
	// pseudonymised aliases without the database ever holding a key. See migration 005 §6b.
	delegatePseudonym, err := r.encryptor.Pseudonym(r.tenantID, delegation.DelegateActorID)
	if err != nil {
		return fmt.Errorf("failed to pseudonymise delegate actor id: %w", err)
	}
	principalPseudonym, err := r.encryptor.Pseudonym(r.tenantID, delegation.PrincipalActorID)
	if err != nil {
		return fmt.Errorf("failed to pseudonymise principal actor id: %w", err)
	}

	const q = `
		INSERT INTO delegations (delegate_actor_id, principal_actor_id, authz_ref, valid_from, valid_to, metadata, created_at, delegate_actor_pseudonym, principal_actor_pseudonym)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
		ON CONFLICT (delegate_actor_id, principal_actor_id, valid_from) DO NOTHING
		RETURNING id`

	err = r.db.QueryRowContext(ctx, q,
		delegation.DelegateActorID,
		delegation.PrincipalActorID,
		delegation.AuthzRef,
		delegation.ValidFrom,
		delegation.ValidTo,
		encryptedMeta,
		delegation.CreatedAt,
		delegatePseudonym,
		principalPseudonym,
	).Scan(&delegation.ID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		return fmt.Errorf("failed to add delegation: %w", err)
	}
	return nil
}

// ClampDelegation terminates any active delegation matching delegateOrAuthzRef by clamping valid_to = clampTime.
func (r *PostgresRepository) ClampDelegation(ctx context.Context, delegateOrAuthzRef string, clampTime time.Time) error {
	if clampTime.IsZero() {
		clampTime = time.Now().UTC()
	}
	const q = `
		UPDATE delegations
		   SET valid_to = $2
		 WHERE (authz_ref = $1 OR delegate_actor_id = $1)
		   AND (valid_to IS NULL OR valid_to > $2)`
	_, err := r.db.ExecContext(ctx, q, delegateOrAuthzRef, clampTime)
	if err != nil {
		return fmt.Errorf("failed to clamp delegation: %w", err)
	}
	return nil
}

// RevokeActiveDelegations terminates all active delegation edges originating from or terminating at
// actorID as well as transitive descendant delegations, setting valid_to to clampTime.
// It also updates the actor status to 'revoked' in an atomic transaction.
func (r *PostgresRepository) RevokeActiveDelegations(ctx context.Context, actorID string, timestamp time.Time) error {
	if timestamp.IsZero() {
		timestamp = time.Now().UTC()
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("failed to begin transaction: %w", err)
	}
	defer tx.Rollback()

	const qTree = `
		WITH RECURSIVE del_tree AS (
			SELECT id, delegate_actor_id, principal_actor_id, valid_from
			FROM delegations
			WHERE (delegate_actor_id = $1 OR principal_actor_id = $1)
			  AND valid_from <= $2
			  AND (valid_to IS NULL OR valid_to > $2)
			UNION
			SELECT d.id, d.delegate_actor_id, d.principal_actor_id, d.valid_from
			FROM delegations d
			JOIN del_tree dt ON d.principal_actor_id = dt.delegate_actor_id
			WHERE d.valid_from <= $2
			  AND (d.valid_to IS NULL OR d.valid_to > $2)
		)
		UPDATE delegations
		   SET valid_to = CASE 
				WHEN valid_from < $2 THEN $2 
				ELSE valid_from + interval '1 microsecond' 
			END,
			status = 'revoked'
		 WHERE id IN (SELECT id FROM del_tree)`

	if _, err := tx.ExecContext(ctx, qTree, actorID, timestamp); err != nil {
		return fmt.Errorf("failed to revoke delegation tree: %w", err)
	}

	const qActor = `
		UPDATE actors
		   SET status = 'revoked', updated_at = $2
		 WHERE actor_id = $1`

	if _, err := tx.ExecContext(ctx, qActor, actorID, timestamp); err != nil {
		return fmt.Errorf("failed to update actor status: %w", err)
	}

	return tx.Commit()
}

// SweepExpiredDelegations marks past time-bounded delegations as expired.
func (r *PostgresRepository) SweepExpiredDelegations(ctx context.Context, now time.Time) (int64, error) {
	if now.IsZero() {
		now = time.Now().UTC()
	}
	const q = `
		UPDATE delegations
		   SET status = 'expired'
		 WHERE valid_to IS NOT NULL
		   AND valid_to <= $1
		   AND (status IS NULL OR status = 'active')`
	res, err := r.db.ExecContext(ctx, q, now)
	if err != nil {
		return 0, fmt.Errorf("failed to sweep expired delegations: %w", err)
	}
	return res.RowsAffected()
}

// GetDelegationsForDelegateAsOf returns active delegations where actor is the delegate.
func (r *PostgresRepository) GetDelegationsForDelegateAsOf(ctx context.Context, delegateID string, asOf time.Time) ([]DelegationRecord, error) {
	const q = `
		SELECT id, delegate_actor_id, principal_actor_id, authz_ref, valid_from, valid_to, metadata, created_at
		FROM delegations
		WHERE delegate_actor_id = $1
		  AND valid_from <= $2
		  AND (valid_to IS NULL OR $2 < valid_to)
		ORDER BY valid_from ASC`

	rows, err := r.db.QueryContext(ctx, q, delegateID, asOf)
	if err != nil {
		return nil, fmt.Errorf("failed to query delegations for delegate: %w", err)
	}
	defer rows.Close()

	return r.scanDelegations(rows)
}

// GetDelegationsForPrincipalAsOf returns active delegations where actor is the principal.
func (r *PostgresRepository) GetDelegationsForPrincipalAsOf(ctx context.Context, principalID string, asOf time.Time) ([]DelegationRecord, error) {
	const q = `
		SELECT id, delegate_actor_id, principal_actor_id, authz_ref, valid_from, valid_to, metadata, created_at
		FROM delegations
		WHERE principal_actor_id = $1
		  AND valid_from <= $2
		  AND (valid_to IS NULL OR $2 < valid_to)
		ORDER BY valid_from ASC`

	rows, err := r.db.QueryContext(ctx, q, principalID, asOf)
	if err != nil {
		return nil, fmt.Errorf("failed to query delegations for principal: %w", err)
	}
	defer rows.Close()

	return r.scanDelegations(rows)
}

func (r *PostgresRepository) scanDelegations(rows *sql.Rows) ([]DelegationRecord, error) {
	var delegations []DelegationRecord
	for rows.Next() {
		var (
			rec           DelegationRecord
			encryptedMeta []byte
		)
		if err := rows.Scan(
			&rec.ID,
			&rec.DelegateActorID,
			&rec.PrincipalActorID,
			&rec.AuthzRef,
			&rec.ValidFrom,
			&rec.ValidTo,
			&encryptedMeta,
			&rec.CreatedAt,
		); err != nil {
			return nil, fmt.Errorf("scan delegation row error: %w", err)
		}
		if len(encryptedMeta) > 0 {
			metaBytes, err := r.encryptor.Decrypt(encryptedMeta)
			if err == nil && len(metaBytes) > 0 && string(metaBytes) != "null" {
				_ = json.Unmarshal(metaBytes, &rec.Metadata)
			}
		}
		delegations = append(delegations, rec)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("delegations rows iteration error: %w", err)
	}
	return delegations, nil
}

// GetActiveGraphForActorAsOf assembles a full snapshot of the actor and its active graph edges at asOf.
func (r *PostgresRepository) GetActiveGraphForActorAsOf(ctx context.Context, actorID string, asOf time.Time) (*ActorGraphSnapshot, error) {
	actor, err := r.GetActorAsOf(ctx, actorID, asOf)
	if err != nil {
		return nil, err
	}

	aliases, err := r.GetAliasesForActorAsOf(ctx, actorID, asOf)
	if err != nil {
		return nil, err
	}

	delegationsAsDelegate, err := r.GetDelegationsForDelegateAsOf(ctx, actorID, asOf)
	if err != nil {
		return nil, err
	}

	delegationsAsPrincipal, err := r.GetDelegationsForPrincipalAsOf(ctx, actorID, asOf)
	if err != nil {
		return nil, err
	}

	return &ActorGraphSnapshot{
		Actor:                  *actor,
		Aliases:                aliases,
		DelegationsAsDelegate:  delegationsAsDelegate,
		DelegationsAsPrincipal: delegationsAsPrincipal,
		AsOf:                   asOf,
	}, nil
}

// FindTransitiveDelegations resolves arbitrary-depth delegation chains using a recursive CTE,
// enforcing strict cycle detection and max-depth clamping. Returns the ordered delegation chain,
// a boolean indicating whether a cycle was detected, and any query error.
func (r *PostgresRepository) FindTransitiveDelegations(ctx context.Context, delegateID string, asOf time.Time, maxDepth int) ([]DelegationRecord, bool, error) {
	if maxDepth <= 0 || maxDepth > 8 {
		maxDepth = 8
	}

	const q = `
		WITH RECURSIVE del_chain AS (
			-- Anchor member
			SELECT 
				d.id, d.delegate_actor_id, d.principal_actor_id, d.authz_ref, 
				d.valid_from, d.valid_to, d.metadata, d.created_at,
				1 AS depth,
				ARRAY[d.delegate_actor_id, d.principal_actor_id] AS path,
				false AS is_cycle
			FROM delegations d
			WHERE d.delegate_actor_id = $1
			  AND d.valid_from <= $2
			  AND (d.valid_to IS NULL OR $2 < d.valid_to)

			UNION ALL

			-- Recursive member
			SELECT 
				d.id, d.delegate_actor_id, d.principal_actor_id, d.authz_ref, 
				d.valid_from, d.valid_to, d.metadata, d.created_at,
				c.depth + 1,
				c.path || d.principal_actor_id,
				d.principal_actor_id = ANY(c.path) AS is_cycle
			FROM delegations d
			JOIN del_chain c ON d.delegate_actor_id = c.principal_actor_id
			WHERE d.valid_from <= $2
			  AND (d.valid_to IS NULL OR $2 < d.valid_to)
			  AND c.depth < $3
			  AND NOT c.is_cycle
		)
		SELECT id, delegate_actor_id, principal_actor_id, authz_ref, valid_from, valid_to, metadata, created_at, is_cycle
		FROM del_chain
		ORDER BY depth ASC`

	rows, err := r.db.QueryContext(ctx, q, delegateID, asOf, maxDepth)
	if err != nil {
		return nil, false, fmt.Errorf("failed to execute recursive delegation query: %w", err)
	}
	defer rows.Close()

	var (
		delegations   []DelegationRecord
		cycleDetected bool
	)

	for rows.Next() {
		var (
			rec           DelegationRecord
			encryptedMeta []byte
			isCycle       bool
		)
		if err := rows.Scan(
			&rec.ID,
			&rec.DelegateActorID,
			&rec.PrincipalActorID,
			&rec.AuthzRef,
			&rec.ValidFrom,
			&rec.ValidTo,
			&encryptedMeta,
			&rec.CreatedAt,
			&isCycle,
		); err != nil {
			return nil, false, fmt.Errorf("scan recursive delegation row error: %w", err)
		}
		if len(encryptedMeta) > 0 {
			metaBytes, err := r.encryptor.Decrypt(encryptedMeta)
			if err == nil && len(metaBytes) > 0 && string(metaBytes) != "null" {
				_ = json.Unmarshal(metaBytes, &rec.Metadata)
			}
		}
		if isCycle {
			cycleDetected = true
		}
		delegations = append(delegations, rec)
	}
	if err := rows.Err(); err != nil {
		return nil, false, fmt.Errorf("recursive delegations rows iteration error: %w", err)
	}

	return delegations, cycleDetected, nil
}
