# Declarative CEL-to-Landlock Policy Compiler Architecture (CRKC Rule SP-4)

This architecture document details the design, implementation, and verification of the declarative security policy compiler in Signal Loom, satisfying **CRKC Rule SP-4**.

## Overview & Purpose

Signal Loom enforces security invariants across two distinct operating environments:
1. **Tier 1 (In-Cluster Kubernetes)**: Mediated at admission time via Kubernetes ValidatingAdmissionPolicy (VAP) using Google Common Expression Language (CEL).
2. **Tier 0 (Host / Process Execution)**: Mediated at process invocation via Linux Landlock LSM profiles managed by `nono`.

The policy compiler (`d2-signalloom/pkg/policy` and `cmd/policy-compiler`) reads a single declarative source manifest (`config/security-invariants.yaml`) and compiles it into:
- Kubernetes VAP manifests (`vap/filesystem.yaml`, `vap/network.yaml`, `vap/process.yaml`)
- `nono` Landlock JSON configuration profiles (`nono/signalloom-agent-runtime.json`)
- Continuous drift detection lockfiles (`policies.lock.json`)

---

## Rule SP-4 Invariant Enforcement

Rule SP-4 mandates that all admission and governance rules must be expressed in standard Google CEL without extension libraries that execute external processes or network lookups.

The compiler enforces Rule SP-4 constructively and through AST inspection:
1. **Constructive Sandboxing**: CEL environments are instantiated strictly with standard definitions (`cel.NewEnv()`) declaring only Kubernetes VAP variables (`object`, `oldObject`, `request`, `params`). No external extension libraries or process lookups are bound.
2. **Checked AST Audit**: The compiler traverses the checked AST to verify that every called function is on an audited, non-Turing complete allowlist.
3. **Complexity Bounds**: Bounds are placed on expression depth, node count, and nested comprehension depth to guarantee deterministic sub-millisecond evaluation at admission.

---

## Cross-Tier Semantic Equivalence

To guarantee that Tier 0 and Tier 1 policies do not diverge:
- **Filesystem Domain**: Both tiers are evaluated across representative probe paths (allowed directories, denied credential locations, system paths). The emitted CEL is evaluated directly using `cel-go` against synthetic Pod specifications and compared against Landlock path resolution rules.
- **Process & Network Domains**: The compiler verifies that every rule declared in the source invariants manifest is covered in both generated targets without granting extraneous permissions.

---

## CLI Usage

### Compile
```bash
policy-compiler compile -i config/security-invariants.yaml -o dist/policies
```

### Validate
```bash
policy-compiler validate -i config/security-invariants.yaml
```

### Verify Drift
```bash
policy-compiler verify -i config/security-invariants.yaml -d dist/policies
```
