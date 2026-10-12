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

### kubernetes — kube-apiserver audit (NEW, the reference vertical) ❌
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

### endpoint_host — agentnono (Landlock) ✅ · tetragon/ebpf 🟡
nono landlock denial covered by `kusari/landlock-denial.yaml`. Tetragon
(`ebpf` collector, syscall stream) gap: sensitive-file open, unexpected
`execve`, capability use, ptrace — needs a `tetragon` bundle. Note the
stun-sentinel also does in-kernel reactive freeze independently of CEL.

### network_egress — netebpf / awslogs VPC flow 🟡
Direct-IP egress, non-cluster resolver, DNS tunnel (high-entropy qname),
egress to a new ASN/destination. VPC REJECT burst is covered; the live netebpf
direct-IP/SNI anomalies need a `network_egress` bundle.

### identity_authorization — spirea / SaaS login ❌
SPIRE: SVID issued to an unexpected SPIFFE path; attestation downgrade.
SaaS login: impossible-travel, new-geo, MFA-absent login, admin role grant.

### application_saas — workspacesaas ❌
Mass file download, external share of a sensitive doc, OAuth app grant,
admin-console setting change.

### gcpaudit — GCP admin activity ❌
IAM policy binding change, service-account key creation, bucket IAM made
public, logging sink deletion (GCP analogues of the AWS rules).

### baoaudit — OpenBao audit ❌
Root-token use, secret-read burst, policy/mount change, seal/unseal, token
creation with broad policy.

## Cross-stream correlations (correlation.Engine, tier 3)

Keyed on the resolved actor (identity graph), not a single label:
- **Exfil chain:** cloud credential change → endpoint sensitive-file read →
  network egress, same actor, short window.
- **Account takeover:** SaaS login anomaly → serviceaccount/token mint (k8s) →
  cloud API access, same resolved identity.
- **Containment evasion:** landlock/tetragon denial → process-spawn burst →
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

`test/policy-coverage-matrix.bats` (to be added) asserts: every registered
collector layer has ≥1 stage-1 rule in some loaded bundle, and every rule has a
positive and a negative fixture (the kusari-e2e expectations-table discipline,
estate-wide). A new collector with no rule, or a rule with no negative, fails CI
— so "full coverage" is enforced, not claimed.
