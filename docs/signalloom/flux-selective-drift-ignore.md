# Flux Selective Drift Ignore & Field-Manager Stun Persistence

> **Document Version:** 1.0.0  
> **Card ID:** CRKC-P1-1  
> **Scope:** Signal Loom Runtime Confinement, Live FAIR Risk & Kernel Containment (2026-Q3)  
> **Status:** Implemented & Verified  

---

## 1. Executive Summary

Signal Loom provides autonomous security governance, active runtime containment, and emergency operational stun capabilities for AI agent workloads running on Kubernetes. When a rogue agent exhibits anomalous behaviour, prompt injection leakage, or credential misuse, Signal Loom's Sentinel controllers and human operators trigger immediate out-of-band containment actions (e.g. cgroup process freezing, SPIFFE/OpenBao credential revocation, NetworkPolicy isolation, and metadata marking).

In a GitOps-driven environment managed by Flux (`kustomize-controller`), continuous reconciliation actively detects and corrects cluster drift against declarative git state. Without precise configuration, GitOps reconciliation undoes operational stun markers within minutes, reverting compromised agents to `active`/`idle` states while their credentials remain revoked—causing a critical split-brain condition where the user interface reassures operators while workloads sit broken or uncontained.

This document details the architecture, JSON pointer escaping specifications, field-manager contracts, and automated verification mechanisms establishing **selective drift ignore** across Signal Loom and all tenant Kustomizations.

---

## 2. The Drift Dilemma: Three Operational Modes

Signal Loom requires runtime mutable labels and annotations (`signalloom.io/stunned`, `signalloom.io/containment-mode`, `signalloom.io/stun-reason`) on workloads managed by Flux. Three configuration models exist:

| Configuration | Manifest State | Kustomization `.spec.ignore` | Reconcile Outcome | Operational Verdict |
|---|---|---|---|---|
| **A: Unmanaged** | Declared | Absent | Fields reverted on every reconcile loop | **FATAL:** Stun state reverted; split-brain UI |
| **B: Omitted** | Not Declared | Configured | Fields deleted outright on apply | **STRICTLY WORSE:** Stun markers wiped permanently |
| **C: Declared & Ignored** | Declared (placeholders) | Configured (RFC 6901 paths) | Live cluster values preserved across reconciles | **CORRECT:** Full out-of-band mutation survival |

### The "Declared & Ignored" Invariant
Flux's `.spec.ignore` works by reading the live cluster object's value at each specified JSON pointer path and substituting it into the rendered desired manifest prior to applying changes.
- If a field is **not declared** in the source manifest, there is no AST node into which the live value can be substituted; Flux drops the field on apply.
- If a field is **declared but not ignored**, Flux applies the git-defined baseline value, overwriting runtime changes.
- Therefore, all runtime-owned fields must be **declared with default placeholders** in base manifests (`signalloom.io/stunned: "false"`, `signalloom.io/containment-mode: "none"`, `signalloom.io/stun-reason: ""`) and **explicitly ignored** in `.spec.ignore`.

---

## 3. RFC 6901 JSON Pointer Escaping Contract

Flux `kustomize-controller` evaluates `.spec.ignore[].paths` using standard **RFC 6901 JSON Pointers**.

### Escaping Syntax Rules
In RFC 6901:
- `/` is the token delimiter separating object hierarchy levels.
- `~1` represents a literal `/` character within a property name.
- `~0` represents a literal `~` character within a property name.

Kubernetes label and annotation keys commonly contain domain prefixes with slashes (e.g., `signalloom.io/stunned`).

```yaml
# ❌ INCORRECT: Unescaped slash evaluates as 4 segments ["metadata", "labels", "signalloom.io", "stunned"]
# Controller searches for child property "stunned" inside object "signalloom.io", failing silently.
spec:
  ignore:
    - target:
        kind: Pod
      paths:
        - /metadata/labels/signalloom.io/stunned

# ✅ CORRECT: Escaped slash (~1) evaluates as 3 segments ["metadata", "labels", "signalloom.io/stunned"]
spec:
  ignore:
    - target:
        kind: Pod
      paths:
        - /metadata/labels/signalloom.io~1stunned
        - /metadata/labels/signalloom.io~1containment-mode
        - /metadata/annotations/signalloom.io~1stun-reason
        - /metadata/labels/signalloom.ai~1state
        - /metadata/annotations/signalloom.ai~1stunned-at
        - /metadata/annotations/signalloom.ai~1stun-reason
```

---

## 4. Field Manager Contract (`flux-client-side-apply`)

Kubernetes tracks field ownership through `metadata.managedFields`. When Flux reconciles resources using client-side apply or server-side apply, mutations originating from different field managers can produce ownership conflicts or unwanted reversions.

To establish idempotent out-of-band mutations:
1. All stun trigger pathways (CLI scripts, Signal Loom Sentinel, `fake-integration-proxy`, and fleet orchestration scripts) specify:
   ```bash
   --field-manager=flux-client-side-apply
   ```
2. API patch requests to the Kubernetes API server include the query parameter:
   ```http
   PATCH /api/v1/namespaces/{ns}/pods/{name}?fieldManager=flux-client-side-apply
   Content-Type: application/strategic-merge-patch+json
   ```
3. This ensures out-of-band operational changes share the field manager identity expected by Flux, preventing conflict-resolution wipes during subsequent reconciliation cycles.

---

## 5. Standardized Metadata Keys

Signal Loom standardizes on the `signalloom.io` domain for all runtime governance markers while maintaining backward compatibility with legacy `signalloom.ai` keys:

### Primary Keys (`signalloom.io`)
- `signalloom.io/stunned`: Label (`"true"` | `"false"`). Indicates immediate operational containment.
- `signalloom.io/containment-mode`: Label (`"frozen"` | `"isolated"` | `"quarantined"` | `"none"`).
- `signalloom.io/stun-reason`: Annotation (string description of trigger condition or operator rationale).

### Legacy Keys (`signalloom.ai`)
- `signalloom.ai/state`: Label (`"active"` | `"non-compliant"` | `"stunned"` | `"idle"`).
- `signalloom.ai/stunned-at`: Annotation (ISO 8601 UTC timestamp).
- `signalloom.ai/stun-reason`: Annotation (string reason).

---

## 6. Verification and Continuous Assurance Tooling

Three levels of automated verification protect this contract against regression:

1. **RFC 6901 Linter (`scripts/lint-flux-ignore-rfc6901.sh`):**
   Scans all YAML manifests in `d2-osramp-fleet` and validates every `spec.ignore[].paths` entry against RFC 6901 pointer syntax, catching unescaped slashes before commit.

2. **Dynamic Label Validator (`scripts/check-flux-dynamic-labels.sh`):**
   Verifies that every field in `DYNAMIC_FIELDS` is both declared in workload manifests and ignored in corresponding Kustomization specifications.

3. **BATS Test Suite (`test/flux-drift-ignore.bats`):**
   Automated regression suite executing static validations and live reconciliation tests.

4. **Continuous 50-Reconciliation Runner (`scripts/test-flux-drift-ignore.sh`):**
   Applies operational stun labels to live workloads, executes 50 consecutive forced Flux reconciliations (`flux reconcile kustomization --with-source`), verifies zero drift reversions, checks `metadata.managedFields`, and outputs evidence to:
   `docs/signalloom/evidence/flux-drift-ignore-proof.json`.
