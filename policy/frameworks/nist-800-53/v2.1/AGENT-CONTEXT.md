# nist-800-53 v2.1 — agent and request context

Paths this pack reads from `agent` and `request`. Shipped paths are frozen:
extend, never rename. Every path is `has()`-guarded. An absent path fails the
check instead of erroring.

## `agent`

| Path | Type | Check |
|------|------|-------|
| `agent.audit_config.event_logging_enabled` | bool | `immutable-audit-sink` |
| `agent.telemetry.monitoring_active` | bool | `anomaly-detection-telemetry` |

## `request`

| Path | Type | Check |
|------|------|-------|
| `request.peer.spiffe_id` | string | `spiffe-peer-authorization`: must start with `spiffe://signalloom.demo/ns/` |
| `request.source.namespace` | string | `cross-namespace-egress-authorization` |
| `request.destination.namespace` | string | `cross-namespace-egress-authorization`: passes when it is non-empty and equals the source namespace (or `context.egress_authorized` is true) |
| `request.context.egress_authorized` | bool | `cross-namespace-egress-authorization`: passes a cross-namespace destination when `true` |
| `request.auth.svid_presented` | bool | `mfa-spiffe-svid-required` |
| `request.network_policy.ingress_isolated` | bool | `network-boundary-enforcement` |

## Trusted registry prefixes

`trusted-registry` passes only when every container, init container and
ephemeral container image starts with one of these prefixes:

- `zot.local/`
- `registry.internal/`
- `ghcr.io/controlplaneio/`
- `ghcr.io/controlplaneio-in-toto/`
- `ghcr.io/controlplaneio-fluxcd/`
- `gcr.io/distroless/`

Public registries are trusted only down to a ControlPlane organisation (or
Google's `distroless` project), never as a whole host: `ghcr.io/attacker/...`
and `gcr.io/<any-project>/...` fail. `zot.local/` and `registry.internal/`
are private-use hosts. The `ghcr.io/controlplaneio*` organisations are the
ones this repository's manifests pull from. Prefixes end in `/`, so a
lookalike organisation such as `ghcr.io/controlplaneio-evil/` fails.
