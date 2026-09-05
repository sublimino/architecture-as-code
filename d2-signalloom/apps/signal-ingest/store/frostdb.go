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
	cs            *frostdb.ColumnStore
	db            *frostdb.DB
	table         *frostdb.Table
	engine        *query.LocalEngine
	pool          memory.Allocator
	droppedBefore time.Time
	mu            sync.RWMutex
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
			{Name: "principal_id", StorageLayout: &schemapb.StorageLayout{Type: schemapb.StorageLayout_TYPE_STRING}},
			{Name: "actor_id", StorageLayout: &schemapb.StorageLayout{Type: schemapb.StorageLayout_TYPE_STRING}},
			{Name: "session_id", StorageLayout: &schemapb.StorageLayout{Type: schemapb.StorageLayout_TYPE_STRING}},
			{Name: "impersonated_user", StorageLayout: &schemapb.StorageLayout{Type: schemapb.StorageLayout_TYPE_STRING}},
			{Name: "delegation_depth", StorageLayout: &schemapb.StorageLayout{Type: schemapb.StorageLayout_TYPE_INT64}},
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
		{Name: "actor_id", Type: arrow.BinaryTypes.String},
		{Name: "confidence", Type: arrow.PrimitiveTypes.Float64},
		{Name: "delegation_depth", Type: arrow.PrimitiveTypes.Int64},
		{Name: "description", Type: arrow.BinaryTypes.String},
		{Name: "fidelity", Type: arrow.BinaryTypes.String},
		{Name: "id", Type: arrow.BinaryTypes.String},
		{Name: "impersonated_user", Type: arrow.BinaryTypes.String},
	}
	// Dynamic label columns are inserted alphabetically among other columns.
	for _, k := range dynNames {
		fields = append(fields, arrow.Field{Name: "labels." + k, Type: arrow.BinaryTypes.String, Nullable: true})
	}
	fields = append(fields,
		arrow.Field{Name: "layer", Type: arrow.BinaryTypes.String},
		arrow.Field{Name: "principal_id", Type: arrow.BinaryTypes.String},
		arrow.Field{Name: "raw_evidence_ref", Type: arrow.BinaryTypes.String},
		arrow.Field{Name: "session_id", Type: arrow.BinaryTypes.String},
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
		builder.Field(idx).(*array.StringBuilder).Append(o.ActorID)
		idx++
		builder.Field(idx).(*array.Float64Builder).Append(o.Confidence)
		idx++
		builder.Field(idx).(*array.Int64Builder).Append(int64(o.DelegationDepth))
		idx++
		builder.Field(idx).(*array.StringBuilder).Append(o.Description)
		idx++
		builder.Field(idx).(*array.StringBuilder).Append(string(o.Fidelity))
		idx++
		builder.Field(idx).(*array.StringBuilder).Append(o.ID)
		idx++
		builder.Field(idx).(*array.StringBuilder).Append(o.ImpersonatedUser)
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
		builder.Field(idx).(*array.StringBuilder).Append(o.PrincipalID)
		idx++
		builder.Field(idx).(*array.StringBuilder).Append(o.RawEvidenceRef)
		idx++
		builder.Field(idx).(*array.StringBuilder).Append(o.SessionID)
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

// QueryRange reads observations from FrostDB using the query engine with pushed-down filters.
func (f *FrostDBStore) QueryRange(ctx context.Context, q Query) ([]model.Observation, error) {
	f.mu.RLock()
	defer f.mu.RUnlock()

	// Fold the retention floor into q.After so engine-level filtering prunes dropped partitions.
	if !f.droppedBefore.IsZero() {
		if q.After.IsZero() || q.After.Before(f.droppedBefore) {
			q.After = f.droppedBefore
		}
	}

	builder := f.engine.ScanTable(tableName).
		Project(logicalplan.All())
	if filter := buildFilter(q); filter != nil {
		builder = builder.Filter(filter)
	}

	var results []model.Observation
	err := builder.Execute(ctx, func(ctx context.Context, r arrow.Record) error {
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
	if err != nil {
		return nil, fmt.Errorf("frostdb: query: %w", err)
	}

	if q.Limit > 0 && len(results) > q.Limit {
		results = results[:q.Limit]
	}

	return results, nil
}

// matchesQuery applies query filters to an observation. Retained as a correctness
// oracle for testing equivalence between pushed-down FrostDB execution and in-memory evaluation.
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
	return f.cs.Close()
}

const (
	colTimestamp = "timestamp"
	colLayer     = "layer"
	colActorHint = "actor_hint"
)

// validateFilterColumns ensures that the column names targeted by query pushdown
// exist in the FrostDB schema definition.
func validateFilterColumns(schema *schemapb.Schema) error {
	required := map[string]bool{
		colTimestamp: false,
		colLayer:     false,
		colActorHint: false,
	}
	for _, col := range schema.Columns {
		if _, ok := required[col.Name]; ok {
			required[col.Name] = true
		}
	}
	for name, found := range required {
		if !found {
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
//   - q.ActorID -> actor_hint == q.ActorID
// Multiple predicates are combined with logicalplan.And.
// An empty query returns nil so the engine performs an unfiltered scan.
func buildFilter(q Query) logicalplan.Expr {
	var exprs []logicalplan.Expr

	if !q.After.IsZero() {
		exprs = append(exprs, colRef(colTimestamp).GtEq(logicalplan.Literal(q.After.UnixNano())))
	}
	if !q.Before.IsZero() {
		exprs = append(exprs, colRef(colTimestamp).Lt(logicalplan.Literal(q.Before.UnixNano())))
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

	if q.ActorID != "" {
		exprs = append(exprs, colRef(colActorHint).Eq(logicalplan.Literal(q.ActorID)))
	}

	switch len(exprs) {
	case 0:
		return nil
	case 1:
		return exprs[0]
	default:
		return logicalplan.And(exprs...)
	}
}

// colRef is a helper for building logicalplan column references.
func colRef(name string) *logicalplan.Column {
	return logicalplan.Col(name)
}
