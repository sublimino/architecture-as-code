package main

import (
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// minIngestMemoryMiB is the stopgap floor. GET /api/v1/observations and /api/v1/store/stats each
// decode the whole FrostDB store per request (api/handlers.go, q.Limit = 0 and an unfiltered
// QueryRange); two concurrent /feeds polls OOM-killed signal-ingest 7 times at 1Gi on 2026-10-06,
// which fe-signalloom surfaced to the dashboard as a 502. EAPCI P1-6 bounds those reads; until it
// lands, lowering the limit reintroduces the outage, so it is pinned here.
const minIngestMemoryMiB = 2048

// memMiB parses the Kubernetes binary memory quantities this manifest uses (Mi, Gi).
func memMiB(t *testing.T, q string) int {
	t.Helper()
	m := regexp.MustCompile(`^([0-9]+)(Mi|Gi)$`).FindStringSubmatch(q)
	if m == nil {
		t.Fatalf("memory quantity %q is not <n>Mi or <n>Gi; extend memMiB rather than guess", q)
	}
	n, _ := strconv.Atoi(m[1])
	if m[2] == "Gi" {
		n *= 1024
	}
	return n
}

func TestReconciledManifestGivesIngestFullStoreReadHeadroom(t *testing.T) {
	r := renderReconciledManifest(t)
	o, ok := r.object("Deployment", "signal-ingest")
	if !ok {
		t.Fatal("signal-ingest Deployment is not in the reconciled manifest")
	}
	var spec struct {
		Template struct {
			Spec struct {
				Containers []struct {
					Name      string `yaml:"name"`
					Resources struct {
						Limits map[string]string `yaml:"limits"`
					} `yaml:"resources"`
				} `yaml:"containers"`
			} `yaml:"spec"`
		} `yaml:"template"`
	}
	if err := o.Spec.Decode(&spec); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, c := range spec.Template.Spec.Containers {
		if c.Name != "signal-ingest" {
			continue
		}
		found = true
		lim, ok := c.Resources.Limits["memory"]
		if !ok {
			t.Fatal("signal-ingest has no memory limit; the pin needs one to check")
		}
		if got := memMiB(t, lim); got < minIngestMemoryMiB {
			t.Errorf("signal-ingest memory limit = %s (%d MiB), want >= %d MiB: full-store reads "+
				"OOM-kill it below that until EAPCI P1-6 bounds them", lim, got, minIngestMemoryMiB)
		}
	}
	if !found {
		t.Fatal("no signal-ingest container in the reconciled Deployment")
	}
}

// The limit is headroom for a known defect, not a sizing decision, so the reason travels with
// the number: whoever lowers it must read why, and whoever lands P1-6 must find it to remove it.
func TestIngestMemoryLimitCarriesItsReason(t *testing.T) {
	raw, err := os.ReadFile("base/deployment.yaml")
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(string(raw), "\n")
	inLimits := false
	for i, l := range lines {
		trimmed := strings.TrimSpace(l)
		if trimmed == "limits:" {
			inLimits = true
			continue
		}
		if !inLimits || !strings.HasPrefix(trimmed, "memory:") {
			continue
		}
		var comment []string
		for j := i - 1; j >= 0 && strings.HasPrefix(strings.TrimSpace(lines[j]), "#"); j-- {
			comment = append([]string{strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(lines[j]), "#"))}, comment...)
		}
		reason := strings.Join(comment, " ")
		for _, want := range []string{"EAPCI P1-6", "decode the whole store"} {
			if !strings.Contains(reason, want) {
				t.Errorf("the comment above the signal-ingest memory limit does not mention %q; got:\n%s", want, reason)
			}
		}
		return
	}
	t.Fatal("no limits.memory line in base/deployment.yaml")
}
