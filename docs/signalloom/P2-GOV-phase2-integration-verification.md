# Phase 2 Governor integration verification

Created: 2026-07-27T06:52:00+01:00
Integration ref: `integration/signalloom-d2-v2.5.0`
Task worktree HEAD at review: `e799fb3`

## Decision

```text
status=fail proceed=no blocking_drift=yes
```

The static security controls and supply-chain contract are present, but Phase 2
integration is not proven: the shared Gateway has no `HTTPRoute` for the
`fe-signalloom` Service, and the existing runtime test does not implement TEST-1
product-flow coverage. No live-cluster acceptance is claimed.

## Canonical patterns reviewed

- Gateway: `d2-infra/components/ingress/configs/base/cluster-gateway.yaml`
  provides HTTP on port 80, HTTPS on port 443 with TLS termination, an HTTP to
  HTTPS 301 redirect, and cross-namespace HTTPS route attachment.
- Portal isolation: `d2-signalloom/apps/fe-signalloom/base/networkpolicy.yaml`
  provides default-deny ingress and egress, DNS on TCP/UDP 53, declared
  dependency ports 5432/6379/9000, bounded OpenBao port 8200, and ingress only
  from `envoy-gateway-system` on port 8000.
- Artifact trust: `docs/signalloom/delivery-contract.json` requires cosign
  signer identity, immutable SHA-256 digest binding, SPDX JSON SBOM, SLSA v1
  provenance, and fail-closed verification.

## Blocking gaps

1. No `HTTPRoute` in the Signal Loom frontend kustomization routes the
   `fe-signalloom` Service through the canonical Gateway.
2. `d2-signalloom/test/runtime.bats` checks Flux readiness and deployment
   presence only; it does not provide TEST-1 browser/API/auth/error/egress
   journey evidence.
3. Supply-chain checks validate the repository-local static contract only.
   Runtime attestation verification and durable evidence storage remain
   unperformed, as explicitly stated by `docs/signalloom/P2-9-supply-chain-evidence-contract.md`.

## Commands and results

| Command | Exit | Result |
| --- | ---: | --- |
| `git merge-base --is-ancestor integration/signalloom-d2-v2.5.0 HEAD` | 0 | Ancestry valid |
| `make -C d2-signalloom test` | 0 | Topology, dependencies, Go helper, 20 BATS checks passed |
| `make signalloom-contract-check` | 0 | Release-pack and delivery contract checks passed |
| `make signalloom-check` | 0 | Release-pack, contract, four-root preflight passed |
| static route/policy assertions | 0 | Gateway and policy patterns present; frontend route absent |

The integration worktree was detached at `e799fb3` and had no tracked changes
before this verification artifact was created. No board, other worktree, push,
or pull request was changed.
