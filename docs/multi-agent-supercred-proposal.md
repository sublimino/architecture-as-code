# SuperCredential Multi-Agent Evolution: "The Cascade"

## The One Slide

**You have 47 AI agents. One goes rogue. In 900 milliseconds, every agent that trusted it is isolated, its credentials revoked, and the board-level risk exposure recalculates live. Your compliance officer watched it happen from her phone. Your team leads saw only their agents. Nobody touched a keyboard.**

That is what no competitor can demo. Not Wiz, not Palo Alto, not CrowdStrike. They can scan. They cannot govern a live agent fleet with cryptographic identity, cascading trust revocation, and quantified risk -- all wired to real SPIFFE/OpenBao infrastructure, not a simulation.

---

## Narrative Arc: "The Seven Minutes"

The instructor runs a 7-minute demo. Two screens: instructor console, audience fleet view.

### Minute 0-1: "The Estate" (DEPLOY)

Instructor clicks **Deploy Fleet**. Five agents materialise on the audience screen in a dependency graph:

| Agent | Type | Team | Trust Profile | Depends On |
|-------|------|------|---------------|------------|
| `agent-cardvault` | Data Vault | platform | High -- handles PCI secrets | -- (root) |
| `agent-txn-pipeline` | Data Pipeline | payments | Medium -- batch processor | `agent-cardvault` |
| `agent-llm-classifier` | LLM Inference | ml-ops | High -- processes customer PII | `agent-txn-pipeline` |
| `agent-api-gateway` | API Gateway | platform | Medium -- routes traffic | `agent-cardvault` |
| `agent-monitor` | Observability | sre | Low -- read-only | all four above |

Each agent gets a SPIFFE SVID, an OpenBao JWT auth mount, and scoped KV secrets. The audience sees them appear one by one on a **topology graph** -- nodes connected by trust edges, each node showing its credential state (`pending` -> `active`).

**What the CISO notices:** these are not containers. These are *AI workloads with identity*. The graph is not a network diagram -- it is a trust dependency map.

### Minute 1-2: "The Credential Chain" (CREDENTIAL)

All five agents complete the SPIFFE -> OpenBao -> secret-fetch chain. The topology graph turns green. The FAIR engine recalculates: fleet ALE drops to baseline (well-governed, tail-dominated). The risk gauge on the audience screen reads "Carried GBP: 12,400" -- a number, not a colour.

**Instructor says:** "Every agent just proved its identity cryptographically, exchanged that proof for scoped credentials, and fetched only the secrets it is authorised to see. No API keys in environment variables. No long-lived tokens. The platform knows exactly who has what."

### Minute 2-3: "The Weak Link" (COMPLIANCE SCAN)

Instructor clicks **Scan Fleet**. Policy engine evaluates all five pods. `agent-llm-classifier` and `agent-txn-pipeline` fail: no `securityContext`, no capability drops. They turn amber on the topology. `agent-cardvault`, `agent-api-gateway`, and `agent-monitor` pass.

The FAIR engine recalculates. Carried GBP jumps to 847,000. The risk gauge moves. The audience sees *which controls failed* and *what that costs in pounds* -- not a red/amber/green traffic light.

**Instructor says:** "Two agents are non-compliant. The platform just quantified the risk: 847 thousand pounds annual tail exposure. That number came from a Monte Carlo simulation calibrated to your industry. It is not an opinion."

### Minute 3-4: "The Grace Period" (SELECTIVE ENFORCEMENT)

Instructor shows the **compliance policy panel**. `agent-txn-pipeline` is in a 72-hour grace period (batch jobs get remediation time). `agent-llm-classifier` has no grace period -- it processes PII. The audience sees differentiated enforcement: same violation, different response, based on risk profile.

**Instructor says:** "Not all non-compliance is equal. The pipeline gets 72 hours to remediate because it runs in batch. The LLM classifier processes customer data right now. The platform knows the difference."

### Minute 4-5: "The Stun" (CASCADING REVOCATION)

Instructor clicks **Stun** on `agent-cardvault` -- the root of the dependency tree.

What happens in sequence, visible on the audience topology graph in real time:

1. `agent-cardvault` credentials revoked, labelled `stunned` (200ms)
2. `agent-txn-pipeline` detects upstream dependency stunned, auto-isolates (400ms)
3. `agent-llm-classifier` detects `agent-txn-pipeline` stunned, auto-isolates (600ms)
4. `agent-api-gateway` detects `agent-cardvault` stunned, auto-isolates (400ms)
5. `agent-monitor` remains active -- read-only, no write dependency (800ms)

The topology graph cascades from green through amber to red, node by node, in under a second. The risk gauge recalculates after each node: 12K -> 340K -> 580K -> 847K. The monitor stays green, still observing.

**Instructor says:** "I stunned one agent. Four were isolated in under a second. The monitor is still running because it has no write dependency on the stunned agent -- it can still observe. The cascade followed the trust graph, not an operator's guess."

### Minute 5-6: "The Multi-Tenant View" (RBAC)

Instructor switches to the **team lead view** (payments team). They see only `agent-txn-pipeline` and `agent-llm-classifier`. Both stunned. They cannot un-stun -- that requires platform team authority. They can see *why* (dependency cascade from `agent-cardvault`) but they cannot override.

Switch to **compliance officer view**. Full fleet. Full risk numbers. Can see every team's agents. Can set grace periods. Cannot stun -- that requires superadmin.

**Instructor says:** "Three roles, three views, one truth. The team lead sees their agents. The compliance officer sees the risk. The platform admin controls the kill switch. Nobody sees more than they need. Nobody can do more than they should."

### Minute 6-7: "The Recovery" (RESET)

Instructor clicks **Recover Fleet**. Agents un-stun in reverse dependency order: `agent-cardvault` first (new credentials), then its dependants verify the upstream is alive before re-credentialing. The FAIR gauge drops back to 12K. Clean state.

**Instructor says:** "Recovery follows the same graph. You do not recover a fleet by restarting everything and hoping. You recover the root, verify it, then let the dependants re-establish trust. The platform enforces the order."

---

## Architecture

### New Components

**1. Agent Fleet Manager** (`apps/fleet-manager/`)
- Go service, same pattern as `policy-engine`
- Owns the agent dependency graph (DAG stored as adjacency list in a ConfigMap, queryable via API)
- Exposes: `POST /api/v1/fleet/deploy`, `POST /api/v1/fleet/stun/{agentId}`, `GET /api/v1/fleet/topology`, `POST /api/v1/fleet/recover`
- On stun: walks the dependency DAG, issues cascading stun commands to `supercred-demo-runner` for each dependent agent
- On recover: topological sort, recover in dependency order
- Deployed via the existing Kustomize/Flux pattern

**2. Agent Definitions** (`d2-signalloom/agents/`)
- YAML manifests per agent, similar to the existing `cardvault-agent/` pattern but richer:
```yaml
apiVersion: signalloom.controlplane.io/v1alpha1
kind: AgentProfile
metadata:
  name: agent-llm-classifier
spec:
  type: llm-inference
  team: ml-ops
  trustProfile: high
  riskClass: high  # EU AI Act
  gracePeriod: 0h  # PII processor, no grace
  dependencies:
    - agent-txn-pipeline
  securityContext:
    # Intentionally missing for demo -- compliance scan catches this
    present: false
  spiffe:
    trustDomain: signalloom.local
    path: /ns/ml-ops/sa/agent-llm-classifier
  openbao:
    authMount: jwt/ml-ops
    kvPath: secret/data/ml-ops/classifier
    policies: [ml-ops-read]
```

**3. Topology Visualisation** (`dashboard-signalloom/src/components/trust/FleetTopology.tsx`)
- D3.js force-directed graph or dagre layout
- Nodes = agents, coloured by state (green/amber/red)
- Edges = trust dependencies, animated during cascade
- Polls fleet-manager `/api/v1/fleet/topology` at 1s intervals
- Audience-mode variant: full-screen, no controls, auto-layout

**4. Risk Gauge** (`dashboard-signalloom/src/components/risk/FleetRiskGauge.tsx`)
- Calls policy-engine `/api/v1/compliance/summary` after each state change
- Displays: ALE, VaR95, Carried GBP as animated numbers
- Trend sparkline showing risk over the demo timeline
- Colour boundary: green < 50K, amber < 500K, red >= 500K

### Modified Components

**`supercred-demo-runner`** -- extended, not replaced:
- New script `scripts/supercred-fleet-demo.sh` alongside existing `supercred-demo.sh`
- Accepts fleet operations: `deploy-fleet`, `stun-cascade <agentId>`, `scan-fleet`, `recover-fleet`
- Each agent deployment reuses the existing SPIFFE/OpenBao/label pattern from the single-agent flow
- The existing single-agent demo continues to work unchanged

**`policy-engine`** -- new endpoint:
- `POST /api/v1/compliance/scan-fleet` -- scans all agents in the fleet, returns per-agent results with FAIR risk per agent and aggregate fleet risk
- Reuses existing `evaluateCheck` and FAIR `Simulate` -- no new risk engine code

**`fe-signalloom`** (API layer) -- new routes:
- `POST /api/demo/fleet/*` proxied to fleet-manager, same pattern as existing supercred proxy
- Superadmin gate on all mutating fleet operations

**`dashboard-signalloom`** -- new page:
- `FleetDemoPage.tsx` -- the multi-agent equivalent of `SuperCredPage.tsx`
- Instructor panel with fleet-level controls
- Embeds `FleetTopology` and `FleetRiskGauge`
- Audience route: `/fleet/audience` -- topology + risk gauge, no controls, auto-refreshing

### Unchanged Components

- OpenBao infrastructure (additional auth mounts per agent, same pattern)
- SPIRE server (additional registration entries, same pattern)
- Dex OIDC (existing viewer/superadmin identities, plus team-scoped roles)
- Flux delivery (ResourceSets parameterised per agent, same postBuild substitution)
- LoadingState component (reused as-is)
- Playwright two-window spec pattern (extended for fleet page)

### Data Model

```
AgentProfile {
  id: string (SPIFFE path suffix)
  name: string
  type: enum(data-vault, data-pipeline, llm-inference, api-gateway, observability)
  team: string
  trustProfile: enum(high, medium, low)
  riskClass: enum(high, medium, low)  // maps to EU AI Act
  gracePeriod: duration
  dependencies: AgentProfile[]  // DAG edges
  state: enum(absent, deploying, active, non-compliant, grace-period, stunned)
  credential: CredentialRecord
  complianceResults: ComplianceResult[]
  fairRisk: { ale, var95, tvar, carriedGbp }
}

FleetTopology {
  agents: AgentProfile[]
  edges: { from: string, to: string, type: enum(data, identity, api) }[]
  aggregateRisk: { ale, var95, tvar, carriedGbp }
  cascadeHistory: CascadeEvent[]
}

CascadeEvent {
  triggerId: string      // agent that was directly stunned
  affectedIds: string[]  // agents that cascaded
  timestamp: string
  durationMs: number
  riskBefore: number
  riskAfter: number
}
```

---

## Phased Delivery

### Phase 1: Fleet Topology + Multi-Agent Deploy (2-3 weeks)

- Agent profile YAML definitions for 5 agents
- Fleet-manager service (deploy, topology endpoints)
- Extended `supercred-fleet-demo.sh` for multi-agent deploy
- `FleetTopology.tsx` with static layout (dagre, not force-directed)
- Dashboard `FleetDemoPage.tsx` with deploy button
- Kustomize overlays per agent, Flux ResourceSet parameterisation
- BATS tests: `supercred-fleet-deploy.bats`, `fleet-topology-api.bats`

**Exit criterion:** instructor clicks Deploy Fleet, 5 agents appear on topology graph with credentials, audience sees the graph populate in real time.

### Phase 2: Fleet Compliance + FAIR Integration (1-2 weeks)

- Fleet-wide compliance scan endpoint on policy-engine
- `FleetRiskGauge.tsx` wired to live FAIR numbers
- Per-agent risk breakdown in topology node tooltips
- Grace period enforcement logic in fleet-manager
- Unit tests for fleet FAIR aggregation

**Exit criterion:** scan shows 2 non-compliant agents, risk gauge jumps to 847K, grace period badge visible on `agent-txn-pipeline`.

### Phase 3: Cascading Stun (1-2 weeks)

- Dependency-aware stun in fleet-manager (DAG walk)
- Cascade animation on topology graph (sequential node transitions)
- Risk gauge recalculation per cascade step
- Audience-mode full-screen layout
- Playwright two-window spec for cascade visibility

**Exit criterion:** stun `agent-cardvault`, watch 3 dependants cascade in <1s, monitor stays green, risk gauge climbs step by step. Audience window shows it without reload.

### Phase 4: RBAC + Multi-Tenant Views (1-2 weeks)

- Team-scoped agent filtering on fleet-manager API
- Dex group claims mapped to team ownership
- Compliance officer role (full read, no stun)
- Team lead role (own agents read, no stun)
- Dashboard role-aware filtering on fleet page

**Exit criterion:** three browser windows showing three different views of the same fleet event.

### Phase 5: Automated Response Policies (2-3 weeks, can defer)

- Policy rules: "if fleet compliance < 80%, auto-stun non-compliant agents"
- Configurable thresholds per team
- Dry-run mode (shows what *would* happen)
- Audit trail of automated actions

**Exit criterion:** compliance drops below threshold, agents auto-stun without instructor intervention, audit log shows the policy that triggered it.

---

## Competitive Moat

What this proves that nobody else can show:

1. **Cryptographic agent identity** -- not API keys, not service accounts, SPIFFE SVIDs exchanged for scoped credentials. The identity is the platform, not a bolt-on.

2. **Quantified risk in pounds** -- not traffic lights. FAIR Monte Carlo on live agent state. The board gets a number, not a feeling.

3. **Cascading trust revocation** -- one stun propagates through the dependency graph. This is supply chain security applied to the agent fleet, not just containers.

4. **Differentiated enforcement** -- same violation, different response based on risk profile and data classification. Grace periods for batch, immediate revocation for PII. This is what regulation actually requires.

5. **Multi-tenant governance** -- three roles, three views, one truth. The organisational structure is visible in the access model.

6. **Live, not simulated** -- real Kubernetes pods, real SPIRE entries, real OpenBao leases. The stun revokes actual credentials. The compliance scan reads actual pod specs. Nothing is mocked for the demo.

---

## Risk Assessment

| Risk | Mitigation |
|------|-----------|
| 5 agents take too long to deploy for a live demo | Pre-deploy 4, deploy the 5th live. Or: pre-bake SPIRE entries, deploy only pods. |
| Cascade timing is not visually dramatic enough | Add 200ms artificial delay between cascade steps for visual effect. The sub-second real timing is the engineering achievement; the audience needs to *see* each step. |
| FAIR numbers look arbitrary to a non-technical audience | Show the triples (min/mode/max) that produced them. "This is calibrated to industry data for a Tier 1 bank handling PCI data." |
| Fleet-manager adds a new service to operate | It is stateless (DAG from ConfigMap, state from pod labels). Same operational pattern as policy-engine. |
| RBAC complexity for the demo | Start with superadmin-only in Phase 1-3. RBAC is Phase 4 and can be deferred if the cascade demo is compelling enough on its own. |
