package frameworks

import (
	"strings"
	"testing"
)

// An applicability window is DECLARED METADATA compared against an as-of date
// the CALLER supplies. Nothing here reads the clock, and nothing here is
// expressible in a celExpression — that is the whole point (hub ADR-0006: no
// date, no expiry, no wall-clock condition in a control body). These tests pin
// the three properties that make it safe:
//
//  1. the comparison is pure — same window, same as-of, same answer, forever;
//  2. an UNVERIFIED window is inert — it is carried and reported, never acted on;
//  3. a window that cannot be read honestly fails to LOAD, loudly, like a
//     malformed risk triple does.

func mustDate(t *testing.T, s string) Date {
	t.Helper()
	d, err := ParseDate(s)
	if err != nil {
		t.Fatalf("ParseDate(%q): %v", s, err)
	}
	return d
}

func TestParseDate_RejectsAnythingButACalendarDay(t *testing.T) {
	for _, bad := range []string{
		"", "2027-12", "2027", "11 Dec 2027", "2027-12-11T00:00:00Z",
		"2027-13-01", "2027-02-30", "2027-12-11 ", "27-12-11", "2027/12/11",
	} {
		if _, err := ParseDate(bad); err == nil {
			t.Errorf("ParseDate(%q) accepted; a window date must be exactly YYYY-MM-DD", bad)
		}
	}
	d, err := ParseDate("2027-12-11")
	if err != nil {
		t.Fatal(err)
	}
	if d.String() != "2027-12-11" {
		t.Errorf("round trip = %q, want 2027-12-11", d.String())
	}
}

// The boundary is INCLUSIVE on inForceFrom and on supersededFrom. Stated as a
// test because an off-by-one day here is a wrong verdict on the day a
// regulation starts applying, which is exactly the day anyone will check.
func TestApplicability_StatusAt_Boundaries(t *testing.T) {
	a := &Applicability{InForceFrom: "2027-12-11", Basis: BasisEnforcementDate, Source: "s", Verified: true}
	for asOf, want := range map[string]WindowStatus{
		"2026-10-11": WindowNotYetInForce,
		"2027-12-10": WindowNotYetInForce,
		"2027-12-11": WindowInForce,
		"2027-12-12": WindowInForce,
		"2099-01-01": WindowInForce,
	} {
		if got := a.StatusAt(mustDate(t, asOf)); got != want {
			t.Errorf("as-of %s: status %v, want %v", asOf, got, want)
		}
	}

	sup := &Applicability{InForceFrom: "2018-05-25", SupersededFrom: "2030-01-01", Basis: BasisEnforcementDate, Source: "s", Verified: true}
	for asOf, want := range map[string]WindowStatus{
		"2018-05-24": WindowNotYetInForce,
		"2018-05-25": WindowInForce,
		"2029-12-31": WindowInForce,
		"2030-01-01": WindowSuperseded,
		"2031-01-01": WindowSuperseded,
	} {
		if got := sup.StatusAt(mustDate(t, asOf)); got != want {
			t.Errorf("superseded window, as-of %s: status %v, want %v", asOf, got, want)
		}
	}
}

// A window with no inForceFrom says nothing about time; it must not gate.
func TestApplicability_StatusAt_NoDateIsUnknown(t *testing.T) {
	for name, a := range map[string]*Applicability{
		"nil":       nil,
		"zero":      {},
		"note only": {Note: "pending research", Verified: false},
		// A supersededFrom in the future with no start date says only "this has
		// not stopped yet", which is not a statement that it has started.
		"superseded only, not yet reached": {SupersededFrom: "2030-01-01", Basis: BasisEnforcementDate, Source: "s", Verified: true},
	} {
		if got := a.StatusAt(mustDate(t, "2026-10-11")); got != WindowUnknown {
			t.Errorf("%s: status %v, want WindowUnknown", name, got)
		}
		if _, gates := a.Gates(mustDate(t, "2026-10-11")); gates {
			t.Errorf("%s: gated with no governing start date", name)
		}
	}
	// A zero as-of date is the "caller stated no date" case and must never gate,
	// whatever the window says. This is the default-behaviour property.
	strict := &Applicability{InForceFrom: "2027-12-11", Basis: BasisEnforcementDate, Source: "s", Verified: true}
	if st, gates := strict.Gates(Date{}); gates || st != WindowUnknown {
		t.Errorf("a zero as-of date gated: status %v gates %v", st, gates)
	}
}

// THE SAFETY PROPERTY. An unverified date must never silently change a verdict.
// Gating asks Gates(), not StatusAt(): StatusAt reports what the declared dates
// say, Gates reports whether the engine is allowed to act on it.
func TestApplicability_UnverifiedWindowNeverGates(t *testing.T) {
	unverified := &Applicability{
		InForceFrom: "2027-12-02",
		Basis:       BasisEnforcementDate,
		Source:      "https://artificialintelligenceact.eu/",
		Note:        "amendment markers only; the amending regulation has not been read",
		Verified:    false,
	}
	asOf := mustDate(t, "2026-10-11")
	if got := unverified.StatusAt(asOf); got != WindowNotYetInForce {
		t.Fatalf("StatusAt still reports the declared window: got %v, want WindowNotYetInForce", got)
	}
	if st, gates := unverified.Gates(asOf); gates {
		t.Errorf("an unverified window gated the verdict (status %v); verified:false must be inert", st)
	}

	verified := *unverified
	verified.Verified = true
	st, gates := verified.Gates(asOf)
	if !gates || st != WindowNotYetInForce {
		t.Errorf("a verified future window did not gate: status %v gates %v", st, gates)
	}
}

// Resolution is MOST-SPECIFIC-WINS-WHOLE, never a field merge: a window that
// overrides another replaces it entirely, so every window in a pack carries its
// own citation and nobody can inherit a date from one source under the basis of
// another.
func TestResolveApplicability_MostSpecificWinsWhole(t *testing.T) {
	fwWin := &Applicability{InForceFrom: "2027-12-11", Basis: BasisEnforcementDate, Source: "fw", Verified: true}
	csWin := &Applicability{InForceFrom: "2026-06-11", Basis: BasisEnforcementDate, Source: "cs", Verified: true}
	ctrlWin := &Applicability{InForceFrom: "2026-09-11", Basis: BasisEnforcementDate, Source: "ctrl", Verified: true}
	chkWin := &Applicability{InForceFrom: "2025-08-02", Basis: BasisEnforcementDate, Source: "chk", Verified: true}

	fw := &Framework{Applicability: fwWin}
	cs := ControlSet{}
	ctrl := Control{}
	chk := Check{}

	for _, tc := range []struct {
		name             string
		csW, ctrlW, chkW *Applicability
		wantSource       string
	}{
		{"framework only", nil, nil, nil, "fw"},
		{"control set overrides framework", csWin, nil, nil, "cs"},
		{"control overrides control set", csWin, ctrlWin, nil, "ctrl"},
		{"check overrides control", csWin, ctrlWin, chkWin, "chk"},
		{"check overrides framework directly", nil, nil, chkWin, "chk"},
	} {
		cs.Applicability, ctrl.Applicability, chk.Applicability = tc.csW, tc.ctrlW, tc.chkW
		got := ResolveApplicability(fw, cs, ctrl, chk)
		if got == nil || got.Source != tc.wantSource {
			t.Errorf("%s: resolved source %v, want %q", tc.name, got, tc.wantSource)
		}
	}

	if got := ResolveApplicability(&Framework{}, ControlSet{}, Control{}, Check{}); got != nil {
		t.Errorf("a pack declaring no window resolved to %v, want nil", got)
	}
}

// LOADER GATE. Same reasoning as the malformed-triple gate: a window with no
// defensible reading must fail to load rather than quietly gate (or quietly
// fail to gate) a regulation.
func TestLoad_RejectsMalformedApplicability(t *testing.T) {
	for name, tc := range map[string]struct{ window, want string }{
		"unparseable inForceFrom": {
			`{"inForceFrom":"11 Dec 2027","basis":"enforcement-date","source":"s","verified":true}`,
			"inForceFrom",
		},
		"unparseable supersededFrom": {
			`{"inForceFrom":"2027-12-11","supersededFrom":"soon","basis":"enforcement-date","source":"s","verified":true}`,
			"supersededFrom",
		},
		"unknown basis": {
			`{"inForceFrom":"2027-12-11","basis":"vibes","source":"s","verified":true}`,
			"basis",
		},
		"basis missing with a date": {
			`{"inForceFrom":"2027-12-11","source":"s","verified":true}`,
			"basis",
		},
		"verified without a source": {
			`{"inForceFrom":"2027-12-11","basis":"enforcement-date","verified":true}`,
			"source",
		},
		"unverified without a note": {
			`{"inForceFrom":"2027-12-11","basis":"enforcement-date","source":"s","verified":false}`,
			"note",
		},
		"superseded before in force": {
			`{"inForceFrom":"2027-12-11","supersededFrom":"2027-12-11","basis":"enforcement-date","source":"s","verified":true}`,
			"supersededFrom",
		},
	} {
		body := strings.Replace(canonicalJSON, `"id":"x"`, `"id":"x","applicability":`+tc.window, 1)
		_, err := Load(writePack(t, "x", "v1.0", map[string]string{"framework.json": body}), "x", "v1.0")
		if err == nil {
			t.Errorf("%s: loaded silently", name)
			continue
		}
		if !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: error %q does not name %q", name, err.Error(), tc.want)
		}
	}
}

// The gate must fire at every level a window may be declared, not only the
// framework. Pinned per level because a loop that forgets one level is the
// obvious way to ship an unvalidated date.
func TestLoad_ValidatesApplicabilityAtEveryLevel(t *testing.T) {
	bad := `{"inForceFrom":"not-a-date","basis":"enforcement-date","source":"s","verified":true}`
	for name, from := range map[string]string{
		"framework":   `"id":"x"`,
		"control set": `"id":"cs"`,
		"control":     `"id":"c1"`,
		"check":       `"id":"ok"`,
	} {
		body := strings.Replace(canonicalJSON, from, from+`,"applicability":`+bad, 1)
		_, err := Load(writePack(t, "x", "v1.0", map[string]string{"framework.json": body}), "x", "v1.0")
		if err == nil || !strings.Contains(err.Error(), "inForceFrom") {
			t.Errorf("%s-level window not validated: %v", name, err)
		}
	}
}

func TestLoad_AcceptsWellFormedApplicability(t *testing.T) {
	window := `{"inForceFrom":"2027-12-11","basis":"enforcement-date","source":"https://eur-lex.europa.eu/eli/reg/2024/2847/oj","note":"Article 71(2)","verified":true}`
	body := strings.Replace(canonicalJSON, `"id":"x"`, `"id":"x","applicability":`+window, 1)
	fw, err := Load(writePack(t, "x", "v1.0", map[string]string{"framework.json": body}), "x", "v1.0")
	if err != nil {
		t.Fatal(err)
	}
	if fw.Applicability == nil || fw.Applicability.InForceFrom != "2027-12-11" || !fw.Applicability.Verified {
		t.Fatalf("applicability not loaded: %+v", fw.Applicability)
	}
	st, gates := fw.Applicability.Gates(mustDate(t, "2027-12-10"))
	if !gates || st != WindowNotYetInForce {
		t.Errorf("status %v gates %v, want WindowNotYetInForce true", st, gates)
	}
}

// YAML must be held to the same contract as JSON; the loader has two decoders
// and only one of them was exercised by the cases above.
func TestLoad_ValidatesApplicabilityFromYAML(t *testing.T) {
	body := "id: x\nname: X\napplicability:\n  inForceFrom: nope\n  basis: enforcement-date\n  source: s\n  verified: true\ncontrolSets:\n  - id: cs\n    name: CS\n    controls:\n      - id: c1\n        name: C1\n        checks:\n          - id: ok\n            name: ok\n            celExpression: \"true\"\n            riskTriple: {min: 1, mode: 2, max: 3}\n            freqTriple: {min: 0.1, mode: 0.2, max: 0.3}\n            policyVersions: [\"v1.0.0\"]\n"
	_, err := Load(writePack(t, "x", "v1.0", map[string]string{"framework.yaml": body}), "x", "v1.0")
	if err == nil || !strings.Contains(err.Error(), "inForceFrom") {
		t.Fatalf("want inForceFrom error from YAML, got %v", err)
	}
}

// ADR-0006, enforced mechanically rather than by review: no shipped check may
// smuggle a date or a clock read into its celExpression. The window is the
// ONLY place time is allowed to live.
func TestShippedPacks_NoDateOrClockInAnyCELExpression(t *testing.T) {
	root := testPolicyRoot(t)
	avail, err := ListFrameworks(root)
	if err != nil {
		t.Fatal(err)
	}
	banned := []string{"now()", "timestamp(", "duration(", "getFullYear", "getDate", "getMonth"}
	for id, versions := range avail {
		for _, v := range versions {
			fw, err := Load(root, id, v)
			if err != nil {
				t.Errorf("%s/%s: %v", id, v, err)
				continue
			}
			for _, cs := range fw.ControlSets {
				for _, ctrl := range cs.Controls {
					for _, chk := range ctrl.Checks {
						for _, b := range banned {
							if strings.Contains(chk.CELExpression, b) {
								t.Errorf("%s/%s check %q celExpression contains %q: ADR-0006 forbids a wall-clock condition in a control body", id, v, chk.ID, b)
							}
						}
						if dateLike.MatchString(chk.CELExpression) {
							t.Errorf("%s/%s check %q celExpression contains a literal date: ADR-0006 forbids a date in a control body", id, v, chk.ID)
						}
					}
				}
			}
		}
	}
}
