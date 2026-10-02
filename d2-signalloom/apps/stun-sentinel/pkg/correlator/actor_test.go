// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/ebpf"
)

// actor_id came from the pod's signalloom.ai/agent-name, agent-name or app
// label, so any pod the sentinel watched could name itself kusari-agent and
// have its activity credited to kusari's agent. It now comes from the pod's
// service account: the same namespace/SA boundary tenancy uses, so no new
// trust root, and kusari's pod (SA kusari-agent) is unchanged on the wire.

func TestActorIsTheServiceAccountNeverALabel(t *testing.T) {
	m := NewSentinelProbeManager(nil, "", nil, WithTenantMap(baseTenantMap(t)))
	for _, tc := range []struct {
		name, sa string
		labels   map[string]string
		want     string
	}{
		{"forged signalloom.ai/agent-name on another SA", "intruder", map[string]string{"signalloom.ai/agent-name": "kusari-agent"}, "intruder"},
		{"forged agent-name on another SA", "intruder", map[string]string{"agent-name": "kusari-agent"}, "intruder"},
		{"forged app on another SA", "intruder", map[string]string{"app": "kusari-agent"}, "intruder"},
		{"kusari's SA cannot claim another agent", "kusari-agent", map[string]string{"signalloom.ai/agent-name": "cardvault-agent"}, "kusari-agent"},
		{"kusari's pod as it ships", "kusari-agent", map[string]string{"signalloom.ai/agent-name": "kusari-agent"}, "kusari-agent"},
		{"unset SA is the default SA", "", map[string]string{"signalloom.ai/agent-name": "kusari-agent"}, "default"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pod := podAs(sharedNS, tc.sa, tc.labels)
			delete(pod.Labels, "signalloom.ai/agent-name")
			for k, v := range tc.labels {
				pod.Labels[k] = v
			}
			obs := m.NormalizeObservation(SyscallEvent{}, pod)
			if obs.ActorID != tc.want || obs.toIngest().ActorID != tc.want {
				t.Fatalf("actor_id = %q (wire %q), want %q", obs.ActorID, obs.toIngest().ActorID, tc.want)
			}
		})
	}
}

// The full path a forged pod takes: still detected, still frozen, filed under
// its own SA and unattributed tenancy.
func TestForgedAgentNameIsFrozenButCreditedToItsOwnServiceAccount(t *testing.T) {
	pod := podAs(sharedNS, "intruder", map[string]string{"signalloom.ai/agent-name": "kusari-agent"})
	m, calls := pipelineWithOpts(t, pod, nil, WithTenantMap(baseTenantMap(t)))
	obs, ok := m.handleRecord(rawRecord(ebpf.EventOpenat, 1001, "/etc/shadow"))
	if !ok || *calls != 1 {
		t.Fatalf("ok=%v freezes=%d", ok, *calls)
	}
	if obs.ActorID != "intruder" || obs.TenantID != UnattributedTenantID {
		t.Fatalf("actor_id=%q tenant_id=%q, want intruder/%s", obs.ActorID, obs.TenantID, UnattributedTenantID)
	}
}
