package main

// Audit H1+H2: a scan evaluates exactly ONE version directory per framework.
// The directory whose pack version equals policyVersion wins; otherwise the
// newest by version order (never lexical); an empty policyVersion means the
// newest directory with all its checks.

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sort"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/frameworks"
)

func scanRaw(t *testing.T, h *complianceHandler, body map[string]any) *httptest.ResponseRecorder {
	t.Helper()
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	w := httptest.NewRecorder()
	h.handleScan(w, httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan", bytes.NewReader(raw)))
	return w
}

func scanResults(t *testing.T, h *complianceHandler, body map[string]any) []ComplianceScanResult {
	t.Helper()
	w := scanRaw(t, h, body)
	if w.Code != http.StatusOK {
		t.Fatalf("scan %v: HTTP %d: %s", body, w.Code, w.Body.String())
	}
	var out []ComplianceScanResult
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	return out
}

// Every real pack × every version string any of its checks carries (and the
// empty string): each (framework, check) appears at most once, all rows come
// from one directory, and /summary counts exactly those rows.
func TestScan_OneDirectoryPerFrameworkPerScan(t *testing.T) {
	root := conformancePolicyRoot(t)
	h, err := newComplianceHandler(root)
	if err != nil {
		t.Fatal(err)
	}
	packs := loadConformancePacks(t, root)
	versionsOf := map[string]map[string]bool{}
	for _, p := range packs {
		if versionsOf[p.fw.ID] == nil {
			versionsOf[p.fw.ID] = map[string]bool{"": true}
		}
		for _, id := range p.order {
			for _, v := range p.checks[id].PolicyVersions {
				versionsOf[p.fw.ID][v] = true
			}
		}
	}
	for fwID, vers := range versionsOf {
		for v := range vers {
			results := scanResults(t, h, map[string]any{"frameworks": []string{fwID}, "policyVersion": v})
			seen := map[string]bool{}
			dirs := map[string]bool{}
			for _, r := range results {
				if seen[r.Check] {
					t.Errorf("%s@%q: check %q reported twice", fwID, v, r.Check)
				}
				seen[r.Check] = true
				dirs[r.FrameworkVersion] = true
			}
			if len(dirs) != 1 {
				t.Errorf("%s@%q: rows from %d pack versions %v, want exactly 1", fwID, v, len(dirs), dirs)
			}
			if s := getSummary(t, h); s["totalControls"] != float64(len(results)) {
				t.Errorf("%s@%q: summary totalControls %v, scan rows %d", fwID, v, s["totalControls"], len(results))
			}
		}
	}
}

// The audit's reproducer: eu-ai-act@v1.0.0 returned 18 rows with duplicated
// IDs because v1.0 and v2.1 both carry v1.0.0 checks. The v1.0 pack (7
// checks, version v1.0.0) is the only directory evaluated.
func TestScan_EUAIActV1SelectsV1DirectoryOnly(t *testing.T) {
	h := testComplianceHandler(t)
	results := scanResults(t, h, map[string]any{"frameworks": []string{"eu-ai-act"}, "policyVersion": "v1.0.0"})
	if len(results) != 7 {
		t.Fatalf("eu-ai-act@v1.0.0: %d rows, want 7", len(results))
	}
	for _, r := range results {
		if r.FrameworkVersion != "v1.0.0" {
			t.Errorf("check %q from frameworkVersion %q, want v1.0.0", r.Check, r.FrameworkVersion)
		}
	}
}

// versionedRoot has dirs v2.9 (v2.9.0) and v2.10 (v2.10.0): lexically "v2.9"
// sorts after "v2.10", so only version-aware ordering picks v2.10.0.
func versionedRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	mk := func(dir, version string, checks ...frameworks.Check) {
		writePack(t, root, "vsel", dir, frameworks.Framework{ID: "vsel", Version: version,
			ControlSets: []frameworks.ControlSet{{ID: "CS", Name: "Set", Controls: []frameworks.Control{{ID: "C", Name: "C", Checks: checks}}}}})
	}
	tagged := func(id string, versions ...string) frameworks.Check {
		c := packCheck(id, "true")
		c.PolicyVersions = versions
		return c
	}
	mk("v2.9", "v2.9.0", tagged("shared", "v2.9.0"), tagged("old-only", "v2.9.0"))
	mk("v2.10", "v2.10.0", tagged("shared", "v2.10.0", "v2.9.0"), tagged("new-only", "v2.10.0"), tagged("legacy", "v1.0.0"))
	return root
}

func checkIDs(rs []ComplianceScanResult) []string {
	var ids []string
	for _, r := range rs {
		ids = append(ids, r.FrameworkVersion+":"+r.Check)
	}
	sort.Strings(ids)
	return ids
}

func TestScan_VersionSelection(t *testing.T) {
	h, err := newComplianceHandler(versionedRoot(t))
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		policyVersion string
		want          []string
	}{
		// empty: newest directory (semver, not lexical), all its checks.
		{"", []string{"v2.10.0:legacy", "v2.10.0:new-only", "v2.10.0:shared"}},
		// exact pack-version match wins even though v2.10 also carries v2.9.0.
		{"v2.9.0", []string{"v2.9.0:old-only", "v2.9.0:shared"}},
		{"v2.10.0", []string{"v2.10.0:new-only", "v2.10.0:shared"}},
		// no directory has version v1.0.0: newest directory, filtered.
		{"v1.0.0", []string{"v2.10.0:legacy"}},
	}
	for _, tc := range cases {
		got := checkIDs(scanResults(t, h, map[string]any{"frameworks": []string{"vsel"}, "policyVersion": tc.policyVersion}))
		if len(got) != len(tc.want) {
			t.Errorf("policyVersion %q: got %v, want %v", tc.policyVersion, got, tc.want)
			continue
		}
		for i := range got {
			if got[i] != tc.want[i] {
				t.Errorf("policyVersion %q: got %v, want %v", tc.policyVersion, got, tc.want)
				break
			}
		}
	}
}

func TestCompareVersions(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"v2.10.0", "v2.9.0", 1},
		{"v2.9.0", "v2.10.0", -1},
		{"v1.0.0", "v1.0.0", 0},
		{"v1.0", "v1.0.0", -1},
		{"1.2.0", "v1.10.0", -1},
		{"v10.0.0", "v9.99.99", 1},
	}
	for _, tc := range cases {
		if got := compareVersions(tc.a, tc.b); got != tc.want {
			t.Errorf("compareVersions(%q, %q) = %d, want %d", tc.a, tc.b, got, tc.want)
		}
	}
}
