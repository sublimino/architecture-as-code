package privacy

import (
	"strings"
	"testing"
)

// TestLegalGround_EnumerationIsExactlyFive pins the enumeration to the Regulation.
//
// Article 17(3) has exactly five subparagraphs, (a) through (e). The count assertion is not
// ceremony: an enumeration that can quietly grow is an enumeration that can acquire
// "art17_3_f_business_need", at which point the "enumerated ground" requirement means nothing. A
// sixth entry should require someone to change this number and explain themselves.
func TestLegalGround_EnumerationIsExactlyFive(t *testing.T) {
	if len(AllLegalGrounds) != 5 {
		t.Fatalf("AllLegalGrounds has %d entries, want exactly 5 (Article 17(3)(a)-(e)): %v", len(AllLegalGrounds), AllLegalGrounds)
	}
	seen := map[LegalGround]bool{}
	for _, g := range AllLegalGrounds {
		if seen[g] {
			t.Errorf("duplicate ground %q in AllLegalGrounds", g)
		}
		seen[g] = true
	}
	for _, want := range []LegalGround{
		GroundFreedomOfExpression, GroundLegalObligation, GroundPublicHealth,
		GroundArchivingResearch, GroundLegalClaims,
	} {
		if !seen[want] {
			t.Errorf("AllLegalGrounds is missing %q", want)
		}
	}
}

func TestLegalGround_Valid(t *testing.T) {
	for _, g := range AllLegalGrounds {
		if !g.Valid() {
			t.Errorf("enumerated ground %q reports invalid", g)
		}
	}
	for _, g := range []LegalGround{"", " ", "art17_3_f", "legal_claims", "GroundLegalClaims", "Article 17(3)(e)"} {
		if g.Valid() {
			t.Errorf("unenumerated ground %q reports valid", g)
		}
	}
}

// TestLegalGround_DescriptionIsNeverEmpty covers the unknown case explicitly.
//
// An empty description is indistinguishable from "this field was not populated", so a refusal body
// whose ground description is blank reads as a broken feature rather than as an unenumerated
// ground. The marker must be non-empty AND must say what is wrong.
func TestLegalGround_DescriptionIsNeverEmpty(t *testing.T) {
	for _, g := range AllLegalGrounds {
		d := g.Description()
		if d == "" {
			t.Errorf("ground %q has an empty description", g)
		}
		if !strings.Contains(d, "Article 17(3)") {
			t.Errorf("ground %q description does not cite the Article: %q", g, d)
		}
	}
	unknown := LegalGround("something-else").Description()
	if unknown == "" {
		t.Fatal("an unknown ground returns an empty description; empty is indistinguishable from unpopulated")
	}
	if !strings.Contains(unknown, "unknown") {
		t.Errorf("an unknown ground's description does not say so: %q", unknown)
	}
	// Discriminating check: the unknown marker must NOT be one of the real descriptions, or a bug
	// that returned a default enumerated description would pass the non-empty assertion above.
	for _, g := range AllLegalGrounds {
		if unknown == g.Description() {
			t.Errorf("an unknown ground returns the description of %q", g)
		}
	}
}

// The cross-artifact guard that used to live here has been REMOVED, deliberately, and this note
// stands in its place so nobody re-adds it without reading why.
//
// It asserted that migration 008's CHECK constraint on retention_exceptions.ground admitted exactly
// the five values in AllLegalGrounds. That table no longer exists: adversarial review established
// that nothing in the Go tree ever wrote it, so every constraint on it was unreachable through the
// application — defence in depth that a reader would cite and that did not exist. Both the table and
// its constraints were deleted rather than caveated.
//
// The consequence for testing is worth stating rather than quietly absorbing: the Article 17(3)
// enumeration is now enforced in ONE place, privacy.LegalGround.Valid, and there is no database
// backstop behind it. TestLegalGround_Valid and the mutation harness's enumerated-ground case are
// the whole of the evidence. When SLDP-P6-1 persists exceptions, the CHECK constraint and this
// cross-artifact guard should both come back together.
