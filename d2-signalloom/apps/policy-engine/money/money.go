// Package money gives every figure in the risk model an explicit denomination, and converts
// between denominations from a checked-in, dated rate table.
//
// WHY THIS PACKAGE EXISTS.
//
// Before it, every money field in the model was a bare float64 with the currency welded into the
// field NAME — annual_cost_gbp, tolerance_gbp, per_deny_control_gbp. That arrangement has three
// failure modes and the repository was exposed to all three:
//
//  1. Nothing could convert, because no value carried a currency as data. A UI defaulting to USD
//     over GBP source data would relabel the number rather than convert it.
//  2. Nothing could be checked. Two amounts in different currencies could be added, compared or
//     thresholded by any code that compiled, because to the compiler they were both float64.
//  3. The currency lived in a name, and names are not carried across a wire, a database column,
//     or a chart axis.
//
// Money fixes (1) and (3) by making the denomination part of the value. It fixes (2) as far as Go
// permits: a bare float64 will not compile where a Money is expected, so the conversions the model
// needs are forced to be explicit and auditable at the point of use.
//
// WHY THE RATES ARE CHECKED IN AND DATED.
//
// The same reason the FAIR engine pins its seed: "a number nobody can reproduce is not evidence."
// A figure quoted on stage, in a board pack, or in a regulatory submission must be the same figure
// tomorrow, next quarter, and in the audit. A live FX lookup makes every historical report
// irreproducible and injects a network dependency into a tool whose entire pitch is that it runs
// offline. The table is data in the repository, it carries an effective date, and changing it is a
// reviewed pull request that re-versions the money alongside the policy.
//
// THE ROUNDING DECISION — MADE ONCE, HERE.
//
//	Convert NEVER rounds. Round is a separate, explicit, presentation-only operation.
//
// Rationale. Conversion is a scalar multiply and the risk pipeline applies it across a 200,000-
// iteration Monte Carlo aggregation. Rounding inside that loop accumulates: 200,000 half-penny
// errors do not cancel, they random-walk, and the resulting figure disagrees with the same figure
// computed a different way — which is a support ticket, and on a compliance number a credibility
// problem. So intermediate values stay at full float64 precision and rounding happens exactly once,
// at the boundary where a human reads the figure.
//
// Where we do round, we round HALF AWAY FROM ZERO on the shortest decimal representation of the
// value, not Go's default round-half-to-even on the exact binary value. Two reasons. Half-away-from-
// zero is what a reader gets with a calculator, and a compliance figure that disagrees with the
// reader's own arithmetic is indefensible in the room. Operating on the shortest decimal repr means
// 2.675 rounds to 2.68 as written, rather than to 2.67 because the nearest double happens to sit a
// hair below the half. See TestRoundHalfAwayFromZero.
//
// The minor-unit exponent comes from the currency: 2 for GBP/USD/EUR, 0 for JPY, 3 for KWD. Printing
// a JPY figure to two decimal places prints a quantity of money that cannot exist.
//
// WHY A MISSING RATE IS AN ERROR.
//
// A conversion that quietly passes the number through unchanged is the single worst failure mode
// available here: it produces a plausible figure, with the wrong label, with no warning, and it is
// invisible until someone in the audience does the division. Convert returns an error naming both
// sides of the missing pair and the table's effective date, and returns the ZERO Converted so a
// caller that ignores the error cannot mistake the result for a real amount.
package money

import (
	"fmt"
	"math"
	"os"
	"sort"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

// Currency is an ISO 4217 alphabetic code: exactly three uppercase letters.
type Currency string

// Validate enforces the ISO 4217 alphabetic shape.
//
// We deliberately do not check membership of the full ISO 4217 list. That list changes (currencies
// are redenominated and retired), and embedding a stale copy would reject a legitimate code with a
// message the operator cannot act on. The binding constraint that actually matters is membership of
// the rate table, and that IS enforced — at conversion, with a message naming the missing pair.
func (c Currency) Validate() error {
	if c == "" {
		return fmt.Errorf("currency is empty; every amount must declare its denomination")
	}
	if len(c) != 3 {
		return fmt.Errorf("currency %q is not a three-letter ISO 4217 code", c)
	}
	for _, r := range c {
		if r < 'A' || r > 'Z' {
			return fmt.Errorf("currency %q is not a three-letter ISO 4217 code (uppercase letters only)", c)
		}
	}
	return nil
}

// minorUnits holds the ISO 4217 minor-unit exponent for every currency whose exponent is not 2.
// Two is the overwhelmingly common case and the fallback, so only the exceptions are listed.
var minorUnits = map[Currency]int{
	// Zero-decimal currencies: there is no sub-unit, so a figure with decimals is not a real amount.
	"BIF": 0, "CLP": 0, "DJF": 0, "GNF": 0, "ISK": 0, "JPY": 0, "KMF": 0, "KRW": 0,
	"PYG": 0, "RWF": 0, "UGX": 0, "UYI": 0, "VND": 0, "VUV": 0, "XAF": 0, "XOF": 0, "XPF": 0,
	// Three-decimal currencies.
	"BHD": 3, "IQD": 3, "JOD": 3, "KWD": 3, "LYD": 3, "OMR": 3, "TND": 3,
}

// MinorUnits returns the number of decimal places in which this currency is quoted.
func (c Currency) MinorUnits() int {
	if e, ok := minorUnits[c]; ok {
		return e
	}
	return 2
}

// Money is an amount with its denomination attached. It is the wire and storage shape for every
// monetary value in the model. There is deliberately no constructor that takes a bare float without
// a currency: an amount whose denomination is unknown is not money, it is a number.
type Money struct {
	Amount   float64  `json:"amount" yaml:"amount"`
	Currency Currency `json:"currency" yaml:"currency"`
}

// isUsableAmount reports whether v is a number a monetary operation can use.
//
// This is the amount-side analogue of isUsableRate. A NaN or Inf amount is not money — it is a
// computation error that should be caught at the boundary, not carried silently into a sum or
// threshold comparison where IEEE 754 comparison semantics produce wrong verdicts.
func isUsableAmount(v float64) bool {
	return !math.IsNaN(v) && !math.IsInf(v, 0)
}

// Validate reports whether this is a usable amount. The context string names the field so the error
// tells an operator which line of which file to fix.
func (m Money) Validate(context string) error {
	if err := m.Currency.Validate(); err != nil {
		return fmt.Errorf("%s: %w", context, err)
	}
	if !isUsableAmount(m.Amount) {
		return fmt.Errorf("%s: amount is %g; amounts must be a finite number", context, m.Amount)
	}
	return nil
}

// Resolve fills in an unset currency from a document-level default.
//
// This exists purely for YAML ergonomics. Writing `currency: GBP` against each of twelve control
// costs is not more explicit than declaring it once for the file — it is twelve chances to
// denominate one line differently by accident. So a file declares its currency once and bare
// scalars inherit it.
//
// Two properties keep that from becoming the silent default this package exists to prevent:
// an amount that states its own currency is NEVER overwritten, and a bare amount with no document
// default is an error, not a guess.
func (m Money) Resolve(def Currency, context string) (Money, error) {
	if m.Currency != "" {
		if err := m.Currency.Validate(); err != nil {
			return Money{}, fmt.Errorf("%s: %w", context, err)
		}
		return m, nil
	}
	if def == "" {
		return Money{}, fmt.Errorf("%s: amount %g has no currency and the document declares no default currency; "+
			"add a top-level `currency:` or denominate this amount explicitly", context, m.Amount)
	}
	if err := def.Validate(); err != nil {
		return Money{}, fmt.Errorf("%s: document default %w", context, err)
	}
	return Money{Amount: m.Amount, Currency: def}, nil
}

// Round quantises to the currency's minor unit for presentation. See the package comment: this is
// the ONLY place rounding is allowed, and it is never applied to a value that will be used in
// further arithmetic.
func (m Money) Round() Money {
	return Money{Amount: roundHalfAwayFromZero(m.Amount, m.Currency.MinorUnits()), Currency: m.Currency}
}

// String renders the amount at its minor-unit precision with its code, e.g. "1234.57 GBP".
func (m Money) String() string {
	return fmt.Sprintf("%.*f %s", m.Currency.MinorUnits(), m.Round().Amount, m.Currency)
}

// UnmarshalYAML accepts either the self-describing mapping form or a bare scalar.
//
//	tolerance: { amount: 25000, currency: GBP }   # self-describing
//	tolerance: 25000                              # inherits the document's `currency:`
//
// A bare scalar deliberately yields an EMPTY currency rather than a default, so that a file which
// never declares one fails at load with a message naming the field, instead of silently adopting
// whatever the code happened to hard-code.
func (m *Money) UnmarshalYAML(n *yaml.Node) error {
	if n.Kind == yaml.ScalarNode {
		v, err := strconv.ParseFloat(n.Value, 64)
		if err != nil {
			return fmt.Errorf("line %d: %q is not a number and not an {amount, currency} mapping", n.Line, n.Value)
		}
		// ParseFloat accepts "NaN", "nan", "Inf", "+Inf", "-Inf" — all valid IEEE 754 but not
		// money. YAML's own float tokens (.nan, .inf) are caught by ParseFloat's dot rejection,
		// but the unquoted strings NaN and Inf slip through because yaml.v3 tags them as !!str
		// while ParseFloat happily parses the token. Reject them here at the boundary rather
		// than carrying a non-finite amount into sums and threshold comparisons where IEEE 754
		// comparison semantics produce wrong verdicts (NaN <= 0 is false, so a NaN tolerance
		// passes the positivity check and divides the residual ALE into NaN).
		if !isUsableAmount(v) {
			return fmt.Errorf("line %d: %q is not a usable monetary amount (NaN and Inf are not money)", n.Line, n.Value)
		}
		m.Amount = v
		m.Currency = ""
		return nil
	}
	// Shadow type to avoid recursing back into this method.
	var raw struct {
		Amount   float64  `yaml:"amount"`
		Currency Currency `yaml:"currency"`
	}
	if err := n.Decode(&raw); err != nil {
		return fmt.Errorf("line %d: %w", n.Line, err)
	}
	// The mapping form can also carry NaN/Inf via `amount: .nan` (tag !!float, decoded by
	// yaml.v3's own float parser which accepts .nan/.inf natively).
	if !isUsableAmount(raw.Amount) {
		return fmt.Errorf("line %d: amount is %g; NaN and Inf are not money", n.Line, raw.Amount)
	}
	m.Amount = raw.Amount
	m.Currency = raw.Currency
	return nil
}

// Add sums two amounts, refusing to add different denominations.
//
// This is the runtime half of what the Money type buys. The compile-time half stops a bare float64
// being passed where money is expected; this stops two DIFFERENT currencies being added, which the
// compiler cannot see because both are Money. Total Cost of Risk is a sum of terms sourced from two
// different files that may legitimately be denominated differently — it is the exact line where a
// silent mismatch would corrupt a board figure, so it is an error rather than a convention.
func Add(a, b Money) (Money, error) {
	if a.Currency != b.Currency {
		return Money{}, fmt.Errorf("cannot add %s to %s: different denominations must be converted to a "+
			"common currency before they are summed, not added as if they were the same unit",
			a.String(), b.String())
	}
	if err := a.Currency.Validate(); err != nil {
		return Money{}, err
	}
	if !isUsableAmount(a.Amount) {
		return Money{}, fmt.Errorf("cannot add: first operand amount is %g; amounts must be finite", a.Amount)
	}
	if !isUsableAmount(b.Amount) {
		return Money{}, fmt.Errorf("cannot add: second operand amount is %g; amounts must be finite", b.Amount)
	}
	result := a.Amount + b.Amount
	if !isUsableAmount(result) {
		return Money{}, fmt.Errorf("cannot add %s to %s: result overflows to %g", a.String(), b.String(), result)
	}
	return Money{Amount: result, Currency: a.Currency}, nil
}

// Sub subtracts o from m, refusing to mix denominations.
func (m Money) Sub(o Money) (Money, error) {
	return Add(m, Money{Amount: -o.Amount, Currency: o.Currency})
}

// Sum adds any number of amounts. An empty sum has no denomination to report and is an error, so a
// caller cannot mistake "nothing to add" for "zero pounds".
//
// The seed element is validated explicitly. Every other check this function performs lives inside
// Add, and Add is only reached from the second element onwards — so a ONE-element sum used to
// validate nothing at all and hand back `Money{5, ""}` as a legitimate result, while the identical
// value in a two-element sum was correctly refused. A single-scenario estate is the smallest real
// estate, not a hypothetical one, and an amount whose denomination is unknown is not money.
func Sum(ms ...Money) (Money, error) {
	if len(ms) == 0 {
		return Money{}, fmt.Errorf("cannot sum zero amounts: the result would have no denomination")
	}
	if err := ms[0].Currency.Validate(); err != nil {
		return Money{}, err
	}
	if !isUsableAmount(ms[0].Amount) {
		return Money{}, fmt.Errorf("cannot sum: first amount is %g; amounts must be finite", ms[0].Amount)
	}
	total := ms[0]
	for _, m := range ms[1:] {
		var err error
		if total, err = Add(total, m); err != nil {
			return Money{}, err
		}
	}
	return total, nil
}

// GreaterThan compares two amounts, refusing to compare across denominations.
//
// A threshold test is where a currency mismatch turns into a WRONG VERDICT rather than merely a
// wrong number: "does tightening this control buy more than the tolerance band" decides whether a
// control is promoted to the gate, and comparing 30,000 USD against a 25,000 GBP band would answer
// yes when the truth is no.
func (m Money) GreaterThan(o Money) (bool, error) {
	if m.Currency != o.Currency {
		return false, fmt.Errorf("cannot compare %s with %s: a threshold test across two denominations "+
			"produces a wrong verdict, not merely a wrong number", m.String(), o.String())
	}
	if !isUsableAmount(m.Amount) {
		return false, fmt.Errorf("cannot compare: first operand amount is %g; amounts must be finite", m.Amount)
	}
	if !isUsableAmount(o.Amount) {
		return false, fmt.Errorf("cannot compare: second operand amount is %g; amounts must be finite", o.Amount)
	}
	return m.Amount > o.Amount, nil
}

// Converted is the result of a conversion. It always shows its working: the source amount, the rate
// applied, and the date that rate was effective. A reader who disagrees with the figure can
// re-derive it with a calculator, which is the difference between a number and evidence.
type Converted struct {
	Amount   float64  `json:"amount"`
	Currency Currency `json:"currency"`
	Source   Money    `json:"source"`
	Rate     float64  `json:"rate"`
	AsOf     string   `json:"as_of"`
}

// Money discards the provenance and returns the converted amount as a plain denominated value.
func (c Converted) Money() Money { return Money{Amount: c.Amount, Currency: c.Currency} }

// RateTable is a dated set of exchange rates expressed against a single base currency.
//
// Rates are quoted as "units of this currency per one unit of base", which is how published tables
// are structured and therefore how a reviewer will check them.
type RateTable struct {
	AsOf  string               `yaml:"as_of" json:"as_of"`
	Base  Currency             `yaml:"base" json:"base"`
	Rates map[Currency]float64 `yaml:"rates" json:"rates"`
	// Source records where the rates came from, so the table is auditable rather than merely dated.
	Source string `yaml:"source,omitempty" json:"source,omitempty"`
}

// Validate checks the table is internally coherent before anything is priced with it.
func (t *RateTable) Validate() error {
	if t.AsOf == "" {
		return fmt.Errorf("rate table has no as_of date; an undated rate cannot be audited or reproduced")
	}
	if err := t.Base.Validate(); err != nil {
		return fmt.Errorf("rate table base: %w", err)
	}
	if len(t.Rates) == 0 {
		return fmt.Errorf("rate table (as of %s) declares no rates", t.AsOf)
	}
	for c, r := range t.Rates {
		if err := c.Validate(); err != nil {
			return fmt.Errorf("rate table (as of %s): %w", t.AsOf, err)
		}
		if !isUsableRate(r) {
			return fmt.Errorf("rate table (as of %s): rate for %s is %g; rates must be a finite number > 0",
				t.AsOf, c, r)
		}
	}
	base, ok := t.Rates[t.Base]
	if !ok {
		return fmt.Errorf("rate table (as of %s): base currency %s has no entry in rates", t.AsOf, t.Base)
	}
	if base != 1.0 {
		return fmt.Errorf("rate table (as of %s): base currency %s has rate %g; the base must be exactly 1.0 "+
			"or every cross-rate is silently scaled", t.AsOf, t.Base, base)
	}
	return nil
}

// isUsableRate reports whether r is a number a figure can be priced with.
//
// WHY THIS IS NOT `r > 0` WRITTEN INLINE. It was `r <= 0` inline, in both Validate and Rate, and
// that guard does not do what its comment said. Every IEEE-754 comparison against NaN is false, so
// `NaN <= 0` is false and a NaN rate passed both checks; +Inf is not <= 0 either. A table declaring
// `GBP: .nan` (which yaml.v3 parses happily) therefore loaded without complaint and converted
// 1,000,000 USD into "NaN GBP" with no error returned.
//
// +Inf is worse than it looks, because it does not stay infinite. It is infinite in one direction
// and ZERO in the other: with GBP quoted at +Inf, Rate(GBP->USD) is 1.0/+Inf = 0, so every GBP
// exposure prices at exactly 0.00 — a plausible figure, on the reassuring side, with nothing to
// suggest it was fabricated. That is precisely the failure mode the package comment describes for a
// silently-assumed rate of 1.0, and it deserved the same treatment.
//
// Rejecting at load is the point: the alternative is `json: unsupported value: +Inf` surfacing from
// json.Marshal several layers downstream, naming neither the currency nor the file.
func isUsableRate(r float64) bool {
	return !math.IsNaN(r) && !math.IsInf(r, 0) && r > 0
}

// Currencies returns the supported codes in sorted order, for deterministic error messages and
// deterministic output.
func (t *RateTable) Currencies() []Currency {
	out := make([]Currency, 0, len(t.Rates))
	for c := range t.Rates {
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

// Rate returns the multiplier taking one unit of `from` to units of `to`.
//
// Cross rates go through the base: rate(from->to) = rates[to] / rates[from]. Both legs are looked
// up; a missing leg is an error naming the pair.
func (t *RateTable) Rate(from, to Currency) (float64, error) {
	if from == to {
		// Exact identity, not a computed 1.0. rates[x]/rates[x] is 1.0 for finite x in IEEE-754,
		// but returning the literal makes the invariant structural rather than incidental — and
		// GBP->GBP not moving a number by an ulp is the regression anchor for the whole repository.
		if err := from.Validate(); err != nil {
			return 0, err
		}
		return 1.0, nil
	}
	rf, okF := t.Rates[from]
	rt, okT := t.Rates[to]
	if !okF || !okT {
		var missing []string
		if !okF {
			missing = append(missing, string(from))
		}
		if !okT {
			missing = append(missing, string(to))
		}
		return 0, fmt.Errorf("no rate for %s->%s: rate table as of %s has no entry for %s (it knows %s). "+
			"Add the rate to risk/fx/rates.yaml — a conversion is never silently assumed to be 1.0",
			from, to, t.AsOf, strings.Join(missing, " or "), joinCurrencies(t.Currencies()))
	}
	if !isUsableRate(rf) {
		return 0, fmt.Errorf("no rate for %s->%s: rate table as of %s quotes %s at %g, which cannot be divided by",
			from, to, t.AsOf, from, rf)
	}
	if !isUsableRate(rt) {
		return 0, fmt.Errorf("no rate for %s->%s: rate table as of %s quotes %s at %g", from, to, t.AsOf, to, rt)
	}
	return rt / rf, nil
}

// Convert converts an amount to the target currency.
//
// Pure and deterministic: the same (amount, from, to, table) yields byte-identical output forever.
// It does not round — see the package comment on where rounding is allowed.
//
// On failure it returns the ZERO Converted, so a caller that drops the error on the floor gets an
// obviously-wrong empty value rather than a plausible-looking number with the wrong label.
func (t *RateTable) Convert(m Money, to Currency) (Converted, error) {
	if err := m.Currency.Validate(); err != nil {
		return Converted{}, fmt.Errorf("source amount: %w", err)
	}
	if !isUsableAmount(m.Amount) {
		return Converted{}, fmt.Errorf("source amount: %g is not a finite number", m.Amount)
	}
	if err := to.Validate(); err != nil {
		return Converted{}, fmt.Errorf("target currency: %w", err)
	}
	rate, err := t.Rate(m.Currency, to)
	if err != nil {
		return Converted{}, err
	}
	return Converted{
		Amount:   m.Amount * rate,
		Currency: to,
		Source:   m,
		Rate:     rate,
		AsOf:     t.AsOf,
	}, nil
}

// MustConvertAll converts a slice of amounts, failing on the first missing pair. Convenience for
// report assembly, where a partial conversion would produce a table mixing two currencies.
func (t *RateTable) ConvertAll(ms []Money, to Currency) ([]Converted, error) {
	out := make([]Converted, 0, len(ms))
	for i, m := range ms {
		c, err := t.Convert(m, to)
		if err != nil {
			return nil, fmt.Errorf("amount %d of %d: %w", i+1, len(ms), err)
		}
		out = append(out, c)
	}
	return out, nil
}

// ParseRateTable parses and validates a rate table from YAML bytes.
func ParseRateTable(b []byte, path string) (*RateTable, error) {
	var t RateTable
	if err := yaml.Unmarshal(b, &t); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	if err := t.Validate(); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &t, nil
}

// LoadRateTable reads and validates a rate table from disk.
func LoadRateTable(path string) (*RateTable, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read rate table %s: %w", path, err)
	}
	return ParseRateTable(b, path)
}

func joinCurrencies(cs []Currency) string {
	s := make([]string, len(cs))
	for i, c := range cs {
		s[i] = string(c)
	}
	return strings.Join(s, ", ")
}

// roundHalfAwayFromZero quantises v to dp decimal places, rounding halves away from zero, operating
// on the SHORTEST decimal representation of v rather than on its exact binary value.
//
// The distinction is not pedantry. The double nearest to 2.675 is 2.67499999999999982..., so
// rounding the exact binary value gives 2.67 while every reader who types 2.675 into a calculator
// gets 2.68. Since these figures are read by humans who will check them, we round what was written.
func roundHalfAwayFromZero(v float64, dp int) float64 {
	if v != v || v > maxSafeDecimal || v < -maxSafeDecimal { // NaN or beyond useful decimal range
		return v
	}
	if dp < 0 {
		dp = 0
	}

	s := strconv.FormatFloat(v, 'f', -1, 64)
	neg := strings.HasPrefix(s, "-")
	s = strings.TrimPrefix(s, "-")

	intPart, fracPart, _ := strings.Cut(s, ".")
	if len(fracPart) <= dp {
		if v == 0 {
			return 0 // normalise -0.0; see the note on negative zero below
		}
		return v // already exact at this precision; do not perturb it
	}

	digits := intPart + fracPart[:dp]
	roundUp := fracPart[dp] >= '5'
	if roundUp {
		digits = incrementDecimalString(digits)
	}

	// Re-insert the point. incrementDecimalString may have grown the string by one leading digit.
	split := len(digits) - dp
	out := digits[:split]
	if dp > 0 {
		out += "." + digits[split:]
	}
	if neg {
		out = "-" + out
	}

	f, err := strconv.ParseFloat(out, 64)
	if err != nil {
		return v // unreachable for well-formed input; never fabricate a figure
	}

	// NEGATIVE ZERO. A small negative amount quantises to zero from below, and re-parsing "-0.00"
	// yields IEEE-754 negative zero, whose sign bit String's %.*f faithfully prints. Money{-0.001,
	// GBP} therefore rendered as "-0.00 GBP" — a signed figure telling a reader the exposure moved
	// in a direction it did not, and a value nobody can reproduce with a calculator, which is the
	// standard this package sets for itself. Zero has no sign in money.
	//
	// This is safe precisely because Round is presentation-only (see the package comment): the
	// value is never fed back into arithmetic, so discarding a sign that carries no quantity costs
	// nothing. The sign is untouched wherever there IS a quantity to sign: -0.006 still gives -0.01.
	if f == 0 {
		return 0
	}
	return f
}

// maxSafeDecimal is the magnitude beyond which a float64 has no fractional precision left to round,
// so quantising is a no-op and the decimal expansion is pointlessly long.
const maxSafeDecimal = 1e18

// incrementDecimalString adds one to a string of decimal digits, propagating the carry.
func incrementDecimalString(s string) string {
	b := []byte(s)
	for i := len(b) - 1; i >= 0; i-- {
		if b[i] < '9' {
			b[i]++
			return string(b)
		}
		b[i] = '0'
	}
	return "1" + string(b)
}
