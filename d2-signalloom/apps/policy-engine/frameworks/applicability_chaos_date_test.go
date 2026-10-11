package frameworks

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

// CHAOS AGAINST THE AS-OF DATE PARSER.
//
// YYYY-MM-DD is a narrow contract, and narrow contracts leak. The failure this
// file exists to exclude is not "a bad date errors" — that one is loud and a
// caller sees a 400. It is the silent one: an input that PARSES and means a
// different day than it reads as. A window compared against the wrong day moves
// priced exposure with nothing anywhere in the response saying so, and the
// evidence bundle records the wrong date as if the caller had asserted it.
//
// Two properties are pinned here, and the second is the one that cannot be
// eyeballed:
//
//  1. every input in testdata/chaos-date-corpus.tsv either errors or parses to
//     exactly the day the corpus declares — never to a third day
//  2. the corpus was actually WALKED. A table-driven chaos test that silently
//     lost half its rows reports PASS identically to one that kept them, so the
//     corpus lives on disk, the count is asserted against a floor, and every
//     input is echoed on a CHAOS-DATE line that test/applicability-chaos.bats
//     diffs against the file. Trim a row and the suite goes red twice.
//
// REUSE NOTE on scripts/jev-test-bot. Its fuzz_api.py was examined for reuse
// and deliberately not used. Its oracle is "no 5xx" — valid client rejections
// 400/401/403/404/422 are recorded as PASS — which is exactly inverted for this
// surface: the defect being hunted here returns HTTP 200 with a wrong verdict,
// which fuzz_api.py scores as a pass. Its payload CATEGORIES (unicode, numbers,
// lengths) are a good checklist and the corpus below covers each of them, but
// the harness itself cannot see this bug class.

const chaosCorpusPath = "testdata/chaos-date-corpus.tsv"

// chaosCorpusFloor is a size gate, not a target. It is the count at the commit
// that introduced the corpus; a run that walks fewer rows than this has lost
// rows rather than found a simpler problem.
const chaosCorpusFloor = 60

type chaosDateCase struct {
	rawLiteral string // the JSON-quoted text as it appears in the file
	input      string // the decoded bytes handed to ParseDate
	wantCanon  string // "" means the input must be rejected
	line       int
}

func loadChaosCorpus(t *testing.T) []chaosDateCase {
	t.Helper()
	f, err := os.Open(chaosCorpusPath)
	if err != nil {
		t.Fatalf("chaos corpus unreadable: %v", err)
	}
	defer f.Close()

	var out []chaosDateCase
	seen := map[string]int{}
	sc := bufio.NewScanner(f)
	for n := 1; sc.Scan(); n++ {
		line := sc.Text()
		if strings.TrimSpace(line) == "" || strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		parts := strings.SplitN(line, "\t", 2)
		if len(parts) != 2 {
			t.Fatalf("%s:%d is not two TAB-separated columns: %q", chaosCorpusPath, n, line)
		}
		input, err := strconv.Unquote(parts[0])
		if err != nil {
			t.Fatalf("%s:%d column 1 is not a JSON-quoted string: %q (%v)", chaosCorpusPath, n, parts[0], err)
		}
		if prev, dup := seen[parts[0]]; dup {
			t.Fatalf("%s:%d duplicates line %d (%s): a duplicated row inflates the corpus count without adding coverage",
				chaosCorpusPath, n, prev, parts[0])
		}
		seen[parts[0]] = n
		want := strings.TrimSpace(parts[1])
		if want == "reject" {
			want = ""
		} else if want == "" {
			t.Fatalf("%s:%d column 2 is empty; want `reject` or a canonical YYYY-MM-DD", chaosCorpusPath, n)
		}
		out = append(out, chaosDateCase{rawLiteral: parts[0], input: input, wantCanon: want, line: n})
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

// THE CENTRAL PROPERTY. Reject, or parse to exactly the declared day. There is
// no third permitted outcome, and the assertion is written against the
// CANONICAL string rather than against a time.Time so a normalising parser
// (2027-02-30 -> 2027-03-02) fails on the value rather than on the error.
func TestChaosDate_ParsesToTheDeclaredDayOrNotAtAll(t *testing.T) {
	corpus := loadChaosCorpus(t)
	if len(corpus) < chaosCorpusFloor {
		t.Fatalf("chaos corpus has %d cases, floor is %d: rows have been lost, and a shrunken corpus passes exactly like a full one",
			len(corpus), chaosCorpusFloor)
	}
	for _, c := range corpus {
		// Echoed unconditionally, pass or fail: the bats suite diffs these
		// lines against the corpus file to prove the walk was complete.
		fmt.Printf("CHAOS-DATE %s\n", c.rawLiteral)

		got, err := ParseDate(c.input)
		switch {
		case c.wantCanon == "":
			if err == nil {
				t.Errorf("%s:%d ParseDate(%s) accepted it as %s; corpus says reject. An input that parses to a day nobody wrote moves exposure silently",
					chaosCorpusPath, c.line, c.rawLiteral, got)
			}
		case err != nil:
			t.Errorf("%s:%d ParseDate(%s) rejected a real calendar day: %v", chaosCorpusPath, c.line, c.rawLiteral, err)
		case got.String() != c.wantCanon:
			t.Errorf("%s:%d ParseDate(%s) = %s, corpus declares %s: THE SILENT CLASS — it parsed, and it means a different day",
				chaosCorpusPath, c.line, c.rawLiteral, got, c.wantCanon)
		}
	}
}

// Every accepted input is its own canonical form. Equivalently: ParseDate is
// idempotent through String(), so an echoed assessmentDate in an evidence
// bundle can be re-parsed to the same day forever.
func TestChaosDate_AcceptedInputsRoundTripExactly(t *testing.T) {
	for _, c := range loadChaosCorpus(t) {
		if c.wantCanon == "" {
			continue
		}
		d, err := ParseDate(c.input)
		if err != nil {
			t.Fatalf("%s:%d: %v", chaosCorpusPath, c.line, err)
		}
		again, err := ParseDate(d.String())
		if err != nil {
			t.Errorf("%s:%d ParseDate rejects its own output %q", chaosCorpusPath, c.line, d.String())
			continue
		}
		if again.String() != d.String() {
			t.Errorf("%s:%d round trip moved the day: %q -> %q -> %q", chaosCorpusPath, c.line, c.input, d.String(), again.String())
		}
		if d.String() != c.input {
			t.Errorf("%s:%d accepted input %s is not canonical (parses to %s): the corpus must only accept canonical forms, or an evidence bundle can carry a date that is not the one compared",
				chaosCorpusPath, c.line, c.rawLiteral, d)
		}
	}
}

// THE CORPUS MUST STAY PLAIN TEXT. A raw NUL in column 1 reads back perfectly
// in Go and makes the whole file a "binary file" to grep, cut and bash — which
// silently broke the bats coverage diff with an encoding artefact that looked
// exactly like a lost row. Escapes only, and this is what keeps it that way.
func TestChaosDate_CorpusIsPlainText(t *testing.T) {
	raw, err := os.ReadFile(chaosCorpusPath)
	if err != nil {
		t.Fatal(err)
	}
	for i, b := range raw {
		if b < 0x09 || (b > 0x0d && b < 0x20) {
			t.Fatalf("%s byte %d is the control character %#x: write it as a backslash escape instead, "+
				"or every shell-side assertion about this file degrades to a binary-file message", chaosCorpusPath, i, b)
		}
	}
}

// THE ROUND-TRIP GUARD'S STATED JUSTIFICATION IS WRONG, and the guard is right
// anyway. ParseDate's comment says "time.Parse normalises 2027-02-30 to
// 2027-03-02 rather than rejecting it", which was true of much older Go: the
// stdlib now range-checks the day against the month and returns
// "day out of range". So the guard is belt-and-braces rather than the only
// thing standing between a typo and a two-day shift, and no input in the corpus
// can reach it — which is why scripts/applicability-chaos-mutations.sh records
// no mutation against it and this test states the real behaviour instead.
//
// Keeping the guard is still correct: it is the only assertion in the function
// that is about the VALUE rather than the error, so it survives a layout change
// or a stdlib regression. This test is what makes such a regression visible.
func TestChaosDate_TheRoundTripGuardsJustificationIsStaleButHarmless(t *testing.T) {
	for _, s := range []string{"2027-02-30", "2027-01-32", "2027-02-29", "2027-13-01"} {
		if _, err := time.Parse(dateLayout, s); err == nil {
			t.Errorf("time.Parse(%q) now succeeds: the stdlib has started normalising out-of-range days again, "+
				"and ParseDate's round-trip guard is the ONLY thing stopping %q from silently becoming a different day", s, s)
		}
		if _, err := ParseDate(s); err == nil {
			t.Errorf("ParseDate(%q) accepted an out-of-range day", s)
		}
	}
}

// THE DEFECT THIS FILE WAS WRITTEN FOR, isolated.
//
// time.Time's zero value is 0001-01-01T00:00:00Z — a real calendar day. Date
// used time.Time.IsZero() as its "nobody supplied a date" sentinel, so the
// first day of year 1 was indistinguishable from an omitted assessmentDate:
// ParseDate accepted it, it round-tripped, the scan echoed it on every row and
// set applicabilityGated:true, and StatusAt returned WindowUnknown for every
// window so NOTHING gated and the full exposure was reported. The sibling day
// 0000-01-01 gated correctly. One day of difference in the input, the entire
// exposure figure of difference in the output, and no error anywhere.
//
// MUTATION PROOF: restore `func (d Date) IsZero() bool { return d.t.IsZero() }`
// and this test fails on the 0001-01-01 row.
func TestChaosDate_YearOneIsADateNotAnAbsence(t *testing.T) {
	absent := Date{}
	if !absent.IsZero() {
		t.Fatal("a Date nobody supplied must report IsZero: it is the sentinel the whole gate keys on")
	}
	for _, day := range []string{"0001-01-01", "0000-01-01", "0001-01-02", "2027-12-11"} {
		d, err := ParseDate(day)
		if err != nil {
			t.Fatalf("ParseDate(%q): %v", day, err)
		}
		if d.IsZero() {
			t.Errorf("ParseDate(%q) reports IsZero: a supplied date is being read as an absent one, so every window degrades to unknown and nothing gates while the summary claims applicabilityGated:true", day)
		}
	}

	// And the consequence, at the level the gate actually runs: a verified
	// future window must gate on year one exactly as it does on year zero.
	win := &Applicability{InForceFrom: "2027-12-11", Basis: BasisEnforcementDate, Source: "x", Verified: true}
	for _, day := range []string{"0000-01-01", "0001-01-01", "0001-01-02", "2020-01-01"} {
		d, err := ParseDate(day)
		if err != nil {
			t.Fatal(err)
		}
		st, gated := win.Gates(d)
		if st != WindowNotYetInForce || !gated {
			t.Errorf("asOf %s against inForceFrom 2027-12-11: status %q gated %v, want %q/true", day, st, gated, WindowNotYetInForce)
		}
	}
}

// The validator keys on the same sentinel, so the same conflation reached it:
// a window declaring inForceFrom 0001-01-01 counted as "no date", which skipped
// the basis requirement and then tripped the inverse rule ("basis with no
// date") on a window that plainly has one.
func TestChaosDate_ValidatorSeesYearOneAsADate(t *testing.T) {
	a := &Applicability{InForceFrom: "0001-01-01", Basis: BasisEnforcementDate, Source: "x", Verified: true}
	if err := validateApplicability("synthetic", a); err != nil {
		t.Errorf("a well-formed window on 0001-01-01 must load; got %v", err)
	}
	// Symmetrically: a date present with no basis is still a basis error.
	b := &Applicability{InForceFrom: "0001-01-01", Source: "x", Verified: true}
	if err := validateApplicability("synthetic", b); err == nil {
		t.Error("inForceFrom 0001-01-01 with no basis must be rejected: a date whose basis is unstated cannot be audited, and year one is a date")
	}
}

// LOCALE AND ZONE INDEPENDENCE. A calendar day in a legal instrument cannot
// depend on where the server is. ParseInLocation(..., time.UTC) is what makes
// this true; the test holds it true by moving time.Local to both hemispheres'
// extremes and re-parsing.
func TestChaosDate_IndifferentToServerTimezone(t *testing.T) {
	orig := time.Local
	t.Cleanup(func() { time.Local = orig })

	const day = "2027-12-11"
	base, err := ParseDate(day)
	if err != nil {
		t.Fatal(err)
	}
	for _, offset := range []int{0, 14 * 3600, -11 * 3600, 5*3600 + 1800} {
		time.Local = time.FixedZone("CHAOS", offset)
		got, err := ParseDate(day)
		if err != nil {
			t.Fatalf("offset %d: %v", offset, err)
		}
		if got.String() != base.String() {
			t.Errorf("offset %d: %q parsed to %s, want %s", offset, day, got, base)
		}
		// And the comparison, not just the parse: the boundary must not move.
		eve, err := ParseDate("2027-12-10")
		if err != nil {
			t.Fatal(err)
		}
		if eve.OnOrAfter(base) {
			t.Errorf("offset %d: 2027-12-10 reads as on-or-after 2027-12-11", offset)
		}
		if !base.OnOrAfter(base) {
			t.Errorf("offset %d: a day is not on-or-after itself", offset)
		}
	}
}
