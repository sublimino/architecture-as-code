# eu-ai-act v2.0 — agent and request context

No check in this pack reads `agent` or `request`. Every check reads only
`object`, the Pod-shaped `{metadata, spec}` described in
[CONFORMANCE.md](../../CONFORMANCE.md).

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
