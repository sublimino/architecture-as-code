// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

//go:build frostdb

package store

import "testing"

// The PRODUCTION default allow-list must admit the agent-nono (Landlock) denial
// labels, or a frostdb-tagged signal-ingest refuses every nono denial batch
// (DisallowedLabelKeyError) and the whole nono→FrostDB→CEL→stun path dies
// silently. The end-to-end store proof extends the default in-test; this guards
// the DEFAULT itself so the prod gap cannot reopen unnoticed.
func TestDefaultLabelAllowListAdmitsNonoDenialKeys(t *testing.T) {
	allow := DefaultLabelAllowList()
	for _, k := range []string{
		"denial_reason", "path", "agent_id", "spiffe_id", "verification_status",
		"event_type", "landlock_status", "landlock_abi", "nono_available",
		"hash_chain_digest", "prev_digest", "signature_gitoid", "delegation_chain_id",
	} {
		if _, ok := allow[k]; !ok {
			t.Errorf("default label allow-list is missing nono denial key %q — a frostdb store would refuse nono denial evidence in production", k)
		}
	}
}
