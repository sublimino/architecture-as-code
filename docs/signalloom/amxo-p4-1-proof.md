# AMXO-P4-1 — Phase 4 Host Confinement, Profile & Digest Gate Proof

**Status:** PASS — Fail-closed nono 0.73.0 profile, systemd unit, and binary digest gate fully implemented and verified  
**Verified at:** 2026-09-13 18:20:00+01:00  
**Logical ID:** `P4-1`  
**Role:** implementation  
**Atomic task:** Build fail-closed nono profile systemd unit and digest gate  
**Integration ref:** `refs/heads/integration/agentmaxxing-onboarding-v0.1.0`  
**Task worktree:** `/home/andy/src/.worktrees/5d3df/osramp-demo` (detached HEAD)

---

## 1. Executive Summary & Verdict

AMXO-P4-1 establishes the defense-in-depth confinement foundation for the external AgentMaxxing Linux agent on host infrastructure.

Key Deliverables:
1. **Nono 0.73.0 Confinement Profile (`profile.json`)**: Formally validated with `nono profile validate`, strictly restricting write access to `/var/lib/agentmaxxing/{work,output,audit}` and `/run/agentmaxxing`, pinning read-only input roots (`/opt/agentmaxxing`, `/etc/ssl/certs`, `/srv/agentmaxxing/input`), denying sensitive system files (`/root`, `/etc/shadow`, `/etc/sudoers`, `~/.ssh`), and proxy-filtering network egress to approved endpoints (`signal-ingest.signalloom.controlplane.io`, `api.agentmaxxing.com:443`).
2. **Hardened Systemd Service Unit (`agentmaxxing-agent.service`)**: Fully hardened with `NoNewPrivileges=yes`, `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`, `PrivateDevices=yes`, `RestrictNamespaces=yes`, `RestrictSUIDSGID=yes`, cgroup v2 resource limits (`MemoryMax=512M`, `TasksMax=64`, `CPUQuota=200%`), and preflight gate integration.
3. **Binary Digest Preflight Verification Gate (`scripts/digest_gate.sh`)**: Fail-closed gate checking Linux kernel Landlock LSM support, nono 0.73.0 binary digest (`71581b92e7683c86276bbbd91c80b059e0fe2d7b1aa95b1176870456ee22ad5c`), and computing SHA-256 hash of agent executable before startup. Refuses execution on digest mismatch or world-writable permissions.
4. **Execution Wrapper (`scripts/start.sh`)**: Strips sensitive cloud/SSH/Git credentials from the environment and spawns the agent under nono confinement.
5. **Comprehensive Test Suite & Makefile Wiring**: 11/11 tests passing in `test/signalloom/agentmaxxing-host-confinement.bats` via `make demo-agentmaxxing-host-test`, including real kernel Landlock denial probes for unauthorized filesystem writes, sensitive file reads, and unapproved network egress.

---

## 2. Prompt-to-Artifact Verification Checklist

| Requirement | Deliverable / Evidence | Result |
| :--- | :--- | :---: |
| Isolated runtime worktree | Worktree `/home/andy/src/.worktrees/5d3df/osramp-demo` | PASS |
| Base ref ancestry | Derived from `integration/agentmaxxing-onboarding-v0.1.0` | PASS |
| Nono 0.73.0 confinement profile | `d2-signalloom/apps/agentmaxxing-host-sensor/profile.json` | PASS |
| Nono profile validation | `nono profile validate profile.json` reported `Result: valid` | PASS |
| Pinned root directories | Writable roots (`/var/lib/agentmaxxing/{work,output,audit}`), Read roots (`/opt/agentmaxxing`, `/srv/agentmaxxing/input`) | PASS |
| Sensitive path denial | `/root`, `/etc/shadow`, `/etc/gshadow`, `/etc/sudoers`, `~/.ssh` in `filesystem.deny` | PASS |
| Network egress allowlist | Egress permitted only to `signal-ingest.signalloom.controlplane.io:443` and `api.agentmaxxing.com:443` | PASS |
| Environment scrubbing | Strips `SSH_AUTH_SOCK`, `AWS_*`, `GITHUB_*`, `KUBECONFIG`, `VAULT_TOKEN`, etc. | PASS |
| Hardened systemd service | `d2-signalloom/apps/agentmaxxing-host-sensor/agentmaxxing-agent.service` | PASS |
| Systemd security directives | `NoNewPrivileges=yes`, `ProtectSystem=strict`, cgroup v2 limits (`MemoryMax=512M`, `TasksMax=64`) | PASS |
| Binary digest verification script | `d2-signalloom/apps/agentmaxxing-host-sensor/scripts/digest_gate.sh` | PASS |
| Startup execution wrapper | `d2-signalloom/apps/agentmaxxing-host-sensor/scripts/start.sh` | PASS |
| Real Landlock filesystem denial | Attempted write outside workspace returned `Permission denied` | PASS |
| Real Landlock sensitive read denial | Attempted read of `/etc/shadow` returned `Permission denied` | PASS |
| Real Landlock network denial | Attempted socket connect to `1.1.1.1:80` returned `Permission denied` | PASS |
| Host confinement test target | `make demo-agentmaxxing-host-test` (11/11 tests passed) | PASS |
| Pytest nono profile test | `pytest ... -k test_nono_profile` (2/2 passed) | PASS |
| Operator installation guide | `docs/signalloom/amxo-p4-1-operator-guide.md` | PASS |
| Evidence report | `docs/signalloom/amxo-p4-1-evidence.md` | PASS |
| Proposal errata entry | Qualified `AMXO-P4-1` errata block appended to proposal Appendix | PASS |

---

## 3. Test Suite Results

### 3.1 Host Confinement Suite (`make demo-agentmaxxing-host-test`)
```
bats test/signalloom/agentmaxxing-host-confinement.bats
agentmaxxing-host-confinement.bats
   confinement profile exists and passes nono profile validate 1/11 ✓ confinement profile exists and passes nono profile validate
   confinement profile matches approved policy roots and denies sensi... 2/11 ✓ confinement profile matches approved policy roots and denies sensitive paths
   confinement profile enforces default-deny network with approved en... 3/11 ✓ confinement profile enforces default-deny network with approved endpoints
   systemd service unit contains mandatory security hardening directives 4/11 ✓ systemd service unit contains mandatory security hardening directives
   scripts pass bash syntax checks 5/11 ✓ scripts pass bash syntax checks
   digest gate fails closed on mismatched binary SHA-256 digest 6/11 ✓ digest gate fails closed on mismatched binary SHA-256 digest
   digest gate succeeds when binary SHA-256 matches expected digest 7/11 ✓ digest gate succeeds when binary SHA-256 matches expected digest
   digest gate rejects world-writable binary 8/11 ✓ digest gate rejects world-writable binary
   real Landlock probe: nono profile denies filesystem write outside ... 9/11 ✓ real Landlock probe: nono profile denies filesystem write outside workspace
   real Landlock probe: nono profile denies reading sensitive /etc/shadow10/11 ✓ real Landlock probe: nono profile denies reading sensitive /etc/shadow
   real Landlock probe: nono profile denies unauthorized outbound net...11/11 ✓ real Landlock probe: nono profile denies unauthorized outbound network connection

11 tests, 0 failures
```

### 3.2 Audit Ingest Pytest Suite (`pytest ... -k test_nono_profile`)
```
======================== 2 passed, 15 deselected, 2 warnings in 0.79s ========================
```

### 3.3 Operator Contract Suite (`make demo-agentmaxxing-contract-test`)
```
6 tests, 0 failures
```

### 3.4 API Contract Suite (`make demo-signalloom-api-test TIER=contract`)
```
======================== 56 passed, 2 warnings in 1.36s ========================
```

---

## 4. Delivery Summary

All deliverables specified in AMXO-P4-1 have been created, tested with positive and negative test cases, and confirmed against real Linux Landlock kernel security modules.
