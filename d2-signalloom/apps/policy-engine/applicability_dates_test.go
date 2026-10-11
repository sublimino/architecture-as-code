package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/frameworks"
)

// Every shipped date is held to the contract that makes it auditable rather
// than merely present. These are data assertions on the packs, not behaviour
// tests of the gate -- the gate itself is pinned against synthetic packs so it
// keeps holding when these dates are corrected.

// A DERIVED DATE, NOT A TYPED ONE. The NIST window's inForceFrom must equal the
// metadata.last-modified recorded in the catalogue's own PROVENANCE.md, so a
// catalogue refresh that moves the date turns this red rather than leaving a
// stale figure behind in three packs. That is the workflow PROVENANCE.md
// already states for the control identifiers: "the catalogue moving is a
// signal, not a nuisance".
func TestNIST80053WindowMatchesTheCatalogueMetadata(t *testing.T) {
	root := conformancePolicyRoot(t)
	prov := filepath.Join(root, "frameworks", "nist-800-53", "catalogue", "PROVENANCE.md")
	raw, err := os.ReadFile(prov)
	if err != nil {
		t.Fatalf("reading the catalogue provenance record: %v", err)
	}
	// | `metadata.last-modified` | `2026-05-11T16:01:09.00000-00:00` |
	m := regexp.MustCompile("`metadata\\.last-modified`[^`]*`(\\d{4}-\\d{2}-\\d{2})").FindSubmatch(raw)
	if m == nil {
		t.Fatalf("%s no longer records metadata.last-modified in the expected table form; "+
			"the NIST window's date is derived from it and cannot be checked", prov)
	}
	want := string(m[1])

	avail, err := frameworks.ListFrameworks(root)
	if err != nil {
		t.Fatal(err)
	}
	versions := avail["nist-800-53"]
	if len(versions) == 0 {
		t.Fatal("no nist-800-53 versions found")
	}
	for _, v := range versions {
		fw, err := frameworks.Load(root, "nist-800-53", v)
		if err != nil {
			t.Fatal(err)
		}
		if fw.Applicability == nil {
			t.Errorf("nist-800-53/%s declares no applicability window", v)
			continue
		}
		if fw.Applicability.InForceFrom != want {
			t.Errorf("nist-800-53/%s inForceFrom = %q, want %q from %s: the date must be DERIVED from the catalogue metadata, not typed",
				v, fw.Applicability.InForceFrom, want, prov)
		}
		if fw.Applicability.Basis != frameworks.BasisPublicationDate {
			t.Errorf("nist-800-53/%s basis = %q, want %s: SP 800-53 is a published standard, not enforced law",
				v, fw.Applicability.Basis, frameworks.BasisPublicationDate)
		}
	}
}

// Every shipped pack must declare a window. Not because every regime has an
// interesting date -- DORA's and NIS2's are years in the past and gate nothing
// -- but because the ABSENCE of a window is indistinguishable from "nobody has
// looked yet", and a regime whose dates nobody has looked at is exactly the
// GBP 256,514 defect. A pack with no window is a pack with no answer.
func TestEveryShippedPackDeclaresAnApplicabilityWindow(t *testing.T) {
	root := conformancePolicyRoot(t)
	avail, err := frameworks.ListFrameworks(root)
	if err != nil {
		t.Fatal(err)
	}
	seen := 0
	for id, versions := range avail {
		for _, v := range versions {
			fw, err := frameworks.Load(root, id, v)
			if err != nil {
				t.Errorf("%s/%s: %v", id, v, err)
				continue
			}
			seen++
			a := fw.Applicability
			if a == nil {
				t.Errorf("%s/%s declares no applicability window: the absence of a date is indistinguishable "+
					"from nobody having looked, which is the defect this gate exists to close", id, v)
				continue
			}
			if a.InForceFrom == "" {
				t.Errorf("%s/%s declares a window with no inForceFrom", id, v)
			}
			// The loader already rejects a verified window with no source and
			// an unverified one with no note; this pins the stronger pack-level
			// rule that EVERY window says where its date came from, verified or
			// not, because an unverified date still has to be re-checkable.
			if strings.TrimSpace(a.Source) == "" {
				t.Errorf("%s/%s window has no source: a date nobody can re-check cannot be audited or promoted", id, v)
			}
			if strings.TrimSpace(a.Note) == "" {
				t.Errorf("%s/%s window has no note: the note is where the article, the caveat and the scope live", id, v)
			}
		}
	}
	if seen < 11 {
		t.Errorf("only %d packs loaded; this test is meant to cover the whole estate", seen)
	}
}

// An EU regulation's window must cite the primary text, not a tracker, a
// summary or a blog. Enforced mechanically because the single most likely way
// to get a statutory date wrong is to read it somewhere convenient: the EU AI
// Act's reported high-risk delay was first carried on the strength of amendment
// markers on artificialintelligenceact.eu, and only the amending regulation on
// EUR-Lex could settle it.
func TestEnforcementDatesCiteThePrimaryText(t *testing.T) {
	root := conformancePolicyRoot(t)
	avail, err := frameworks.ListFrameworks(root)
	if err != nil {
		t.Fatal(err)
	}
	for id, versions := range avail {
		for _, v := range versions {
			fw, err := frameworks.Load(root, id, v)
			if err != nil || fw.Applicability == nil {
				continue
			}
			a := fw.Applicability
			if a.Basis != frameworks.BasisEnforcementDate || !a.Verified {
				continue
			}
			if !strings.Contains(a.Source, "eur-lex.europa.eu") && !strings.Contains(a.Source, "legislation.gov.uk") {
				t.Errorf("%s/%s declares a VERIFIED enforcement date sourced from %q: a statutory date that gates "+
					"a verdict must cite the primary text (eur-lex.europa.eu or legislation.gov.uk), not a tracker or a summary",
					id, v, a.Source)
			}
			if !strings.Contains(a.Note, "Article") && !strings.Contains(a.Note, "Art.") {
				t.Errorf("%s/%s declares a verified enforcement date whose note names no article; "+
					"the provision that sets the date is the citation", id, v)
			}
		}
	}
}
