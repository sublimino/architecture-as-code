package frameworks

import (
	"fmt"
	"regexp"
	"strings"
	"time"
)

// APPLICABILITY WINDOWS — why this is metadata and not a CEL expression.
//
// Hub ADR-0006 forbids a date, an expiry or a wall-clock condition inside a
// control body, and the precedent is stated in full on
// risk/packs/agent-policy/2.1.0/cel/agt-c01-conditional-autonomy.yaml:10-11:
// "Time-bounding is expressed as a bounded scope ... not as a countdown the
// engine evaluates." So no celExpression in this repository may contain a date,
// and nothing anywhere in the evaluation path may call now().
//
// A regime still has a date. The EU CRA's essential requirements do not apply
// until 11 December 2027; pricing a breach of them today is wrong by statute,
// not by opinion. The resolution is the one risk/fx/rates.yaml:14-19 already
// uses for money: DECLARED DATA plus an EXPLICIT AS-OF SUPPLIED BY THE CALLER.
// The FX table does not look up a live rate, it records the date the rates were
// observed and carries it with every converted figure. A window does the same:
// it records when an obligation starts, the caller states the date it is asking
// about, and the engine does one pure comparison between two values it was
// given.
//
// That distinction is the whole reproducibility argument. A scan evidenced with
// assessmentDate=2026-10-11 replays to the identical verdicts in 2030, because
// nothing in the comparison moves. `now()` would make the same request return
// different answers on different days, which is precisely the property the FAIR
// engine pins its seed to avoid: "a number nobody can reproduce is not
// evidence".
//
// Note how this sits beside hub ADR-0007 ("advisory metadata carried, never
// consumed by the engine"). An applicability window IS consumed by the engine,
// deliberately. It is not advisory, and the ADR-0007 reasoning does not reach
// it, because the thing consumed is a declared constant compared against a
// caller-supplied constant — not a side channel and not a clock.

// Date is a calendar day with no time and no zone. A window boundary is a day
// in a legal instrument, not an instant: "applies from 11 December 2027" names
// a date, and attaching a time to it would invent a precision the source does
// not have and make the answer depend on the reader's timezone.
type Date struct{ t time.Time }

const dateLayout = "2006-01-02"

// dateLike is the ADR-0006 tripwire: any YYYY-MM-DD in a control body.
var dateLike = regexp.MustCompile(`\b\d{4}-\d{2}-\d{2}\b`)

// ParseDate accepts exactly YYYY-MM-DD. It is strict on purpose: a lenient
// parser that accepted "2027-12" would silently pick a day, and a window that
// gates a regulation cannot have a day nobody chose.
func ParseDate(s string) (Date, error) {
	if s != strings.TrimSpace(s) {
		return Date{}, fmt.Errorf("date %q has surrounding whitespace; want YYYY-MM-DD", s)
	}
	t, err := time.ParseInLocation(dateLayout, s, time.UTC)
	if err != nil {
		return Date{}, fmt.Errorf("date %q is not a calendar day in YYYY-MM-DD form", s)
	}
	// time.Parse normalises 2027-02-30 to 2027-03-02 rather than rejecting it.
	if t.Format(dateLayout) != s {
		return Date{}, fmt.Errorf("date %q is not a real calendar day (it normalises to %s)", s, t.Format(dateLayout))
	}
	return Date{t: t}, nil
}

func (d Date) String() string { return d.t.Format(dateLayout) }

// IsZero reports an absent date.
func (d Date) IsZero() bool { return d.t.IsZero() }

// OnOrAfter is the inclusive comparison every boundary uses: a regulation that
// "applies from" a date applies ON that date.
func (d Date) OnOrAfter(other Date) bool { return !d.t.Before(other.t) }

// Basis names what a window's date actually IS. Two regimes can both carry
// "2027-12-11" and mean entirely different things, and a reader who cannot tell
// an enforcement date from a publication date cannot audit the gate.
const (
	// BasisEnforcementDate: the instrument itself states a date from which the
	// obligations apply (an EU regulation's "applies from" article).
	BasisEnforcementDate = "enforcement-date"
	// BasisPublicationDate: a standard, benchmark or guidance document with no
	// enforcement of its own. The date is when the document was published.
	BasisPublicationDate = "publication-date"
	// BasisTranspositionDeadline: a DIRECTIVE, which binds Member States and
	// not entities. The date is the deadline by which national law must exist,
	// NOT a date on which an obligation begins for anyone scanned. See the note
	// requirement below: a window on this basis must say so.
	BasisTranspositionDeadline = "transposition-deadline"
)

var validBases = map[string]bool{
	BasisEnforcementDate:       true,
	BasisPublicationDate:       true,
	BasisTranspositionDeadline: true,
}

// Applicability declares when a regime's obligations exist. It is declared data
// with a citation, never a condition the engine computes.
//
// It may be declared at four levels — framework, control set, control, check —
// because regimes genuinely split. The CRA is the worked example: Article 71
// gives general application on 11 December 2027, Article 14 reporting duties
// from 11 September 2026 and Chapter IV from 11 June 2026, so one date for the
// whole instrument would be wrong three ways.
type Applicability struct {
	// InForceFrom is the first day the obligation applies, inclusive.
	InForceFrom string `json:"inForceFrom,omitempty" yaml:"inForceFrom,omitempty"`
	// SupersededFrom is the first day it no longer does, inclusive. Absent for
	// every regime shipped today; present so a repealed or replaced instrument
	// can be retired without deleting the evidence trail of scans that ran
	// while it was live.
	SupersededFrom string `json:"supersededFrom,omitempty" yaml:"supersededFrom,omitempty"`
	// Basis is one of the Basis* constants. Required whenever a date is set.
	Basis string `json:"basis,omitempty" yaml:"basis,omitempty"`
	// Source is where the date was read. Required when Verified is true: a date
	// nobody can re-check is not verified, it is asserted.
	Source string `json:"source,omitempty" yaml:"source,omitempty"`
	// Note is the reasoning — which article, what the date does and does not
	// mean. Required when Verified is false, where it must say what is missing.
	Note string `json:"note,omitempty" yaml:"note,omitempty"`
	// Jurisdiction scopes the window. Empty means the window is stated by the
	// instrument itself. For a directive the in-force date is PER MEMBER STATE
	// and no single EU-wide date exists, so a window that asserts one must name
	// the jurisdiction it is asserting it for.
	Jurisdiction string `json:"jurisdiction,omitempty" yaml:"jurisdiction,omitempty"`
	// Verified is true only when someone read the primary text at Source. It is
	// the gate's master switch: an unverified window is carried, reported and
	// NEVER acted on. See Gates.
	Verified bool `json:"verified" yaml:"verified"`
}

// WindowStatus is what a window says about one as-of date.
type WindowStatus string

const (
	// WindowUnknown: no window governs this check, or it declares no start
	// date. Says nothing about time; never gates.
	WindowUnknown WindowStatus = "unknown"
	// WindowInForce: the obligation exists on the as-of date.
	WindowInForce WindowStatus = "in_force"
	// WindowNotYetInForce: the as-of date is before the obligation starts.
	WindowNotYetInForce WindowStatus = "not_yet_in_force"
	// WindowSuperseded: the as-of date is on or after the day it stopped.
	WindowSuperseded WindowStatus = "superseded"
)

// StatusAt reports what the DECLARED dates say, regardless of Verified. It is
// the honest reading of the metadata and is what a report shows a human.
func (a *Applicability) StatusAt(asOf Date) WindowStatus {
	if a == nil || asOf.IsZero() {
		return WindowUnknown
	}
	if a.SupersededFrom != "" {
		if d, err := ParseDate(a.SupersededFrom); err == nil && asOf.OnOrAfter(d) {
			return WindowSuperseded
		}
	}
	if a.InForceFrom == "" {
		return WindowUnknown
	}
	d, err := ParseDate(a.InForceFrom)
	if err != nil {
		// Unreachable through Load, which rejects an unparseable date. Reported
		// as unknown rather than panicking so a hand-built Applicability in a
		// test or a future caller degrades to "no opinion" instead of to a
		// verdict.
		return WindowUnknown
	}
	if asOf.OnOrAfter(d) {
		return WindowInForce
	}
	return WindowNotYetInForce
}

// Gates reports whether the engine may ACT on this window, and the status if it
// may. It is the only function the scan path calls.
//
// THE SAFETY PROPERTY, and the reason this is separate from StatusAt: an
// unverified date must never silently change a verdict. The EU AI Act's
// reported 2 December 2027 high-risk delay is corroborated only by amendment
// markers on a third-party tracker; nobody here has read the amending
// regulation. It is declared, it is reported with verified:false and its note
// says why — and it gates nothing until someone reads the primary text and
// flips the flag in a reviewed pull request.
//
// The default is therefore FAIL OPEN, and that is the conservative direction
// for this gate specifically: a window that does not fire leaves the check
// evaluating and its exposure counted, exactly as before the gate existed. A
// fail-CLOSED default would let a typo'd or unresearched date erase priced
// exposure from a report, which is the more expensive mistake by far.
func (a *Applicability) Gates(asOf Date) (WindowStatus, bool) {
	st := a.StatusAt(asOf)
	if a == nil || !a.Verified || st == WindowUnknown || st == WindowInForce {
		return st, false
	}
	return st, true
}

// ResolveApplicability returns the ONE window governing a check: check, then
// control, then control set, then framework. Most specific wins WHOLE — a
// window never inherits a field from the level above it.
//
// Whole-replacement rather than a field merge, because a merge would let a
// check inherit `source` from the framework while overriding `inForceFrom`,
// producing a window whose citation points at a document that does not state
// its date. Every window carries its own citation or it is not a window.
func ResolveApplicability(fw *Framework, cs ControlSet, ctrl Control, chk Check) *Applicability {
	for _, a := range []*Applicability{chk.Applicability, ctrl.Applicability, cs.Applicability} {
		if a != nil {
			return a
		}
	}
	if fw != nil {
		return fw.Applicability
	}
	return nil
}

// validateApplicability enforces the shape contract. Same reasoning as the
// malformed-triple gate in validate(): the loader has no opinion on whether 11
// December 2027 is the right date for the CRA, and deliberately never will. It
// does have an opinion on a date that is not a date, a basis that names nothing,
// a verified claim with no source and an unverified one with no explanation —
// those have no defensible reading, and a pack carrying one must fail to load.
func validateApplicability(where string, a *Applicability) error {
	if a == nil {
		return nil
	}
	inForce, supersededSet := Date{}, false
	if a.InForceFrom != "" {
		d, err := ParseDate(a.InForceFrom)
		if err != nil {
			return fmt.Errorf("%s applicability inForceFrom: %w", where, err)
		}
		inForce = d
	}
	if a.SupersededFrom != "" {
		d, err := ParseDate(a.SupersededFrom)
		if err != nil {
			return fmt.Errorf("%s applicability supersededFrom: %w", where, err)
		}
		if !inForce.IsZero() && !d.t.After(inForce.t) {
			return fmt.Errorf("%s applicability supersededFrom %s is not after inForceFrom %s: the window would never be in force",
				where, a.SupersededFrom, a.InForceFrom)
		}
		supersededSet = true
	}
	hasDate := !inForce.IsZero() || supersededSet
	if hasDate && !validBases[a.Basis] {
		return fmt.Errorf("%s applicability basis %q must be one of %s, %s, %s: a date whose basis is unstated cannot be audited",
			where, a.Basis, BasisEnforcementDate, BasisPublicationDate, BasisTranspositionDeadline)
	}
	if !hasDate && a.Basis != "" {
		return fmt.Errorf("%s applicability declares basis %q with no date", where, a.Basis)
	}
	if a.Verified {
		if strings.TrimSpace(a.Source) == "" {
			return fmt.Errorf("%s applicability is verified:true with no source: a date nobody can re-check is asserted, not verified", where)
		}
	} else if hasDate && strings.TrimSpace(a.Note) == "" {
		return fmt.Errorf("%s applicability is verified:false with no note: say what is missing, so the next reader knows what to go and read", where)
	}
	if a.Basis == BasisTranspositionDeadline && strings.TrimSpace(a.Note) == "" {
		return fmt.Errorf("%s applicability basis is %s with no note: a directive has no single in-force date and the window must say so", where, BasisTranspositionDeadline)
	}
	return nil
}
