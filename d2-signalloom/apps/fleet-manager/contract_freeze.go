package main

import "fmt"

// ── The freeze ───────────────────────────────────────────────────────────────
//
// SLER-P1-3 declares the enforcement wire contract FROZEN at the version below.
// "Frozen" is not a note in a document; it is contract_freeze_test.go, which
// walks every frozen type by reflection and fails by name on any field rename,
// removal, retype or retag. Prose asks; the test enforces.
//
// Why freeze at all, and why now. /api/v1/fleet/* has no consumer outside its
// own tests today, so this is the cheapest moment the schema will ever change —
// and the last moment before five phase-2-through-6 cards each start encoding a
// different assumption about what a field is called. Every one of those cards
// is written against this file.
//
// Normative reference: docs/signalloom/sler-p1-3-frozen-contract.md
// Machine-readable:    docs/signalloom/sler-p1-3-json-schema.json

// FrozenSchemaVersion is the version SLER-P1-3 froze. It MUST equal
// CurrentSchemaVersion; contract_freeze_test.go asserts that, so bumping one
// without the other is a test failure rather than a silent divergence.
const FrozenSchemaVersion = "sler.signalloom.io/v1alpha1"

// FrozenContractDoc and FrozenContractJSONSchema are the paths, relative to the
// repository root, of the two normative artefacts. They are constants so the
// conformance test's failure message can point an engineer at the procedure
// rather than at a hash mismatch.
const (
	FrozenContractDoc        = "docs/signalloom/sler-p1-3-frozen-contract.md"
	FrozenContractJSONSchema = "docs/signalloom/sler-p1-3-json-schema.json"
)

// FrozenContractBumpProcedure is the text the conformance test prints when it
// catches a divergence. It exists as a constant because the useful half of a
// failing contract test is not "these differ" but "here is what you do next" —
// an engineer who cannot find the procedure edits the expectation instead of
// requesting the bump, which is precisely the silent drift the freeze prevents.
const FrozenContractBumpProcedure = `
The SLER enforcement wire contract is FROZEN at ` + FrozenSchemaVersion + `.

If you genuinely need this change:
  1. Raise it with the P1-GOV governor. Do not edit the descriptor to match
     your code; the descriptor is the contract, your code is the proposal.
  2. ADDITIVE change (a new optional field, a new enum member)? P1-GOV approves
     a MINOR bump: sler.signalloom.io/v1alpha2. Existing consumers keep working.
  3. BREAKING change (rename, removal, retype, retag, enum member removed)?
     P1-GOV approves a MAJOR bump: sler.signalloom.io/v1. Every plane client in
     phases 2 through 6 must be updated in the same change.
  4. Update FrozenSchemaVersion, CurrentSchemaVersion and the descriptor in
     contract_freeze_test.go together, then regenerate
     ` + FrozenContractJSONSchema + ` and re-run this test.
  5. Record the bump in the proposal errata.

See ` + FrozenContractDoc + ` for the full compatibility statement.
`

// assertFrozenSchemaVersion reports whether a schemaVersion observed on the
// wire is the frozen one.
//
// Exported behaviour rather than an inline string comparison because every
// plane client in phases 2 through 6 must perform this check on ingress: a
// message arriving under an unrecognised schemaVersion must be REFUSED, never
// best-effort decoded. Best-effort decoding of an unknown version is how a
// field that moved becomes a field that silently reads as its zero value, and a
// zero value in this contract means "not contained".
func assertFrozenSchemaVersion(schemaVersion string) error {
	if schemaVersion != FrozenSchemaVersion {
		return fmt.Errorf("unsupported schema_version %q: this build speaks only %s",
			schemaVersion, FrozenSchemaVersion)
	}
	return nil
}
