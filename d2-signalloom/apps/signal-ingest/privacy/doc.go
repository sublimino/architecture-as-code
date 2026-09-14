// Package privacy gates the destruction of personal data behind an Article 17(3) legal hold.
//
// # Why this package exists
//
// Erasure in a cryptographically-attested evidence store is not only a privacy control. It is also
// an evidence-destruction primitive: crypto-shredding a subject's key destroys the forensic
// attribution for every action that subject took. An operator who is compromised, coerced, or
// simply mistaken can therefore invoke GDPR Article 17 against an actor tied to a live security
// incident and delete the attribution chain for that incident. That is simultaneously a
// privacy-shaped action and a DORA Article 11 operational-resilience breach, because the resilience
// obligation requires incident evidence to survive.
//
// This package does not destroy anything. It decides whether destruction is permitted, and it is
// deliberately built before the destruction mechanism (SLDP-P4-1) so that no window exists in which
// unconstrained on-demand crypto-shredding is reachable.
//
// # The control, in one sentence
//
// A subject linked to an unresolved security incident or an active containment record may not be
// erased, and neither may a subject whose incident state cannot be determined; the only way past a
// hold is a retention-exception record signed by two distinct registry-bounded operators, neither of
// whom is the requester, naming one of the five enumerated Article 17(3) grounds and carrying both
// an expiry and a review date.
//
// # A hold is a proof obligation, not an authorisation check
//
// The distinction matters and it shapes the API. An authorisation check asks "may this caller act?"
// and a negative answer is recoverable — retry with better credentials. A hold asks the destroyer to
// positively demonstrate that no hold exists, and "I could not find one" is not a demonstration.
// The cost asymmetry is what forces this: wrongly refusing an erasure costs delay, wrongly
// permitting one costs evidence that cannot be reconstructed. Worse, incident-state lookups are
// most likely to fail precisely during the incidents the hold exists for.
//
// Four consequences follow, and each is load-bearing:
//
//   - [IncidentSource.ActiveHolds] returns a three-valued answer — determined / declined /
//     undetermined — rather than a slice and an error. Absence, no-jurisdiction and failure are
//     three different facts and only the first permits erasure.
//   - [CompositeIncidentSource] refuses if ANY constituent source errors, not only if all do. A
//     union of holds computed from a partial view is not a union.
//   - [CompositeIncidentSource] also refuses if NO constituent had jurisdiction. A composite whose
//     every member declines is functionally an empty composite, and an empty one would answer "no
//     holds" to every subject in the tenant.
//   - There is no constructor that yields a Service with a permissive default incident source, and
//     no passthrough IncidentSource exists in non-test code. The pattern being avoided is the one
//     identity.NewEncryptorFromKeyString used to have before SLDP-P1-2 closed it: a passthrough
//     returned on an unconfigured input. That function now refuses unless an explicit
//     INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR opt-in is set.
//
// # There is no development opt-in for destruction
//
// The encryption and audit layers both offer an explicit insecure development mode
// (identity.DevOptInEnvVars, audit.NewNopWriter(true)). This package deliberately offers no
// equivalent, and the asymmetry is the point: a development passthrough on encryption produces
// weaker data that still exists, whereas a development passthrough on destruction produces no data
// at all, irreversibly. A development deployment that wants to exercise the erasure path supplies a
// KeyDestroyer that records and refuses. Grep confirms it: no environment variable in this package
// relaxes any gate.
//
// # Why "fail closed" is under-specified here, and which direction was chosen
//
// Every other control in this service is monotone — refusing is always the safe answer. Encryption,
// audit and authorisation all fail closed for free, because a denied request costs availability and
// nothing else.
//
// Erasure is not monotone. Erasing under a hold destroys irrecoverable incident evidence, breaching
// DORA Article 11. Refusing a legitimate erasure breaches GDPR Article 17, and falsely reporting an
// erasure that did not happen is a misstatement to a regulator. The safe defaults point in opposite
// directions, so "controls fail closed" does not by itself say what this package should do, and an
// implementer who does not notice will pick one silently.
//
// The direction chosen, and the reasoning: REFUSE. Article 17 breaches are remediable — the subject
// re-submits, the controller completes the erasure late, and the lateness is visible and
// explainable. Evidence destroyed during a live incident is not remediable by anything. Refusal
// also fails loudly (a 409 with a named hold that an operator must act on) while wrongful erasure
// fails silently, and a control whose failure mode is silent is not a control. This choice is
// recorded rather than assumed precisely because the opposite choice is defensible on Article 17
// grounds alone.
//
// # Precedence: legal hold beats retention expiry
//
// These two mechanisms both conclude "this record should go away" and they can disagree. The
// precedence is fixed and is not configurable:
//
//	                       | no active hold      | active hold
//	-----------------------+---------------------+---------------------------
//	within retention period| not due, not deletable | not due, not deletable
//	past retention period  | due AND deletable     | due but NOT deletable
//
// A record whose retention period has elapsed is still not deletable while a hold is active. The
// reasoning is that retention expiry is a schedule and a hold is a fact about the world; a schedule
// that silently overrides a fact is a fail-open path with a calendar attached. [Retention] implements
// this, and like erasure it fails closed when incident state is unavailable.
//
// # A hold that expires while a request is pending
//
// This is a genuine policy choice rather than a derivable answer, so it is stated rather than
// assumed. Holds are evaluated against the DECISION-time clock, never the request-time clock, and a
// refused request is terminal: it does not queue, and it does not auto-execute when the hold later
// lapses. A data subject whose request was refused must re-submit.
//
// The alternative — holding the request open and acting on it the moment the hold clears — was
// rejected because it destroys data with no fresh operator in the loop and against an incident
// picture nobody re-examined. Requests older than [MaxRequestAge] are refused outright with
// [ErrRequestStale] for the same reason: a request carries an implicit claim that the world has not
// materially changed since it was made, and that claim decays.
//
// # Discovering that a hold is blocking you
//
// A silent block is indistinguishable from a broken feature, and an unlogged refusal is
// indistinguishable from a request that was never made — which is itself an Article 12 transparency
// problem. Every refusal therefore does three things: writes an audit event naming the reason, the
// blocking hold IDs and the Article 17(3) ground that would permit an override; emits a warning log
// line; and returns a [Decision] carrying the same information, which the HTTP layer renders as a
// 409 body. If the audit write fails, the erasure is still refused and the caller is told that the
// refusal was not recorded.
//
// # Threat model boundaries
//
// This package assumes the operator registry and the key material behind it are managed outside it.
// It does not defend against an attacker who controls two registered operator private keys
// simultaneously; dual authorisation raises the bar to two compromises, it does not eliminate the
// class. It also does not defend against an attacker with direct database write access who forges a
// hold release, which is the tamper-evident audit trail's job rather than this package's.
package privacy
