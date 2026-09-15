# SLER frozen enforcement wire contract — `sler.signalloom.io/v1alpha1`

**Card:** SLER-P1-3 · **Created:** 2026-09-15 02:22:40+01:00
**Status:** FROZEN — **pending P1-GOV ratification**
**Consumes:** SLER-P1-1 (real `FleetClient`, `ErrEnforcementUnavailable`), SLER-P1-2 (dispatch schemas), SLER-P1-5 (partial-containment result types)
**Binds:** every implementation card in phases 2 through 6

This document is the single normative reference for the SLER enforcement wire
contract. Where it and any other document disagree, this one wins. Where it and
the code disagree, `d2-signalloom/apps/fleet-manager/contract_freeze_test.go`
decides — the freeze is a test, not a promise.

**Machine-readable form:** [`sler-p1-3-json-schema.json`](./sler-p1-3-json-schema.json) (JSON Schema draft 2020-12, 25 `$defs`).
**Worked examples:** [`sler-p1-3-example-containment-decision.json`](./sler-p1-3-example-containment-decision.json), [`sler-p1-3-example-resume-token.json`](./sler-p1-3-example-resume-token.json).

---

## 1. Why the freeze happens now

`/api/v1/fleet/*` has no consumer outside its own tests today. That makes this
the cheapest moment this schema will ever change, and the last moment before
five phase-2-through-6 cards each independently guess what a field is called.
A contract nothing tests is a suggestion; a rename is invisible until the fifth
card disagrees with the first four.

Two things had to land before the freeze could be honest, and both have:

| Dependency | Commit | What it contributes |
|---|---|---|
| SLER-P1-1 | `2b37f931` | The real client-go `FleetClient`, `ErrEnforcementUnavailable`, `ErrTargetNotFound`, `ErrEnforcementDenied`, and the retirement of the silent `noopFleetClient` fallback |
| SLER-P1-2 | `92bc899e` | `PlaneResult`, `ContainmentDecision`, `TargetRef`, `ContainmentReason` and nine per-plane request/response types |
| SLER-P1-5 | `b53d7d21` | `OutcomeNotFound`, honest `TargetOutcome`, and the aggregation rules that keep a partial containment representable |

Freezing before P1-1 and P1-2 landed would have locked in a guess. It did not.

## 2. Scope and ownership

**This card is the sole owner of the enforcement result schema.** Every other
card in the mission CONSUMES these types and MUST NOT redefine, shadow or
locally re-declare them. This closes the mission-wide `sharedFileRisks` entry
for the enforcement result schema.

Frozen surface: 23 struct types and 2 string enums, declared in
`d2-signalloom/apps/fleet-manager/{schema.go,cascade.go,enforcement.go}`.

| Group | Types |
|---|---|
| Core result | `PlaneResult`, `PlaneOutcome`, `EnforcementPlane`, `TargetRef`, `ContainmentReason`, `ContainmentDecision` |
| Mesh plane | `MeshIsolationRequest`, `MeshIsolationResponse` |
| Bao plane | `BaoRevokeRequest`, `BaoRevokeResponse` |
| SPIRE plane | `SpireEvictionRequest`, `SpireEvictionResponse` |
| Admission plane | `AdmissionBlockRequest`, `AdmissionBlockResponse` |
| Freeze plane | `FreezeRequest`, `FreezeResponse` |
| Governance resume | `ResumeToken`, `ResumeTokenSignature`, `ResumeRequest`, `ResumeResponse` |
| Cascade API surface | `StepResult`, `TargetOutcome`, `StateChangeEvent`, `CascadeResult` |
| Fail-closed state | `DegradedTarget` |

Complete field lists, Go types, JSON tags and optionality are in the JSON Schema
and in `frozen_contract_table_test.go`. They are not duplicated here: a third
copy of the field list is a third thing to drift.

### 2.1 The enums are frozen COMPLETE

```
PlaneOutcome      contained | partial | unavailable | not_found
EnforcementPlane  mesh | bao | spire | admission | freeze
```

`EnforcementPlane` was cross-checked against every plane this mission actually
enforces before the freeze — P2-1 mesh, P2-2 bao, P3-1 spire, P3-2 admission,
P4-1 freeze — because a plane discovered missing in phase 3 would force
reopening a frozen contract. All five are present and all five are members of
`AllEnforcementPlanes()`, which is what the cascade iterates; a constant that is
not in that list is a plane the dispatcher never calls.

`unavailable` and `not_found` are deliberately not synonyms. The first says the
plane did not answer and the target's state is UNKNOWN, and sends an operator to
check plane connectivity. The second says the plane answered and there was
nothing to contain, and sends them to check their targeting. Collapsing them
costs the operator the one distinction that decides where to look.

### 2.2 Partial and failed containment remain representable

Confirmed before the freeze, and re-asserted at the freeze boundary by
`TestPartialContainmentRemainsRepresentable`:

- `PlaneResult` carries a per-plane `outcome` AND a per-plane `error`.
- `ContainmentDecision` carries `plane_results[]` AND an aggregated `overall_outcome`.
- A mixed contained/unavailable decision aggregates to `partial`.
- A decision with zero containment never aggregates to `contained` or `partial`.

Freezing a result type that could not express a partial containment would lock
in the exact defect SLER-P1-5 exists to remove. The published worked example is
deliberately a PARTIAL containment exercising all four outcome values, because
the example is the artefact a downstream engineer copies.

## 3. The stable plane-client interface

`FleetClient` (declared in `cascade.go`) is frozen as the plane-client interface
every plane client implements against:

```go
type FleetClient interface {
    GetPodState(ctx context.Context, namespace, agentID string) (string, error)
    SetPodState(ctx context.Context, namespace, agentID, state string) error
    RevokeCredentials(ctx context.Context, agentID string) error
    RestoreCredentials(ctx context.Context, agentID string) error
    Health(ctx context.Context) error
}
```

### 3.1 The error contract is part of the interface

A plane request has three outcomes, never two. Implementations MUST use these
sentinels and callers MUST distinguish them with `errors.Is`:

| Sentinel | Meaning | Caller obligation |
|---|---|---|
| `nil` | the plane answered "done" | record `contained` |
| `ErrTargetNotFound` | the plane answered "absent" | record `not_found`; this is NOT a failure and NOT blindness |
| `ErrEnforcementUnavailable` | the plane did not answer | record `unavailable`, mark the target degraded, **fail closed** |
| `ErrEnforcementDenied` | policy decisively refused | wraps `ErrEnforcementUnavailable`, so fail-closed callers keep working; separable so a backoff loop stops retrying a permanent decision |

An unrecognised error MUST be treated as `unavailable`. Fail closed on the
unknown: any state value synthesised when the plane did not answer is fabricated.

### 3.2 Ingress version check

Every plane client MUST reject a message whose `schema_version` it does not
recognise, rather than best-effort decoding it. Use
`assertFrozenSchemaVersion(schemaVersion)`. Best-effort decoding of an unknown
version is how a field that moved becomes a field that silently reads as its
zero value — and in this contract a zero value means "not contained".

## 4. Governance resume token

### 4.1 Why the current shared secret cannot satisfy operator attribution

The sentinel today reads one value from the environment and compares it:

```go
// d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go:56
resumeToken: os.Getenv("STUN_RESUME_TOKEN"),
// d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go:272
resumeValidate := constantTimeTokenValidator(cfg.resumeToken)
```

That value is identical on every node of the DaemonSet and identical in the
hands of every operator. **This is not weak attribution — it is a bearer
credential, and a bearer credential is definitionally unattributable.** The
bytes the sentinel receives carry exactly zero information about who presented
them, so no verifier, however written, can tell two operators apart. Three
consequences follow, and none of them are fixable by improving the check:

1. **No attribution.** The forensic record can only say "the shared secret was presented". It cannot name a human, which is precisely what the attested record is for.
2. **No per-operator revocation.** Removing one operator's access means rotating the secret on every node AND redistributing it to every remaining operator — an O(N) blast radius for a one-person change. With per-operator keys, revocation is deleting one registry entry.
3. **No binding.** The token authorises *any* resume of *any* agent in *any* namespace at *any* time. Nothing in it names a target.

SLER-P1-3 treats the resume token as an **interface decision, not a value**.
Attribution is a property of keys: one private key held by exactly one party,
its public half registered against that party's identity, and a signature over
claims that name the target. `TestSharedSecretCannotAttribute` states this as
an executable property — two operators signing identical claims produce
different bytes, and that difference IS attribution.

### 4.2 Claims

`ResumeToken`, all fields mandatory:

| Claim | Meaning |
|---|---|
| `schema_version` | MUST be `sler.signalloom.io/v1alpha1`. A detached token must still be checkable. |
| `token_id` | Unique token identity. The verifier MUST enforce single use on it (§4.7). |
| `alg` | MUST be `ed25519`. Carried so an unknown algorithm is rejected rather than assumed, and so a post-quantum migration is a new value rather than a breaking change. |
| `agent_id` | Target agent. |
| `namespace` | Target namespace. Not optional: without it, a token minted for `agent-x` in staging resumes `agent-x` in production. |
| `audience` | The cluster or sentinel fleet this token is valid at. |
| `operator_id` | First signer's identity, normatively a SPIFFE ID. MUST equal `signatures[0].operator_id`. |
| `governance_approval_ref` | The governance approval this resume executes. |
| `issued_at`, `expires_at` | RFC3339 UTC. |
| `nonce` | base64(std), MUST decode to ≥ 16 bytes. |
| `trust_root_id` | The operator-key trust root the minter expects the verifier to pin. See §4.3.1. |
| `required_signatures` | The approval threshold recorded AT MINT TIME. See §4.3.2. |
| `signature` | First signer's signature. MUST equal `signatures[0].signature`. |
| `signatures[]` | Every signer — see §4.3. |

`token_id` and `nonce` are not redundant, and the distinction matters because an
unused claim implies a protection it does not provide. **`token_id`** is the
operational identity and the key of the single-use ledger (§4.7); it may be
human-assigned and sequential. **`nonce`** is unpredictable entropy inside the
signed body, so that a guessable `token_id` cannot be pre-signed or ground
against, and so two tokens sharing an operational id are still cryptographically
distinct.

**`governance_approval_ref` MUST be a content digest, not a mutable pointer.**
A pointer the verifier does not dereference is decoration — two signatures then
authorise a resume tied to no governance record — and a pointer it does
dereference imports a second registry with the same substitution problem as the
first. Normative form: `sha256:<hex>` over the canonical approval record.

`operator_id` and `signature` are scalar projections of `signatures[0]`,
retained from SLER-P1-2 so a single-operator break-glass token is representable
without an array. Two fields carrying the same fact drift unless something
checks them; `ValidateStructure` is that something.

### 4.3 Dual-operator signing

`ResumeTokenSignature` carries `operator_id`, `key_id`, `alg`, `signed_at`,
`signature`.

- A dual-control policy requires **at least two entries with DISTINCT `operator_id` AND DISTINCT `key_id`**. Counting *signatures* rather than *distinct operators* is satisfied by one operator holding two keys, which is not dual control.
- **Every** entry must verify, not merely `RequiredSignatures` of them. Tolerating invalid extras lets an attacker append junk and makes the rejection reason ambiguous.
- `key_id` is **self-certifying**: `sha256:` + lowercase hex of SHA-256 over the raw 32-byte Ed25519 public key. The verifier MUST recompute it from the key it resolved and reject a mismatch. An opaque label could be re-pointed at an attacker's key by anyone able to write the registry.
- The verifier MUST confirm the registry agrees that `key_id` belongs to `operator_id`. A valid signature carrying a lying `operator_id` would otherwise verify, and the forensic record would be fiction.
- Every `signed_at` MUST fall within `[issued_at − skew, expires_at + skew]`. A signature dated outside the token's own validity is not a co-approval *of this token*; it is a signature from somewhere else that happens to verify.
- Co-approvals MUST be contemporaneous: `|signed_at_latest − signed_at_earliest| ≤ policy.MaxApprovalWindow`. Without a bound, one operator banks a signature and a second adds theirs weeks later against an approval neither is still looking at — sequential rubber-stamping wearing dual control's clothes.
- `alg` appears at both token and signature level. The verifier MUST NOT dispatch on either: both are hard-allowlisted to `ed25519` and required to agree.

#### 4.3.1 `trust_root_id` and the limit of a self-certifying key handle

The self-certifying `key_id` closes registry **mis-indexing** — an existing
entry re-pointed at a different key — because the verifier recomputes the
fingerprint. **It does not close a registry-WRITE adversary.** Someone who can
add a whole entry binding their own key to a victim's `operator_id` passes every
check cleanly, and the self-certifying handle makes that substitution *more*
silent, not less: there is no mismatch left to detect.

No token format can close this; it is a trust-root problem. What the contract
does is name the root in the signed body, so the pinning obligation is part of
the wire contract rather than an assumption, and a token minted for one root is
explicitly refused at a verifier pinning another. The residual — who may write
the operator key registry at runtime, and whether that write path is reachable
from an agent compromise — is **OQ-6**, for P1-GOV.

`TestRegistryWriteAdversaryIsNotClosedByTheTokenFormat` asserts that this attack
*succeeds*, on purpose. The boundary is stated in a test so it cannot quietly
become an assumed property; if a future change closes it, that test fails and
someone re-reads this section.

#### 4.3.2 `required_signatures` and the max() rule

> **Effective threshold = max(verifier policy, token's `required_signatures`).**

Each half alone is broken, in opposite directions.

*Policy alone* leaves "every signature must verify" as a **validity** predicate
and not a **quorum** one. An attacker who observes a genuine two-approval token
strips one signature; the remainder satisfies every other check, and the attested
record shows a legitimate-looking single-operator resume. That is an attribution
loss — exactly the property this token exists to provide.

*Token alone* is worse: whoever mints a token would choose how many signatures it
needs, so an attacker simply claims 1.

`max()` gives the token power to **raise** the bar and never to lower it. An
attacker-minted token claiming 1 gains nothing against a dual-control policy, and
a stripped genuine token now fails because the surviving signed body still
records that two were required. A legitimate single-operator break-glass token
must therefore be **minted** with `required_signatures: 1` — it cannot be
produced by removing a signature from a dual-control token.

### 4.4 Signature wire encoding — normative

> **The raw 64-byte Ed25519 signature (RFC 8032, `R || S`), base64 std-encoded WITH padding: exactly 88 characters.**
> Not hex. Not base64url. Not DER. Not multibase.

If a downstream verifier assumes a different encoding, verification fails for a
reason that has nothing to do with a bad signature, and the debugger goes
looking at key material. Stated here so P4-3 has nothing to choose.

### 4.5 Signing input — normative byte layout

**The signature is over a length-prefixed binary concatenation, NEVER over the
JSON.** "Sign the JSON" is the classic own-goal: key order, unicode escaping,
whitespace and number formatting all vary between encoders, so two correct
implementations produce different bytes.

```
LP(s)  := uint32_be(len(s)) || utf8_bytes(s)          // 4-byte big-endian length prefix

BODY   := LP("sler.signalloom.io/resume-token/v1alpha1")   // domain separator
       || LP(schema_version)
       || LP(token_id)
       || LP(alg)
       || LP(agent_id)
       || LP(namespace)
       || LP(audience)
       || LP(operator_id)
       || LP(governance_approval_ref)
       || LP(issued_at)
       || LP(expires_at)
       || LP(nonce)
       || LP(trust_root_id)
       || LP(decimal(required_signatures))    // decimal string — one byte form per integer

INPUT_i := BODY
       || LP(signatures[i].operator_id)
       || LP(signatures[i].key_id)
       || LP(signatures[i].alg)
       || LP(signatures[i].signed_at)

signatures[i].signature = base64_std( Ed25519_Sign( operator_private_key, INPUT_i ) )
```

Field order is normative; any change to it is a breaking change.

**Why each signature covers its own signer fields.** If the signed bytes were
`BODY` alone, an attacker holding one valid token could lift the signature into
a different `signatures[]` entry and rewrite `operator_id`. The signature would
still verify and the attested record would name the wrong human — destroying the
one property this token exists to provide. Signer identity is therefore bound
cryptographically, not by convention.

Reference implementation: `SigningInput` / `SigningInputFor` in
`d2-signalloom/apps/fleet-manager/resume_token.go`. Byte layout pinned by
`TestSigningInputIsLengthPrefixedAndDomainSeparated`. Reproducible test vectors,
including the operator seeds, are in `resume_token_test.go` — a test vector with
a hidden key is not a test vector.

### 4.6 Verification algorithm

In order, each step producing a DISTINCT typed error:

1. `ValidateStructure` — required claims, `alg`, nonce entropy, RFC3339 parse, signature length (64 raw bytes), scalar projection invariant, distinct signers.
2. `schema_version` is the frozen version.
3. `agent_id` **and** `namespace` match the target being resumed.
4. `audience` matches this fleet.
5. `expires_at - issued_at` ≤ `policy.MaxLifetime`.
6. `now` within `[issued_at - skew, expires_at + skew]`.
7. For **every** signature: resolve `key_id` → registry entry; entry not revoked; entry within its own validity window; recomputed fingerprint equals `key_id`; registry `operator_id` equals the entry's claimed `operator_id`; `Ed25519_Verify`.
8. Every `signed_at` inside the token window; co-approval spread within `MaxApprovalWindow`.
9. Count DISTINCT `operator_id` ≥ max(`policy.RequiredSignatures`, `token.required_signatures`).

The verifier MUST report WHICH `key_id` failed. An aggregate "invalid token" destroys the attribution this design exists to provide, at the exact moment it is needed.

**Distinct errors are a requirement, not tidiness.** Every failure above is
indistinguishable from "bad signature" unless the verifier says which one it
was. An operator holding a genuinely valid token during an incident, told only
"unauthorized", concludes the new mechanism is broken and reaches for the shared
secret that still works. The error taxonomy is what keeps the break-glass usable
under stress. Twenty sentinels are exported from `resume_token.go`.

**Policy lives at the verifier, not in the token.** A token carrying its own
`required_signatures` would let whoever mints it choose how many signatures it
needs.

### 4.7 Replay and idempotency — the rule that reconciles two hard constraints

"Containment actions MUST be idempotent under retry" and "a resume token MUST
NOT be reusable" pull against each other. A naive nonce-rejects-replay rule
turns an HTTP retry into a hard failure at the worst possible moment.

> The verifier MUST keep a single-use ledger keyed on `token_id`.
> A repeat presentation carrying the **same** `idempotency_key` as the recorded
> first use MUST return the cached prior result — retry-safe.
> A presentation of a **consumed** `token_id` with a **different**
> `idempotency_key` MUST be REFUSED as replay.

Two implementation obligations follow, and both are load-bearing:

- **The ledger write MUST be atomic with the resume.** Check-then-act loses to two concurrent presentations. Use a unique-constraint insert in the same transaction as the resume and fail closed on conflict.
- **Ledger retention MUST exceed `MaxLifetime + ClockSkew`.** A `token_id` that expires and is then purged becomes replayable inside its own validity window.

Note that `idempotency_key` lives on `ResumeRequest` and is deliberately NOT a
signed claim. It does not need to be: the binding is recorded at first use, so
replaying a captured token under a freshly chosen key hits the "consumed
`token_id`, different key" arm and is refused. Signing it would instead force the
minter to predict the transport-level retry identity.

### 4.8 Resume implies credential rotation

`ResumeResponse.credentials_rotated` MUST be `true` before success is reported.
Resuming an agent on the credentials that were live when it misbehaved defeats
the revocation half of containment. Implemented by SLER-P4-3.

## 5. Compatibility statement and the version-bump process

The contract is frozen at `sler.signalloom.io/v1alpha1`. **A phase-2-through-6
card that needs a field not present here MUST request a version bump through the
P1-GOV governor. It MUST NOT silently add an unversioned field.**

| Change | Bump | Approver | Consequence |
|---|---|---|---|
| New optional field; new enum member | **MINOR** → `v1alpha2` | P1-GOV | existing consumers keep working |
| Rename, removal, retype, retag, enum member removed | **MAJOR** → `v1` | P1-GOV | every plane client in phases 2-6 updated in the same change |

Procedure, also printed verbatim by the failing test:

1. Raise it with P1-GOV. Do not edit the descriptor to match your code — the descriptor is the contract, your code is the proposal.
2. Update `FrozenSchemaVersion`, `CurrentSchemaVersion` and the descriptor in `frozen_contract_table_test.go` **together**.
3. Regenerate `sler-p1-3-json-schema.json` and the worked examples.
4. Record the bump in the proposal errata.

## 6. How the freeze is enforced

Three independent layers. The first two were each proven by mutation — a guard
never observed failing is an untested claim.

| Layer | Catches | Proof |
|---|---|---|
| **Go compiler** | removal or rename of any field referenced elsewhere in the package | mutation: deleting `PlaneResult.LatencyMs` fails the build at `schema_test.go:131` |
| **`contract_freeze_test.go`** | rename, removal, addition, retype, retag, enum change, version drift, Go↔JSON-Schema drift — including the case where a field and all its uses are deleted in one change, which the compiler cannot see | 11 mutations, 11 kills (§6.1) |
| **JSON Schema** | cross-module and cross-language consumers (stun-sentinel, node-capability-guard, P6-3's acceptance suite) | diffed against the Go types on every test run |

### 6.1 Mutation evidence

| # | Mutation | Killed by |
|---|---|---|
| 1 | `PlaneResult.Outcome` json tag `outcome`→`result` | `FROZEN FIELD RETAGGED` |
| 2 | Unversioned field added to `ContainmentDecision` | `FIELD ADDED WITHOUT A VERSION BUMP` |
| 3 | `ContainmentDecision.DurationMs` `int64`→`int` | `FROZEN FIELD RETYPED` |
| 4 | `PlaneFreeze` dropped from `AllEnforcementPlanes()` | `FROZEN ENUM CHANGED` |
| 5 | `CurrentSchemaVersion` bumped unilaterally | `TestFrozenSchemaVersionIsPinned` |
| 6 | Descriptor carries a field the Go type lacks (= removal) | `FROZEN FIELD REMOVED OR RENAMED` |
| 7 | Descriptor carries the pre-rename name (= rename) | `FROZEN FIELD REMOVED OR RENAMED` |
| 8 | Whole type dropped from the descriptor | `FROZEN TYPE MISSING` |
| 9 | Descriptor emptied | `TestFrozenDescriptorIsNotVacuous` |
| 10 | `PlaneResult.LatencyMs` deleted | compiler, `schema_test.go:131` |
| 11 | `MeshIsolationResponse.PolicyApplied` renamed | compiler, `schema_test.go:401` |
| 12 | `ResumeToken.TrustRootID` renamed in the descriptor after regeneration | `FROZEN FIELD REMOVED OR RENAMED` |

Mutations 12 was run *after* the descriptor, JSON Schema and worked examples
were regenerated for the two claims added in §4.3.1–4.3.2, to confirm
regeneration had not produced a table that guards nothing. The regeneration
itself was caught by the freeze: adding `trust_root_id` and
`required_signatures` failed `TestFrozenGoShapeMatchesDescriptor`,
`TestJSONSchemaMatchesGoShape` and the worked-example validation before the
artefacts were updated — the machinery caught its own author.

The descriptor in `frozen_contract_table_test.go` is written out as a literal on
purpose. Deriving it from the types it guards would make the test a tautology —
it would compare the structs to themselves and pass on any change whatsoever.
`TestFrozenDescriptorIsNotVacuous` guards the guard: a table that lost its
entries in an edit compares equal to nothing and would pass on everything.

---

## 7. Open questions — for P1-GOV, deliberately unresolved here

These are `stopAndReport` items. Seven in total; OQ-6 and OQ-7 came out of the commitment-boundary advisor review and are the two most consequential. Each is a decision with a real trade, and
resolving one unilaterally inside this card would remove a human decision point
the mission is structured to preserve. **None blocks phase 2.**

### OQ-1 — Break-glass reachability when containment has isolated the control plane

The constitution forbids a design where break-glass traverses a plane
containment may have severed. The frozen contract **permits** a compliant
design: Ed25519 verification is purely local, so a sentinel holding a cached
operator key registry can verify a token with no control-plane call at all.
What is not decided is whether the deployed verifier will hold that cache, how
it is seeded, and what an operator physically does when the mesh plane has cut
the node off. **Decision needed: is the node-local cached key bundle mandatory?**

### OQ-2 — Revocation freshness under isolation (the residual that cannot be engineered away)

OQ-1's cached registry is exactly what makes break-glass survive containment,
and the cache TTL is exactly the window in which a revoked operator key still
works. These pull in opposite directions and no design removes the tension —
it must be *chosen*. **Decision needed: the maximum tolerable revocation
latency, which sets the cache TTL.**

Note for the record: the residual is NOT "SPIFFE cannot revoke". SPIFFE indeed
has no CRL or OCSP — an SVID is revoked by deleting the registration entry and
waiting out the TTL, so a compromised SVID stays valid for its remaining
lifetime. But **the operator signing key is not an SVID.** It is a registry
entry, revoked the instant it is removed at any verifier that can see the
removal. The `operator_id` is a SPIFFE ID used as a NAME, not as a credential.
The real residual is reachability, not SPIFFE's revocation model.

### OQ-3 — Operator key distribution — SCOPED HERE, SOLVED BY P4-3

Ed25519 dual-operator signing is an **interface replacement plus a distribution
problem**. This card delivers the interface. It does not deliver: how operator
public keys reach every node's DaemonSet, how that bundle is itself signed and
rotated, where operator private keys live (HSM? smartcard? `age`-encrypted
file?), or what bootstraps the first key. **P4-3 owns this.** It is named here
so P4-3 does not discover it mid-implementation.

### OQ-4 — `RevokeCredentials`/`RestoreCredentials` carry no namespace

Raised by SLER-P1-1's errata and handed to this card. Because the credential
methods take only `agentID`, their degraded-registry records key on the client's
DEFAULT namespace while freeze-plane records key on the target's. For an agent
outside the default namespace, the credential-plane entry is unreachable by
`IsDegraded` for the process lifetime — a plane known to be blind reports
available.

**Not fixed here, and the reason is procedural, not technical.** The remedy is a
signature change to `FleetClient`, which is declared in `cascade.go` — an
explicit shared-file collision risk this card is instructed not to edit. The fix
is `RevokeCredentials(ctx, namespace, agentID)` and the symmetric
`RestoreCredentials`, a MAJOR bump under §5. **Decision needed: does P1-GOV
authorise the `FleetClient` signature change, and which card lands it?**

### OQ-5 — A shared Go contract module is blocked by the container build context

The natural way to give downstream cards a compile-time break on divergence is a
shared module, e.g. `d2-signalloom/pkg/slerwire`, consumed via `replace`. **It
breaks the image build.** `Makefile:1710` runs
`docker build -t fleet-manager:local d2-signalloom/apps/fleet-manager`, and that
Dockerfile is `COPY . .` over the app directory, so a `../../pkg/...`
replacement target does not exist inside the build context and `go build` fails.

Mitigated, not solved. The four in-module plane clients (mesh, bao, spire,
admission dispatch) live in `package main` beside the frozen types and get the
compile-time property for free. The two cross-module wire peers (stun-sentinel,
node-capability-guard) consume the JSON Schema. **Decision needed: widen the
build context — a two-line change to the Makefile and Dockerfile — or accept the
JSON Schema as the cross-module contract?**

### OQ-6 — Who may write the operator key registry?

Raised by the commitment-boundary advisor review and confirmed by an executable
test (§4.3.1). The `key_id` fingerprint check closes registry **mis-indexing**;
it does not close an adversary who can **write** the registry and add an entry
binding their own key to a victim's `operator_id`. `trust_root_id` makes the
pinning obligation explicit but does not supply the integrity.

**Decision needed:** is the operator key registry a signed bundle pinned to an
offline trust root, append-only with revocation-only mutation, or something
else? And critically — **is the registry write path reachable from the same
compromise the containment is responding to?** If an agent compromise can reach
it, the entire attribution chain is decorative. This is adjacent to OQ-3 but is
an integrity question, not a distribution one.

### OQ-7 — Requester/approver separation

`ResumeToken` records signers but not a *requester*. If one operator can be both
the person requesting a resume and one of the two approving it, dual control is
one-of-two in practice. Adding `requested_by` with a `requester ∉ signers` rule
would close it, but that is an authorization-model decision, not a wire-format
one, and inventing the policy here would be exactly the unilateral resolution
this section exists to prevent. **Decision needed: is self-approval intended?**
If not, the fix is a MINOR bump under §5.

Related and also open: `required_signatures` counts *distinct* operators but
says nothing about *which* operators. As frozen, any two valid operators can
resume any agent in any namespace. **Is there a per-namespace approver set?**

---

## 8. Incidental findings

**`stun-sentinel/pkg/tc` does not build, for an environment reason.**
`pkg/tc/bpf_embed.go:25` embeds `tc_drop.bpf.o`, documented as committed to the
repository. It is not tracked: the developer's **global** gitignore carries a
bare `*.o` rule, so the object was silently never added. `go test ./...` in that
module therefore reports two `[setup failed]` packages. **Pre-existing, present
before this card, unrelated to the freeze, and not fixed here** — committing a
build artefact is the principal's call. Recorded so a later card does not
mis-attribute it to the contract change.
