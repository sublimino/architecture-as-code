# Automated Response Policy Grammar and Evaluation Schema

This specification defines the grammar, evaluation semantics, and REST interfaces for automated response policies in the Fleet Manager.

## 1. Overview

Automated response policies provide autonomous, closed-loop containment for enterprise multi-agent fleets. When compliance posture or aggregate financial risk exceeds organizational thresholds, the Policy Engine triggers cascading containment to isolate affected agents in sub-second time.

## 2. Policy Model

Each policy is defined by a `ResponsePolicy` record:

```go
type ResponsePolicy struct {
	ID            string        `json:"id"`
	Name          string        `json:"name"`
	Description   string        `json:"description"`
	Enabled       bool          `json:"enabled"`
	ConditionType ConditionType `json:"condition_type"`
	Operator      string        `json:"operator"`
	Threshold     float64       `json:"threshold"`
	TargetAgentID string        `json:"target_agent_id"`
	Action        ActionType    `json:"action"`
}
```

### 2.1 Condition Types

- `RiskThreshold`: Evaluates aggregate Carried GBP exposure against the threshold.
- `ComplianceFailure`: Evaluates agent compliance status and remaining grace period hours.
- `GracePeriodExpiry`: Evaluates non-compliant workloads whose grace period has reached zero hours.

### 2.2 Operators

- `>`: Value strictly greater than threshold.
- `>=`: Value greater than or equal to threshold.
- `==`: Value equals threshold.
- `<=`: Value less than or equal to threshold.

### 2.3 Action Types

- `CascadeStun`: Invokes CascadeOrchestrator.Stun to isolate the target and downstream dependants in topological order.
- `StunTarget`: Isolates only the specific target agent.
- `Alert`: Emits an advisory alert record without modifying pod state.

## 3. Baseline Policies

The default configuration includes three canonical governance policies:

1. `pol-risk-500k`: High-Risk Carried GBP Auto-Containment
   - Condition: `RiskThreshold` > £500,000.00
   - Target: `cardvault`
   - Action: `CascadeStun`

2. `pol-pii-compliance`: Critical PII Zero-Grace Compliance Containment
   - Condition: `ComplianceFailure` with remaining grace period == 0.0h
   - Target: `agent-llm-classifier`
   - Action: `CascadeStun`

3. `pol-grace-expiry`: Grace Period Expiry Containment
   - Condition: `GracePeriodExpiry` with remaining hours <= 0.0h
   - Target: `agent-txn-pipeline`
   - Action: `CascadeStun`

## 4. Evaluation Semantics

### 4.1 Dry-Run Simulation

When `dry_run: true` is passed in `PolicyEvaluationInput`, condition matching executes normally and records matched policies, but does not invoke credential revocation or pod state mutation.

### 4.2 Target Debounce

If a target agent is already in `StateStunned`, the evaluator debounces the action to prevent repeated revocations.

## 5. REST Interfaces

### 5.1 List Policies

`GET /api/v1/fleet/policies`

Returns active policy configurations:

```json
{
  "count": 3,
  "policies": [
    {
      "id": "pol-risk-500k",
      "name": "High-Risk Carried GBP Auto-Containment",
      "enabled": true,
      "condition_type": "RiskThreshold",
      "operator": ">",
      "threshold": 500000.0,
      "target_agent_id": "cardvault",
      "action": "CascadeStun"
    }
  ]
}
```

### 5.2 Evaluate Policies

`POST /api/v1/fleet/policies/evaluate`

Accepts evaluation inputs and executes matching actions:

```json
{
  "carried_gbp": 847000.0,
  "dry_run": false
}
```

Returns execution outcome:

```json
{
  "evaluated_at": "2026-10-08T17:00:00Z",
  "dry_run": false,
  "triggered": true,
  "policies_checked": 3,
  "actions": [
    {
      "policy_id": "pol-risk-500k",
      "policy_name": "High-Risk Carried GBP Auto-Containment",
      "action": "CascadeStun",
      "target_agent_id": "cardvault",
      "triggered": true,
      "reason": "Carried GBP £847000.00 exceeds threshold £500000.00"
    }
  ]
}
```
