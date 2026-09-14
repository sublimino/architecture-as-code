// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package retention

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
)

// PostgresLedger persists receipts to retention_deletion_receipts (migration 010).
//
// Tenant scoping is enforced twice, matching privacy.PostgresIncidentSource: the WHERE clause here and
// the row-level security policy migration 010 installs. Belt-and-braces because SLDP-P2-2's finding
// was that WHERE-clause-only isolation has no database backstop — zero ENABLE ROW LEVEL SECURITY
// statements existed in the repository while 151 files referenced tenant_id.
//
// Note which way a missing tenant claim fails for THIS table. Reading zero receipt rows makes every
// copy look outstanding, so a misconfiguration inflates the overdue gauge rather than clearing it. A
// retention ledger must fail toward "we cannot prove deletion", never toward "everything is deleted".
type PostgresLedger struct {
	db *sql.DB
}

// NewPostgresLedger constructs a database-backed ledger.
func NewPostgresLedger(db *sql.DB) (*PostgresLedger, error) {
	if db == nil {
		return nil, errors.New("retention: database handle is required")
	}
	return &PostgresLedger{db: db}, nil
}

// recordStatement is the idempotent upsert.
//
// ON CONFLICT (operation_id) is the idempotence guarantee, enforced by the database rather than by
// application bookkeeping. operation_id is SHA-256(tenant, sink, boundary) and excludes the nonce, so
// a resumed sweep recomputes the same key and collapses onto the same row.
//
// The DO UPDATE arm is deliberately narrow: it advances an INCOMPLETE row to a complete one, and
// refuses to move a complete row backwards. Without the WHERE, a later unreachable receipt would
// overwrite an earlier successful purge and the copy would silently reappear as outstanding — a
// working control reporting its own success as a failure, which trains operators to ignore it.
const recordStatement = `
INSERT INTO retention_deletion_receipts (
    operation_id, schema_version, tenant_id, sink_id, sink_class, disposition,
    dropped_before, propagation_deadline, evaluated_at, completed_at,
    records_removed, partitions_dropped, clock_source, hold_ids, linkage_receipts,
    receipt_nonce, receipt_digest, residual_state, compliance_note
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19)
ON CONFLICT (operation_id) DO UPDATE SET
    disposition          = EXCLUDED.disposition,
    completed_at         = EXCLUDED.completed_at,
    records_removed      = EXCLUDED.records_removed,
    partitions_dropped   = EXCLUDED.partitions_dropped,
    evaluated_at         = EXCLUDED.evaluated_at,
    hold_ids             = EXCLUDED.hold_ids,
    linkage_receipts     = EXCLUDED.linkage_receipts,
    receipt_nonce        = EXCLUDED.receipt_nonce,
    receipt_digest       = EXCLUDED.receipt_digest,
    residual_state       = EXCLUDED.residual_state,
    compliance_note      = EXCLUDED.compliance_note
WHERE retention_deletion_receipts.completed_at IS NULL
`

// Record implements Ledger.
func (l *PostgresLedger) Record(ctx context.Context, receipt DeletionReceipt) error {
	if err := receipt.VerifyDigest(); err != nil {
		return fmt.Errorf("%w: %v", ErrLedgerRefused, err)
	}
	var completed any
	if !receipt.CompletedAt.IsZero() {
		completed = receipt.CompletedAt.UTC().Truncate(time.Microsecond)
	}
	_, err := l.db.ExecContext(ctx, recordStatement,
		receipt.OperationID, receipt.Schema, receipt.TenantID, receipt.SinkID, receipt.SinkClass,
		string(receipt.Disposition),
		receipt.DroppedBefore.UTC().Truncate(time.Microsecond),
		receipt.PropagationDeadline.UTC().Truncate(time.Microsecond),
		receipt.EvaluatedAt.UTC().Truncate(time.Microsecond),
		completed,
		receipt.RecordsRemoved, receipt.PartitionsDropped, receipt.ClockSource,
		textArray(receipt.HoldIDs), textArray(receipt.LinkageReceipts),
		receipt.ReceiptNonce, receipt.ReceiptDigest, receipt.ResidualState, receipt.ComplianceNote,
	)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrLedgerUnavailable, err)
	}
	return nil
}

const getStatement = `
SELECT operation_id, schema_version, tenant_id, sink_id, sink_class, disposition,
       dropped_before, propagation_deadline, evaluated_at, completed_at,
       records_removed, partitions_dropped, clock_source, hold_ids, linkage_receipts,
       receipt_nonce, receipt_digest, residual_state, compliance_note
FROM retention_deletion_receipts
WHERE tenant_id = $1 AND operation_id = $2
`

// Get implements Ledger.
func (l *PostgresLedger) Get(ctx context.Context, tenantID, operationID string) (DeletionReceipt, bool, error) {
	row := l.db.QueryRowContext(ctx, getStatement, tenantID, operationID)
	receipt, err := scanReceipt(row)
	if errors.Is(err, sql.ErrNoRows) {
		return DeletionReceipt{}, false, nil
	}
	if err != nil {
		return DeletionReceipt{}, false, fmt.Errorf("%w: %v", ErrLedgerUnavailable, err)
	}
	return receipt, true, nil
}

// latestStatement returns the most recent receipt per sink for a tenant.
//
// DISTINCT ON rather than a GROUP BY with a max: the row body is needed, not just the timestamp, and a
// GROUP BY that returned the max evaluated_at and then joined back would pick an arbitrary row on a
// tie. A tie is reachable here because two sinks can be evaluated inside the same microsecond.
const latestStatement = `
SELECT DISTINCT ON (sink_id)
       operation_id, schema_version, tenant_id, sink_id, sink_class, disposition,
       dropped_before, propagation_deadline, evaluated_at, completed_at,
       records_removed, partitions_dropped, clock_source, hold_ids, linkage_receipts,
       receipt_nonce, receipt_digest, residual_state, compliance_note
FROM retention_deletion_receipts
WHERE tenant_id = $1
ORDER BY sink_id, evaluated_at DESC, operation_id DESC
`

// Outstanding implements Ledger.
func (l *PostgresLedger) Outstanding(ctx context.Context, tenantID string, expected []SinkSpec, asOf time.Time) ([]Outstanding, error) {
	rows, err := l.db.QueryContext(ctx, latestStatement, tenantID)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrLedgerUnavailable, err)
	}
	defer rows.Close()

	latest := make(map[string]DeletionReceipt)
	for rows.Next() {
		receipt, err := scanReceipt(rows)
		if err != nil {
			return nil, fmt.Errorf("%w: %v", ErrLedgerUnavailable, err)
		}
		latest[receipt.SinkID] = receipt
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrLedgerUnavailable, err)
	}

	var out []Outstanding
	for _, spec := range expected {
		receipt, seen := latest[spec.ID]
		if seen && receipt.Disposition.Complete() {
			continue
		}
		entry := Outstanding{TenantID: tenantID, SinkID: spec.ID, SinkClass: string(spec.Class)}
		if seen {
			entry.Disposition = receipt.Disposition
			entry.Deadline = receipt.PropagationDeadline
			entry.LastEvaluated = receipt.EvaluatedAt
			entry.HoldIDs = receipt.HoldIDs
		} else {
			entry.Deadline = asOf.Add(MaxPropagationDelay)
		}
		out = append(out, entry)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].SinkID < out[j].SinkID })
	return out, nil
}

const completedDigestsStatement = `
SELECT DISTINCT ON (sink_id) sink_id, receipt_digest
FROM retention_deletion_receipts
WHERE tenant_id = $1
  AND completed_at IS NOT NULL
  AND sink_id = ANY($2)
ORDER BY sink_id, evaluated_at DESC, operation_id DESC
`

// CompletedDigests implements Ledger.
func (l *PostgresLedger) CompletedDigests(ctx context.Context, tenantID string, sinkIDs []string) ([]string, error) {
	rows, err := l.db.QueryContext(ctx, completedDigestsStatement, tenantID, textArray(sinkIDs))
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrLedgerUnavailable, err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var sink, digest string
		if err := rows.Scan(&sink, &digest); err != nil {
			return nil, fmt.Errorf("%w: %v", ErrLedgerUnavailable, err)
		}
		out = append(out, digest)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrLedgerUnavailable, err)
	}
	sort.Strings(out)
	return out, nil
}

const earliestOpenDeadlineStatement = `
SELECT MIN(propagation_deadline)
FROM retention_deletion_receipts
WHERE tenant_id = $1 AND sink_id = $2 AND completed_at IS NULL
`

// EarliestOpenDeadline implements Ledger. See the interface comment for why this exists.
func (l *PostgresLedger) EarliestOpenDeadline(ctx context.Context, tenantID, sinkID string) (time.Time, bool, error) {
	var deadline sql.NullTime
	if err := l.db.QueryRowContext(ctx, earliestOpenDeadlineStatement, tenantID, sinkID).Scan(&deadline); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return time.Time{}, false, nil
		}
		return time.Time{}, false, fmt.Errorf("%w: %v", ErrLedgerUnavailable, err)
	}
	if !deadline.Valid {
		return time.Time{}, false, nil
	}
	return deadline.Time.UTC(), true, nil
}

// scanner is satisfied by both *sql.Row and *sql.Rows.
type scanner interface {
	Scan(dest ...any) error
}

func scanReceipt(s scanner) (DeletionReceipt, error) {
	var (
		r         DeletionReceipt
		disp      string
		completed sql.NullTime
		holds     string
		linkage   string
	)
	err := s.Scan(
		&r.OperationID, &r.Schema, &r.TenantID, &r.SinkID, &r.SinkClass, &disp,
		&r.DroppedBefore, &r.PropagationDeadline, &r.EvaluatedAt, &completed,
		&r.RecordsRemoved, &r.PartitionsDropped, &r.ClockSource, &holds, &linkage,
		&r.ReceiptNonce, &r.ReceiptDigest, &r.ResidualState, &r.ComplianceNote,
	)
	if err != nil {
		return DeletionReceipt{}, err
	}
	r.Disposition = Disposition(disp)
	if completed.Valid {
		r.CompletedAt = completed.Time.UTC()
	}
	r.HoldIDs = parseTextArray(holds)
	r.LinkageReceipts = parseTextArray(linkage)
	r.DroppedBefore = r.DroppedBefore.UTC()
	r.PropagationDeadline = r.PropagationDeadline.UTC()
	r.EvaluatedAt = r.EvaluatedAt.UTC()
	return r, nil
}

// textArray renders a Go slice as a PostgreSQL array literal.
//
// Hand-rendered rather than via pq.Array because this module's Postgres access is database/sql with no
// driver-specific array helper imported elsewhere, and adding one for two columns would be a new
// dependency for a formatting problem. Element quoting escapes backslashes and double quotes, which is
// the full set PostgreSQL's array input syntax treats specially inside a quoted element.
func textArray(values []string) string {
	if len(values) == 0 {
		return "{}"
	}
	parts := make([]string, 0, len(values))
	for _, v := range values {
		escaped := strings.ReplaceAll(v, `\`, `\\`)
		escaped = strings.ReplaceAll(escaped, `"`, `\"`)
		parts = append(parts, `"`+escaped+`"`)
	}
	return "{" + strings.Join(parts, ",") + "}"
}

// parseTextArray parses a PostgreSQL text[] literal.
func parseTextArray(raw string) []string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" || trimmed == "{}" {
		return nil
	}
	trimmed = strings.TrimPrefix(trimmed, "{")
	trimmed = strings.TrimSuffix(trimmed, "}")

	var (
		out     []string
		current strings.Builder
		inQuote bool
		escaped bool
	)
	for _, ch := range trimmed {
		switch {
		case escaped:
			current.WriteRune(ch)
			escaped = false
		case ch == '\\':
			escaped = true
		case ch == '"':
			inQuote = !inQuote
		case ch == ',' && !inQuote:
			out = append(out, current.String())
			current.Reset()
		default:
			current.WriteRune(ch)
		}
	}
	if current.Len() > 0 {
		out = append(out, current.String())
	}
	return out
}
