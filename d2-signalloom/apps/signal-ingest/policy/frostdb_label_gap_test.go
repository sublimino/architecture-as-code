// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

//go:build frostdb

package policy

import (
	"sort"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// This file documents a REAL, CURRENT production gap that is out of this card's
// ownership, and it is deliberately written to pass today.
//
// # The gap
//
// store/label_allowlist.go (frostdb build only) refuses, at Append, any
// observation carrying a dynamic label key outside a closed allow-list, before
// any Arrow record is built. The policy label sets this package writes are
// mostly NOT in that list:
//
//	finding:  rule_id OK, severity OK, tenant_id OK
//	          bundle_id, bundle_version, source_observation_id, mode  REFUSED
//	decision: rule_id OK, severity OK, tenant_id OK
//	          window_id, bundle_id, bundle_version, mode, count, finding_ids  REFUSED
//
// base/deployment.yaml sets SIGNAL_STORE=frostdb and the image is built
// `-tags frostdb`, so in the deployed configuration every finding and decision
// write returns DisallowedLabelKeyError.
//
// # Why this is not a silent failure
//
// policy.Sink treats a failed finding write exactly as it treats any other
// policy fault: counted on signalloom_policy_finding_write_errors_total,
// logged at ERROR with "the detection happened and was not recorded", and
// never propagated to the writer. Stage 2 still counts in memory, so a burst is
// still DETECTED and still alerts. What is lost is PERSISTENCE of findings and
// decisions, which is what the Weave surface and the replay corpus read.
//
// So the failure mode is loud and bounded rather than silent, but the feature
// is not functional on a frostdb store until the allow-list is extended.
//
// # The fix, which belongs to whoever owns store/
//
// Add these seven keys to defaultLabelAllowList: bundle_id, bundle_version,
// source_observation_id, mode, window_id, count, finding_ids. Every one is
// policy metadata from a closed vocabulary — a bundle identity, a semver, a
// mode enum, an integer, a derived observation ID, a list of derived finding
// IDs. None names a natural person, so none weakens the privacy claim the
// allow-list exists to make checkable. `source_observation_id` and
// `finding_ids` carry sha256-derived identifiers, not identifiers of people.
//
// # Why this test asserts the gap rather than the fix
//
// Asserting the fix would mean committing a knowingly-red test to a shared
// integration branch, which reads as a regression from this card. Asserting the
// gap keeps the bar green and honest, and this test FAILS the moment the
// allow-list is extended — at which point the correct action is to delete this
// file, because the gap it documents is closed.
func TestFrostDBLabelAllowListDoesNotYetAdmitPolicyLabels(t *testing.T) {
	// Keys the policy label sets need and the allow-list does not have.
	wantRefused := []string{
		LabelBundleID,
		LabelBundleVersion,
		LabelSourceObsID,
		LabelMode,
		LabelWindowID,
		LabelCount,
		LabelFindingIDs,
	}
	sort.Strings(wantRefused)

	var unexpectedlyAllowed []string
	for _, k := range wantRefused {
		if store.IsAllowedLabelKey(k) {
			unexpectedlyAllowed = append(unexpectedlyAllowed, k)
		}
	}
	if len(unexpectedlyAllowed) > 0 {
		t.Fatalf(
			"the frostdb label allow-list now admits %v.\n"+
				"That is the FIX this file documents, not a failure: findings and decisions can\n"+
				"now persist to a frostdb store. Delete policy/frostdb_label_gap_test.go and, if\n"+
				"every key in %v is admitted, add a positive test asserting that a finding and a\n"+
				"decision round-trip through the frostdb store.",
			unexpectedlyAllowed, wantRefused)
	}

	// The three keys that DO survive, so a future allow-list change that removed
	// one of them is caught here rather than in production.
	for _, k := range []string{LabelRuleID, LabelSeverity, TenantLabel} {
		if !store.IsAllowedLabelKey(k) {
			t.Errorf("policy label %q is no longer admitted by the frostdb allow-list; "+
				"findings lose a field the Weave surface reads", k)
		}
	}
}
