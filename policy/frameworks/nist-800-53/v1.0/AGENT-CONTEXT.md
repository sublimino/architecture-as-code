# nist-800-53 v1.0 — agent and request context

No check in this pack reads `agent` or `request`. Every check reads only
`object`, the Pod-shaped `{metadata, spec}` described in
[CONFORMANCE.md](../../CONFORMANCE.md).

## Absent-field semantics

Every path is `has()`-guarded and an absent path **fails** the check rather
than erroring. No check returns `error` on any schema-valid input. A Pod with
an absent or empty `spec.containers` fails every per-container check rather
than reporting not-applicable.

`no-automount-sa-token` requires `spec.automountServiceAccountToken: false`
explicitly; a pod inheriting the protection from its ServiceAccount is still
failed, because the pack never sees the ServiceAccount object.

An explicit `runAsNonRoot: false` or `runAsUser: 0` at **pod** level is fatal
regardless of container overrides: Pod Security Standards reject the pod at
either level, so the effective runtime value is not the test.
`capabilities.drop` must contain `ALL` compared case-sensitively (lowercase
`all` fails, matching Pod Security Admission) and `capabilities.add` must stay
within `{NET_BIND_SERVICE}`. `no-privilege-escalation` is skipped when
`spec.os.name` is `windows`, where the API forbids the field.

## Container-list scope

`container-run-as-non-root`, `no-privilege-escalation`, `no-privileged-mode`,
`read-only-rootfs`, `drop-all-capabilities` and `image-digest-required`
evaluate `containers` + `initContainers` + `ephemeralContainers`.
`resource-limits-set` evaluates `containers` + `initContainers` only — the
Kubernetes API forbids `resources` on ephemeral containers, so requiring it
there could never pass for any admissible pod.
