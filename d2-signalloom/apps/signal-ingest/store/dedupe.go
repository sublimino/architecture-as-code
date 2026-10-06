// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package store

import (
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// DedupeByID collapses rows that share an Observation.ID down to one.
//
// # Why a read-side pass as well as a write-side one
//
// The write-side Deduper stops NEW duplicates. It cannot repair Parquet
// segments that were written before it existed, and those segments are the ones
// Weave reads and the ones the replay command and stage-2 warm-up re-derive
// their counts from. A row counted twice there is a burst that never happened.
// Dropping and rebuilding the store is not an option — it is the evidence.
//
// So the read side collapses what is already there. The pass is O(n) over a
// result set that every caller already holds in memory.
//
// # Which copy survives
//
// The first occurrence in the order given. Observation.ID is derived from the
// evidence reference, so two rows sharing an ID are two writes of the same
// projection of the same record and are equal in content; "first" is therefore
// a deterministic choice of row rather than an arbitrary one, and the input
// order is left untouched for callers (Weave, export) that depend on it.
//
// A row with an empty ID is passed through unconditionally: there is nothing to
// key on, and collapsing every unidentified row onto one would delete evidence
// to tidy a count. model.Observation.Validate rejects an empty ID on ingest, so
// this only arises for rows that predate that check.
//
// A nil or single-element input is returned unchanged, with no allocation.
func DedupeByID(rows []model.Observation) []model.Observation {
	if len(rows) < 2 {
		return rows
	}
	seen := make(map[string]struct{}, len(rows))
	out := make([]model.Observation, 0, len(rows))
	for i := range rows {
		id := rows[i].ID
		if id != "" {
			if _, dup := seen[id]; dup {
				continue
			}
			seen[id] = struct{}{}
		}
		out = append(out, rows[i])
	}
	if len(out) == len(rows) {
		// Nothing was duplicated: hand back the caller's slice rather than a
		// copy, so the common case costs one map and no retained allocation.
		return rows
	}
	return out
}
