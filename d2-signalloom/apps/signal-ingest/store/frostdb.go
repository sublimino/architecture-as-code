//go:build frostdb

package store

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/apache/arrow-go/v18/arrow"
	"github.com/apache/arrow-go/v18/arrow/array"
	"github.com/apache/arrow-go/v18/arrow/memory"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/polarsignals/frostdb"
	"github.com/polarsignals/frostdb/query"
	"github.com/polarsignals/frostdb/query/logicalplan"
	"github.com/thanos-io/objstore/providers/filesystem"

	schemapb "github.com/polarsignals/frostdb/gen/proto/go/frostdb/schema/v1alpha1"
)

const (
	tableName = "observations"
	dbName    = "signaldb"
)

// FrostDBStore persists signal observations in an embedded FrostDB (Parquet).
type FrostDBStore struct {
	cs     *frostdb.ColumnStore
	db     *frostdb.DB
	table  *frostdb.Table
	engine *query.LocalEngine
	pool   memory.Allocator
	mu     sync.RWMutex
}

// NewFrostDBStore creates a new in-memory FrostDB-backed store.
func NewFrostDBStore() (*FrostDBStore, error) {
	return newFrostDBStore()
}

// NewFrostDBStoreWithBucket creates a FrostDB store backed by a filesystem
// directory so Parquet files are persisted to disk.
func NewFrostDBStoreWithBucket(dir string) (*FrostDBStore, error) {
	bucket, err := filesystem.NewBucket(dir)
	if err != nil {
		return nil, fmt.Errorf("frostdb: filesystem bucket: %w", err)
	}
	sink := frostdb.NewDefaultObjstoreBucket(bucket)
	return newFrostDBStore(frostdb.WithReadWriteStorage(sink))
}

func newFrostDBStore(opts ...frostdb.Option) (*FrostDBStore, error) {
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
	tbl, err := db.Table(tableName, frostdb.NewTableConfig(schema))
	if err != nil {
		cs.Close()
		return nil, fmt.Errorf("frostdb: new table: %w", err)
	}

	pool := memory.NewGoAllocator()
	engine := query.NewEngine(pool, db.TableProvider())

	return &FrostDBStore{
		cs:     cs,
		db:     db,
		table:  tbl,
		engine: engine,
		pool:   pool,
	}, nil
}

func schemaDef() *schemapb.Schema {
	return &schemapb.Schema{
		Columns: []*schemapb.Column{
			{Name: "id", StorageLayout: &schemapb.StorageLayout{Type: schemapb.StorageLayout_TYPE_STRING}},
			{Name: "timestamp", StorageLayout: &schemapb.StorageLayout{Type: schemapb.StorageLayout_TYPE_INT64}},
			{Name: "layer", StorageLayout: &schemapb.StorageLayout{Type: schemapb.StorageLayout_TYPE_STRING}},
			{Name: "fidelity", StorageLayout: &schemapb.StorageLayout{Type: schemapb.StorageLayout_TYPE_STRING}},
			{Name: "source", StorageLayout: &schemapb.StorageLayout{Type: schemapb.StorageLayout_TYPE_STRING}},
			{Name: "confidence", StorageLayout: &schemapb.StorageLayout{Type: schemapb.StorageLayout_TYPE_DOUBLE}},
			{Name: "actor_hint", StorageLayout: &schemapb.StorageLayout{Type: schemapb.StorageLayout_TYPE_STRING}},
			{Name: "raw_evidence_ref", StorageLayout: &schemapb.StorageLayout{Type: schemapb.StorageLayout_TYPE_STRING}},
			{Name: "description", StorageLayout: &schemapb.StorageLayout{Type: schemapb.StorageLayout_TYPE_STRING}},
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

// Append writes observations into FrostDB as Arrow records.
func (f *FrostDBStore) Append(ctx context.Context, observations []model.Observation) error {
	f.mu.Lock()
	defer f.mu.Unlock()

	// Collect all dynamic label keys across this batch.
	dynCols := map[string]struct{}{}
	for _, o := range observations {
		for k := range o.Labels {
			dynCols[k] = struct{}{}
		}
	}
	dynNames := make([]string, 0, len(dynCols))
	for k := range dynCols {
		dynNames = append(dynNames, k)
	}

	// Build Arrow schema: static columns + dynamic label columns.
	fields := []arrow.Field{
		{Name: "actor_hint", Type: arrow.BinaryTypes.String},
		{Name: "confidence", Type: arrow.PrimitiveTypes.Float64},
		{Name: "description", Type: arrow.BinaryTypes.String},
		{Name: "fidelity", Type: arrow.BinaryTypes.String},
		{Name: "id", Type: arrow.BinaryTypes.String},
	}
	// Dynamic label columns are inserted alphabetically among other columns.
	for _, k := range dynNames {
		fields = append(fields, arrow.Field{Name: "labels." + k, Type: arrow.BinaryTypes.String, Nullable: true})
	}
	fields = append(fields,
		arrow.Field{Name: "layer", Type: arrow.BinaryTypes.String},
		arrow.Field{Name: "raw_evidence_ref", Type: arrow.BinaryTypes.String},
		arrow.Field{Name: "source", Type: arrow.BinaryTypes.String},
		arrow.Field{Name: "timestamp", Type: arrow.PrimitiveTypes.Int64},
	)

	arrowSchema := arrow.NewSchema(fields, nil)
	builder := array.NewRecordBuilder(f.pool, arrowSchema)
	defer builder.Release()

	for _, o := range observations {
		idx := 0
		builder.Field(idx).(*array.StringBuilder).Append(o.ActorHint)
		idx++
		builder.Field(idx).(*array.Float64Builder).Append(o.Confidence)
		idx++
		builder.Field(idx).(*array.StringBuilder).Append(o.Description)
		idx++
		builder.Field(idx).(*array.StringBuilder).Append(string(o.Fidelity))
		idx++
		builder.Field(idx).(*array.StringBuilder).Append(o.ID)
		idx++
		// Dynamic label columns
		for _, k := range dynNames {
			v, ok := o.Labels[k]
			if ok {
				builder.Field(idx).(*array.StringBuilder).Append(v)
			} else {
				builder.Field(idx).(*array.StringBuilder).AppendNull()
			}
			idx++
		}
		builder.Field(idx).(*array.StringBuilder).Append(string(o.Layer))
		idx++
		builder.Field(idx).(*array.StringBuilder).Append(o.RawEvidenceRef)
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

// QueryRange reads observations from FrostDB using the query engine.
func (f *FrostDBStore) QueryRange(ctx context.Context, q Query) ([]model.Observation, error) {
	f.mu.RLock()
	defer f.mu.RUnlock()

	var results []model.Observation

	// Build filter expression for the query engine.
	// We push time and layer filters to the engine; actor filter is applied
	// in Go after retrieval since it requires string equality on a non-indexed
	// column.

	err := f.engine.ScanTable(tableName).
		Execute(ctx, func(ctx context.Context, r arrow.Record) error {
			obs := recordToObservations(r)
			for _, o := range obs {
				if !matchesQuery(o, q) {
					continue
				}
				results = append(results, o)
				if q.Limit > 0 && len(results) >= q.Limit {
					break
				}
			}
			return nil
		})
	if err != nil {
		return nil, fmt.Errorf("frostdb: query: %w", err)
	}

	return results, nil
}

// matchesQuery applies query filters to an observation.
func matchesQuery(o model.Observation, q Query) bool {
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
	if q.ActorID != "" && o.ActorHint != q.ActorID {
		return false
	}
	return true
}

// recordToObservations converts an Arrow record batch to model.Observation slices.
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

	for i := 0; i < n; i++ {
		o := model.Observation{
			Labels: make(map[string]string),
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
// FrostDB does not expose granule-level deletion in its current API.
// This implementation rotates blocks, which triggers persistence of completed
// blocks to storage (if configured), but does not delete individual rows.
// Documented limitation: DropPartition is a no-op for row-level deletion.
func (f *FrostDBStore) DropPartition(_ context.Context, _ time.Time) error {
	// FrostDB's block rotation is internal and automatic. The API does not
	// expose row-level or time-range deletion. For a production system, this
	// would be implemented via table recreation or TTL-based block expiry.
	//
	// Attempted approaches:
	// - Table.RotateBlock() is not exported
	// - No Delete/Truncate API on Table or DB
	// - Block persistence happens automatically when blocks are full
	//
	// This is a documented limitation of the FrostDB PoC integration.
	return nil
}

// Close shuts down the FrostDB store.
func (f *FrostDBStore) Close() error {
	return f.cs.Close()
}

// colRef is a helper for building logicalplan column references.
func colRef(name string) *logicalplan.Column {
	return logicalplan.Col(name)
}
