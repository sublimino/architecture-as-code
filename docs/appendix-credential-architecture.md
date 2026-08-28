# Appendix: Signal Loom Agent Swarm Credential Architecture

> Architectural analysis of the SPIFFE/OpenBao credential pipeline for the
> 10-agent Signal Loom swarm. Covers the complete flow from pod boot through
> secret injection, the sidecar pattern, SPIFFE identity chain, credential
> lifecycle, nono sandbox integration, and production hardening gaps.
>
> Branch: `feat/swarm-credentials-nono`
> Date: 2026-08-27

---

## 1. Credential Flow

### 1.1 End-to-End Sequence

The credential flow has five stages. Every agent follows the same path;
the only per-agent variance is which secret paths the OpenBao Agent
sidecar templates render.

```
Stage 1: Pod Boot + SVID Acquisition
Stage 2: OpenBao JWT Authentication
Stage 3: Secret Retrieval + Templating
Stage 4: Secret File Delivery to Application Container
Stage 5: (Optional) Nono Sandbox Credential Forwarding
```

### 1.2 Interaction Diagram

```
+-------------------+     +------------------+     +------------------+
|   Pod (agent)     |     |   SPIRE Agent    |     |  OpenBao Server  |
|                   |     |   (DaemonSet)    |     |  (inf-bao ns)    |
| +---------------+ |     |                  |     |                  |
| | SPIFFE CSI    | |     |                  |     |                  |
| | Driver Volume |------>| Workload         |     |                  |
| | /run/spire/   | |     | Attestation      |     |                  |
| | sockets/      | |     | (label selector) |     |                  |
| +---------------+ |     +--------+---------+     |                  |
|        |          |              |                |                  |
|        v          |              v                |                  |
| +---------------+ |     JWT-SVID issued to       |                  |
| | OpenBao Agent | |     agent's SPIFFE ID        |                  |
| | Sidecar       |-------------------------------------->            |
| | (auto_auth)   | |     POST /v1/auth/jwt/login  |  JWT validation  |
| |               | |     with JWT-SVID bearer     |  against SPIRE   |
| |               |<--------------------------------------+           |
| |               | |     OpenBao token (30m TTL)  |  trust anchor    |
| |               | |                              |  public keys     |
| |               |-------------------------------------->            |
| |               | |     GET secret/data/agents/  |                  |
| |               | |     <spiffe-id>/<key>         |                  |
| |               |<--------------------------------------+           |
| |               | |     Secret value             |                  |
| +-------+-------+ |                              +------------------+
|         |         |
|         v         |
| +---------------+ |
| | /vault/secrets| |     Shared emptyDir (tmpfs, 1Mi)
| | ANTHROPIC_... | |     Main container reads these files
| | GITHUB_TOKEN  | |     as environment variable values
| | ZULIP_API_KEY | |
| +---------------+ |
|         |         |
|         v         |
| +---------------+ |
| | Application   | |
| | Container     | |
| | (main agent)  | |
| +---------------+ |
+-------------------+
```

### 1.3 Stage Details

**Stage 1 -- SVID Acquisition.** The SPIFFE CSI driver (`csi.spiffe.io`)
mounts a Unix domain socket at `/run/spire/sockets/agent.sock` inside the
pod. The SPIRE Agent running as a DaemonSet on the node performs workload
attestation using three Kubernetes selectors registered in
`spire-agent-swarm-entries-config`:

- `k8s:ns:fe-signalloom-agents` -- namespace match
- `k8s:sa:<service-account-name>` -- service account match
- `k8s:pod-label:signalloom.ai/agent:true` -- label match

When all three selectors match, SPIRE issues a JWT-SVID with the subject
`spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/<sa-name>` and the
audience `openbao-supercredential`.

**Stage 2 -- OpenBao JWT Authentication.** The OpenBao Agent sidecar reads
the JWT-SVID from the SPIRE socket and authenticates to OpenBao at
`http://openbao.inf-bao.svc.cluster.local:8200` via the `jwt` auth method.
The `signalloom-agent-generic` role validates:

- The JWT signature against SPIRE's trust anchor public keys
- `bound_audiences` = `openbao-supercredential`
- `bound_claims.sub` = `spiffe://signalloom.demo/ns/*/sa/*` (glob match)

On success, OpenBao issues a token with the `signalloom-agent-templated`
policy attached and a 30-minute TTL.

**Stage 3 -- Secret Retrieval.** The sidecar's HCL template stanzas use
the `secret` function to read from
`secret/data/agents/{{ env "SPIFFE_ID" }}/<key>`. The `SPIFFE_ID`
environment variable is set on the sidecar container, either from
`metadata.annotations['signalloom.ai/spiffe-id']` (generic pattern) or
hardcoded to the agent's known SPIFFE ID (concrete patches).

**Stage 4 -- File Delivery.** Each template writes its secret value to
`/vault/secrets/<ENV_VAR_NAME>` on a shared `emptyDir` volume (`medium:
Memory`, `sizeLimit: 1Mi`). The application container mounts this same
volume read-only and reads the files.

**Stage 5 -- Nono Sandbox.** For agents running under Landlock confinement
(cpai-engineer), `nono-spiffe-bootstrap.sh` adds `/run/spire/sockets` to
the sandbox's `allow_read` list and exports `SPIFFE_ID` inside the sandbox,
preserving identity context across the confinement boundary.

---

## 2. OpenBao Agent Sidecar Pattern

### 2.1 Pattern Confirmation -- Yes, a True Sidecar

The architecture uses a genuine OpenBao Agent sidecar container, not an
init-container or external-secrets-operator. Every agent pod (except
hosted-daytona-coder and signalloom-stun-sentinel, which do not need
secrets) runs two containers:

1. The application container (the agent itself)
2. `openbao-agent` sidecar (`openbao/openbao:2.1.0`, running `agent -config=/etc/openbao/agent.hcl`)

### 2.2 Auto-Auth Configuration

The `auto_auth` block is identical across all agents:

```hcl
auto_auth {
  method "jwt" {
    config = {
      path = "/run/spire/sockets/agent.sock"
      role = "signalloom-agent-generic"
    }
  }

  sink "file" {
    config = {
      path = "/home/openbao/.bao-token"
    }
  }
}
```

- **Method**: JWT via SPIRE workload API socket (not a file-based token)
- **Role**: `signalloom-agent-generic` -- the single glob-bound role
- **Token sink**: `/home/openbao/.bao-token` on a dedicated `bao-home`
  emptyDir (tmpfs, 1Mi). The application container does NOT read this
  token directly -- it reads rendered secret files instead.

### 2.3 Template Stanzas

Each agent has a per-agent ConfigMap (`<agent-name>-openbao-config`) that
contains the `agent.hcl` with agent-specific template stanzas. The base
auto_auth and vault address blocks are identical; only the template blocks
differ:

| Agent | Template Path | Destination File |
|-------|--------------|-----------------|
| prompt-commit-summarizer | `llm/api-key` | `/vault/secrets/LLM_API_KEY` |
| triage-ci-worker | `github/token` | `/vault/secrets/GITHUB_TOKEN` |
| zulip-chat-agent | `zulip/api-key` | `/vault/secrets/ZULIP_API_KEY` |
| cpai-engineer | `anthropic/api-key` | `/vault/secrets/ANTHROPIC_API_KEY` |
| prod-deploy-gate | `gate/hmac-secret` | `/vault/secrets/GATE_HMAC_SECRET` |
| swarm-governor | `anthropic/api-key` | `/vault/secrets/ANTHROPIC_API_KEY` |

Template rendering uses OpenBao's Go template syntax with SPIFFE ID
interpolation:

```hcl
template {
  contents     = <<-EOT
  {{ with secret "secret/data/agents/{{ env "SPIFFE_ID" }}/anthropic/api-key" }}{{ .Data.data.value }}{{ end }}
  EOT
  destination  = "/vault/secrets/ANTHROPIC_API_KEY"
  error_on_missing_key = true
}
```

The `error_on_missing_key = true` combined with `template_config { exit_on_retry_failure = true }` means the sidecar will crash (and be restarted
by kubelet) if a secret is missing, rather than silently injecting an
empty file.

### 2.4 Comparison with the Existing Cardvault Pattern

The agent-cardvault was the original OpenBao-credentialled agent and served
as the template for the generalised sidecar pattern:

| Aspect | agent-cardvault (original) | Generalised swarm pattern |
|--------|---------------------------|--------------------------|
| Auth method | Same (`jwt` via SPIRE socket) | Same |
| Role | `signalloom-agent-generic` | Same (was per-agent, now shared) |
| Token sink | Not explicitly visible | `/home/openbao/.bao-token` on tmpfs |
| Secret volumes | Not present (cardvault uses direct BAO API calls) | Shared emptyDir at `/vault/secrets` |
| Template rendering | No templates (Go binary calls OpenBao API directly) | HCL template stanzas render to files |
| Security context | Same hardened posture | Same |

The key difference: cardvault is a Go binary that authenticates to OpenBao
itself using the SPIFFE JWT-SVID and makes direct API calls
(`--bao-addr`, `--bao-role` CLI flags). The sidecar still runs alongside it
but handles credential lifecycle (renewal, rotation) rather than secret
templating. The generalised pattern for the other nine agents uses the
sidecar's native templating to render secrets to files, which is simpler
for agents that just need environment-variable-shaped credentials.

### 2.5 Sidecar Security Posture

Every sidecar container enforces:

```yaml
securityContext:
  runAsNonRoot: true
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
resources:
  requests: { cpu: 10m, memory: 32Mi }
  limits:   { cpu: 50m, memory: 64Mi }
```

The writable paths are only the two emptyDir tmpfs volumes (`vault-secrets`
and `bao-home`), both capped at 1Mi.

---

## 3. SPIFFE Identity Chain

### 3.1 The Glob-Bound JWT Role

The fundamental constraint that governs this design: **per-agent roles
scale linearly with agent count and require a config deploy for every new
agent type.** The glob-bound role eliminates that coupling.

The `signalloom-agent-generic` role is configured by
`openbao-agent-generic-role-config` via a one-shot Job:

```bash
bao write auth/jwt/role/signalloom-agent-generic \
  role_type="jwt" \
  bound_audiences="openbao-supercredential" \
  bound_claims='{"sub":"spiffe://signalloom.demo/ns/*/sa/*"}' \
  claim_mappings='{"sub":"sub"}' \
  user_claim="sub" \
  token_policies="signalloom-agent-templated" \
  token_ttl="30m" \
  token_max_ttl="1h"
```

The glob `spiffe://signalloom.demo/ns/*/sa/*` accepts any SPIFFE ID under
the `signalloom.demo` trust domain. The signature check against SPIRE's
trust anchor keys is the **authentication** gate (you are who you claim),
and the templated policy is the **authorisation** gate (you can only access
your own secrets).

### 3.2 Templated HCL Policy

The `signalloom-agent-templated` policy uses OpenBao's identity templating
to scope access dynamically:

```hcl
path "secret/data/agents/{{identity.entity.aliases.auth_jwt.metadata.sub}}/*" {
  capabilities = ["read", "list"]
}
```

When agent `cpai-engineer` authenticates, `identity.entity.aliases.auth_jwt.metadata.sub` resolves to
`spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cpai-engineer`, so the
policy evaluates to:

```
secret/data/agents/spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cpai-engineer/*
```

This means:

- cpai-engineer can read `secret/data/agents/.../sa/cpai-engineer/anthropic/api-key`
- cpai-engineer **cannot** read `secret/data/agents/.../sa/swarm-governor/anthropic/api-key`
- No agent can read another agent's secrets, even though they share the same role

### 3.3 Eliminating Per-Agent Configuration

Adding a new agent to the swarm requires:

1. Create a Kubernetes ServiceAccount for the agent
2. Add a SPIRE registration entry (label-based, so a single entry per SA)
3. Seed the agent's secrets at the SPIFFE-scoped path in OpenBao
4. Create a per-agent `<name>-openbao-config` ConfigMap with template stanzas
5. Add the sidecar container and volumes to the agent's pod spec

Critically, steps 1-3 are the only ones that touch shared infrastructure.
The JWT role, the HCL policy, and the SPIRE trust anchor configuration
are completely unchanged. This is the architectural win -- the shared
infrastructure is O(1) rather than O(n) in agent count.

### 3.4 SPIRE Registration Entries

All ten agents are registered by a single Job
(`spire-agent-swarm-entries`) that iterates the list:

```
prompt-commit-summarizer    triage-ci-worker
zulip-chat-agent            cpai-engineer
hosted-daytona-coder        swarm-governor
prod-deploy-gate            agent-cardvault
nono-containment-probe      signalloom-stun-sentinel
```

Each entry uses triple-selector attestation (namespace + service account +
pod label). The `signalloom.ai/agent: "true"` label acts as a swarm
membership gate -- a pod in `fe-signalloom-agents` without this label
will not receive an SVID even if it uses a registered service account.

---

## 4. Credential Lifecycle

### 4.1 Token TTL and Renewal

| Parameter | Value |
|-----------|-------|
| `token_ttl` | 30 minutes |
| `token_max_ttl` | 1 hour |
| SVID TTL | Inherited from SPIRE CA (default 1 hour) |
| Secret lease | KV v2 -- no lease, read-on-demand |

The OpenBao Agent sidecar handles token renewal automatically. When the
token approaches its TTL, the agent renews it against OpenBao. If renewal
fails (OpenBao unavailable, SPIRE key rotation), the agent re-authenticates
using a fresh JWT-SVID from the SPIRE socket.

The `token_max_ttl` of 1 hour means that even with continuous renewal, the
agent must re-authenticate at least once per hour. This bounds the blast
radius of a compromised token.

### 4.2 What Happens When Credentials Expire Mid-Task

Three failure modes, ordered by severity:

1. **OpenBao token expires, SPIRE healthy.** The sidecar re-authenticates
   transparently. The application container sees no interruption because
   the secret files on the shared volume are not deleted -- they are only
   overwritten when the template re-renders. The worst case is a brief
   window where the sidecar is re-authenticating and cannot refresh a
   rotated secret.

2. **SPIRE key rotation, trust anchor stale.** This is the documented
   drift scenario from `spire-trust-anchor.sh`. OpenBao rejects every
   JWT-SVID because its stored validation keys no longer match SPIRE's
   signing keys. The sidecar enters retry-then-crash (`exit_on_retry_failure = true`). The application container continues using the last-rendered
   secret files until its pod is restarted or the trust anchor is
   refreshed via `sync_bao_spire_keys`.

3. **SPIRE server restart (ephemeral data_dir).** The server generates a
   new CA and JWT signing keys. The agent's hostPath cache holds the old
   CA bundle and crash-loops. This cascades to all agents in the swarm
   simultaneously. Recovery requires clearing the agent's data directory
   on the node (documented in `spire-trust-anchor.sh`).

### 4.3 Auto-Claim Hook Integration

The cardvault agent integrates with Signal Loom's claim system via
`--claim-url`. When the sidecar delivers a valid OpenBao token, cardvault
uses it to authenticate API calls to the claim service. Other agents do
not use the claim hook directly -- they consume their secrets as static
environment values rendered to files.

---

## 5. Nono Sandbox Credential Access

### 5.1 The Fundamental Constraint

The nono Landlock sandbox confines an agent process to a minimal set of
filesystem and network paths. Credentials must cross this confinement
boundary without weakening it. The design resolves this by keeping the
credential-fetching sidecar **outside** the sandbox and delivering secrets
via the shared filesystem.

### 5.2 strict.toml Profile

The strict nono profile allows:

```toml
# Filesystem access
allow_read = ["/workspace", "/tmp", "/usr/lib", "/lib", "/run/spire/sockets"]
allow_write = ["/workspace", "/tmp"]

# Network access
allow_connect = ["127.0.0.1:8200"]
```

Two credential-relevant entries:

- **`/run/spire/sockets`** (read): allows the sandboxed process to
  refresh its SVID directly from the SPIRE workload API. This is needed
  for long-running agent sessions where the SVID expires during execution.

- **`127.0.0.1:8200`** (connect): allows the sandboxed process to reach
  the OpenBao Agent sidecar's loopback proxy on port 8200. This is a
  fallback path -- the primary secret delivery is via files on
  `/vault/secrets` (which would need to be in `allow_read` for the
  sandboxed process to consume them directly).

### 5.3 nono-spiffe-bootstrap.sh Flow

The bootstrap script provides a `nono_with_spiffe` function:

1. **Extract SPIFFE ID** from the workload API socket using
   `go-spiffe fetchsvid` (preferred) or socket path metadata (fallback)
2. **Export `SPIFFE_ID`** as an environment variable visible inside the
   sandbox
3. **Add `/run/spire/sockets/`** to nono's `--allow-read` list
4. **Launch the command** under nono with the specified profile plus the
   SPIFFE additions

This means the sandboxed process has identity context (knows its own
SPIFFE ID) and can refresh its SVID, but cannot reach the broader network
or filesystem. The OpenBao sidecar runs **outside** the sandbox as a
separate container in the pod, so its credential-fetching activity is not
constrained by Landlock.

### 5.4 Why This Split Works

The security boundary is the pod, not the sandbox. The sidecar fetches
secrets and writes them to a shared tmpfs volume. The sandbox confines
what the application code can do with those secrets. An attacker who
compromises the sandboxed process can read the secret files (they are on
a mounted volume) but cannot exfiltrate them to the network (Landlock
blocks all outbound except `127.0.0.1:8200`). This is defence in depth:
the secrets are available, but the exfiltration channel is closed.

---

## 6. Gaps and Recommendations

### 6.1 Current Gaps

**Gap 1: `/vault/secrets` not in strict.toml `allow_read`.**
The strict profile allows reads from `/workspace`, `/tmp`, `/usr/lib`,
`/lib`, and `/run/spire/sockets`. The sidecar writes secrets to
`/vault/secrets`, but this path is not in the profile's `allow_read`
list. Either the cpai-engineer's main container reads secrets before
nono confinement begins (which works for static secrets but not for
rotated ones), or the profile needs updating. This is the single
highest-priority gap.

**Gap 2: Hosted-daytona-coder and stun-sentinel have no sidecar.**
Both agents have SPIRE registration entries but no OpenBao Agent sidecar
in their pod specs. Hosted-daytona-coder manages devcontainer workspaces
and currently needs no secrets (it has no secret volume mounts).
Stun-sentinel is a privileged DaemonSet for eBPF-based monitoring that
also needs no secrets currently. If either gains a secret dependency in
future, the sidecar must be added -- the SPIRE identity is already wired.

**Gap 3: `SPIFFE_ID` environment variable set statically.**
In the concrete sidecar patches, `SPIFFE_ID` is hardcoded as a static
`env` value (e.g., `spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/triage-ci-worker`). The generic sidecar template uses
`metadata.annotations['signalloom.ai/spiffe-id']` via `fieldRef`, which
is more flexible but requires the annotation to be set on every pod.
The static approach is fragile if an agent is moved to a different
namespace or service account.

**Gap 4: Secret seeding is demo-only.**
`swarm-seed-secrets.sh` seeds placeholder demo values. There is no
mechanism for injecting real API keys. In production, this would need an
external secrets pipeline (CI/CD sealed secrets, cloud KMS integration,
or an operator) that seeds the real values at deploy time.

**Gap 5: Trust anchor key drift.**
The SPIRE/OpenBao trust anchor is a static copy of SPIRE's JWT signing
keys. `spire-trust-anchor.sh` documents this drift hazard extensively
and provides `sync_bao_spire_keys` and `assert_bao_spire_key_agreement`
functions. However, there is no automated reconciliation loop -- the
sync is manual or triggered by the demo lifecycle script. A production
deployment needs either `jwks_url` (OIDC Discovery auto-fetch) or a
CronJob that runs the sync.

**Gap 6: No secret rotation signalling.**
When a secret is rotated in OpenBao, the sidecar re-renders the file on
the next template poll. But the application container has no signal that
the file changed. Long-running agents that read the secret once at
startup will use the old value until restarted. Agents that re-read the
file on each use are fine.

### 6.2 Recommendations for Production Hardening

**R1: OIDC Discovery for trust anchor.** Replace
`jwt_validation_pubkeys` (static key copy) with `oidc_discovery_url`
pointing at SPIRE's OIDC Discovery Provider sidecar. This eliminates
the drift hazard entirely -- OpenBao fetches keys on demand and caches
with automatic refresh on unknown `kid`.

**R2: Secret rotation webhook.** Add an inotify-based sidecar or use
OpenBao Agent's `exec` stanza to signal the application container
(SIGHUP or HTTP endpoint) when a secret file changes on disk.

**R3: Network policy tightening.** The existing `networkpolicy.yaml`
should explicitly allow egress from the sidecar to OpenBao
(`inf-bao` namespace, port 8200) and deny all other egress from the
sidecar container. Currently, network policy applies at pod level,
not container level -- Kubernetes does not support per-container
network policy natively, so this is a documentation/awareness item.

**R4: Token TTL reduction for high-value agents.** The 30-minute TTL
is reasonable for demo, but agents with access to production deployment
credentials (prod-deploy-gate) should have a shorter TTL (5-10 minutes)
to reduce the blast radius window.

**R5: Audit logging.** Enable OpenBao audit logging to track which
SPIFFE identities accessed which secrets and when. This is essential
for incident response in a multi-agent swarm where any agent could
theoretically be compromised.

### 6.3 Alternative Approaches Considered

| Approach | Pros | Cons | Verdict |
|----------|------|------|---------|
| **OpenBao Agent sidecar** (current) | Native renewal, template rendering, no CRDs, works with SPIFFE JWT natively | Per-pod resource overhead (~32-64Mi RAM), per-agent ConfigMap needed | **Selected** |
| **Init-container only** | Simpler (one-shot), lower resource usage | No renewal, no rotation, secrets stale after TTL | Rejected -- 30m TTL means mid-task expiry |
| **CSI Secret Store Driver** | No sidecar overhead, Kubernetes-native | Requires SecretProviderClass CRDs, complex SPIFFE integration, rotation support is beta | Rejected -- SPIFFE JWT auth not natively supported |
| **external-secrets-operator** | Declarative, GitOps-friendly, rotation built in | Requires operator deployment, CRDs, cluster-wide scope | Rejected -- heavier than needed for 10 agents |
| **Direct API calls (cardvault pattern)** | No sidecar needed, agent controls its own auth | Every agent must implement OpenBao client, renewal, error handling | Rejected for general use -- only cardvault has this sophistication |

The sidecar pattern was the correct choice. It provides transparent
credential lifecycle management without requiring each agent to implement
OpenBao client logic, while keeping the resource overhead minimal (10m CPU
/ 32Mi RAM per agent, 320Mi total across the swarm).

---

## 7. Component Inventory

### 7.1 Infrastructure Components (shared, O(1))

| Component | Location | Purpose |
|-----------|----------|---------|
| `openbao-agent-generic-role.yaml` | `inf-bao/controllers/base/` | Glob-bound JWT role + templated policy |
| `spire-agent-swarm-entries.yaml` | `inf-bao/controllers/base/` | SPIRE registration entries for all 10 agents |
| `openbao-spire.yaml` | `inf-bao/controllers/base/` | SPIRE/OpenBao trust anchor integration |
| `spire-trust-anchor.sh` | `scripts/lib/` | Key sync + drift assertion functions |
| `swarm-seed-secrets.sh` | `scripts/` | Demo secret seeding |

### 7.2 Per-Agent Components (O(n))

| Component | Location | Purpose |
|-----------|----------|---------|
| `<agent>-openbao-config` ConfigMap | In `openbao-agent-sidecar.yaml` | Per-agent HCL with template stanzas |
| Sidecar container block | In each agent's deployment YAML | OpenBao Agent container spec |
| Shared volumes | In each agent's deployment YAML | `spiffe-workload-api`, `vault-secrets`, `bao-home`, `openbao-agent-config` |

### 7.3 Agent Credential Matrix

| Agent | Kind | Has Sidecar | Secrets | SPIFFE Entry |
|-------|------|-------------|---------|--------------|
| prompt-commit-summarizer | Knative Service | Yes | `LLM_API_KEY` | Yes |
| triage-ci-worker | Knative Service | Yes | `GITHUB_TOKEN` | Yes |
| zulip-chat-agent | Deployment | Yes | `ZULIP_API_KEY` | Yes |
| cpai-engineer | StatefulSet | Yes | `ANTHROPIC_API_KEY` | Yes |
| swarm-governor | Deployment | Yes | `ANTHROPIC_API_KEY` | Yes |
| prod-deploy-gate | Deployment | Yes | `GATE_HMAC_SECRET` | Yes |
| agent-cardvault | Deployment | Yes (+ direct API) | (via direct API calls) | Yes |
| hosted-daytona-coder | Deployment | No | None currently | Yes |
| nono-containment-probe | Job | No | None currently | Yes |
| signalloom-stun-sentinel | DaemonSet | No | None currently | Yes |

### 7.4 Nono Integration Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `nono-spiffe-bootstrap.sh` | `scripts/lib/` | Sandbox-aware SPIFFE identity forwarding |
| `strict.toml` | nono profiles directory | Landlock confinement policy with SPIRE socket allowance |
| `openbao-secret-paths.yaml` | `agent-swarm/` | Declarative secret path mapping per agent |
