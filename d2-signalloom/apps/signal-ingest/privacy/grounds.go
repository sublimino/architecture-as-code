package privacy

// LegalGround is one of the exhaustive exemptions in GDPR Article 17(3), under which the right to
// erasure in Article 17(1) does not apply.
//
// It is a named type rather than a bare string so that a free-form justification cannot reach a
// function expecting a ground. "Ongoing investigation", "legal asked us to", and "" are all valid
// Go strings and none of them is an Article 17(3) ground; the type plus [LegalGround.Valid] is what
// makes the enumeration enforceable rather than documentary.
type LegalGround string

const (
	// GroundFreedomOfExpression is Article 17(3)(a): exercising the right of freedom of expression
	// and information.
	GroundFreedomOfExpression LegalGround = "art17_3_a_freedom_of_expression"

	// GroundLegalObligation is Article 17(3)(b): compliance with a legal obligation requiring
	// processing under Union or Member State law, or performance of a task carried out in the
	// public interest or in the exercise of official authority.
	GroundLegalObligation LegalGround = "art17_3_b_legal_obligation"

	// GroundPublicHealth is Article 17(3)(c): reasons of public interest in the area of public
	// health, per Article 9(2)(h) and (i) and Article 9(3).
	GroundPublicHealth LegalGround = "art17_3_c_public_health"

	// GroundArchivingResearch is Article 17(3)(d): archiving purposes in the public interest,
	// scientific or historical research purposes, or statistical purposes per Article 89(1), where
	// erasure is likely to render impossible or seriously impair the achievement of that
	// processing.
	GroundArchivingResearch LegalGround = "art17_3_d_archiving_research"

	// GroundLegalClaims is Article 17(3)(e): the establishment, exercise or defence of legal
	// claims.
	//
	// This is the ground that matters operationally here. A subject tied to an unresolved security
	// incident is a subject about whom legal claims may be established, exercised or defended, and
	// (e) is therefore the ground a legitimate override will almost always name. It is deliberately
	// not the only enumerated value: hard-coding one ground would make the enumeration decorative
	// and would silently mis-label an override granted for, say, a statutory retention obligation.
	GroundLegalClaims LegalGround = "art17_3_e_legal_claims"
)

// AllLegalGrounds enumerates every ground admitted by this package.
//
// Article 17(3) is exhaustive — it has exactly five subparagraphs — so this slice is complete by
// construction rather than by convention. TestLegalGround_EnumerationIsExactlyFive asserts the
// count, so adding a sixth entry without a corresponding regulatory change fails the suite.
var AllLegalGrounds = []LegalGround{
	GroundFreedomOfExpression,
	GroundLegalObligation,
	GroundPublicHealth,
	GroundArchivingResearch,
	GroundLegalClaims,
}

// Valid reports whether g is one of the five enumerated Article 17(3) grounds.
//
// The empty string is not valid. This is the check that turns "reject free-form permanent
// overrides" from a policy sentence into a refused request.
func (g LegalGround) Valid() bool {
	for _, known := range AllLegalGrounds {
		if g == known {
			return true
		}
	}
	return false
}

// String returns the ground's wire value.
func (g LegalGround) String() string { return string(g) }

// Description returns the human-readable statement of the ground, for refusal bodies and audit
// detail where an operator has to act on what they read.
//
// An unrecognised ground returns a non-empty marker rather than the empty string. Empty would be
// indistinguishable from "this field was not populated", and a refusal body whose ground field is
// blank reads as a broken feature rather than as an unenumerated ground.
func (g LegalGround) Description() string {
	switch g {
	case GroundFreedomOfExpression:
		return "Article 17(3)(a): exercising the right of freedom of expression and information"
	case GroundLegalObligation:
		return "Article 17(3)(b): compliance with a legal obligation or performance of a public-interest task"
	case GroundPublicHealth:
		return "Article 17(3)(c): reasons of public interest in the area of public health"
	case GroundArchivingResearch:
		return "Article 17(3)(d): archiving in the public interest, scientific or historical research, or statistical purposes"
	case GroundLegalClaims:
		return "Article 17(3)(e): establishment, exercise or defence of legal claims"
	default:
		return "unknown ground: not one of the five enumerated Article 17(3) exemptions"
	}
}
