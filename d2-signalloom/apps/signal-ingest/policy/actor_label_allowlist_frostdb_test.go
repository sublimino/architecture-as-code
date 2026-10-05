// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

//go:build frostdb

package policy

import (
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// Every label key the policy layer writes must be in the segment allow-list, or
// FrostDBStore.Append refuses the WHOLE BATCH containing it -- so a key added
// here without an allow-list entry would not drop a column, it would discard
// every finding in the batch. `actor` is new in this change and this is the
// assertion that pins it.
func TestPolicyLabelKeysAreAllowListed(t *testing.T) {
	for _, k := range []string{
		LabelActor, LabelRuleID, LabelBundleID, LabelBundleVersion, LabelSeverity,
		LabelSourceObsID, LabelMode, LabelWindowID, LabelCount, LabelFindingIDs, TenantLabel,
	} {
		if !store.IsAllowedLabelKey(k) {
			t.Errorf("policy writes label key %q, which is not in store.defaultLabelAllowList; "+
				"FrostDBStore.Append would refuse every batch carrying it", k)
		}
	}
}
