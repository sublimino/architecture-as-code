package audit

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"regexp"
	"strings"
)

// EventTypeConstraintName is the CHECK constraint on signal_audit_trail that
// lists the admitted event types. fe-signalloom owns it (its migrations
// define it, most recently 051_batch_chain_event_type.sql).
const EventTypeConstraintName = "signal_audit_trail_event_type_check"

// ErrEventTypeConstraintAbsent: the constraint (or the table) does not exist,
// so nothing shows the database will accept this service's event types --
// typically a half-applied migration. Readiness treats it as not admitted.
var ErrEventTypeConstraintAbsent = errors.New(EventTypeConstraintName + " is absent from signal_audit_trail")

// ConstraintSource returns the event_type constraint's definition as
// pg_get_constraintdef prints it; found is false when it does not exist.
type ConstraintSource func(ctx context.Context) (def string, found bool, err error)

// VocabularyError names the event types this service emits that the live
// constraint does not admit. Every audit write of one would fail.
type VocabularyError struct {
	Missing []EventType
}

func (e *VocabularyError) Error() string {
	names := make([]string, len(e.Missing))
	for i, t := range e.Missing {
		names[i] = string(t)
	}
	return fmt.Sprintf("%s does not admit event type(s) %s: the migration that adds them has not run; "+
		"roll fe-signalloom (it owns the migrations) before signal-ingest", EventTypeConstraintName, strings.Join(names, ","))
}

// MissingNames returns the missing types comma-separated, for a probe body.
func (e *VocabularyError) MissingNames() string {
	names := make([]string, len(e.Missing))
	for i, t := range e.Missing {
		names[i] = string(t)
	}
	return strings.Join(names, ",")
}

var (
	eventTypeColumn = regexp.MustCompile(`\bevent_type\b`)
	quotedLiteral   = regexp.MustCompile(`'((?:[^']|'')*)'`)
)

// admittedEventTypes reads the literals a definition admits. A definition
// that does not test event_type against literals cannot be shown to admit
// anything, so it is an error rather than an empty set.
func admittedEventTypes(def string) (map[string]bool, error) {
	if !eventTypeColumn.MatchString(def) {
		return nil, fmt.Errorf("%s does not constrain event_type: %q", EventTypeConstraintName, def)
	}
	admitted := map[string]bool{}
	for _, m := range quotedLiteral.FindAllStringSubmatch(def, -1) {
		admitted[strings.ReplaceAll(m[1], "''", "'")] = true
	}
	if len(admitted) == 0 {
		return nil, fmt.Errorf("%s lists no admitted event types: %q", EventTypeConstraintName, def)
	}
	return admitted, nil
}

// CheckVocabulary reports whether the live constraint admits every type in
// types. It fails closed: a query error, an absent constraint and an
// unreadable definition are all errors, never a pass.
func CheckVocabulary(ctx context.Context, src ConstraintSource, types []EventType) error {
	def, found, err := src(ctx)
	if err != nil {
		return fmt.Errorf("read %s: %w", EventTypeConstraintName, err)
	}
	if !found {
		return ErrEventTypeConstraintAbsent
	}
	admitted, err := admittedEventTypes(def)
	if err != nil {
		return err
	}
	var missing []EventType
	for _, t := range types {
		if !admitted[string(t)] {
			missing = append(missing, t)
		}
	}
	if len(missing) > 0 {
		return &VocabularyError{Missing: missing}
	}
	return nil
}

// EventTypeConstraint is the ConstraintSource for a live database.
// to_regclass yields NULL for a missing table, so a missing table is
// "absent" (no row) rather than a query error.
func (p *PostgresWriter) EventTypeConstraint(ctx context.Context) (string, bool, error) {
	const q = `SELECT pg_get_constraintdef(con.oid)
		FROM pg_constraint con
		WHERE con.conrelid = to_regclass('public.signal_audit_trail')
		  AND con.conname = $1`
	var def string
	err := p.db.QueryRowContext(ctx, q, EventTypeConstraintName).Scan(&def)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return def, true, nil
}
