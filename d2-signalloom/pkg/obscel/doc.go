// Package obscel is the single shared vocabulary and evaluator for Signal Loom
// observation policy (SLAWS v2 §4.1, D2, D3, D9).
//
// Dependency direction is fixed: both apps/signal-ingest and apps/policy-engine
// import this package; neither app imports the other. The CEL environment, the
// bundle format, the in-process Evaluator, and the canonical Finding/Decision
// types live here so stage 1 (per-observation predicates), stage 2 (windowed
// counters over findings), boot-time warm-up and regression replay are one code
// path.
//
// # Determinism contract (binding for every producer and for the replay oracle)
//
// Replay over the backlog must reproduce live output byte for byte under an
// explicit projection (see CanonicalFinding). To make that possible:
//
//   - Finding.ID is derived: sha256(tenant_id | rule_id | bundle_version | source observation id),
//     hex, never a random UUID.
//   - Finding.Timestamp is the source observation's Timestamp, never time.Now().
//   - Decision.ID is derived from tenant_id | rule_id | window key | the IDs of the
//     findings that crossed the threshold, in sorted order.
//   - Labels serialise in sorted key order.
//   - Rules evaluate in sorted rule ID order, never map order.
//   - The replay comparison projects an allowlist of fields (CanonicalFinding);
//     store-assigned fields (ingest time, offsets) never take part.
//
// # Actor identity (binding)
//
// obs.actor is the keyed PSEUDONYM of the actor, never the cleartext hint. This
// holds on the live path and the replay path alike, and it is not an
// optimisation. A segment-schema-v2 segment stores no cleartext actor column at
// all, so a replay has nothing else to read. Evaluating cleartext live and an
// empty string on replay is the defect this rule exists to prevent.
//
// Four consequences follow and each is load-bearing.
//
//   - Pseudonymisation uses the configured store key. A per-process salt is a
//     defect. A second instance built from the environment is also a defect,
//     because it agrees only while key, tenant scope and epoch all agree.
//   - A row that already holds the store's pseudonym is used verbatim. A row
//     holding cleartext is pseudonymised to the same value a stored row would
//     have. A corpus spanning the schema change must not count one identity as
//     two.
//   - An observation naming no actor projects an empty actor. Hashing the empty
//     string would write one constant digest into every identity-free record.
//     That digest is a join key across all of them, and it makes the guard
//     obs.actor != "" true for all of them.
//   - obs.actor supports equality and membership only. It has no internal
//     structure, so startsWith and substring reads of it are defects. A rule
//     needing a component of an identifier reads a projected label instead.
//
// # Actor allowlists
//
// A bundle var holding actor identities must be named in Bundle.ActorVars. Those
// lists are rewritten into the pseudonym space at load, by the same
// pseudonymiser obs.actor uses. See PseudonymiseActorVars.
//
// Omitting the declaration produces the worst failure shape available. The list
// stays cleartext, so obs.actor in vars.X is never true, so the negative form
// every shipped rule uses becomes always true. The identities an operator
// exempted then produce a finding on every record. Live and replay agree on
// that wrong answer, so the replay oracle reports parity.
//
// Conform therefore REFUSES any rule comparing obs.actor against a var absent
// from ActorVars. Load time is the only point at which the omission is visible.
//
// # Window key dimensions
//
// A stored finding carries the closed policy label set plus the label values
// every window over its rule keys on. Warm-up rebuilds a window keyed on
// labels.key from those values.
//
// Without them every warmed finding reads an empty value for that dimension.
// They then land in a counter keyed on the empty string, which no live finding
// can ever join, so warm-up contributes nothing and a restart misses the burst.
//
// # Missing-key semantics
//
// `has(obs.labels.k)` on an absent key evaluates to false and never errors, so an
// unlabelled record cannot become a finding or a denial by accident.
package obscel
