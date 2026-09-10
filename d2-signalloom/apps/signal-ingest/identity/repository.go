package identity

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
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

	GetActiveGraphForActorAsOf(ctx context.Context, actorID string, asOf time.Time) (*ActorGraphSnapshot, error)
}

// PostgresRepository implements Repository on top of PostgreSQL.
type PostgresRepository struct {
	db        *sql.DB
	encryptor Encryptor
}

// NewPostgresRepository constructs a PostgresRepository sharing the provided sql.DB pool.
func NewPostgresRepository(db *sql.DB, encryptor Encryptor) *PostgresRepository {
	if encryptor == nil {
		encryptor = NewNoopEncryptor()
	}
	return &PostgresRepository{
		db:        db,
		encryptor: encryptor,
	}
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
	alias.AliasValueHash = r.encryptor.Hash(alias.AliasValue)

	const q = `
		INSERT INTO aliases (actor_id, alias_type, alias_value, alias_value_hash, edge_fidelity, valid_from, valid_to, created_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		RETURNING id`

	err := r.db.QueryRowContext(ctx, q,
		alias.ActorID,
		alias.AliasType,
		alias.AliasValue,
		alias.AliasValueHash,
		string(alias.EdgeFidelity),
		alias.ValidFrom,
		alias.ValidTo,
		alias.CreatedAt,
	).Scan(&alias.ID)
	if err != nil {
		return fmt.Errorf("failed to add alias: %w", err)
	}
	return nil
}

// FindAliasesAsOf finds active aliases matching aliasValue at asOf.
// Half-open interval predicate: valid_from <= asOf AND (valid_to IS NULL OR asOf < valid_to).
func (r *PostgresRepository) FindAliasesAsOf(ctx context.Context, aliasValue string, asOf time.Time) ([]AliasRecord, error) {
	hash := r.encryptor.Hash(aliasValue)
	const q = `
		SELECT id, actor_id, alias_type, alias_value, alias_value_hash, edge_fidelity, valid_from, valid_to, created_at
		FROM aliases
		WHERE (alias_value = $1 OR alias_value_hash = $2)
		  AND valid_from <= $3
		  AND (valid_to IS NULL OR $3 < valid_to)
		ORDER BY valid_from DESC`

	rows, err := r.db.QueryContext(ctx, q, aliasValue, hash, asOf)
	if err != nil {
		return nil, fmt.Errorf("failed to query aliases: %w", err)
	}
	defer rows.Close()

	return r.scanAliases(rows)
}

// GetAliasesForActorAsOf returns all aliases active for an actor at asOf.
func (r *PostgresRepository) GetAliasesForActorAsOf(ctx context.Context, actorID string, asOf time.Time) ([]AliasRecord, error) {
	const q = `
		SELECT id, actor_id, alias_type, alias_value, alias_value_hash, edge_fidelity, valid_from, valid_to, created_at
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
		)
		if err := rows.Scan(
			&rec.ID,
			&rec.ActorID,
			&rec.AliasType,
			&rec.AliasValue,
			&rec.AliasValueHash,
			&fidelityStr,
			&rec.ValidFrom,
			&rec.ValidTo,
			&rec.CreatedAt,
		); err != nil {
			return nil, fmt.Errorf("scan alias row error: %w", err)
		}
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

	const q = `
		INSERT INTO delegations (delegate_actor_id, principal_actor_id, authz_ref, valid_from, valid_to, metadata, created_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		RETURNING id`

	err = r.db.QueryRowContext(ctx, q,
		delegation.DelegateActorID,
		delegation.PrincipalActorID,
		delegation.AuthzRef,
		delegation.ValidFrom,
		delegation.ValidTo,
		encryptedMeta,
		delegation.CreatedAt,
	).Scan(&delegation.ID)
	if err != nil {
		return fmt.Errorf("failed to add delegation: %w", err)
	}
	return nil
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

