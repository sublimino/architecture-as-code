# AMXO-P4-GOV Verification Proof: Phase 4 Linux Host Confinement, Sensor Telemetry, Anti-Escape Validation, and TOCTOU Hasher Governor Certification

**Card**: `AMXO-P4-GOV` (`58840`)  
**Timestamp**: `2026-09-13T18:35:00+01:00`  
**Base Ref**: `refs/heads/integration/agentmaxxing-onboarding-v0.1.0`  
**Workspace**: `/home/andy/src/.worktrees/osramp-demo/agentmaxxing-onboarding-v0.1.0/governor`  
**Status**: `CERTIFIED_PASS`  

---

## 1. Executive Summary & Phase 4 Certification

The Phase 4 Governor for AgentMaxxing Signal Loom User and External Agent Onboarding (AMXO) certifies all Phase 4 Linux host confinement, process telemetry, descriptor-relative anti-escape validation, and bounded TOCTOU artifact hashing deliverables (`AMXO-P4-PRE`, `AMXO-P4-1`, `AMXO-P4-2`, `AMXO-P4-3`, `AMXO-P4-4`, `AMXO-P4-GOV`) against the Definition of Done, kernel isolation boundaries, privacy allowlists, and anti-escape invariants.

All deliverables are fully integrated into `integration/agentmaxxing-onboarding-v0.1.0` and reconciled with zero drift, verified across Python 3 unit tests, Pytest integration fixtures, and BATS host confinement assertions.

### Certified Milestones & Invariants

1. **AMXO-P4-PRE (Confinement & Kernel Preflight)**: Verified Linux kernel Landlock LSM support, cgroups v2 resource hierarchy, nono 0.73.0 profile schema, and preflight test runners at commit `bad24d68`.
2. **AMXO-P4-1 (Fail-Closed Nono Profile & Digest Gate)**: Delivered fail-closed nono 0.73.0 profile with strict filesystem allowlist pinned to `/var/lib/agentmaxxing/work` and `/var/lib/agentmaxxing/output`, denied sensitive paths (`/root`, `/etc/shadow`, `/etc/sudoers`), default-deny network egress with approved endpoints (`signal-ingest.signalloom.controlplane.io:443`, `api.agentmaxxing.com:443`), hardened systemd service unit (`agentmaxxing-agent.service` with `NoNewPrivileges=yes`, `ProtectSystem=strict`, `ProtectHome=yes`, `MemoryMax=512M`), and preflight binary digest gate (`scripts/digest_gate.sh`) verifying SHA-256 digests before execution at commit `f13eb63f`.
3. **AMXO-P4-2 (Bounded Process Lifecycle Telemetry Collector)**: Delivered `agentmaxxing-host-sensor` package emitting strictly bounded process lifecycle metadata (`health_state`, `cpu_time_ms`, `resident_memory_bytes`, `exit_code`, `restart_count`) adhering to `process-lifecycle-telemetry.v1.schema.json`. Verified strict zero-payload guarantees: zero reading of `/proc/<pid>/mem`, `/proc/<pid>/maps`, `/proc/<pid>/stack`, or `/proc/<pid>/environ`, and zero harvesting of command-line secret payloads at commit `dcc71583`.
4. **AMXO-P4-3 (Descriptor-Relative Artifact Eligibility & Anti-Escape)**: Delivered `file_validator.py` and `openat2.py` implementing descriptor-relative path validation under pinned root directory descriptors. Enforces `openat2` syscall with `RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_XDEV`. Provably rejects symlinks pointing inside or outside roots, path traversal attempts (`..`), absolute paths, hardlinked files (`st_nlink > 1`), directory targets, and FIFO named pipes with exactly 0 bytes read at commit `caaf7550`.
5. **AMXO-P4-4 (Bounded Artifact Hasher & TOCTOU Identity Validation)**: Delivered `hasher.py` and `ratelimit.py` implementing stream-hashing with pre- and post-read identity checks (inode, mount ID, size, link count, `mtime_ns`, `ctime_ns`). Concurrent modifications or TOCTOU races invalidate the digest and return `observation_state="unobserved"`, `sha256=null`, and `reason_code="toctou_mutation_detected"`. Sliding-window rate limiter prevents CPU exhaustion at commit `d5005ee7`.
6. **AMXO-P4-GOV (Governor Monorepo Reconciliation)**: Reconciled shared-file collisions across `Makefile`, `README.md`, `__init__.py`, `cli.py`, and `test_audit_ingest.py`. Unified `demo-agentmaxxing-host-test` target orchestrating 70 passing test cases with 0 failures, 0 skips, and 0 warnings. Falsified all escape vectors and certified Phase 4 completion.

---

## 2. Test Verification Matrix

| Test Suite | Scope | Target / Command | Result |
| :--- | :--- | :--- | :--- |
| Host Sensor Unit Suite | Process telemetry, cgroups, procfs, CLI, filter, models | `python3 -m unittest discover -s d2-signalloom/apps/agentmaxxing-host-sensor/ -p 'test_*.py'` | 38/38 PASS (0 fail) |
| Host Audit Ingest Tests | Nono profile, process telemetry, anti-escape, TOCTOU | `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py -k "nono or process or anti_escape or toctou"` | 6/6 PASS (0 fail) |
| Host Confinement BATS | Landlock LSM, systemd unit, digest gate, network deny | `bats test/signalloom/agentmaxxing-host-confinement.bats` | 11/11 PASS (0 fail) |
| File Validator Anti-Escape BATS | Symlink, traversal, hardlink, FIFO, 0 bytes read | `bats test/signalloom/file-validator-anti-escape.bats` | 9/9 PASS (0 fail) |
| Hasher TOCTOU & RateLimit BATS | Concurrent mutations, mtime touch, rate limits | `bats test/signalloom/hasher-toctou.bats` | 6/6 PASS (0 fail) |
| Operator Contract Suite | Attributable operator identity & governance | `make demo-agentmaxxing-contract-test` | 6/6 PASS (0 fail) |
| Unified Host Test Target | Complete Phase 4 host isolation & sensor suite | `make demo-agentmaxxing-host-test` | 70/70 PASS (0 fail) |

---

## 3. Host Confinement & Anti-Escape Invariant Proof

- **Kernel LSM Confinement**: Landlock LSM strictly enforces filesystem read/write boundaries at the kernel level. Tests confirm that direct attempts to write outside the workspace or read sensitive system files (`/etc/shadow`, `/root`) are blocked by the kernel.
- **Syscall-Level Anti-Escape (`openat2`)**: Artifacts are opened relative to pinned root descriptors using `RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_XDEV`. Any symlink, path traversal, or mount point traversal fails at the kernel syscall layer before opening the descriptor.
- **Zero-Byte Read Guarantee**: For all ineligible files (symlinks, hardlinks with `st_nlink > 1`, directories, FIFOs, traversal escapes), the validator terminates before calling `read()` — guaranteeing 0 bytes read from untrusted or out-of-scope files.
- **Post-Read TOCTOU Identity Verification**: Baseline file metadata snapshot (`st_dev`, `st_ino`, `st_nlink`, `st_size`, `st_mtime_ns`, `st_ctime_ns`, mount ID) is compared against post-read metadata after hashing. If any attribute changed during reading, the digest is invalidated and marked `observation_state="unobserved"`, `integrity_state="unverified"`.
- **Zero-Payload Privacy Assurance**: The host sensor strictly restricts telemetry to allowlisted numeric metrics and status enums. Process memory, stack, registers, environment variables, command arguments, customer files, and payload contents are never inspected or transmitted.

---

## 4. Phase 4 Spend Accounting

| Task | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :-------- | :----- | :------ | :----- |
| P4-PRE | $0.00 | N/A — no session | N/A | cpai://open?id=bb4bd&dir=/home/andy/.cline/worktrees/bb4bd/osramp-demo&host=fortuna&model=coding_medium |
| P4-1 | $0.00 | N/A — no session | N/A | cpai://open?id=5d3df&dir=/home/andy/.cline/worktrees/5d3df/osramp-demo&host=fortuna&model=coding_medium |
| P4-2 | $0.00 | N/A — no session | N/A | cpai://open?id=dee2a&dir=/home/andy/.cline/worktrees/dee2a/osramp-demo&host=fortuna&model=coding_medium |
| P4-3 | $0.00 | N/A — no session | N/A | cpai://open?id=af50e&dir=/home/andy/.cline/worktrees/af50e/osramp-demo&host=fortuna&model=coding_medium |
| P4-4 | $0.00 | N/A — no session | N/A | cpai://open?id=942a1&dir=/home/andy/.cline/worktrees/942a1/osramp-demo&host=fortuna&model=coding_medium |
| P4-GOV | $0.00 | N/A — no session | N/A | cpai://open?id=58840&dir=/home/andy/.cline/worktrees/58840/osramp-demo&host=fortuna&model=coding_medium |

---

Phase 4 Linux Host Confinement, Sensor Telemetry, Anti-Escape Validation, and TOCTOU Hasher Governance is certified. Ready to advance to Phase 5 (Server-Side Session Verification, Ingestion Pipeline & Tenant Evidence Projections).
