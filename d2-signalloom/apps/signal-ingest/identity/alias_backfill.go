// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package identity

import (
	"context"
	"database/sql"
	"fmt"
	"log/slog"
)

// AliasBackfillReport summarises a forward migration or rollback pass over the aliases table.
type AliasBackfillReport struct {
	// Scanned is the number of rows the pass examined.
	Scanned int
	// Rewritten is the number of rows the pass actually changed.
	Rewritten int
	// RemainingCleartext is the number of rows still carrying a non-NULL alias_value after the
	// pass. For a successful forward migration this must be zero.
	RemainingCleartext int
	// MissingCiphertext is the number of rows with a NULL alias_value_encrypted after the pass.
	// For a successful forward migration this must be zero.
	MissingCiphertext int
}

// EncryptExistingAliasValues rewrites every pre-migration alias row in place: it recomputes
// alias_value_hash as a keyed pseudonym, writes the identifier into alias_value_encrypted as
// AES-GCM envelope ciphertext, and nulls the cleartext alias_value column.
//
// This is the data half of migration 005. It lives in Go rather than SQL because the database
// does not hold — and must not hold — the HMAC key or the encryption key.
//
// It is idempotent: rows already migrated (alias_value IS NULL) are skipped, so re-running after
// a partial failure completes the job rather than double-encrypting.
//
// The whole pass runs in one transaction. A partial rewrite would leave the table in a state where
// some identifiers are protected and some are not, with nothing recording which is which.
func EncryptExistingAliasValues(ctx context.Context, db *sql.DB, enc Encryptor, tenantID string) (*AliasBackfillReport, error) {
	if db == nil {
		return nil, fmt.Errorf("identity: cannot backfill alias encryption on a nil db connection")
	}
	if enc == nil {
		return nil, fmt.Errorf("identity: cannot backfill alias encryption without an Encryptor")
	}
	if tenantID == "" {
		tenantID = DefaultTenantID
	}

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to begin alias backfill transaction: %w", err)
	}
	defer tx.Rollback()

	// Delegations are backfilled first. trg_aliases_never_merge compares an incoming alias
	// pseudonym against delegations.{delegate,principal}_actor_pseudonym, so those columns must
	// be populated before any alias row is rewritten — otherwise the comparison has nothing to
	// match and the invariant is unenforced for the duration of the alias pass.
	delegationRows, err := tx.QueryContext(ctx,
		`SELECT id, delegate_actor_id, principal_actor_id FROM delegations
		 WHERE delegate_actor_pseudonym IS NULL OR principal_actor_pseudonym IS NULL ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("failed to read delegations for pseudonym backfill: %w", err)
	}
	type delegationPending struct {
		id                  int64
		delegate, principal string
	}
	var delegationTodo []delegationPending
	for delegationRows.Next() {
		var d delegationPending
		if err := delegationRows.Scan(&d.id, &d.delegate, &d.principal); err != nil {
			delegationRows.Close()
			return nil, fmt.Errorf("failed to scan delegation row: %w", err)
		}
		delegationTodo = append(delegationTodo, d)
	}
	if err := delegationRows.Err(); err != nil {
		delegationRows.Close()
		return nil, fmt.Errorf("delegation row iteration error: %w", err)
	}
	delegationRows.Close()

	for _, d := range delegationTodo {
		dp, err := enc.Pseudonym(tenantID, d.delegate)
		if err != nil {
			return nil, fmt.Errorf("failed to pseudonymise delegate on delegation %d: %w", d.id, err)
		}
		pp, err := enc.Pseudonym(tenantID, d.principal)
		if err != nil {
			return nil, fmt.Errorf("failed to pseudonymise principal on delegation %d: %w", d.id, err)
		}
		if _, err := tx.ExecContext(ctx,
			`UPDATE delegations SET delegate_actor_pseudonym = $1, principal_actor_pseudonym = $2 WHERE id = $3`,
			dp, pp, d.id); err != nil {
			return nil, fmt.Errorf("failed to write delegation pseudonyms for row %d: %w", d.id, err)
		}
	}

	rows, err := tx.QueryContext(ctx, `SELECT id, actor_id, alias_type, alias_value FROM aliases WHERE alias_value IS NOT NULL ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("failed to read cleartext alias rows: %w", err)
	}

	type pending struct {
		id                 int64
		actorID, aliasType string
		value              string
	}
	var todo []pending
	for rows.Next() {
		var p pending
		if err := rows.Scan(&p.id, &p.actorID, &p.aliasType, &p.value); err != nil {
			rows.Close()
			return nil, fmt.Errorf("failed to scan cleartext alias row: %w", err)
		}
		todo = append(todo, p)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, fmt.Errorf("cleartext alias row iteration error: %w", err)
	}
	rows.Close()

	report := &AliasBackfillReport{Scanned: len(todo)}

	for _, p := range todo {
		pseudonym, err := enc.Pseudonym(tenantID, p.value)
		if err != nil {
			return nil, fmt.Errorf("failed to pseudonymise alias row %d: %w", p.id, err)
		}
		sealed, err := enc.EncryptEnvelope([]byte(p.value), AliasEnvelopeAAD(p.actorID, p.aliasType, pseudonym))
		if err != nil {
			return nil, fmt.Errorf("failed to envelope-encrypt alias row %d: %w", p.id, err)
		}
		// alias_value is nulled in the same statement that writes the ciphertext, so no row is
		// ever visible holding both representations.
		res, err := tx.ExecContext(ctx,
			`UPDATE aliases SET alias_value_hash = $1, alias_value_encrypted = $2, alias_value = NULL WHERE id = $3`,
			pseudonym, sealed, p.id)
		if err != nil {
			return nil, fmt.Errorf("failed to rewrite alias row %d: %w", p.id, err)
		}
		n, err := res.RowsAffected()
		if err != nil {
			return nil, fmt.Errorf("failed to read rows affected for alias row %d: %w", p.id, err)
		}
		report.Rewritten += int(n)
	}

	if err := tx.QueryRowContext(ctx, `SELECT count(*) FROM aliases WHERE alias_value IS NOT NULL`).Scan(&report.RemainingCleartext); err != nil {
		return nil, fmt.Errorf("failed to count remaining cleartext rows: %w", err)
	}
	if err := tx.QueryRowContext(ctx, `SELECT count(*) FROM aliases WHERE alias_value_encrypted IS NULL`).Scan(&report.MissingCiphertext); err != nil {
		return nil, fmt.Errorf("failed to count rows missing ciphertext: %w", err)
	}

	// Fail closed rather than committing a half-migrated table.
	if report.RemainingCleartext != 0 {
		return nil, fmt.Errorf("identity: alias backfill incomplete, %d rows still hold cleartext alias_value", report.RemainingCleartext)
	}
	if report.MissingCiphertext != 0 {
		return nil, fmt.Errorf("identity: alias backfill incomplete, %d rows have NULL alias_value_encrypted", report.MissingCiphertext)
	}

	// Promote the NOT VALID constraint added by 005 now that every row conforms. If this fails,
	// the transaction rolls back and the table stays as it was.
	if _, err := tx.ExecContext(ctx, `ALTER TABLE aliases VALIDATE CONSTRAINT chk_aliases_pseudonymised`); err != nil {
		return nil, fmt.Errorf("failed to validate chk_aliases_pseudonymised after backfill: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("failed to commit alias backfill: %w", err)
	}

	slog.Info("alias pseudonymisation backfill complete",
		"scanned", report.Scanned,
		"rewritten", report.Rewritten,
		"remaining_cleartext", report.RemainingCleartext,
		"tenant", tenantID)
	return report, nil
}

// RederivePseudonymsForEpoch re-keys every pseudonym in the identity graph from oldEnc's epoch to
// newEnc's epoch, in one transaction.
//
// WHY THIS EXISTS. Rotating IDENTITY_PSEUDONYM_EPOCH changes every pseudonym at once. Because the
// never-merge triggers compare aliases.alias_value_hash against
// delegations.{delegate,principal}_actor_pseudonym, rotating one side without the other makes
// every comparison miss — the trigger silently degrades to a no-op, which is the exact fail-open
// migration 005 was written to close, merely deferred by one rotation.
//
// EncryptExistingAliasValues cannot do this job: it only populates pseudonyms that are NULL, and
// check_never_merge_delegation refuses to let them BE nulled (correctly — a NULL pseudonym is
// unverifiable). A rotation must therefore overwrite in place, which is what this does.
//
// Order matters. Delegations are re-keyed first: trg_aliases_never_merge consults the delegation
// pseudonyms, so if aliases moved first the alias pass would be checked against stale values.
//
// The AAD binds the pseudonym, so every alias envelope must also be re-sealed under the new
// pseudonym. That is why both encryptors are required — the old one to open, the new one to seal.
func RederivePseudonymsForEpoch(ctx context.Context, db *sql.DB, oldEnc, newEnc Encryptor, tenantID string) (*AliasBackfillReport, error) {
	if db == nil {
		return nil, fmt.Errorf("identity: cannot rotate pseudonyms on a nil db connection")
	}
	if oldEnc == nil || newEnc == nil {
		return nil, fmt.Errorf("identity: pseudonym rotation requires both the outgoing and incoming Encryptor")
	}
	if tenantID == "" {
		tenantID = DefaultTenantID
	}

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to begin pseudonym rotation transaction: %w", err)
	}
	defer tx.Rollback()

	// 1. Delegations first.
	delRows, err := tx.QueryContext(ctx, `SELECT id, delegate_actor_id, principal_actor_id FROM delegations ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("failed to read delegations for rotation: %w", err)
	}
	type delPending struct {
		id                  int64
		delegate, principal string
	}
	var delTodo []delPending
	for delRows.Next() {
		var d delPending
		if err := delRows.Scan(&d.id, &d.delegate, &d.principal); err != nil {
			delRows.Close()
			return nil, fmt.Errorf("failed to scan delegation row for rotation: %w", err)
		}
		delTodo = append(delTodo, d)
	}
	if err := delRows.Err(); err != nil {
		delRows.Close()
		return nil, fmt.Errorf("delegation rotation iteration error: %w", err)
	}
	delRows.Close()

	for _, d := range delTodo {
		dp, err := newEnc.Pseudonym(tenantID, d.delegate)
		if err != nil {
			return nil, fmt.Errorf("failed to re-derive delegate pseudonym on delegation %d: %w", d.id, err)
		}
		pp, err := newEnc.Pseudonym(tenantID, d.principal)
		if err != nil {
			return nil, fmt.Errorf("failed to re-derive principal pseudonym on delegation %d: %w", d.id, err)
		}
		if _, err := tx.ExecContext(ctx,
			`UPDATE delegations SET delegate_actor_pseudonym = $1, principal_actor_pseudonym = $2 WHERE id = $3`,
			dp, pp, d.id); err != nil {
			return nil, fmt.Errorf("failed to rotate delegation %d: %w", d.id, err)
		}
	}

	// 2. Aliases: open under the old key and AAD, re-key, re-seal under the new key and AAD.
	aliasRows, err := tx.QueryContext(ctx,
		`SELECT id, actor_id, alias_type, alias_value_hash, alias_value_encrypted FROM aliases
		 WHERE alias_value_encrypted IS NOT NULL ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("failed to read aliases for rotation: %w", err)
	}
	type aliasPending struct {
		id                            int64
		actorID, aliasType, pseudonym string
		sealed                        []byte
	}
	var aliasTodo []aliasPending
	for aliasRows.Next() {
		var a aliasPending
		if err := aliasRows.Scan(&a.id, &a.actorID, &a.aliasType, &a.pseudonym, &a.sealed); err != nil {
			aliasRows.Close()
			return nil, fmt.Errorf("failed to scan alias row for rotation: %w", err)
		}
		aliasTodo = append(aliasTodo, a)
	}
	if err := aliasRows.Err(); err != nil {
		aliasRows.Close()
		return nil, fmt.Errorf("alias rotation iteration error: %w", err)
	}
	aliasRows.Close()

	report := &AliasBackfillReport{Scanned: len(aliasTodo)}

	for _, a := range aliasTodo {
		plaintext, err := oldEnc.DecryptEnvelope(a.sealed, AliasEnvelopeAAD(a.actorID, a.aliasType, a.pseudonym))
		if err != nil {
			return nil, fmt.Errorf("failed to open alias %d under the outgoing key: %w", a.id, err)
		}
		newPseudonym, err := newEnc.Pseudonym(tenantID, string(plaintext))
		if err != nil {
			return nil, fmt.Errorf("failed to re-derive pseudonym for alias %d: %w", a.id, err)
		}
		resealed, err := newEnc.EncryptEnvelope(plaintext, AliasEnvelopeAAD(a.actorID, a.aliasType, newPseudonym))
		if err != nil {
			return nil, fmt.Errorf("failed to re-seal alias %d under the incoming key: %w", a.id, err)
		}
		res, err := tx.ExecContext(ctx,
			`UPDATE aliases SET alias_value_hash = $1, alias_value_encrypted = $2 WHERE id = $3`,
			newPseudonym, resealed, a.id)
		if err != nil {
			return nil, fmt.Errorf("failed to rotate alias %d: %w", a.id, err)
		}
		n, err := res.RowsAffected()
		if err != nil {
			return nil, fmt.Errorf("failed to read rows affected for alias %d: %w", a.id, err)
		}
		report.Rewritten += int(n)
	}

	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("failed to commit pseudonym rotation: %w", err)
	}

	slog.Info("pseudonym epoch rotation complete",
		"delegations", len(delTodo), "aliases", report.Rewritten, "tenant", tenantID)
	return report, nil
}

// RollbackAliasEncryption is the data half of the 005 rollback: it decrypts alias_value_encrypted
// back into the cleartext alias_value column so that
// 005_pseudonymisation_and_encryption_rollback.sql can restore NOT NULL and the cleartext indexes.
//
// Run this BEFORE the rollback SQL. The rollback SQL's `ALTER COLUMN alias_value SET NOT NULL`
// will fail if this step was skipped, which is the intended guard.
//
// This re-materialises cleartext identifiers in the heap. It is an incident-response action.
func RollbackAliasEncryption(ctx context.Context, db *sql.DB, enc Encryptor) (*AliasBackfillReport, error) {
	if db == nil {
		return nil, fmt.Errorf("identity: cannot roll back alias encryption on a nil db connection")
	}
	if enc == nil {
		return nil, fmt.Errorf("identity: cannot roll back alias encryption without an Encryptor")
	}

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to begin alias rollback transaction: %w", err)
	}
	defer tx.Rollback()

	// The fail-closed constraint forbids a row holding cleartext and ciphertext simultaneously,
	// so it must come off before the decrypt pass repopulates alias_value.
	if _, err := tx.ExecContext(ctx, `ALTER TABLE aliases DROP CONSTRAINT IF EXISTS chk_aliases_pseudonymised`); err != nil {
		return nil, fmt.Errorf("failed to drop chk_aliases_pseudonymised before rollback: %w", err)
	}

	// The 005 trigger is BEFORE INSERT OR UPDATE and refuses any row with a NULL
	// alias_value_encrypted. The rollback's whole job is to produce exactly such rows, so the
	// trigger rejects the rollback's own UPDATEs — found by TestAliasPG_RollbackRestoresCleartext
	// against a live database, which is the only place this is observable.
	//
	// Dropping it here is safe and is not a bypass: it happens inside this transaction, and
	// 005_pseudonymisation_and_encryption_rollback.sql re-creates the original cleartext-comparing
	// trigger as its first act. If that SQL is not run afterwards the table is left without an
	// alias trigger, which is why the two halves are documented as one procedure.
	if _, err := tx.ExecContext(ctx, `DROP TRIGGER IF EXISTS trg_aliases_never_merge ON aliases`); err != nil {
		return nil, fmt.Errorf("failed to drop trg_aliases_never_merge before rollback: %w", err)
	}

	rows, err := tx.QueryContext(ctx,
		`SELECT id, actor_id, alias_type, alias_value_hash, alias_value_encrypted FROM aliases
		 WHERE alias_value_encrypted IS NOT NULL ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("failed to read encrypted alias rows: %w", err)
	}

	type pending struct {
		id                            int64
		actorID, aliasType, pseudonym string
		sealed                        []byte
	}
	var todo []pending
	for rows.Next() {
		var p pending
		if err := rows.Scan(&p.id, &p.actorID, &p.aliasType, &p.pseudonym, &p.sealed); err != nil {
			rows.Close()
			return nil, fmt.Errorf("failed to scan encrypted alias row: %w", err)
		}
		todo = append(todo, p)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, fmt.Errorf("encrypted alias row iteration error: %w", err)
	}
	rows.Close()

	report := &AliasBackfillReport{Scanned: len(todo)}

	for _, p := range todo {
		plaintext, err := enc.DecryptEnvelope(p.sealed, AliasEnvelopeAAD(p.actorID, p.aliasType, p.pseudonym))
		if err != nil {
			return nil, fmt.Errorf("failed to decrypt alias row %d: %w", p.id, err)
		}
		res, err := tx.ExecContext(ctx,
			`UPDATE aliases SET alias_value = $1, alias_value_encrypted = NULL WHERE id = $2`,
			string(plaintext), p.id)
		if err != nil {
			return nil, fmt.Errorf("failed to restore alias row %d: %w", p.id, err)
		}
		n, err := res.RowsAffected()
		if err != nil {
			return nil, fmt.Errorf("failed to read rows affected for alias row %d: %w", p.id, err)
		}
		report.Rewritten += int(n)
	}

	if err := tx.QueryRowContext(ctx, `SELECT count(*) FROM aliases WHERE alias_value IS NULL`).Scan(&report.MissingCiphertext); err != nil {
		return nil, fmt.Errorf("failed to count rows still missing cleartext: %w", err)
	}
	if report.MissingCiphertext != 0 {
		return nil, fmt.Errorf("identity: alias rollback incomplete, %d rows still have NULL alias_value", report.MissingCiphertext)
	}

	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("failed to commit alias rollback: %w", err)
	}

	slog.Warn("alias encryption ROLLED BACK; cleartext identifiers are re-materialised in the heap",
		"scanned", report.Scanned, "restored", report.Rewritten)
	return report, nil
}
