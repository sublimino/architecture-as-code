# ADR — SLAWS policy language: CEL only, Cedar rejected

- Status: accepted 2026-10-04 (SLAWS v2 §4, decision D9)
- Card: P3-PRE
- Supersedes: v1 proposal text naming "Cedar formal SMT policy verification"

## Context

SLAWS v1 named Cedar as the entitlement and formal-verification engine alongside CEL predicates. The code review at `83b7f6e3` found no Cedar in the repository, two CEL environments already in use (`apps/policy-engine/cel_eval.go` over `agent/request/object/manifest`; `apps/signal-ingest/correlation/engine.go` over observation pairs `a`/`b`), and a third CEL emitter in `pkg/policy` (ValidatingAdmissionPolicy generator). FAIR scoring in `apps/policy-engine/fair/` is Monte Carlo over beta-PERT triples, not an SMT engine.

## Decision

Observation policy is written in CEL only, against one shared vocabulary in `d2-signalloom/pkg/obscel` (variable `obs`, plus `vars` from the bundle). Stage-1 predicates are CEL; stage-2 thresholds are declared in the bundle as windows, not in CEL. Cedar is not adopted. FAIR is retained for decision scoring.

## Reasoning

1. **Problem shape.** Cedar answers "may principal P perform action A on resource R" against an entity store with a schema and hierarchy. Nothing in the ingest path asks permission; the need is predicates over an event stream with time windows, which is CEL's shape.
2. **Entitlement checks are a CEL rule.** "Was this ARN allowed to `CreateAccessKey`" is `obs.labels.event_name == "CreateAccessKey" && !(obs.actor in vars.break_glass_actors)`. An allowlist variable per bundle replaces a Cedar entity store.
3. **One vocabulary, not two schemas.** Adopting Cedar would introduce a second schema that must track `model.Observation` and a second evaluator to keep conformant with the first. The repo already carries the cost of two CEL environments diverging (`Labels` projected into neither); the fix is one environment, not a third language.
4. **Dependency weight.** `cedar-go` adds a parser, a policy store and an entity model to both apps for formal analysis that no card would exercise.
5. **Formal verification was not the requirement.** The v1 wording conflated FAIR risk scoring with SMT. Replay-equals-live under the determinism contract (`pkg/obscel/doc.go`) is the verification SLAWS needs: a bundle's output over the backlog is reproducible byte for byte.

## Consequences

- `pkg/obscel` is the only CEL environment for observations; every shipped rule compiles against it in CI (`Conform`).
- `correlation/engine.go` becomes a consumer of findings; its pairwise environment is not extended.
- If an authorisation use case arrives (an agent asking permission before an action), it is a new proposal, and Cedar is a candidate there.

## References

- Proposal §4 and §9 (D2, D3, D9): `docs/Proposal — Signal Loom AWS Telemetry Ingest & Multilayer Policy Engine Beta (2026-Q3).md`
- Vocabulary and determinism contract: `d2-signalloom/pkg/obscel/doc.go`
