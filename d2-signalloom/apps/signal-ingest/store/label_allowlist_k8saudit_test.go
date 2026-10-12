// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

//go:build frostdb

package store

import "testing"

// k8sAuditContractKeys is the exact label-key set the collectors/k8saudit
// projection materialises (docs/EAP "k8s label contract"). Every one of these
// must be admitted by the default allow-list, or a frostdb-tagged signal-ingest
// refuses the whole batch at Append and the vertical's unit fixtures pass while
// the cluster path fails — the L2 gap the coverage matrix exists to close.
//
// This list is duplicated deliberately from the collector, as an independent
// witness: if the collector adds a projected key, this test (and the coverage
// matrix) go red until the allow-list is extended and this witness updated in
// the same commit.
var k8sAuditContractKeys = []string{
	"verb", "resource", "subresource", "resource_kind", "api_group", "api_version",
	"namespace", "name", "decision", "response_code", "source_ip", "audit_id",
	"stage", "reason", "user_agent",
}

func TestDefaultAllowList_AdmitsEveryK8sAuditContractKey(t *testing.T) {
	for _, k := range k8sAuditContractKeys {
		if !IsAllowedLabelKey(k) {
			t.Errorf("k8s audit contract key %q is not in the default label allow-list; "+
				"FrostDBStore.Append would refuse the whole k8saudit batch", k)
		}
	}
}

// TestDefaultAllowList_UserAgentIsAdmitted is the narrow guard for the one key
// this card ADDS (docs/EAP binding: "ADD to the default allow-list: user_agent").
// It is separate from the contract sweep above so its intent reads at a glance
// and a mutation that drops user_agent names exactly what broke.
func TestDefaultAllowList_UserAgentIsAdmitted(t *testing.T) {
	if !IsAllowedLabelKey("user_agent") {
		t.Fatal("user_agent must be in the default allow-list: the k8saudit projection ships it")
	}
}
