---
name: cp-sl-containment-guard
description: "Scheduled-run agent stun, containment, and GitOps suspension integrity guard for the #partner-signal-loom platform. Enforces the GitOps suspension invariant (kustomize.toolkit.fluxcd.io/reconcile: disabled) on stunned workloads, verifies H1 forensic preservation with liveness probe suppression, audits Fleet Manager in-memory DAG state synchronization, and verifies agent-monitor immunity. USE WHEN agent stun check, containment integrity, verify stunned agent, flux reconcile disabled, cp-sl-containment-guard, or on schedule '*/15 * * * *'."
---

# cp-sl-containment-guard

Scheduled containment invariant and forensic state verification for the **Signal Loom** (`#partner-signal-loom`) platform.

## Loop Lens & Schedule Contract

- **Cadence**: `*/15 * * * *` (Every 15 minutes, or immediately following an agent containment or stun drill).
- **Trigger**: Cron notification, `/cp-sl-containment-guard`, or manual prompt "check agent containment".
- **Checkpoint**: Push right. Audit all agent workloads across namespaces (`fe-signalloom-agents`, `inf-signalloom`). Automatically patch missing GitOps suspension annotations. Emit brief to human if uncontained network egress or DAG desynchronization is detected.
- **Brief**: Emit a 4-bullet executive status: (1) Total agents inspected, (2) Active vs Stunned agent count, (3) GitOps suspension compliance status, (4) Fleet Manager DAG state alignment.

---

## Mandate & Non-Negotiable Invariants

1. **GitOps Suspension Invariant**:
   - Any agent deployment subjected to stun or containment MUST be annotated with:
     ```yaml
     kustomize.toolkit.fluxcd.io/reconcile: disabled
     ```
   - If this annotation is missing, Flux GitOps reconciliation will immediately overwrite or resurrect the stunned pod, destroying containment.

2. **Forensic Preservation Contract (H1)**:
   - Stunned agent pods must suppress Kubernetes liveness probe kills.
   - Crash state, in-memory artifacts, and network socket buffers must remain preserved for post-incident forensic collection.

3. **Fleet Manager DAG Synchronization**:
   - Fleet Manager in-memory DAG state (`s.dag.SetAgentState(agentID, AgentStateStunned)`) must strictly match `GET /api/v1/fleet/topology`. Stunned agents must not appear as `active` in audience views.

4. **Observability Agent Immunity**:
   - Telemetry and security monitor agents (e.g. `agent-monitor`) are strictly exempt from stun cascades and must remain active under all conditions.

---

## Information Hierarchy

- **Primary Workflow**: [`Workflows/Guard.md`](Workflows/Guard.md)
- **Containment Contracts Reference**: [`References/ContainmentContracts.md`](References/ContainmentContracts.md)
- **Executable Guard**: [`Tools/check-containment.sh`](Tools/check-containment.sh)

---

## Execution Sequence

1. **Agent Workload Enumeration**:
   - List all pods and deployments in `fe-signalloom-agents` and `fe-signalloom`.
   - Identify workloads marked with label `signalloom.ai/containment-status` or annotations.

2. **GitOps Suspension Audit**:
   - For every workload in `stunned` or `contained` state:
     - Check deployment metadata annotations for `kustomize.toolkit.fluxcd.io/reconcile: disabled`.
     - If missing, auto-apply annotation immediately and log remediation event.

3. **Fleet Manager DAG State Cross-Check**:
   - Query `http://localhost:5173/fleet-api/v1/fleet/topology` or `http://localhost:8080/fleet-api/v1/fleet/topology`.
   - Verify that agents returned with `state: "stunned"` match cluster deployment states.

4. **NetworkPolicy & tc-drop Filter Verification**:
   - Verify tc-drop filter attachment on stunned veth interfaces via `signalloom-warden` logs.
   - Assert `agent-monitor` has active network egress for telemetry streaming.

5. **Executive Brief Delivery**:
   - Format and output summary brief.

---

## Completion Criteria

- **Clarity**: Complete visibility into all active/stunned workloads with verified Flux suspension.
- **Demand**: 100% of stunned workloads checked for Flux suspension; DAG state verified; brief delivered.
