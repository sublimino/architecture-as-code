# CRKC Phase 3 Governor Certification Proof

- **Phase:** Phase 3 — Kernel Confinement & Declarative Invariants
- **Card:** `CRKC-P3-GOV`
- **Reconciler / Governor:** Antigravity Autonomous Governor
- **Date:** 2026-09-07T22:30:00Z
- **Integration Branch:** `integration/crkc-v0.1.0`
- **Base Ref / Head SHA:** `0acc3d894d9ebcb5642718c0717b3c5a6beb7a1d`

---

## 1. Integrated Phase 3 Deliverables Ledger

| Card | Description | Task ID | Deliverable Commit | Status |
| :--- | :--- | :--- | :--- | :--- |
| **`CRKC-P3-PRE`** | Phase 3 Preflight: verify Kubernetes cluster VAP admission support & Landlock nono | `49aec` | `f185e3ddcad7037feae99d7cd68353183ed0d15c` | PASS |
| **`CRKC-P3-1`** | Build declarative CEL-to-Landlock policy compiler with 95 cross-tier equivalence rules | `d2121` | `b02171ab47c448478114c2a9b629554d9838a4da` | PASS |
| **`CRKC-P3-2`** | Implement Rule SP-1 worktree Landlock confinement, `worktree-agent` nono profile & `bin/agent-git` | `23068` | `6aae8672419c6632ca27c83fea23203d71e243a6` | PASS |
| **`CRKC-P3-3`** | Build fail-closed admission webhook ensuring agent pods schedule only on Landlock-confined nodes | `30e7d` | `9cf3883cc285651ee3b3817d5b4e828f2b0e3909` | PASS |

---

## 2. Declarative CEL-to-Landlock Policy Compiler Validation (Rule SP-4)

The declarative security invariants compiler (`d2-signalloom/pkg/policy` and `cmd/policy-compiler`) compiles abstract security invariants (`config/security-invariants.yaml`) into dual enforcement tiers:
1. **Kubernetes ValidatingAdmissionPolicy (VAP):** Pure, non-Turing complete CEL expressions enforced at cluster admission.
2. **Host-level Landlock Sandbox Profile (`nono`):** ABI v1-v5 compliant JSON profile constraining syscall-level filesystem and network access.

Key Invariant Guarantees:
- **Rule SP-4 Non-Turing Completeness:** Verified that CEL expressions reject unbounded recursion, while loops, and unverified functions.
- **Cross-Tier Semantic Equivalence:** 95/95 equivalence probes confirm that admission rules map 1:1 to host containment profiles without policy leakage or semantic divergence.
- **Out-of-Band Tamper Detection:** Policy verifier catches any out-of-band mutation and halts deployment.

---

## 3. Worktree Landlock Confinement & Agent-Git Confinement (Rule SP-1)

Coding agents operating in git worktrees are confined at the Linux LSM kernel layer:
- **Filesystem Confinement:** Read-write access is restricted exclusively to the allocated worktree directory and the parent repository's `.git/` directory. All host credential paths (`~/.ssh`, `~/.gnupg`, `~/.andy_sync`, `~/.aws`, `/etc/shadow`) are kernel-denied.
- **Network Egress Confinement:** Kernel blocks outbound raw TCP/UDP sockets by default; git remote endpoints (ports 22, 443, 9418) cannot be opened by confined agents.
- **Agent-Git Safe Wrapper (`bin/agent-git`):** Enforces `--no-gpg-sign` to prevent pinentry TTY hangs under non-interactive harnesses, while strictly refusing all forms of `git push` (returning Rule SP-1 exit code 4).
- **Execution Proof:** Validated by `scripts/test-worktree-confinement.sh` across 21 live kernel probes with 0 failures (`docs/signalloom/evidence/worktree-confinement-proof.json`).

---

## 4. Fail-Closed Node Capability Admission Guard (Rule SP-2)

The admission guard webhook service (`d2-signalloom/apps/node-capability-guard`):
- **Admission Enforcement:** Rejects agent pods requesting capabilities on nodes lacking verified Landlock runtime containment with HTTP 403 Forbidden.
- **Attestation Match:** Confined agent pods targeted at compliant nodes with valid Landlock profiles are admitted with HTTP 200 OK.
- **Telemetry Exposition:** Metrics (`node_capability_rejections_total`, `node_capability_admissions_total`) update in real-time for estate-wide observability.

---

## 5. Adversarial Red-Team & Confinement Verification

The red-team verification suite (`test/crkc-phase3-confinement-redteam.bats`) validated the system against active adversarial exploit scenarios:
- **Turing-Complete Injection Attack:** Successfully rejected with non-zero exit code.
- **Host Credential Exfiltration Attack:** Kernel refused read access to `~/.ssh` and credential stores.
- **Unauthorized Network Socket Opening:** Blocked by kernel Landlock network layer.
- **Push Bypass Attempts:** `agent-git push --force`, `agent-git push -f`, and `agent-git push --all` all refused with exit code 4 (Rule SP-1).
- **Total Audit Findings:** 0 policy escapes, 0 unauthorized socket connections.

---

## 6. Phase 3 Certification Sign-Off

All Phase 3 requirements have been built, integrated into `integration/crkc-v0.1.0` and `feat/signal-loop-and-bootstrap-refactor`, and certified 100% green across all unit, integration, and red-team suites.
