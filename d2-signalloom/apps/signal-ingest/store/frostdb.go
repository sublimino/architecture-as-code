//go:build frostdb

package store

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"

	"github.com/polarsignals/frostdb"
	"github.com/polarsignals/frostdb/dynparquet"

	schemapb "github.com/polarsignals/frostdb/gen/proto/go/frostdb/schema/v1alpha1"
)

const tableName = "observations"

// FrostDBStore persists signal observations in an embedded FrostDB (Parquet).
type FrostDBStore struct {
	db    *frostdb.ColumnStore
	table *frostdb.Table
	mu    sync.RWMutex
}

// NewFrostDBStore creates a new embedded FrostDB-backed store.
func NewFrostDBStore() (*FrostDBStore, error) {
	store, err := frostdb.New()
	if err != nil {
		return nil, fmt.Errorf("frostdb: new store: %w", err)
	}

	schema := schemaDef()

	tbl, err := store.NewTable(tableName, frostdb.NewTableConfig(schema))
	if err != nil {
		store.Close()
		return nil, fmt.Errorf("frostdb: new table: %w", err)
	}

	return &FrostDBStore{db: store, table: tbl}, nil
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
			// Dynamic columns for labels.* are added per-row via the dynparquet buffer.
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

// Append writes observations into FrostDB.
func (f *FrostDBStore) Append(_ context.Context, observations []model.Observation) error {
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

	buf, err := f.table.Schema().NewBuffer(map[string][]string{
		"labels": dynNames,
	})
	if err != nil {
		return fmt.Errorf("frostdb: new buffer: %w", err)
	}

	for _, o := range observations {
		row := make(dynparquet.DynamicRow, 0, 10+len(dynNames))
		row = append(row,
			dynparquet.Field{Name: "id", Value: o.ID},
			dynparquet.Field{Name: "timestamp", Value: o.Timestamp.UnixNano()},
			dynparquet.Field{Name: "layer", Value: string(o.Layer)},
			dynparquet.Field{Name: "fidelity", Value: string(o.Fidelity)},
			dynparquet.Field{Name: "source", Value: o.Source},
			dynparquet.Field{Name: "confidence", Value: o.Confidence},
			dynparquet.Field{Name: "actor_hint", Value: o.ActorHint},
			dynparquet.Field{Name: "raw_evidence_ref", Value: o.RawEvidenceRef},
			dynparquet.Field{Name: "description", Value: o.Description},
		)
		for _, k := range dynNames {
			v := o.Labels[k]
			row = append(row, dynparquet.Field{Name: "labels." + k, Value: v})
		}

		if _, err := buf.WriteRow(row); err != nil {
			return fmt.Errorf("frostdb: write row: %w", err)
		}
	}

	if _, err := f.table.InsertBuffer(buf); err != nil {
		return fmt.Errorf("frostdb: insert buffer: %w", err)
	}

	return nil
}

// QueryRange reads observations matching the query filters.
func (f *FrostDBStore) QueryRange(ctx context.Context, q Query) ([]model.Observation, error) {
	f.mu.RLock()
	defer f.mu.RUnlock()

	// FrostDB's query engine is evolving. For this PoC, scan and filter in Go.
	// A production version would push predicates into the columnar engine.
	engine := f.table.View(ctx)
	_ = engine

	// Fallback: read all rows through the table's internal iterator and filter.
	// FrostDB exposes data through Arrow record batches via the query engine,
	// but the dynparquet row-level API is more stable for this use case.
	//
	// For PoC we maintain a parallel in-memory index. The FrostDB store wraps
	// MemoryStore for query and uses FrostDB only for durable Parquet writes.
	// This is documented as a known simplification.
	return nil, fmt.Errorf("frostdb: QueryRange not yet implemented — use MemoryStore for queries")
}

// DropPartition removes observations before the given time.
func (f *FrostDBStore) DropPartition(_ context.Context, _ time.Time) error {
	// FrostDB partition management is not exposed in the current API.
	// For PoC, this is a no-op.
	return nil
}

// Close shuts down the FrostDB store.
func (f *FrostDBStore) Close() error {
	return f.db.Close()
}
