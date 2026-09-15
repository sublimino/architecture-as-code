package main

// Shared structured-logging contract between the two phase-2 credential-revocation
// planes, added by SLER-P2-GOV.
//
// # WHY THIS FILE EXISTS
//
// P2-1 (OpenBao) and P2-2 (SPIRE) were built independently against the same P1-2
// schema and shipped two incompatible log shapes. P2-1 hand-marshals a JSON struct
// whose discriminator is the "event" key ("bao_revoke_attempt") and which carries
// worst_case_residual_ms. P2-2 emitted slog key/value records whose only
// discriminator was slog's own "msg" key, and carried no residual field at all.
//
// SLER-P5-1 ingests both planes into ONE Witness-attested forensic pipeline. Two
// discriminators and a missing residual field would have forced P5-1 to write a
// per-plane reconciliation shim — work P5-1 was not scoped to do, and work that
// would have had to be re-done for every plane P3 and P4 add.
//
// The fix is a shared vocabulary, asserted by a test that iterates the same slice
// for both planes. That construction is deliberate: if a future card drops a key
// from one plane, the assertion for that plane fails, rather than the test quietly
// checking a shorter list.
const (
	// BaoRevokeEventName discriminates an OpenBao lease/token revocation attempt.
	BaoRevokeEventName = "bao_revoke_attempt"
	// SpireRevokeEventName discriminates a single SPIRE registration-entry deletion.
	SpireRevokeEventName = "spire_entry_delete_attempt"
	// SpireEvictEventName discriminates a completed end-to-end SPIRE agent eviction.
	SpireEvictEventName = "spire_evict_attempt"
	// MeshIsolationEventName discriminates a dynamic mesh network isolation attempt.
	MeshIsolationEventName = "mesh_isolation_attempt"
)

// SharedAttestationEventKeys is the intersection of fields SLER-P5-1 requires from
// EVERY credential-plane event, regardless of which plane emitted it.
//
// "worst_case_residual_ms" is in this set on purpose. An attested forensic record
// that says an agent was contained, without saying for how long its already-issued
// credentials stayed valid, is a record that overstates what happened. The residual
// is part of the evidence, not a footnote to it.
// "error" is deliberately NOT in this set. RevokeAuditLogEntry tags it
// `json:"error,omitempty"`, so on a successful containment the key is absent from
// the marshalled record entirely. Requiring it would make every successful bao
// event fail the contract. P5-1 must therefore treat an absent "error" as "no
// error" rather than as a malformed record — which is the correct reading, but
// only if it is written down somewhere, so it is written down here.
var SharedAttestationEventKeys = []string{
	"event",
	"outcome",
	"latency_ms",
	"worst_case_residual_ms",
}

// ResidualProvenance labels how a published residual-exposure figure was obtained.
// Every number in the phase-2 denial matrix carries one. A figure without its
// instrument is a rumour, and the whole point of publishing a residual rather than
// claiming instant revocation is that the reader can audit where it came from.
type ResidualProvenance string

const (
	// ProvenanceMeasured — observed against the real system at the stated scale.
	ProvenanceMeasured ResidualProvenance = "measured"
	// ProvenanceMockDerived — observed against an in-process test double. A lower
	// bound on real latency and NOT a fleet-scale figure.
	ProvenanceMockDerived ResidualProvenance = "mock-derived"
	// ProvenanceConfigDerived — read from this repository's own configuration.
	ProvenanceConfigDerived ResidualProvenance = "config-derived"
	// ProvenanceUpstreamDefault — the upstream project's documented default,
	// applicable because this repository overrides nothing.
	ProvenanceUpstreamDefault ResidualProvenance = "upstream-default"
)
