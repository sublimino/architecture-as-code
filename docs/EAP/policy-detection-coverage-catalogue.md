# Policy detection coverage catalogue (threat catalogue)

This is the per-stream threat catalogue that drives full CEL detection coverage.
For every collector stream it names: the layer, the load-bearing labels a rule
can read, the **policy failures** (stage-1 CEL rules → findings), and the
**cross-stream correlations** (the `correlation.Engine` joins findings per
resolved actor → stun). It is the source the per-stream bundles and the
coverage-matrix gate are built against.

Status key: ✅ bundle exists · 🟡 partial · ❌ no rule yet (gap).

## How detection works (three tiers)

1. **Stage-1 rules (obscel)** — every observation is evaluated against every
   tenant bundle's CEL rules in `Sink.Evaluate`; a match logs a `Finding`. A
   rule targets one or many streams purely by its CEL (`obs.layer`, labels).
2. **Stage-2 windows (obscel)** — `over_rule` (one rule) keyed by
   `[tenant_id, actor, labels.…]`; burst/threshold → `Decision` → stun dispatcher.
3. **Correlation Engine** — resolves one actor across layers, corroborates
   findings (confidence-capped), runs attack-chain cascades → stun. This is
   where multi-collector behaviours are joined.

## Per-stream catalogue

### kubernetes — kube-apiserver audit (NEW, the reference vertical) ✅
> Coexists with an EXISTING `k8saudit` collector (adapters.go / WebhookReceiver)
> that projects the same source to **LayerIdentityAuth** for delegation/
> impersonation tracking — left untouched. This new vertical is the **threat**
> projection on **LayerKubernetes**, Source `k8saudit-kube`, env
> `COLLECTOR_K8SAUDIT_KUBE_MODE`. Making it canonical under the existing name is
> a separate follow-up card.
Layer `kubernetes`. Labels: `verb`, `resource`, `subresource`, `namespace`,
`name`, `actor` (user/SA), `decision` (allow/forbid), `response_code`,
`source_ip`, `user_agent`, `cluster`, `audit_stage`.

**Ingestion — one projection, pluggable sources.** The `k8saudit` collector
projects a kube-apiserver audit event → observation once; the source is
swappable, like awslogs' live/fixture seam:
- **warden-local** (primary): the signalloom-warden on each node tails the
  apiserver audit log file or receives the apiserver audit *webhook* locally and
  forwards to signal-ingest — the same on-node path nono evidence rides. This is
  the preferred local gatherer; **kagent is NOT the k8s-audit path** (it is an
  agent tool-use collector, de-prioritised here).
- **cloud-streamed** (managed control planes, no node access): EKS →
  CloudWatch Logs, GKE → Cloud Logging, AKS → Azure Monitor. Live cloud clients
  sit behind a `Source` interface (EKS/GKE/AKS adapters); `fixture` mode feeds
  testdata for offline tests. EKS/GKE may reuse the awslogs/gcpaudit transport.
Policy failures (stage-1):
- `pods/exec` or `pods/attach` into a workload (interactive shell).
- read of `secrets` (get/list/watch) outside an allowed SA.
- privileged / hostPath / hostPID pod create.
- RBAC escalation: create/patch `clusterrolebindings`, `rolebindings`, bind to
  `cluster-admin`, or `escalate`/`bind` verbs.
- `serviceaccounts/token` creation (token minting).
- `nodes/proxy`, `pods/portforward`.
- anonymous / `system:unauthenticated` verb that was allowed.
- delete of audit/logging/policy resources.
Windows: exec-burst per actor; secret-read burst per actor.
Cross-stream: k8s exec/secret-read + endpoint_host sensitive-file + network_egress → exfil chain.

### cloud_control_plane — awslogs (CloudTrail/IAM) ✅
Covered by `kusari/cloud-signals.yaml` + `iam-change.yaml` (EKS config, IAM
priv/key, S3 exposure, GuardDuty tamper, console root, cross-account, VPC reject).

### endpoint_host — agentnono (Landlock) ✅ · sentinel eBPF ✅
nono landlock denial covered by `kusari/landlock-denial.yaml`. The sentinel eBPF
endpoint stream is covered by `kusari/endpoint-runtime.yaml` (sensitive-file open,
unexpected `execve`, capability/ptrace). TWO endpoint_host streams share one
label contract and every rule source-gates on BOTH: the LIVE stun-sentinel
(`source: "stun-sentinel"`, in-kernel eBPF, no DaemonSet — Tier-0 reactive freeze
AND central CEL) and the collector projection (`collectors/ebpf`,
`source: "sentinel.ebpf.syscall_trace"`, env `COLLECTOR_EBPF_ENDPOINT_MODE`).
Tetragon is fully removed (no gRPC client, no `cilium/tetragon` dependency, no
deploy manifests). TWO residuals: (i) live exec-scoping is by the workload
actor/pod pseudonym because the kernel probe cannot see the service account — a
trusted live workload is exempted by its actor identity in `allowed_exec_actors`,
not an SA name; (ii) `capability-or-ptrace` fires only on the collector projection
until the sentinel probes the ptrace/cap syscalls (deferred to a bpf-toolchain
build host).

### network_egress — netebpf / awslogs VPC flow ✅
Direct-IP egress, non-cluster resolver, DNS tunnel (high-entropy qname),
egress to a new ASN/destination. Covered by `kusari/network-egress.yaml`
(live netebpf direct-IP/SNI anomalies) plus the VPC REJECT burst in the AWS
bundles.

### identity_authorization — spirea / SaaS login ✅
Covered by `kusari/identity-auth.yaml`. SPIRE: SVID issued to an unexpected
SPIFFE path; attestation-selector downgrade (the spirea collector now projects
`attestation_selector_type`). SaaS login: impossible-travel, new-geo, MFA-absent
login, admin role grant.

### application_saas — workspacesaas ✅
Covered by `kusari/application-saas.yaml`. Mass file download, external share of
a sensitive doc, OAuth app grant, admin-console setting change.

### gcpaudit — GCP admin activity ✅
Covered by `kusari/gcp-admin.yaml`. IAM policy binding change, service-account
key creation, bucket IAM made public, logging sink deletion (GCP analogues of
the AWS rules).

### baoaudit — OpenBao audit ✅
Covered by `kusari/openbao-audit.yaml`. Root-token use, secret-read burst,
policy/mount change, seal/unseal, token creation with broad policy.

## Cross-stream correlations (correlation.Engine, tier 3)

Keyed on the resolved actor (identity graph), not a single label:
- **Exfil chain:** cloud credential change → endpoint sensitive-file read →
  network egress, same actor, short window.
- **Account takeover:** SaaS login anomaly → serviceaccount/token mint (k8s) →
  cloud API access, same resolved identity.
- **Containment evasion:** landlock / sentinel eBPF denial → process-spawn burst →
  egress (the redteam_cascade shape already modelled).
- **Privilege cascade:** RBAC escalation (k8s) → secret read → OpenBao root use.

## Adversarial-review corrections (binding — applied to every bundle)

Verified against the live env/allow-list by the catalogue review:

- **Layer must exist.** `model/signal.go` has 7 layers and NO `kubernetes`. The
  k8s vertical adds `LayerKubernetes = "kubernetes"` to `model/signal.go` +
  `confidence.go` + the coverage gate's registered-layer set FIRST.
- **`actor` is a pseudonym, never a label.** The k8s user/SA goes to
  `Observation.ActorHint` → pseudonymised `obs.actor`; identity rules are
  `!(obs.actor in vars.<set>)` with the set declared in the bundle's
  `actor_vars` (pseudonymised at load) — not a label comparison. Same for
  anonymous (`system:anonymous` in an `actor_vars` set, not a string match).
- **Source-gate every rule.** `identity_authorization` (spirea+baoaudit+SaaS),
  `cloud_control_plane` (aws+gcp), `network_egress` (netebpf+vpcflow) are each
  multi-provider — every rule MUST also gate on `obs.source`.
- **Correlations join on `actor_id`/`principal_id`, and the correlation env has
  NO labels map.** Push per-event semantics into stage-1 findings, then
  correlate on the PRESENCE of those findings (layer+source+resolved actor_id),
  never on raw observation labels or cleartext `actor_hint`.
- **Allow-list gaps to close per stream (C3/C4/C5, same class as the nono gap):**
  gcpaudit (`service_name, method_name, project_id`; route `principal_email`→
  ActorHint, `caller_ip`→`source_ip`), netebpf (`classification, src_port,
  pod_uid, service_account, agent_role`, gap/coverage keys; `bytes_sent`→`bytes`,
  `node_name`→`node`), baoaudit (`operation, accessor, role, mount_point`).
- **k8s specifics:** require `obs.labels.stage == "ResponseComplete"` on every
  rule (apiserver emits ≤4× per event); a large pseudonymised `system:*`
  allow-set in `actor_vars` + verb scoping (drop `watch`) to kill FPs from
  kubelet/controllers; add techniques — `impersonate`, `pods/ephemeralcontainers`,
  `certificatesigningrequests` create+approve, `validating/mutatingwebhook-
  configurations` create, `secrets` create/update, `hostNetwork`/`hostIPC`/
  `runAsUser:0`/added-caps.
- **Entropy is collector-side.** DNS-tunnel qname entropy is a bucketed label
  the collector computes (`qname_entropy_bucket`), not a CEL primitive.
- **The coverage gate also checks allow-list membership** of each collector's
  projected keys (L2) — a rule with green unit fixtures can still refuse every
  batch under `-tags frostdb`.

## k8s label contract (reference vertical)

Reuse (already allow-listed): `verb, resource, subresource, resource_kind,
api_group, api_version, namespace, name, decision, response_code, source_ip,
audit_id, stage, reason`. ADD to the default allow-list: `user_agent`.
Identity via ActorHint→`obs.actor`; allowed-principal sets
(`allowed_secret_readers, anonymous_principals, system_controllers`) in `vars`
and named in `actor_vars`.

## The coverage gate

The policy-coverage-matrix test suite (to be added) asserts: every registered
collector layer has ≥1 stage-1 rule in some loaded bundle, and every rule has a
positive and a negative fixture (the kusari-e2e expectations-table discipline,
estate-wide). A new collector with no rule, or a rule with no negative, fails CI
— so "full coverage" is enforced, not claimed.

## Remaining work (scoped, as of 2026-10-12, `integration/slsi-v0.1.0` @ `b5bd818b`)

This wave took the detection pipeline to full stage-1/stage-2/correlation
coverage and re-executed the Tetragon removal (EAPCI-P1-8) inside `signal-ingest`.
What is left, ordered by risk:

1. **De-Tetragon residue OUTSIDE `signal-ingest` (P1-9 scope).** `signal-ingest`
   is clean (no `cilium/tetragon`, re-sourced to `sentinel.ebpf.syscall_trace`),
   but the estate still carries dead Tetragon surface, confirmed by
   `rg -i tetragon`:
   - Deploy: `d2-signalloom/deploy/tetragon-agent-telemetry.yaml`,
     `tetragon-helm-values.yaml` — remove or replace with the stun-sentinel
     DaemonSet once the endpoint stream is live-wired.
   - Test harness: `test/mocks/tetragon_grpc_mock.go` + `tetragon_grpc_test.go`
     (+ the mock module `test/mocks/go.mod`/`go.sum`), `scripts/test-tetragon-stream.sh`,
     `test/tetragon-telemetry-stream.bats`, and the `test-tetragon-*` Makefile
     targets — all exercise a gRPC server the collector no longer dials.
   - Docs/dashboard wording: `docs-signalloom/.../operate/detection-coverage.mdx`
     and `.../agents/dual-agent-onboarding.mdx`; dashboard
     `FeedsExplorerPage`, `SignalsPage`, `AgentActivityTab`, `ClaimModal`,
     `ContainmentPolicyConsentStep`, `policyApi.ts`; `test/acceptance/agent-claim.spec.ts`;
     `fe-signalloom/src/api_compat.py`. Decide retain-as-history vs rename to the
     own-eBPF framing.

2. **Two-endpoint_host-stream contract reconciliation (confirmed 2026-10-12, live-path audit).**
   The store path is sound: the live stun-sentinel emits `endpoint_host`
   observations to `POST /api/v1/observations` with `Source: "stun-sentinel"`
   (`stun-sentinel/pkg/correlator/ingest.go`); all 9 of its label keys are
   allow-listed and `store/sentinel_contract_test.go` proves acceptance; Tier-0
   in-kernel freeze is verified live. **But no CEL rule fires on that live
   stream.** `endpoint-runtime.yaml` is written against the *collector
   projection* contract — it gates on `obs.source == "sentinel.ebpf.syscall_trace"`
   AND `obs.labels.classification in {file_access, process_exec}`. The live
   stun-sentinel stream carries neither: its source is `stun-sentinel` and it has
   no `classification` label (it carries `syscall`/`target`/`severity`/
   `direct_reaction`/`cgroup_path`). So 2 of the 3 rules (sensitive-file-open,
   unexpected-execve) could never fire on live data even after a source rename;
   only `capability-or-ptrace` (gates on `syscall`) would. Net: live endpoint
   detections exist as stored evidence + Tier-0 containment, but drive no central
   Finding/Decision via CEL. The collector-projection source
   (`sentinel.ebpf.syscall_trace`) has no live producer (that is the deliberate
   seam from item 3), so `endpoint-runtime.yaml` currently fires only on fixtures/e2e.
   **Decision needed:** either (a) align the two label contracts and add
   `stun-sentinel` as an accepted source so the live stream drives central
   findings, (b) author a live endpoint bundle matching the stun-sentinel
   contract, or (c) accept Tier-0-only for the live stream and keep
   endpoint-runtime as the server-side-projection path. The provider label is
   `sentinel-ebpf`; any dashboard/P1-10 filter keyed on a literal `sentinel-ebpf`
   source must also be reconciled to the dotted form.

   **RESOLVED 2026-10-12 (option a — contract alignment).** The sentinel now emits
   a `classification` label (`sys_enter_openat`→`file_access`,
   `sys_enter_execve`/`evasive_syscall_burst`→`process_exec`) and an `ActorHint`
   (json `actor_hint`) carrying the workload actor; the three endpoint-runtime
   rules union the source gate to `{sentinel.ebpf.syscall_trace, stun-sentinel}`.
   `sensitive-file-open`, `unexpected-execve` and `capability-or-ptrace` all fire
   on the live stream, pseudonym-scoped and mutation-proven (producer + consumer).
   TWO residuals remain by design: (i) the kernel probe cannot see a service
   account, so live exec-scoping is by the workload ACTOR/POD pseudonym — a trusted
   live workload is exempted by its actor identity in `allowed_exec_actors`, not an
   SA name (the collector projection still scopes by SA); (ii) the sentinel probes
   no ptrace/capability syscall, so `capability-or-ptrace` fires only on the
   collector projection until those probes exist. Source/provider-name
   reconciliation with the dashboard/P1-10 is still open.

3. **Live-wire the own-eBPF endpoint stream.** `collectors/ebpf` endpoint
   projection is built and e2e-covered against fixtures, but the `Start` loop is
   an `ErrLiveDeferred` seam — it does not yet consume the stun-sentinel's
   `syscall_trace` ring. This is the only own-eBPF detection not yet fed by real
   kernel events. Pairs with (1)'s DaemonSet.

4. **Coverage-gate gaps (CovGate).** Two documented exceptions remain: the
   `landlock-verified-denial` stream has no e2e ±fixture row, and only
   `k8saudit` + `awslogs` expose `ProjectedKeys()` for the L2 allow-list
   membership check — the other collectors need the same accessor so the gate
   asserts their projected keys too.

5. **Make `k8saudit-kube` canonical.** The new kubernetes vertical coexists with
   the identity-auth `k8saudit` (delegation tracking). Promoting it under one
   `COLLECTOR_K8SAUDIT_MODE` means relocating the delegation path first — a
   separate card, not a drop-in, because it retires a working stream.

### Deferred to a bpf-toolchain build host — sentinel ptrace/cap probing (chunk C)

Closes residual (ii) above: make `capability-or-ptrace` fire on the LIVE
stun-sentinel stream. **Cannot be done without clang/the bpf hermetic toolchain**
(`d2-signalloom/apps/stun-sentinel/bpf/build.sh`) — the probe is a bpf2go-generated
344-byte frozen contract with a BTF-layout test, and new BPF programs will not
even compile into the Go loader until regenerated. Scoped for a build host:

- `bpf/sentinel_probe.c`: add `SENTINEL_EVT_PTRACE 5` (tracepoint
  `syscalls/sys_enter_ptrace`) and `SENTINEL_EVT_CAP 6` (kprobe/fentry on
  `cap_capable` — a kernel function, NOT a syscall tracepoint). Encode the ptrace
  request/target pid and the capability number into the connect-only fields
  (`dport`/`family`/`daddr`, unused for these types) so `sizeof(syscall_event_t)`
  stays 344 and `TestSyscallEventLayoutMatchesBTF` still holds.
- `pkg/ebpf/loader.go`: attach the two new programs. `pkg/ebpf/event.go`: decode
  types 5/6 → syscall names `sys_enter_ptrace` / `cap_capable`.
- `pkg/correlator`: map the two types to `TelemetryObservation.Syscall`; omit
  `classification` (they are neither file_access nor process_exec — matches the
  existing tcp_connect handling), so only `capability-or-ptrace` picks them up.
- `policy/bundles/kusari/endpoint-runtime.yaml`: add `sys_enter_ptrace` to
  `vars.sensitive_syscalls` (keep `cap_capable`, `ptrace`, `__x64_sys_ptrace` for
  the collector projection); remove the "collector-only" NOTE on the rule.
- Regenerate bpf2go objects under clang; run `TestSyscallEventLayoutMatchesBTF`
  and a live in-kernel verification (ptrace/cap attempt → finding) before closing.
