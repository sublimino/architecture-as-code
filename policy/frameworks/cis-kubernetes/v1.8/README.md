# CIS Kubernetes Benchmark v1.8.0 — pod-evaluable pack

`framework.json` here is pack `cis-kubernetes`, version `v1.8.0`. It holds the
CIS v1.8.0 section 5 (Policies) recommendations that can be decided from a
single pod spec. Every check is proven by the fixtures under `fixtures/`
against the contract in [`../../CONFORMANCE.md`](../../CONFORMANCE.md).

## Source of the numbering

The CIS PDF is gated. Recommendation numbers and titles are copied verbatim
from kube-bench, which carries them for the `cis-1.8` benchmark (Kubernetes
1.26):

<https://github.com/aquasecurity/kube-bench/blob/main/cfg/cis-1.8/policies.yaml>

## The frame: admissibility, not runtime effect

CIS §5.2 is worded "Minimize the **admission** of …". So where a manifest's
runtime effect and its admissibility under the
[Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
disagree, **these checks follow admissibility**: a pod that a `restricted`
namespace rejects fails, even if the container runtime would have produced a
safe process had the pod ever been admitted. A pod that is rejected never runs,
so reporting it compliant is a false negative, and a false negative is the
dangerous direction for a compliance product.

Three places where this bites, each pinned by a fixture:

| Manifest | Runtime effect | Admissibility | Verdict |
|----------|----------------|---------------|---------|
| `capabilities.drop: ["all"]` | containerd/CRI-O normalise the name and drop everything | PSA compares the `ALL` token exactly and rejects | `capabilities-dropped-all` **fails** (`drop-all-lowercase`) |
| `runAsUser: 1000`, no `runAsNonRoot` | the process gets UID 1000 | PSS `restricted` requires `runAsNonRoot: true` | `no-root-containers` **fails** (`root-container-uid-1000-no-pod-identity`) |
| pod `seccompProfile: Unconfined`, container overrides `RuntimeDefault` | that one container is confined | pod-level `Unconfined` is forbidden at baseline, so the pod is rejected | `seccomp-runtime-default` **fails** (`seccomp-container-runtimedefault-overrides-pod-unconfined`) |

**Stricter than PSS where CIS is stricter.** The frame resolves disagreements
about what a manifest *means*, not about where the bar sits. `no-added-capabilities`
fails any non-empty `capabilities.add`, including `NET_BIND_SERVICE`, which PSS
`restricted` explicitly permits — CIS 5.2.9 permits no added capability, and
this pack implements CIS (fixture `added-capability-net-bind-service`).

## Input

`object` is a Pod-shaped object `{metadata, spec}`. No check reads `agent` or
`request`. "All containers" means `spec.containers`, `spec.initContainers` and
`spec.ephemeralContainers` together; every per-container check covers all three.

## Checks

| Check ID | CIS | Title | Absent-field semantics |
|----------|-----|-------|------------------------|
| `sa-token-automount-disabled` | 5.1.6 | Ensure that Service Account Tokens are only mounted where necessary | Absent `automountServiceAccountToken` falls back to the ServiceAccount, default `true`: **fail**. Only an explicit `false` passes. |
| `no-privileged-containers` | 5.2.2 | Minimize the admission of privileged containers | Absent `privileged` is `false`: pass. |
| `no-host-pid` | 5.2.3 | Minimize the admission of containers wishing to share the host process ID namespace | Absent `hostPID` is `false`: pass. |
| `no-host-ipc` | 5.2.4 | Minimize the admission of containers wishing to share the host IPC namespace | Absent `hostIPC` is `false`: pass. |
| `no-host-network` | 5.2.5 | Minimize the admission of containers wishing to share the host network namespace | Absent `hostNetwork` is `false`: pass. |
| `no-privilege-escalation` | 5.2.6 | Minimize the admission of containers with allowPrivilegeEscalation | Absent `allowPrivilegeEscalation` is effectively `true`: **fail**. Windows exempt. |
| `no-root-containers` | 5.2.7 | Minimize the admission of root containers | As PSA decides it. Effective `runAsNonRoot` (container, else pod) must be explicitly `true` — a non-zero `runAsUser` alone does **not** substitute for it, because `runAsNonRoot: true` is what makes the kubelet refuse an image whose USER is root. And no `runAsUser` may be `0`: not at pod level (even if every container overrides it) and not at container level. A container setting `runAsNonRoot: false` fails whatever the effective UID. |
| `no-net-raw` | 5.2.8 | Minimize the admission of containers with the NET_RAW capability | Runtimes grant NET_RAW by default, so absent `capabilities` **fails**. Names compare case-insensitively, as containerd and CRI-O do. Passes only if `drop` holds `ALL`, `NET_RAW` or `CAP_NET_RAW` (any case), `add` does not re-add any of those (any case, including `cap_all`), and the container is not privileged. Windows exempt. This check stays case-insensitive on purpose: PSS has no NET_RAW-specific rule, so there is no admissibility reading to follow, and the question is whether the process holds the capability — CRI normalises the name, so `add: ["net_raw"]` really does re-grant it and must be detected. A pod whose only drop is a lowercase `all` therefore passes `no-net-raw` and fails `capabilities-dropped-all`, which is where PSA rejects it. |
| `no-added-capabilities` | 5.2.9 | Minimize the admission of containers with added capabilities | Absent or empty `capabilities.add`: pass. |
| `capabilities-dropped-all` | 5.2.10 | Minimize the admission of containers with capabilities assigned | `drop` must contain the exact token `ALL`, as Pod Security Admission compares it. `"all"` in any other case is rejected by a `restricted` namespace: **fail**. Absent: **fail**. Windows exempt. |
| `no-windows-hostprocess` | 5.2.11 | Minimize the admission of Windows HostProcess containers | Absent `windowsOptions.hostProcess` is `false`. Fails if the pod or any container sets `true` (the API rejects a pod/container mismatch, so either level is decisive). |
| `no-hostpath-volumes` | 5.2.12 | Minimize the admission of HostPath volumes | Absent `volumes`: pass. |
| `no-host-ports` | 5.2.13 | Minimize the admission of containers which use HostPorts | Absent or `0` `hostPort`: pass. With `hostNetwork: true` the API server defaults `hostPort` to `containerPort`, so any declared port on a hostNetwork pod **fails**. |
| `no-secrets-in-env` | 5.4.1 | Prefer using Secrets as files over Secrets as environment variables | Fails on `env[].valueFrom.secretKeyRef` or `envFrom[].secretRef`. Absent `env`/`envFrom`: pass. |
| `seccomp-runtime-default` | 5.7.2 | Ensure that the seccomp profile is set to docker/default in your Pod definitions | As PSA decides it. A **pod-level** `Unconfined` **fails outright**, whatever the containers override it with: PSA forbids it at baseline as well as restricted, and a container added later without an override inherits it. Otherwise effective profile = container, else pod; type must be `RuntimeDefault`, or `Localhost` with a non-empty `localhostProfile` — `Localhost` with no `localhostProfile` is rejected by the API server itself ([`validateSeccompProfileField`](https://github.com/kubernetes/kubernetes/blob/master/pkg/apis/core/validation/validation.go)), so it **fails**. `Unconfined` fails; absent everywhere **fails** (kubelet default is Unconfined). The deprecated `seccomp.security.alpha.kubernetes.io/*` annotations are not read: since 1.19 the API server mirrors them into the field on create. Windows exempt. |
| `security-context-applied` | 5.7.3 | Apply SecurityContext to your Pods and Containers | Pod `securityContext` present and non-empty, and every container's `securityContext` present and non-empty. `{}` counts as absent. |
| `no-default-namespace` | 5.7.4 | The default namespace should not be used | `metadata.namespace` must be set, non-empty and not `default`. Absent **fails**: it resolves to `default` unless the client context says otherwise. |

**Windows exemption.** `spec.os.name: windows` exempts `no-privilege-escalation`,
`no-net-raw`, `capabilities-dropped-all` and `seccomp-runtime-default`, mirroring
Pod Security Standards: those fields are Linux-only and the API rejects them on
Windows pods. The exemption keys on `spec.os.name` only; a Windows pod that
relies on a `kubernetes.io/os` nodeSelector is evaluated as Linux
(fixture `windows-without-os-field`).

**Empty `containers`.** Schema-invalid (the API requires one container).
Per-container checks pass vacuously because nothing runs; pod-level checks
still evaluate (fixture `empty-containers-vacuous`).

**Missing `spec`.** Not a pod. Every spec-reading check fails closed (`has(object.spec)` guard), never `error`.

**Numbers.** JSON numbers reach CEL as `double`. `runAsUser > 0`, `hostPort != 0`
compare int literals against doubles correctly (fixtures `root-container-uid-0`,
`root-container-uid-1000-no-pod-identity`, `host-port-zero-explicit`).

## Excluded recommendations

These CIS v1.8.0 section 5 recommendations are not evaluable from one pod spec:

| CIS | Why excluded |
|-----|--------------|
| 5.1.1–5.1.5, 5.1.7–5.1.13 | RBAC: Roles, ClusterRoles, bindings, group membership and ServiceAccount objects, not pods. (5.1.5 needs the ServiceAccount object as well as the pod.) |
| 5.2.1 | Cluster has an active policy control mechanism: an admission-controller property. |
| 5.3.1, 5.3.2 | CNI support and NetworkPolicy presence per namespace: cluster and namespace objects. |
| 5.4.2 | External secret storage: an architecture choice, not visible in a pod. |
| 5.5.1 | ImagePolicyWebhook: API server admission configuration. |
| 5.7.1 | Administrative boundaries with namespaces: namespace design across the cluster. |

## Cost

The engine caps CEL cost at 10000 (`cel_eval.go`). Fixture `ten-container-cost`
(4 init + 5 main + 1 ephemeral container, each with 25 env vars, 4 envFrom,
5 ports) evaluates every check; the highest measured cost is
`no-secrets-in-env` at 2178, which scales with containers × env entries.
The longest expression is 743 bytes against the 4096-byte limit.

## Fixtures

- `fixtures/unit/`: each fixture is the Linux or Windows baseline with one fact
  changed, and lists the full verdict vector, so a fail is attributable to that
  fact and the baseline itself is shown compliant (`baseline-*-compliant`).
- `fixtures/integration/`: hardened distroless API, Helm nginx with defaults,
  privileged node-agent DaemonSet pod, Windows HostProcess agent, 10-container
  cost pod.

Run:

```bash
cd d2-signalloom/apps/policy-engine
go test -run 'TestConformance_(Verdicts|Coverage|FixturesWellFormed)' -count=1 -v .
```
