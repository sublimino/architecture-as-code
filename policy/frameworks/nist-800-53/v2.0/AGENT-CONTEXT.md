# nist-800-53 v2.0 — agent and request context

No check in this pack reads `agent` or `request`. Every check reads only
`object`, the Pod-shaped `{metadata, spec}` described in
[CONFORMANCE.md](../../CONFORMANCE.md).

## Absent-field semantics

Every path is `has()`-guarded and an absent path **fails** the check rather
than erroring. No check returns `error` on any schema-valid input. A Pod with
an absent or empty `spec.containers` fails every per-container check rather
than reporting not-applicable.

Fields that must be set **explicitly** — inheriting the protection from
elsewhere is not enough, because the pack sees only this one object:

| Field | Check | Note |
|-------|-------|------|
| `spec.automountServiceAccountToken: false` | `no-automount-sa-token` | A pod whose ServiceAccount sets this false is still failed; the pack never sees the ServiceAccount. |
| `allowPrivilegeEscalation: false` | `no-privilege-escalation` | Required per container. Skipped entirely when `spec.os.name` is `windows`, where the API forbids the field. |
| `readOnlyRootFilesystem: true` | `read-only-rootfs` | Required per container. |
| `capabilities.drop` contains `ALL` | `drop-all-capabilities` | Compared case-sensitively, as Pod Security Admission compares it; lowercase `all` fails. `capabilities.add` must also stay within `{NET_BIND_SERVICE}`. |

An explicit `false`/`Unconfined` at **pod** level is fatal regardless of
container overrides, for `runAsNonRoot` and `seccompProfile`. Pod Security
Standards reject the pod at either level, so the effective runtime value is not
the test. `runAsUser: 0` is likewise fatal at either level.

## Container-list scope

| Checks | Lists evaluated |
|--------|-----------------|
| `container-run-as-non-root`, `no-privilege-escalation`, `no-privileged-mode`, `read-only-rootfs`, `drop-all-capabilities`, `seccomp-profile`, `image-digest-required`, `trusted-registry` | `containers` + `initContainers` + `ephemeralContainers` |
| `resource-limits-set`, `resource-requests-set` | `containers` + `initContainers` |
| `liveness-probe-present`, `readiness-probe-present`, `log-volume-mount` | `containers` only |

The narrower scopes are deliberate, not gaps. The Kubernetes API **forbids**
`resources`, `livenessProbe`, `readinessProbe`, `lifecycle` and `ports` on
ephemeral containers, and forbids probes on non-sidecar init containers. A
check requiring those fields there could never pass for any admissible pod.

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
