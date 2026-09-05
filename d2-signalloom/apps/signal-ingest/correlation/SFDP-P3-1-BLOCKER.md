# SFDP-P3-1: deterministic producer prerequisite blocked

Status: **fail — implementation stopped at the shared-credential hard gate**.

Inspected base: `2efc851d8a3d49c924b41d82d9fb3f4a53a4335f`.
No resolver implementation, fixture relaxation, collector modification, database
change, HTTP wiring, merge, push, or PR was performed by this card.

## Contract and finding

The card requires deterministic same-entity edges justified by a typed credential
identifier **plus a workload discriminator**. It explicitly requires stopping if
the available merge signal is only a shared credential. It also prohibits new CEL
identity rules and collector changes.

The existing rule matches establish credential equality (or source/time proximity),
not workload equality. Classifying those matches as deterministic would not meet
the contract. Classifying them all as weak and shipping an always-separate engine
would not satisfy the positive same-principal/recall requirements either.

This finding is **not** that workload metadata is absent everywhere. Some producers
already retain it in labels. The missing prerequisite is an approved, reachable
principal-binding contract that makes those fields a justified deterministic edge
across the required observation pairs. Mere availability of a label is not proof
of its common issuer, lifetime, authenticity, or workload-instance semantics.

## Evidence

Paths below are relative to `d2-signalloom/apps/signal-ingest/` at the inspected base.

| Evidence | Finding |
| --- | --- |
| `correlation/rules.go:12-126` and `correlation/rules_identity.go:6-35` | Complete DefaultRules set: 20 rules; 17 positive actor-hint joins, two positive source/time joins, one negative exclusion. No predicate tests workload identity, labels, or principal_id. |
| `correlation/rules_identity.go:12-35` | Each of the four identity audit rules relies on nonempty equal actor_hint, optionally bounded by time. None proves workload equality. |
| `correlation/engine.go:84-100` | obsToMap exposes scalar identity fields, but not Labels. Existing CEL cannot inspect pod_uid or other label discriminators. |
| `correlation/resolve.go:19-30,98-110` | Existing resolver prefers ActorHint; equal hints are accepted and shared source is a fallback. This is not a principal-level deterministic proof. |
| `collectors/spirea/collector.go:108-153` | Workload context is retained in labels; ActorHint is SPIFFE identity, PrincipalID is service-account identity. A service-account SPIFFE path can identify a credential shared by workloads. |
| `collectors/baoaudit/receiver.go:266-329` | Identity metadata and SA/SPIFFE mapping are available, with role/accessor fallbacks. Those fallbacks do not establish workload-instance equality. |
| `collectors/gcpaudit/collector.go:585-639` | ActorHint comes from principal email/subject. Shared service-account principal is not a workload discriminator. |
| `collectors/netebpf/collector.go:164-194` | Labels retain pod_uid, namespace, service_account and spiffe_id, but emitted observation has no ActorHint/PrincipalID. Existing nonempty-hint CEL joins cannot consume these identity labels. |
| `collectors/spirea/tracker.go:90-121` | BindAccessor is a mutable credential-alias association, not an attested workload binding; it cannot independently justify deterministic identity fusion. |

A read-only independent source audit agreed with the producer prerequisite finding.
A direct code-based audit printed all 20 rule names with
`workload predicate=false` and printed the complete obsToMap activation fields.
The audit command exited 0; these are source findings, not a runtime soundness test.

## Preflight and verification boundary

- `git merge-base --is-ancestor integration/signal-fusion-v0.1.0 HEAD`: exit 0.
- Worktree began clean and detached at the inspected base.
- Board inspected once read-only: P3-1 active; P3-2 through P3-5 in backlog.
- Proposal and P3-PRE errata read. Preflight green does not prove this identity prerequisite.
- No labelled false-merge test was run; no false-merge==0 claim is made.
- No confluence, recall, race, full-suite, or runtime acceptance result is claimed.
- No bad merge was deliberately introduced to manufacture a failing test.

## Prompt-to-artifact disposition

| Requested deliverable | Disposition |
| --- | --- |
| Resolve engine, typed algebra, union-find, deterministic gating | Not implemented: hard stop before implementation. |
| Typed identifiers, fidelity vocabulary, exhaustive rule classifications | Producer audit only; no production classification installed. |
| Confidence cap, directed delegation, provenance, persistence seam | Not implemented. |
| Cannot-link, rebuild/retraction, hub/degree caps | Not implemented. |
| Canonical representative, lineage, candidate recall, temporal robustness | Not implemented. |
| Labelled twins, fan-out, confluence, stress, race and regression gates | Not run or claimed. |
| Commit and proposal failure errata/Result | Blocker report committed; proposal updated separately through Obsidian bridge. |
| Integration merge and runtime proof | Not achieved; Governor owns reconciliation. |

## Recommended action

**Escalate the prerequisite contract**, rather than retrying this unchanged card.
Authorize and specify either an existing-rule promotion gate backed by trusted
workload bindings, or a producer change owned by the appropriate predecessor card.
That contract must define issuer/scheme/value, workload-instance discriminator,
binding provenance, lifetime/retraction, and cross-source candidate recall. Then
provide positive and falsification fixtures from those real producer fields.

Do not promote SA equality, mutable accessor aliases, IP, or source/time matches
to deterministic merely to obtain a positive merge. Resume P3-1 only after the
hard-stop prerequisite is explicitly resolved.
