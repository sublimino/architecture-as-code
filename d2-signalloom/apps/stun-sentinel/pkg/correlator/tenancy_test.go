// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/ebpf"
	corev1 "k8s.io/api/core/v1"
)

// Review M5 (2026-10-02): tenant_id came from the pod's own `tenant` label and
// otherwise defaulted to kusari, so whoever could label a pod chose the tenant
// its observations were filed under, and every unlabelled pod was kusari's.
// Attribution now comes only from the operator's tenant map, keyed by
// namespace or namespace/serviceAccount.

const sharedNS = "fe-signalloom-agents"

// The base ConfigMap's shape: a shared namespace mapped per service account,
// and a namespace owned outright by one tenant.
func baseTenantMap(t *testing.T) *TenantMap {
	t.Helper()
	tm, err := ParseTenantMap(sharedNS + "/kusari-agent=kusari, tenant-acme=acme")
	if err != nil {
		t.Fatal(err)
	}
	return tm
}

func podAs(ns, sa string, labels map[string]string) *corev1.Pod {
	pod := CreateTestPod(ns, "agent-1", pipelinePodUID, "agent-1", "")
	delete(pod.Labels, "tenant")
	for k, v := range labels {
		pod.Labels[k] = v
	}
	pod.Spec.ServiceAccountName = sa
	return pod
}

func TestTenantAttributionIgnoresEveryPodLabel(t *testing.T) {
	m := NewSentinelProbeManager(nil, "", nil, WithTenantMap(baseTenantMap(t)))
	for _, tc := range []struct {
		name string
		pod  *corev1.Pod
		want string
	}{
		{"forged tenant label on a foreign SA", podAs(sharedNS, "intruder", map[string]string{"tenant": "kusari"}), UnattributedTenantID},
		{"forged signalloom.ai/tenant on a foreign SA", podAs(sharedNS, "intruder", map[string]string{"signalloom.ai/tenant": "kusari"}), UnattributedTenantID},
		{"forged kusari label on a foreign SA", podAs(sharedNS, "intruder", map[string]string{"kusari": "true"}), UnattributedTenantID},
		{"homoglyph tenant label on a foreign SA", podAs(sharedNS, "intruder", map[string]string{"tenant": "kusarі"}), UnattributedTenantID},
		{"kusari's SA cannot be relabelled away", podAs(sharedNS, "kusari-agent", map[string]string{"tenant": "acme", "signalloom.ai/tenant": "acme"}), "kusari"},
		{"acme's namespace cannot claim kusari", podAs("tenant-acme", "default", map[string]string{"tenant": "kusari", "kusari": "true"}), "acme"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := m.NormalizeObservation(SyscallEvent{}, tc.pod).TenantID; got != tc.want {
				t.Fatalf("tenant_id = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestUnmappedWorkloadIsMarkedUnattributedNeverKusari(t *testing.T) {
	m := NewSentinelProbeManager(nil, "", nil, WithTenantMap(baseTenantMap(t)))
	for _, tc := range []struct{ name, ns, sa string }{
		{"unmapped namespace", "tenant-unknown", "kusari-agent"},
		{"mapped shared namespace, foreign SA", sharedNS, "cardvault-agent"},
		{"mapped shared namespace, default SA", sharedNS, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := m.NormalizeObservation(SyscallEvent{}, podAs(tc.ns, tc.sa, nil)).TenantID; got != UnattributedTenantID {
				t.Fatalf("tenant_id = %q, want %q", got, UnattributedTenantID)
			}
		})
	}
}

func TestObservationWithoutAPodIsUnattributed(t *testing.T) {
	m := NewSentinelProbeManager(nil, "", nil, WithTenantMap(baseTenantMap(t)))
	if got := m.NormalizeObservation(SyscallEvent{}, nil).TenantID; got != UnattributedTenantID {
		t.Fatalf("tenant_id = %q with no pod, want %q", got, UnattributedTenantID)
	}
}

func TestNoTenantMapAttributesNothing(t *testing.T) {
	m := NewSentinelProbeManager(nil, "", nil)
	if got := m.NormalizeObservation(SyscallEvent{}, podAs(sharedNS, "kusari-agent", map[string]string{"tenant": "kusari"})).TenantID; got != UnattributedTenantID {
		t.Fatalf("tenant_id = %q with no operator map, want %q", got, UnattributedTenantID)
	}
}

func TestServiceAccountEntryOverridesItsNamespaceEntry(t *testing.T) {
	tm, err := ParseTenantMap("shared=acme\nshared/kusari-agent=kusari")
	if err != nil {
		t.Fatal(err)
	}
	if got := tm.Resolve("shared", "kusari-agent"); got != "kusari" {
		t.Fatalf("SA entry: got %q, want kusari", got)
	}
	// The documented residual: a namespace entry covers every SA in it.
	if got := tm.Resolve("shared", "anything"); got != "acme" {
		t.Fatalf("namespace entry: got %q, want acme", got)
	}
}

func TestEmptyServiceAccountNameResolvesAsDefault(t *testing.T) {
	tm, err := ParseTenantMap("ns-a/default=acme")
	if err != nil {
		t.Fatal(err)
	}
	if got := tm.Resolve("ns-a", ""); got != "acme" {
		t.Fatalf("got %q; the API server admits an empty serviceAccountName as \"default\"", got)
	}
}

// An unmapped workload is still reported and still frozen: attribution is
// metadata on the observation, never a gate on detection or containment.
func TestUnattributedSensitiveOpenIsStillReportedAndFrozen(t *testing.T) {
	m, calls := pipelineWithOpts(t, podAs(sharedNS, "intruder", map[string]string{"tenant": "kusari"}), nil,
		WithTenantMap(baseTenantMap(t)))
	obs, ok := m.handleRecord(rawRecord(ebpf.EventOpenat, 1001, "/etc/shadow"))
	if !ok || *calls != 1 {
		t.Fatalf("ok=%v freezes=%d: an unattributed agent must still be reported and frozen", ok, *calls)
	}
	if obs.TenantID != UnattributedTenantID || obs.toIngest().Labels["tenant_id"] != UnattributedTenantID {
		t.Fatalf("tenant_id = %q (wire %q), want %q", obs.TenantID, obs.toIngest().Labels["tenant_id"], UnattributedTenantID)
	}
}

func TestParseTenantMapRejectsAmbiguousOrForgedEntries(t *testing.T) {
	for _, tc := range []struct{ name, spec, want string }{
		{"homoglyph tenant", "ns-a=kusarі", "tenant"},
		{"reserved marker as tenant", "ns-a=" + UnattributedTenantID, "tenant"},
		{"retired kurasi typo", "fe-signalloom-agents/kusari-agent=kurasi", "retired"},
		{"uppercase tenant", "ns-a=Kusari", "tenant"},
		{"empty tenant", "ns-a=", "tenant"},
		{"oversized tenant", "ns-a=" + strings.Repeat("a", 64), "tenant"},
		{"no separator", "ns-a", "key=tenant"},
		{"homoglyph namespace", "nѕ-a=acme", "namespace"},
		{"empty namespace", "/sa=acme", "namespace"},
		{"too many path parts", "ns/sa/extra=acme", "service account"},
		{"empty service account", "ns/=acme", "service account"},
		{"duplicate key", "ns-a=acme,ns-a=kusari", "duplicate"},
		{"duplicate key even when equal", "ns-a=acme,ns-a=acme", "duplicate"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := ParseTenantMap(tc.spec)
			if err == nil {
				t.Fatalf("ParseTenantMap(%q) accepted it", tc.spec)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error %q does not name %q", err, tc.want)
			}
		})
	}
}

func TestParseTenantMapAcceptsCommaAndNewlineSeparatedEntries(t *testing.T) {
	tm, err := ParseTenantMap("\n  fe-signalloom-agents/kusari-agent=kusari,\n tenant-acme = acme \n\n")
	if err != nil {
		t.Fatal(err)
	}
	if tm.Len() != 2 || tm.Resolve(sharedNS, "kusari-agent") != "kusari" || tm.Resolve("tenant-acme", "x") != "acme" {
		t.Fatalf("parsed map = %+v", tm)
	}
	empty, err := ParseTenantMap("   ")
	if err != nil || empty.Len() != 0 {
		t.Fatalf("blank spec: len=%d err=%v, want an empty map", empty.Len(), err)
	}
}
