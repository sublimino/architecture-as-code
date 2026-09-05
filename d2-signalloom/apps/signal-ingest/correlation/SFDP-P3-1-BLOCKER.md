# SFDP-P3-1 blocker: public Resolve violates false-merge cardinal gate

Status: **Failed — implementation stopped on observed false-merge != 0**.

## Current evidence (2026-09-05)

The assigned runtime checkout passes the required integration ancestry check:
`git merge-base --is-ancestor integration/signal-fusion-v0.1.0 HEAD` exits 0
at starting HEAD `043c30c1c28c39aa57b46726487a5608c775c6a0` and integration ref
`2efc851d`. No ref repair, merge, rebase, push, or PR was performed.

An existing uncommitted resolver implementation was recovered and audited.
Its correlation/model suite passed before adding the following labelled
regression. That earlier green result did not cover the public entry-point
identity collision.

Reproduce from `d2-signalloom/apps/signal-ingest`:

```sh
env LC_ALL=C LANG=C \
  GOCACHE=/tmp/opencode/go-cache-sfdp \
  GOMODCACHE=/tmp/opencode/go-mod-sfdp \
  go test ./correlation \
  -run '^TestCardinalResolveDistinctTrustDomainsFalseMergeZero$' -count=1 -v
```

Exit status: **1**. Operative output:

```text
false-merge == 1, want 0: distinct labelled SPIFFE principals "spiffe://z-one.example/ns/prod/sa/payments" and "spiffe://z-two.example/ns/prod/sa/payments" collapse to canonical actor_id "actor-kubernetes|kubernetes-service-account|system:serviceaccount:prod:payments"
```

The fixture supplies authenticated SPIRE issuance observations with the same
local service-account principal name but distinct trust domains and conflicting
actor hints. `ResolvePair` rejects this exact pair with
`ErrContradictoryPrincipals`; individual public `Resolve` calls nevertheless
return the identical canonical ID. `contractIdentifiers` sorts the generic
`kubernetes` principal before the two `z-*` SPIFFE trust domains, and
`deriveResolutionKey` selects that first identifier without the partition's
conflict gate. This is not a request to disallow authenticated identity merges:
the supervisor's authorization applies to **non-conflicting** actor hints,
whereas this fixture deliberately contains conflicting authenticated hints.

Per the task's explicit STOP instruction, the implementation was not repaired
after this failure, and the fixture/assertion was not weakened. The checkpoint
preserves the recovered implementation plus the reproducer for remediation;
it is **not merge-ready or delivered**. The full suite, race lane, live runtime,
and complete confluence/recall acceptance are not certified. Additional audit
findings remain unverified; the concrete false merge alone is sufficient to stop.

## Requirement-to-evidence disposition

| Requirement | Evidence / disposition |
| --- | --- |
| Required isolated integration ancestry | Pass at the starting refs above |
| Public Resolve canonical identity soundness | **Fail**, exact regression above |
| Trust-domain separation with conflicting actor hints | **Fail**, same canonical ID |
| False-merge nonzero build exit | Demonstrated by the regression exit 1 |
| Deterministic algebra, confidence, delegation, provenance | Recovered code exists; not accepted as delivered |
| Confluence, retraction, representative lineage, caps | Partial inherited tests; not fully certified |
| Store seam, full candidate recall, serialization | Partial inherited tests; not fully certified |
| Exhaustive classifications, BindAccessor, typed identifiers | Audited but acceptance incomplete |
| Clock skew, late arrival, replay, concurrent race lane | Acceptance incomplete |
| Full signal-ingest suite | Not run after mandatory hard stop |
| Changes outside correlation/ and model/ | None in this checkpoint |
| Commit, proposal errata and Result | Failure checkpoint; Governor must not merge as successful delivery |

Recommended action: **remediate** under an authorized retry. Unify the public
resolution contract with the constrained partition decision, preserve this
falsification fixture, and complete the card's remaining acceptance audit.
This is implementation failure, not proposal drift (`blocking_drift=no`).

## Historical deterministic-producer objection (superseded)

Status: **superseded by supervisor authorization on 2026-09-05**.

The earlier stop correctly rejected plain shared credentials, mutable accessor
aliases, source/time proximity, IP addresses, and unauthenticated
`spiffe://`-looking strings as deterministic identity proof. It is retained as
historical context only and is not a current implementation blocker.

The authorized contract permits deterministic merging for matching SPIFFE or
PrincipalID values emitted through authenticated collector source/field
contracts, provided actor hints do not conflict. Current trusted contracts are:

- SPIRE issuance: `source=spire-agent`, `event_type=spire_svid_issuance`, and
  matching `labels[spiffe_id]`/`actor_hint` (plus matching emitted SA principal).
- OpenBao audit: `source=openbao-audit` authenticated audit metadata materialized
  as matching SPIFFE or SA principal fields.
- Kubernetes audit: `source=k8s-apiserver-audit` authenticated acting
  `principal_id`, including its collector-produced SPIFFE mapping.
- GCP Cloud Audit: `source=gcp-cloud-audit` authenticated
  `labels[principal_email]` scoped by `labels[project_id]`.

No fidelity tier, CEL match, bare actor hint, BindAccessor association, source,
time, or IP value independently authorizes a deterministic union.

## Trust-boundary clarification

Observation payload fields do not authenticate their producer. The correlation
engine therefore defaults to `DenyUnverifiedProducer`. Applications may inject
a `ProducerVerifier`; `TrustedCollectorAdapter` is only for channels whose
producer was authenticated before correlation and then validates the expected
collector field shape. Installing that adapter is an explicit caller-held trust
precondition, not evidence derived from `Observation.Source`.
