//go:build frostdb

package store

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/apache/arrow-go/v18/arrow"
	"github.com/apache/arrow-go/v18/arrow/array"
	"github.com/apache/arrow-go/v18/arrow/memory"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/transform"
	"github.com/polarsignals/frostdb"
	"github.com/polarsignals/frostdb/query"
	"github.com/polarsignals/frostdb/query/logicalplan"
	"github.com/thanos-io/objstore"
	"github.com/thanos-io/objstore/providers/filesystem"

	schemapb "github.com/polarsignals/frostdb/gen/proto/go/frostdb/schema/v1alpha1"
)

const (
	tableName = "observations"
	dbName    = "signaldb"
)

// FrostDBStore persists signal observations in an embedded FrostDB (Parquet).
type FrostDBStore struct {
	cs            *frostdb.ColumnStore
	db            *frostdb.DB
	table         *frostdb.Table
	engine        *query.LocalEngine
	pool          memory.Allocator
	droppedBefore time.Time
	mu            sync.RWMutex
	attestor      *SegmentAttestor
	pseudonymiser *SegmentPseudonymiser
	labelAllow    map[string]struct{}
}

type frostDBStoreConfig struct {
	manualFlush bool
	// activeMemoryBytes bounds the in-memory active block before FrostDB rotates it to
	// Parquet. Zero means DefaultActiveMemoryBytes.
	activeMemoryBytes int64
	attestation       *SegmentAttestorConfig
	pseudonymiser     *SegmentPseudonymiser
	labelAllow        map[string]struct{}
	labelAllowSet     bool
	labelAllowErr     error
}

// FrostDBStoreOption configures persistence behavior without changing queries.
type FrostDBStoreOption func(*frostDBStoreConfig)

// WithSegmentPseudonymiser supplies the keyed pseudonymiser used to convert direct identifiers
// into segment columns. Without one — by option or by environment — the store refuses to be
// constructed; see resolvePseudonymiser.
func WithSegmentPseudonymiser(p *SegmentPseudonymiser) FrostDBStoreOption {
	return func(cfg *frostDBStoreConfig) { cfg.pseudonymiser = p }
}

// WithLabelAllowList replaces the built-in dynamic-label allow-list.
//
// A nil or empty set is an error rather than a permit-all. The error is carried on the config and
// surfaced at construction, because an Option cannot return one and silently ignoring it would
// produce a store whose label control is configured and inert.
func WithLabelAllowList(set map[string]struct{}) FrostDBStoreOption {
	return func(cfg *frostDBStoreConfig) {
		if err := validateLabelAllowList(set); err != nil {
			cfg.labelAllowErr = err
			return
		}
		out := make(map[string]struct{}, len(set))
		for k := range set {
			out[k] = struct{}{}
		}
		cfg.labelAllow = out
		cfg.labelAllowSet = true
	}
}

// resolvePseudonymiser returns the configured pseudonymiser, falling back to the environment.
//
// It fails closed. There is no compiled-in default key and no passthrough mode: a process that
// cannot pseudonymise must refuse to start rather than write cleartext identity into an immutable,
// signed segment that can never afterwards be erased.
func resolvePseudonymiser(cfg *frostDBStoreConfig) (*SegmentPseudonymiser, error) {
	if cfg.pseudonymiser != nil {
		return cfg.pseudonymiser, nil
	}
	return NewSegmentPseudonymiserFromEnv()
}

// WithManualFlush disables automatic size rotation and exposes Flush as the
// deterministic immutable-segment boundary used by integration tests.
func WithManualFlush() FrostDBStoreOption {
	return func(cfg *frostDBStoreConfig) { cfg.manualFlush = true }
}

// DefaultActiveMemoryBytes is the active-block ceiling when no option or environment sets one.
//
// FrostDB's own default is 512 MiB, which on 2026-10-06 was exactly the pod's memory limit on
// kind-osramp: the active block was allowed to grow to the whole container before rotation, so
// the dashboard's four concurrent reads tipped the pod into an OOM kill, and every row in that
// block went with it. 64 MiB rotates often enough that a kill costs little and the WAL replays
// the rest.
const DefaultActiveMemoryBytes = 64 << 20

// WithActiveMemoryBytes bounds the in-memory active block. Values below 1 MiB are refused at
// construction rather than clamped, so a mis-set environment variable cannot quietly produce a
// store that rotates on every row.
func WithActiveMemoryBytes(n int64) FrostDBStoreOption {
	return func(cfg *frostDBStoreConfig) { cfg.activeMemoryBytes = n }
}

// WithSegmentAttestation signs each successfully persisted immutable segment.
func WithSegmentAttestation(cfg SegmentAttestorConfig) FrostDBStoreOption {
	return func(storeCfg *frostDBStoreConfig) { storeCfg.attestation = &cfg }
}

// NewFrostDBStore creates a new in-memory FrostDB-backed store.
//
// It resolves its pseudonymiser from the environment and returns
// ErrSegmentPseudonymKeyRequired when no key material is available.
func NewFrostDBStore(options ...FrostDBStoreOption) (*FrostDBStore, error) {
	cfg := frostDBStoreConfig{}
	for _, option := range options {
		option(&cfg)
	}
	return newFrostDBStore(&cfg, nil)
}

// NewFrostDBStoreWithBucket creates a FrostDB store backed by a filesystem
// directory so Parquet files are persisted to disk.
func NewFrostDBStoreWithBucket(dir string, options ...FrostDBStoreOption) (*FrostDBStore, error) {
	cfg := frostDBStoreConfig{}
	for _, option := range options {
		option(&cfg)
	}
	bucket, err := filesystem.NewBucket(dir)
	if err != nil {
		return nil, fmt.Errorf("frostdb: filesystem bucket: %w", err)
	}
	var attestor *SegmentAttestor
	var storageBucket objstore.Bucket = bucket
	if cfg.attestation != nil {
		// Inventory the same bucket we wrap, including programmatic callers
		// that do not use the environment factory. Never trust a second root.
		cfg.attestation.SegmentRoot = dir
		attestor, err = NewSegmentAttestor(*cfg.attestation)
		if err != nil {
			_ = bucket.Close()
			return nil, fmt.Errorf("frostdb: segment attestor: %w", err)
		}
		storageBucket = newAttestingBucket(bucket, attestor)
	}
	sink := frostdb.NewDefaultObjstoreBucket(storageBucket)
	active := cfg.activeMemoryBytes
	if active == 0 {
		active = DefaultActiveMemoryBytes
	}
	if active < 1<<20 {
		_ = bucket.Close()
		return nil, fmt.Errorf("frostdb: active memory %d bytes is below the 1 MiB floor", active)
	}
	// The WAL under dir/databases/<db>/wal is what makes an acknowledged Append survive the
	// process: without it every row in the un-rotated active block is lost on a crash or an OOM
	// kill, which contradicts the "no loss for any source" decision (proposal D1). The WAL is
	// truncated when a block persists to the bucket, so it never outgrows one active block.
	// Residual, stated: FrostDB writes the WAL from a goroutine on a 50 ms tick and has no
	// synchronous flush, so a kill inside that tick loses the rows acked in it. See
	// TestFrostDB_UnrotatedRowsSurviveAbandonedProcess.
	frostOptions := []frostdb.Option{
		frostdb.WithReadWriteStorage(sink),
		frostdb.WithStoragePath(dir),
		frostdb.WithWAL(),
		frostdb.WithActiveMemorySize(active),
	}
	if cfg.manualFlush {
		frostOptions = append(frostOptions, frostdb.WithManualBlockRotation())
	}
	store, err := newFrostDBStore(&cfg, attestor, frostOptions...)
	if err != nil && attestor != nil {
		_ = attestor.Close()
	}
	return store, err
}

func newFrostDBStore(cfg *frostDBStoreConfig, attestor *SegmentAttestor, opts ...frostdb.Option) (*FrostDBStore, error) {
	if cfg == nil {
		cfg = &frostDBStoreConfig{}
	}
	// Refuse before allocating anything. A store that cannot pseudonymise, or whose label control
	// was configured into an inert state, must not exist at all.
	if cfg.labelAllowErr != nil {
		return nil, cfg.labelAllowErr
	}
	pseudonymiser, err := resolvePseudonymiser(cfg)
	if err != nil {
		return nil, err
	}
	labelAllow := cfg.labelAllow
	if !cfg.labelAllowSet {
		labelAllow = DefaultLabelAllowList()
	}

	cs, err := frostdb.New(opts...)
	if err != nil {
		return nil, fmt.Errorf("frostdb: new column store: %w", err)
	}

	db, err := cs.DB(context.Background(), dbName)
	if err != nil {
		cs.Close()
		return nil, fmt.Errorf("frostdb: new db: %w", err)
	}

	schema := schemaDef()
	if err := validateFilterColumns(schema); err != nil {
		cs.Close()
		return nil, err
	}
	tbl, err := db.Table(tableName, frostdb.NewTableConfig(schema))
	if err != nil {
		cs.Close()
		return nil, fmt.Errorf("frostdb: new table: %w", err)
	}

	pool := memory.NewGoAllocator()
	engine := query.NewEngine(pool, db.TableProvider())

	return &FrostDBStore{
		cs:            cs,
		db:            db,
		table:         tbl,
		engine:        engine,
		pool:          pool,
		attestor:      attestor,
		pseudonymiser: pseudonymiser,
		labelAllow:    labelAllow,
	}, nil
}

// Pseudonymiser exposes the store's keyed pseudonymiser so a caller can compute the pseudonym of a
// query value, and so evidence can record the epoch and tenant scope the segments were written
// under. It never returns nil on a constructed store.
func (f *FrostDBStore) Pseudonymiser() *SegmentPseudonymiser { return f.pseudonymiser }

// AllowsLabelKey reports whether Append would admit label key k under this store's allow-list,
// so a caller that owns a corpus (the fixture seed) can project onto it instead of having the
// whole batch refused.
func (f *FrostDBStore) AllowsLabelKey(k string) bool {
	_, ok := f.labelAllow[k]
	return ok
}

// schemaDef declares the v2 segment column layout (SegmentSchemaV2).
//
// SLDP-P3-1 removed the six cleartext identifier columns listed in v1RemovedColumns and replaced
// them with keyed pseudonyms. Existing v1 segments are NOT rewritten — Parquet segments are signed
// and chained, so rewriting one breaks its attestation and the checkpoint continuity after it.
// Segments of both generations therefore coexist in the bucket indefinitely, and
// recordToObservations decodes whichever it is handed.
func schemaDef() *schemapb.Schema {
	str := func(name string) *schemapb.Column {
		return &schemapb.Column{Name: name, StorageLayout: &schemapb.StorageLayout{Type: schemapb.StorageLayout_TYPE_STRING}}
	}
	return &schemapb.Schema{
		Columns: []*schemapb.Column{
			str("id"),
			{Name: "timestamp", StorageLayout: &schemapb.StorageLayout{Type: schemapb.StorageLayout_TYPE_INT64}},
			str("layer"),
			str("fidelity"),
			str("source"),
			{Name: "confidence", StorageLayout: &schemapb.StorageLayout{Type: schemapb.StorageLayout_TYPE_DOUBLE}},
			str("description"),
			{Name: "delegation_depth", StorageLayout: &schemapb.StorageLayout{Type: schemapb.StorageLayout_TYPE_INT64}},
			// Self-describing generation marker. A segment without this column is v1.
			str(SegmentSchemaVersionColumn),
			// Keyed pseudonyms. Equality on these is equality on the plaintext, so predicate
			// pushdown is preserved exactly — which is why these are HMACs and not ciphertext.
			str(ColHMACActorHint),
			str(ColHMACActorID),
			str(ColHMACPrincipalID),
			str(ColHMACSessionID),
			str(ColHMACImpersonatedUser),
			str(ColEvidenceRefDigest),
			{
				Name: "labels",
				StorageLayout: &schemapb.StorageLayout{
					Type: schemapb.StorageLayout_TYPE_STRING,
				},
				Dynamic: true,
			},
		},
	}
}

// Append writes observations into FrostDB as Arrow records under segment schema v2.
//
// Two controls run before a single Arrow builder is allocated, because a segment is immutable and
// signed: once a row is in a Parquet block there is no later pass that can take it out.
//
//  1. Every dynamic label key is checked against the allow-list. A disallowed key refuses the
//     whole batch. Checking at query time instead would be no control at all — the data would
//     already be in the segment.
//  2. Every direct identifier is replaced by a keyed pseudonym. Nothing in v1RemovedColumns is
//     written.
func (f *FrostDBStore) Append(ctx context.Context, observations []model.Observation) error {
	f.mu.Lock()
	defer f.mu.Unlock()

	if f.pseudonymiser == nil {
		// Unreachable on a store built through the constructors, which refuse without key
		// material. Kept as a fail-closed backstop for a zero-valued struct.
		return ErrSegmentPseudonymKeyRequired
	}

	// Collect all dynamic label keys across this batch, refusing any key outside the allow-list.
	// The refusal happens here, ahead of array.NewRecordBuilder, so a rejected key never reaches a
	// record, a block, a Parquet file or an attestation.
	dynCols := map[string]struct{}{}
	for _, o := range observations {
		for k := range o.Labels {
			if _, ok := f.labelAllow[k]; !ok {
				return &DisallowedLabelKeyError{Key: k, ObservationID: o.ID}
			}
			dynCols[k] = struct{}{}
		}
	}
	dynNames := make([]string, 0, len(dynCols))
	for k := range dynCols {
		dynNames = append(dynNames, k)
	}
	sort.Strings(dynNames)

	// Pseudonymise the whole batch before building anything, so a pseudonymisation failure aborts
	// with nothing written rather than leaving a partially-identified record.
	pseudonyms := make([]observationPseudonyms, len(observations))
	descriptions := make([]string, len(observations))
	for i, o := range observations {
		p, err := f.pseudonymiseObservation(o)
		if err != nil {
			return err
		}
		pseudonyms[i] = p
		// `description` is the one free-text column surviving into v2, and it is redacted HERE
		// rather than at any caller.
		//
		// Redacting at a caller was the original mistake: `api/audit/receiver.go` was fixed and
		// the other seven writers were not, so `POST /api/v1/observations` could still put an
		// attacker-supplied "alice@corp.com from 10.0.0.5" into a signed, unerasable segment while
		// every schema-level test stayed green — those tests inspect column NAMES and are blind to
		// the payload. A guard applied by one caller of eight is the same as no guard. Append is
		// the single chokepoint every writer crosses, so the guard belongs at the chokepoint.
		descriptions[i] = redactHomeDirectoryUserInText(segmentDescriptionRedactor.RedactText(o.Description))
	}

	// Build Arrow schema: static columns + dynamic label columns, alphabetically ordered.
	// "labels." sorts after "id" and before "layer", which is where the dynamic block belongs.
	fields := []arrow.Field{
		{Name: "confidence", Type: arrow.PrimitiveTypes.Float64},
		{Name: "delegation_depth", Type: arrow.PrimitiveTypes.Int64},
		{Name: "description", Type: arrow.BinaryTypes.String},
		{Name: ColEvidenceRefDigest, Type: arrow.BinaryTypes.String},
		{Name: "fidelity", Type: arrow.BinaryTypes.String},
		{Name: ColHMACActorHint, Type: arrow.BinaryTypes.String},
		{Name: ColHMACActorID, Type: arrow.BinaryTypes.String},
		{Name: ColHMACImpersonatedUser, Type: arrow.BinaryTypes.String},
		{Name: ColHMACPrincipalID, Type: arrow.BinaryTypes.String},
		{Name: ColHMACSessionID, Type: arrow.BinaryTypes.String},
		{Name: "id", Type: arrow.BinaryTypes.String},
	}
	for _, k := range dynNames {
		fields = append(fields, arrow.Field{Name: LabelColumnPrefix + k, Type: arrow.BinaryTypes.String, Nullable: true})
	}
	fields = append(fields,
		arrow.Field{Name: "layer", Type: arrow.BinaryTypes.String},
		arrow.Field{Name: SegmentSchemaVersionColumn, Type: arrow.BinaryTypes.String},
		arrow.Field{Name: "source", Type: arrow.BinaryTypes.String},
		arrow.Field{Name: "timestamp", Type: arrow.PrimitiveTypes.Int64},
	)

	arrowSchema := arrow.NewSchema(fields, nil)
	builder := array.NewRecordBuilder(f.pool, arrowSchema)
	defer builder.Release()

	for i, o := range observations {
		p := pseudonyms[i]
		idx := 0
		builder.Field(idx).(*array.Float64Builder).Append(o.Confidence)
		idx++
		builder.Field(idx).(*array.Int64Builder).Append(int64(o.DelegationDepth))
		idx++
		builder.Field(idx).(*array.StringBuilder).Append(descriptions[i])
		idx++
		builder.Field(idx).(*array.StringBuilder).Append(p.EvidenceRefDigest)
		idx++
		builder.Field(idx).(*array.StringBuilder).Append(string(o.Fidelity))
		idx++
		builder.Field(idx).(*array.StringBuilder).Append(p.ActorHint)
		idx++
		builder.Field(idx).(*array.StringBuilder).Append(p.ActorID)
		idx++
		builder.Field(idx).(*array.StringBuilder).Append(p.ImpersonatedUser)
		idx++
		builder.Field(idx).(*array.StringBuilder).Append(p.PrincipalID)
		idx++
		builder.Field(idx).(*array.StringBuilder).Append(p.SessionID)
		idx++
		builder.Field(idx).(*array.StringBuilder).Append(o.ID)
		idx++
		// Dynamic label columns
		for _, k := range dynNames {
			v, ok := o.Labels[k]
			if ok {
				builder.Field(idx).(*array.StringBuilder).Append(redactLabelValue(k, v))
			} else {
				builder.Field(idx).(*array.StringBuilder).AppendNull()
			}
			idx++
		}
		builder.Field(idx).(*array.StringBuilder).Append(string(o.Layer))
		idx++
		builder.Field(idx).(*array.StringBuilder).Append(SegmentSchemaV2)
		idx++
		builder.Field(idx).(*array.StringBuilder).Append(o.Source)
		idx++
		builder.Field(idx).(*array.Int64Builder).Append(o.Timestamp.UnixNano())
	}

	rec := builder.NewRecord()
	defer rec.Release()

	if _, err := f.table.InsertRecord(ctx, rec); err != nil {
		return fmt.Errorf("frostdb: insert record: %w", err)
	}

	return nil
}

// segmentDescriptionRedactor scrubs direct identifiers out of free text on its way into an
// immutable segment. Stateless, so one shared instance is safe.
var segmentDescriptionRedactor = transform.NewSecretRedactor()

// observationPseudonyms holds the keyed replacements for one observation's direct identifiers.
type observationPseudonyms struct {
	ActorHint         string
	ActorID           string
	PrincipalID       string
	SessionID         string
	ImpersonatedUser  string
	EvidenceRefDigest string
}

// pseudonymiseObservation computes every keyed replacement for one observation.
//
// An empty source field yields an empty pseudonym rather than the pseudonym of "": a constant
// digest written into every identity-free row would be a join key linking all of them, which is a
// correlation channel invented by the privacy fix.
func (f *FrostDBStore) pseudonymiseObservation(o model.Observation) (observationPseudonyms, error) {
	var p observationPseudonyms
	var err error
	if p.ActorHint, err = f.pseudonymiser.Pseudonym(o.ActorHint); err != nil {
		return p, err
	}
	if p.ActorID, err = f.pseudonymiser.Pseudonym(o.ActorID); err != nil {
		return p, err
	}
	if p.PrincipalID, err = f.pseudonymiser.Pseudonym(o.PrincipalID); err != nil {
		return p, err
	}
	if p.SessionID, err = f.pseudonymiser.Pseudonym(o.SessionID); err != nil {
		return p, err
	}
	if p.ImpersonatedUser, err = f.pseudonymiser.Pseudonym(o.ImpersonatedUser); err != nil {
		return p, err
	}
	if p.EvidenceRefDigest, err = f.pseudonymiser.EvidenceRefDigest(o.RawEvidenceRef); err != nil {
		return p, err
	}
	return p, nil
}

// QueryRange reads observations from FrostDB using the query engine with pushed-down filters.
func (f *FrostDBStore) QueryRange(ctx context.Context, q Query) ([]model.Observation, error) {
	f.mu.RLock()
	defer f.mu.RUnlock()

	// A present-but-empty ID set matches nothing, and must do so BEFORE the plan is built:
	// buildFilter emits no `id` predicate for a zero-length list, so without this the query would
	// degrade into the unfiltered whole-table scan it was written to avoid. That is the expensive
	// direction to fail, and it fails silently — the caller still gets rows, just all of them.
	if q.IDs != nil && len(q.IDs) == 0 {
		return nil, nil
	}

	// Fold the retention floor into q.After so engine-level filtering prunes dropped partitions.
	if !f.droppedBefore.IsZero() {
		if q.After.IsZero() || q.After.Before(f.droppedBefore) {
			q.After = f.droppedBefore
		}
	}

	builder := f.engine.ScanTable(tableName).
		Project(logicalplan.All())
	filter, err := buildFilter(q, f.pseudonymiser)
	if err != nil {
		return nil, fmt.Errorf("frostdb: build filter: %w", err)
	}
	if filter != nil {
		builder = builder.Filter(filter)
	}

	var results []model.Observation
	err = builder.Execute(ctx, func(ctx context.Context, r arrow.Record) error {
		if q.Limit > 0 && len(results) >= q.Limit {
			return nil
		}
		obs := recordToObservations(r)
		for _, o := range obs {
			results = append(results, o)
			if q.Limit > 0 && len(results) >= q.Limit {
				break
			}
		}
		return nil
	})
	if q.Offset > 0 {
		if q.Offset >= len(results) {
			return nil, nil
		}
		results = results[q.Offset:]
	}

	if q.Limit > 0 && len(results) > q.Limit {
		results = results[:q.Limit]
	}

	return results, nil
}

// errScanLimitReached unwinds out of the engine callback once q.Limit rows have been
// emitted. It never escapes ScanIDs: a sentinel is the only way to stop a push-based scan
// early, and it is matched by identity with errors.Is so a real engine error of any shape
// still propagates.
var errScanLimitReached = errors.New("store: scan limit reached")

// ScanIDs streams observation IDs without materialising rows.
//
// Two things make this cheap where QueryRange is not. The projection is the id column alone,
// so the engine never decodes the free-text description, the six pseudonym columns or any
// dynamic label column; and nothing is accumulated, so peak memory is one Arrow record
// rather than the whole result.
//
// The filter is applied BEFORE the projection in the plan, so the timestamp predicate still
// pushes down to partition pruning even though timestamp is not in the output.
func (f *FrostDBStore) ScanIDs(ctx context.Context, q Query, fn func(id string) error) error {
	f.mu.RLock()
	defer f.mu.RUnlock()

	// Same retention floor QueryRange applies, so a dropped partition cannot be warmed back
	// into an ID set after it has been swept.
	if !f.droppedBefore.IsZero() {
		if q.After.IsZero() || q.After.Before(f.droppedBefore) {
			q.After = f.droppedBefore
		}
	}

	filter, err := buildFilter(q, f.pseudonymiser)
	if err != nil {
		return fmt.Errorf("frostdb: build filter: %w", err)
	}
	builder := f.engine.ScanTable(tableName)
	if filter != nil {
		builder = builder.Filter(filter)
	}
	builder = builder.Project(colRef("id"))

	emitted, skipped := 0, 0
	var callbackErr error
	execErr := builder.Execute(ctx, func(_ context.Context, r arrow.Record) error {
		idx := -1
		for i, fld := range r.Schema().Fields() {
			if fld.Name == "id" {
				idx = i
				break
			}
		}
		if idx < 0 {
			// The projection asked for exactly this column. Its absence means the plan did
			// not do what this code assumes, and silently scanning zero IDs would warm an
			// empty dedupe set and re-admit every replayed record.
			callbackErr = errors.New("frostdb: scan ids: projected record has no id column")
			return callbackErr
		}
		col := r.Column(idx)
		for i := 0; i < int(r.NumRows()); i++ {
			if skipped < q.Offset {
				skipped++
				continue
			}
			// Clone: arrow-go returns a string aliasing the record's buffer, and the caller
			// retains these. Without the copy, one warmed ID pins the whole Arrow record —
			// every column of every row in it — for as long as the ID set holds it.
			if err := fn(strings.Clone(stringAt(col, i))); err != nil {
				callbackErr = err
				return err
			}
			emitted++
			if q.Limit > 0 && emitted >= q.Limit {
				return errScanLimitReached
			}
		}
		return nil
	})

	switch {
	case callbackErr != nil:
		// fn's own error, or the missing-column failure. Reported as-is; the engine may have
		// wrapped it on the way out, and the caller is owed the error it returned.
		return callbackErr
	case execErr != nil && !errors.Is(execErr, errScanLimitReached):
		return fmt.Errorf("frostdb: scan ids: %w", execErr)
	default:
		return nil
	}
}

// ScanObservations streams matching observations one row at a time.
//
// Unlike ScanIDs this must decode whole rows, so it projects everything. What it does not do
// is accumulate: peak memory is one Arrow record plus whatever the caller chooses to retain,
// instead of the entire result set. A paging caller stops early and pays for its page.
//
// The *model.Observation passed to fn points at a slice this function owns and reuses per
// record; a caller retaining a row must copy it.
func (f *FrostDBStore) ScanObservations(ctx context.Context, q Query, fn func(o *model.Observation) error) error {
	f.mu.RLock()
	defer f.mu.RUnlock()

	if !f.droppedBefore.IsZero() {
		if q.After.IsZero() || q.After.Before(f.droppedBefore) {
			q.After = f.droppedBefore
		}
	}

	filter, err := buildFilter(q, f.pseudonymiser)
	if err != nil {
		return fmt.Errorf("frostdb: build filter: %w", err)
	}
	builder := f.engine.ScanTable(tableName)
	if filter != nil {
		builder = builder.Filter(filter)
	}
	builder = builder.Project(logicalplan.All())

	emitted, skipped := 0, 0
	var callbackErr error
	execErr := builder.Execute(ctx, func(_ context.Context, r arrow.Record) error {
		rows := recordToObservations(r)
		for i := range rows {
			if skipped < q.Offset {
				skipped++
				continue
			}
			if err := fn(&rows[i]); err != nil {
				callbackErr = err
				return err
			}
			emitted++
			if q.Limit > 0 && emitted >= q.Limit {
				return errScanLimitReached
			}
		}
		return nil
	})

	switch {
	case callbackErr != nil:
		return callbackErr
	case execErr != nil && !errors.Is(execErr, errScanLimitReached):
		return fmt.Errorf("frostdb: scan observations: %w", execErr)
	default:
		return nil
	}
}

// ObservationStats aggregates in the engine and returns only the totals.
//
// One grouped query does all of it: count and max(timestamp) grouped by (layer, fidelity).
// The result is one row per distinct pair — a couple of dozen at most, against a table of
// millions — so the totals cross the interface instead of the rows. byLayer, byFidelity, the
// grand total and the last ingestion all derive from that one result.
func (f *FrostDBStore) ObservationStats(ctx context.Context, q Query) (ObservationStats, error) {
	f.mu.RLock()
	defer f.mu.RUnlock()

	if !f.droppedBefore.IsZero() {
		if q.After.IsZero() || q.After.Before(f.droppedBefore) {
			q.After = f.droppedBefore
		}
	}

	out := ObservationStats{ByLayer: map[string]int{}, ByFidelity: map[string]int{}}

	filter, err := buildFilter(q, f.pseudonymiser)
	if err != nil {
		return out, fmt.Errorf("frostdb: build filter: %w", err)
	}
	builder := f.engine.ScanTable(tableName)
	if filter != nil {
		builder = builder.Filter(filter)
	}
	builder = builder.Aggregate(
		[]*logicalplan.AggregationFunction{
			// Counted over timestamp, not id: FrostDB refuses an aggregation whose
			// expression is not Int64/Uint64/Float64, and id is a string column. Every row
			// carries a timestamp — Append writes it unconditionally — so counting non-null
			// timestamps is counting rows. The contract suite asserts this equals a
			// QueryRange tally, against both implementations.
			logicalplan.Count(colRef(colTimestamp)),
			logicalplan.Max(colRef(colTimestamp)),
		},
		[]logicalplan.Expr{colRef(colLayer), colRef(colFidelity)},
	)

	execErr := builder.Execute(ctx, func(_ context.Context, r arrow.Record) error {
		cols := map[string]int{}
		for i, fld := range r.Schema().Fields() {
			cols[fld.Name] = i
		}
		// Aggregate output column names are engine-chosen (count(id), max(timestamp)), so
		// they are located by suffix rather than assumed. A rename upstream must fail loudly
		// here rather than silently reporting zero observations.
		countIdx, maxIdx := -1, -1
		for name, i := range cols {
			switch {
			case strings.HasPrefix(name, "count("):
				countIdx = i
			case strings.HasPrefix(name, "max("):
				maxIdx = i
			}
		}
		if countIdx < 0 {
			return errors.New("frostdb: observation stats: aggregate result has no count column")
		}
		layerIdx, hasLayer := cols[colLayer]
		fidelityIdx, hasFidelity := cols[colFidelity]

		for i := 0; i < int(r.NumRows()); i++ {
			n := int(int64At(r.Column(countIdx), i))
			out.Total += n
			if hasLayer {
				out.ByLayer[stringAt(r.Column(layerIdx), i)] += n
			}
			if hasFidelity {
				out.ByFidelity[stringAt(r.Column(fidelityIdx), i)] += n
			}
			if maxIdx >= 0 {
				ts := time.Unix(0, int64At(r.Column(maxIdx), i)).UTC()
				if out.LastIngestion == nil || ts.After(*out.LastIngestion) {
					t := ts
					out.LastIngestion = &t
				}
			}
		}
		return nil
	})
	if execErr != nil {
		return ObservationStats{}, fmt.Errorf("frostdb: observation stats: %w", execErr)
	}
	return out, nil
}

// matchesQuery applies query filters to an observation. Retained as a correctness
// oracle for testing equivalence between pushed-down FrostDB execution and in-memory evaluation.
//
// The actor comparison is generation-aware. A v1 observation carries a cleartext ActorHint and is
// compared against the raw query value; a v2 observation carries only HMACActorHint and is compared
// against the pseudonym of that value. If the oracle compared one representation only, it would
// disagree with the engine on exactly half the corpus and the equivalence tests would read as an
// engine defect.
func matchesQuery(o model.Observation, q Query, p *SegmentPseudonymiser) bool {
	if !q.matchesIDs(o.ID) {
		return false
	}
	if !q.After.IsZero() && o.Timestamp.Before(q.After) {
		return false
	}
	if !q.Before.IsZero() && !o.Timestamp.Before(q.Before) {
		return false
	}
	if len(q.Layers) > 0 {
		found := false
		for _, l := range q.Layers {
			if o.Layer == l {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	if q.ActorID != "" {
		if o.SchemaVersion == SegmentSchemaV2 || o.HMACActorHint != "" {
			if p == nil {
				return false
			}
			pseudonym, err := p.Pseudonym(q.ActorID)
			if err != nil || o.HMACActorHint != pseudonym {
				return false
			}
		} else if o.ActorHint != q.ActorID {
			return false
		}
	}
	if q.SubjectID != "" {
		if o.SchemaVersion == SegmentSchemaV2 || o.HMACActorHint != "" {
			if p == nil {
				return false
			}
			pseudonym, err := p.Pseudonym(q.SubjectID)
			if err != nil {
				return false
			}
			matchSub := o.HMACActorHint == pseudonym ||
				o.HMACActorID == pseudonym ||
				o.HMACPrincipalID == pseudonym ||
				o.HMACImpersonatedUser == pseudonym
			if !matchSub {
				return false
			}
		} else {
			matchSub := o.ActorHint == q.SubjectID ||
				o.ActorID == q.SubjectID ||
				o.PrincipalID == q.SubjectID ||
				o.ImpersonatedUser == q.SubjectID
			if !matchSub {
				return false
			}
		}
	}
	return true
}

// recordToObservations converts an Arrow record batch to model.Observation slices.
//
// It decodes BOTH segment column-schema generations from the same corpus, which is a permanent
// requirement rather than a migration window: v1 segments are signed and chained, so they are
// never rewritten and never go away. Detection is by column presence — every lookup below is
// guarded by `colIdx[name]`, so a v2 record simply has no `actor_hint` to find and a v1 record has
// no `hmac_actor_hint`. SchemaVersion on the result says which was read, so a consumer can tell a
// pseudonymised identifier from an absent one instead of inferring it from emptiness.
func recordToObservations(r arrow.Record) []model.Observation {
	n := int(r.NumRows())
	if n == 0 {
		return nil
	}

	// Build column index map for fast lookup.
	schema := r.Schema()
	colIdx := make(map[string]int, schema.NumFields())
	for i, f := range schema.Fields() {
		colIdx[f.Name] = i
	}

	results := make([]model.Observation, n)
	generation := SegmentSchemaOf(r)

	for i := 0; i < n; i++ {
		o := model.Observation{
			Labels:        make(map[string]string),
			SchemaVersion: generation,
		}

		if idx, ok := colIdx["id"]; ok {
			o.ID = stringAt(r.Column(idx), i)
		}
		if idx, ok := colIdx["timestamp"]; ok {
			ns := int64At(r.Column(idx), i)
			o.Timestamp = time.Unix(0, ns).UTC()
		}
		if idx, ok := colIdx["layer"]; ok {
			o.Layer = model.Layer(stringAt(r.Column(idx), i))
		}
		if idx, ok := colIdx["fidelity"]; ok {
			o.Fidelity = model.FidelityTier(stringAt(r.Column(idx), i))
		}
		if idx, ok := colIdx["source"]; ok {
			o.Source = stringAt(r.Column(idx), i)
		}
		if idx, ok := colIdx["confidence"]; ok {
			o.Confidence = float64At(r.Column(idx), i)
		}
		if idx, ok := colIdx["actor_hint"]; ok {
			o.ActorHint = stringAt(r.Column(idx), i)
		}
		if idx, ok := colIdx["raw_evidence_ref"]; ok {
			o.RawEvidenceRef = stringAt(r.Column(idx), i)
		}
		if idx, ok := colIdx["description"]; ok {
			o.Description = stringAt(r.Column(idx), i)
		}
		if idx, ok := colIdx["principal_id"]; ok {
			o.PrincipalID = stringAt(r.Column(idx), i)
		}
		if idx, ok := colIdx["actor_id"]; ok {
			o.ActorID = stringAt(r.Column(idx), i)
		}
		if idx, ok := colIdx["session_id"]; ok {
			o.SessionID = stringAt(r.Column(idx), i)
		}
		if idx, ok := colIdx["impersonated_user"]; ok {
			o.ImpersonatedUser = stringAt(r.Column(idx), i)
		}
		if idx, ok := colIdx["delegation_depth"]; ok {
			o.DelegationDepth = int(int64At(r.Column(idx), i))
		}

		// v2 pseudonym columns. Absent on a v1 record, which is why each is guarded.
		if idx, ok := colIdx[ColHMACActorHint]; ok {
			o.HMACActorHint = stringAt(r.Column(idx), i)
		}
		if idx, ok := colIdx[ColHMACActorID]; ok {
			o.HMACActorID = stringAt(r.Column(idx), i)
		}
		if idx, ok := colIdx[ColHMACPrincipalID]; ok {
			o.HMACPrincipalID = stringAt(r.Column(idx), i)
		}
		if idx, ok := colIdx[ColHMACSessionID]; ok {
			o.HMACSessionID = stringAt(r.Column(idx), i)
		}
		if idx, ok := colIdx[ColHMACImpersonatedUser]; ok {
			o.HMACImpersonatedUser = stringAt(r.Column(idx), i)
		}
		if idx, ok := colIdx[ColEvidenceRefDigest]; ok {
			o.EvidenceRefDigest = stringAt(r.Column(idx), i)
		}
		if idx, ok := colIdx[SegmentSchemaVersionColumn]; ok {
			if v := stringAt(r.Column(idx), i); v != "" {
				o.SchemaVersion = v
			}
		}

		// Extract dynamic label columns (prefixed with "labels.").
		for name, idx := range colIdx {
			if strings.HasPrefix(name, "labels.") {
				key := strings.TrimPrefix(name, "labels.")
				val := stringAt(r.Column(idx), i)
				if val != "" {
					o.Labels[key] = val
				}
			}
		}

		results[i] = o
	}

	return results
}

// stringAt safely extracts a string from an Arrow array at position i.
func stringAt(col arrow.Array, i int) string {
	if col.IsNull(i) {
		return ""
	}
	switch c := col.(type) {
	case *array.String:
		return c.Value(i)
	case *array.Binary:
		return string(c.Value(i))
	case *array.Dictionary:
		// FrostDB may dictionary-encode string columns.
		idx := c.GetValueIndex(i)
		dict := c.Dictionary()
		switch d := dict.(type) {
		case *array.String:
			return d.Value(idx)
		case *array.Binary:
			return string(d.Value(idx))
		}
	}
	return ""
}

// int64At safely extracts an int64 from an Arrow array at position i.
func int64At(col arrow.Array, i int) int64 {
	if col.IsNull(i) {
		return 0
	}
	switch c := col.(type) {
	case *array.Int64:
		return c.Value(i)
	}
	return 0
}

// float64At safely extracts a float64 from an Arrow array at position i.
func float64At(col arrow.Array, i int) float64 {
	if col.IsNull(i) {
		return 0
	}
	switch c := col.(type) {
	case *array.Float64:
		return c.Value(i)
	}
	return 0
}

// DropPartition removes observations before the given time.
func (f *FrostDBStore) DropPartition(_ context.Context, before time.Time) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if before.After(f.droppedBefore) {
		f.droppedBefore = before
	}
	return nil
}

// Close shuts down the FrostDB store.
func (f *FrostDBStore) Close() error {
	f.mu.Lock()
	storeErr := f.cs.Close()
	f.mu.Unlock()
	if f.attestor != nil {
		if err := f.attestor.Close(); storeErr == nil {
			storeErr = err
		}
	}
	return storeErr
}

// Flush rotates the active block and waits until its real Parquet object has
// been uploaded. It never waits for the independent attestation worker.
func (f *FrostDBStore) Flush(ctx context.Context) error {
	var wait sync.WaitGroup
	wait.Add(1)
	f.mu.Lock()
	if err := f.table.RotateBlock(ctx, f.table.ActiveBlock(), frostdb.WithRotateBlockWaitGroup(&wait)); err != nil {
		f.mu.Unlock()
		return fmt.Errorf("frostdb: rotate block: %w", err)
	}
	f.mu.Unlock()
	done := make(chan struct{})
	go func() { wait.Wait(); close(done) }()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// WaitForAttestations is a test and shutdown observation seam. Ingestion does
// not call it and therefore never blocks on signing or publication.
func (f *FrostDBStore) WaitForAttestations(ctx context.Context) error {
	if f.attestor == nil {
		return nil
	}
	return f.attestor.Wait(ctx)
}

const (
	colTimestamp = "timestamp"
	colLayer     = "layer"
	// colActorHint is the pushdown column for Query.ActorID. It moved from the cleartext
	// "actor_hint" to the keyed pseudonym in segment schema v2. The predicate shape is unchanged —
	// still a single Eq on a STRING column — because a keyed HMAC is deterministic, so equality on
	// the pseudonym is equality on the plaintext. That property is the entire reason this card
	// pseudonymises rather than encrypts: an encrypted column would have forced a decrypt-and-scan,
	// measured at 19.43 ms p95 against a 2.75 ms budget.
	colActorHint = ColHMACActorHint
	// colID is the pushdown column for Query.IDs. It is cleartext and stays so: an observation ID
	// is a derived content address, not an identifier of a person, and a by-ID read has to be
	// expressible without a key or the key's absence would turn every lookup into a full scan —
	// which is the defect this column was added to the filter set to remove.
	colID = "id"
	// colFidelity is a GROUP BY column for ObservationStats, not a filter column, so it is
	// deliberately absent from validateFilterColumns' required set: nothing pushes a
	// predicate down on it.
	colFidelity = "fidelity"
)

// validateFilterColumns ensures that the column names targeted by query pushdown
// exist in the FrostDB schema definition.
func validateFilterColumns(schema *schemapb.Schema) error {
	// Ordered, not map-ranged. Ranging a map made the reported column depend on Go's randomised
	// iteration order, so with two columns missing the message named an arbitrary one — and a test
	// asserting on the message was flaky in a way that only showed up once a second column moved.
	required := []string{colTimestamp, colLayer, colActorHint, colID}
	present := make(map[string]struct{}, len(schema.Columns))
	for _, col := range schema.Columns {
		present[col.Name] = struct{}{}
	}
	for _, name := range required {
		if _, ok := present[name]; !ok {
			return fmt.Errorf("frostdb: required filter column %q not found in schema", name)
		}
	}
	return nil
}

// buildFilter translates a Query into a FrostDB logicalplan.Expr using exact Arrow schema column names.
// It maps:
//   - q.After  -> timestamp >= q.After.UnixNano() (int64)
//   - q.Before -> timestamp < q.Before.UnixNano() (int64)
//   - q.Layers -> layer == layer[0] OR layer == layer[1] ...
//   - q.IDs    -> id == ids[0] OR id == ids[1] ...
//   - q.ActorID -> hmac_actor_hint == pseudonym(q.ActorID)
//
// Multiple predicates are combined with logicalplan.And.
// An empty query returns nil so the engine performs an unfiltered scan.
//
// The actor predicate keeps its exact pre-v2 shape — one Eq against one STRING column — so the
// pushdown plan and its measured latency are unchanged. Only the literal moves, from the caller's
// cleartext identifier to that identifier's keyed pseudonym.
//
// It fails closed: filtering by actor with no pseudonymiser returns an error rather than falling
// back to emitting the cleartext literal, which would both miss every v2 row and put the caller's
// identifier into a query plan and any log that records one.
func buildFilter(q Query, p *SegmentPseudonymiser) (logicalplan.Expr, error) {
	var exprs []logicalplan.Expr

	if !q.After.IsZero() {
		exprs = append(exprs, colRef(colTimestamp).GtEq(logicalplan.Literal(q.After.UnixNano())))
	}
	if !q.Before.IsZero() {
		exprs = append(exprs, colRef(colTimestamp).Lt(logicalplan.Literal(q.Before.UnixNano())))
	}

	// An ID list is pushed down the same way a layer list is. The engine prunes on `id`, so a
	// by-ID read costs the rows it names rather than the whole table; the caller no longer has to
	// decode every observation in the store to find one.
	if len(q.IDs) == 1 {
		exprs = append(exprs, colRef(colID).Eq(logicalplan.Literal(q.IDs[0])))
	} else if len(q.IDs) > 1 {
		idExprs := make([]logicalplan.Expr, len(q.IDs))
		for i, id := range q.IDs {
			idExprs[i] = colRef(colID).Eq(logicalplan.Literal(id))
		}
		exprs = append(exprs, logicalplan.Or(idExprs...))
	}

	if len(q.Layers) == 1 {
		exprs = append(exprs, colRef(colLayer).Eq(logicalplan.Literal(string(q.Layers[0]))))
	} else if len(q.Layers) > 1 {
		layerExprs := make([]logicalplan.Expr, len(q.Layers))
		for i, l := range q.Layers {
			layerExprs[i] = colRef(colLayer).Eq(logicalplan.Literal(string(l)))
		}
		exprs = append(exprs, logicalplan.Or(layerExprs...))
	}

	// Tenancy pushed down to the label column so a scoped page can stop early in the engine
	// rather than being filtered after every row is already decoded.
	if q.TenantID != "" {
		exprs = append(exprs, colRef(LabelColumnPrefix+TenantLabelKey).Eq(logicalplan.Literal(q.TenantID)))
	}

	if q.ActorID != "" {
		if p == nil {
			return nil, ErrSegmentPseudonymKeyRequired
		}
		pseudonym, err := p.Pseudonym(q.ActorID)
		if err != nil {
			return nil, err
		}
		exprs = append(exprs, colRef(colActorHint).Eq(logicalplan.Literal(pseudonym)))
	}

	if q.SubjectID != "" {
		if p == nil {
			return nil, ErrSegmentPseudonymKeyRequired
		}
		pseudonym, err := p.Pseudonym(q.SubjectID)
		if err != nil {
			return nil, err
		}
		subExprs := []logicalplan.Expr{
			colRef(ColHMACActorHint).Eq(logicalplan.Literal(pseudonym)),
			colRef(ColHMACActorID).Eq(logicalplan.Literal(pseudonym)),
			colRef(ColHMACPrincipalID).Eq(logicalplan.Literal(pseudonym)),
			colRef(ColHMACImpersonatedUser).Eq(logicalplan.Literal(pseudonym)),
		}
		exprs = append(exprs, logicalplan.Or(subExprs...))
	}

	switch len(exprs) {
	case 0:
		return nil, nil
	case 1:
		return exprs[0], nil
	default:
		return logicalplan.And(exprs...), nil
	}
}

// colRef is a helper for building logicalplan column references.
func colRef(name string) *logicalplan.Column {
	return logicalplan.Col(name)
}
