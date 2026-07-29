# SLDPB25-P3-PRE preflight evidence

Date: 2026-07-27 (Europe/London)
Base ref: `refs/heads/integration/signalloom-d2-v2.5.0`
Worktree: `integration/signalloom-d2-v2.5.0`

## Decision

**FAIL — do not advance to Phase 3 implementation or Governor sign-off.**

The required ancestry and static checks pass, but the existing proposal errata
records unresolved runtime and supply-chain blockers. This preflight performed
validation only; it did not edit `board.json`, another worktree, or the
proposal, and it did not push or create a pull request.

## Baseline evidence

| Check | Result |
| --- | --- |
| `git merge-base --is-ancestor refs/heads/integration/signalloom-d2-v2.5.0 HEAD` | 0 |
| `make signalloom-check` | 0; release-pack, delivery-contract, and root checks passed |
| `make demo-signalloom-test-config` | 0; topology, bootstrap drift, dependency, and static assertions passed |
| `d2-signalloom/test/validate-topology.sh` | 0 |
| `bats d2-signalloom/test/gateway-routing.bats` | 0 |
| `bats d2-signalloom/test/least-privilege.bats` | 0 |
| `bats d2-signalloom/test/topology.bats` | 0 |

The worktree was not clean at inspection: one tracked PRD was modified and
three `MEMORY/WORK` directories were untracked. These were pre-existing and
were not changed by this validation.

## Review findings

### Routes — static pass

- `/` routes to `fe-signalloom:8000`.
- `/api` routes to `fe-signalloom-api:8000`.
- Both routes bind `ingress/cluster` section `https`.
- The route manifest names no internal database, cache, object-store, Dex, or
  fake-proxy backend.

### NetworkPolicies — static pass, least-privilege concern

- Frontend and infrastructure overlays declare default-deny ingress and egress.
- Focused BATS checks pass for gateway, fake-proxy, dependency, DNS, and Dex
  paths.
- `inf-signalloom/allow-dependency-traffic` permits unrestricted same-namespace
  ingress and egress via empty `podSelector` peers with no ports. The Bao policy
  has the same broad same-namespace control-plane allowance. This is wider than
  the proposal's least-privilege and denied-path claims; runtime negative tests
  are still required before treating isolation as proven.

### Supply-chain gates — contract pass, delivery evidence absent

- `make signalloom-check` validates the declarative contract, including Cosign
  signer constraints, SHA-256 digest format, SPDX JSON SBOM, SLSA provenance,
  fail-closed verification, and required security-gate dispositions.
- `scripts/attested-test.sh` attests test execution with Witness and queries
  Archivista; it does not itself verify a candidate image's Cosign signature,
  immutable digest, SBOM, or SLSA provenance.
- Existing proposal errata records no immutable candidate digest, unavailable
  Syft, and unresolved scanner/DAST/egress evidence. Therefore the static gate
  must not be interpreted as supply-chain qualification.

### Prompts and duplication

- The tracked Promptfoo baseline and guarded files are distinct: 61 and 60
  lines, SHA-256 prefixes `d305a8187476` and `6ab4b2fe1e65`, with 21 changed
  lines under a 0.826 sequence similarity ratio.
- No exact duplicate was found between those two prompt files.
- Repository-wide exact-content scanning found existing duplicates, notably the
  Signalloom bootstrap SQL copied into both `contracts/` and the local overlay.
  This is a maintenance-risk observation, not a Phase 3 implementation change.

## Proposal errata consulted

The proposal's existing entries for Gateway Routing, P3 TEST-1, and bounded
security validation remain blocking: runtime namespaces/services/Gateway/Dex
were unavailable or not ready, Flux lacked HTTPRoute patch permission, and
artifact/scanner evidence was incomplete. The current static rerun does not
supersede those failures.

## Required follow-up before retry

1. Re-run the complete TEST-1 runtime and browser gate on a healthy isolated
   stack, including live Gateway, Dex, dependency readiness, and negative
   NetworkPolicy assertions.
2. Narrow or explicitly justify the broad same-namespace NetworkPolicy rules,
   then add a test that would fail if unintended peer/port access is restored.
3. Produce candidate-digest-bound Cosign, SPDX SBOM, SLSA provenance, and all
   required security-gate dispositions under the fail-closed release contract.
