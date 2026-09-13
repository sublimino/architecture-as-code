# AMXO-P4-1 Verification Evidence

**Recorded:** 2026-09-13T18:20:00+01:00  
**Scope:** Fail-closed nono 0.73.0 profile, systemd service unit hardening, binary SHA-256 digest preflight gate, and Linux Landlock LSM isolation test suite for external AgentMaxxing Linux agent.

## Test Ledger

| Command | Outcome | Skips | Evidence |
| :--- | :--- | :--- | :--- |
| `make demo-agentmaxxing-host-test` | 11 passed | 0 | Full BATS test suite asserting nono profile validation, approved root and network enforcement, systemd security directives, digest gate tampering rejection, world-writable rejection, real Landlock filesystem write denial, sensitive file read denial, and network connect denial |
| `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py -k test_nono_profile` | 2 passed | 0 | Pytest assertions verifying `profile.json` satisfies `agentmaxxing-host-policy.v1.json` roots, network destinations, and fail-closed security directives |
| `bash -n d2-signalloom/apps/agentmaxxing-host-sensor/scripts/start.sh` | 0 exit | 0 | Clean bash syntax verification for sensor execution wrapper |
| `bash -n d2-signalloom/apps/agentmaxxing-host-sensor/scripts/digest_gate.sh` | 0 exit | 0 | Clean bash syntax verification for binary digest gate script |
| `make demo-agentmaxxing-contract-test` | 6 passed | 0 | Attributable AgentMaxxing operator identity and lifecycle governance contracts |
| `make demo-signalloom-api-test TIER=contract` | 56 passed | 0 | FastAPI Tier 1 contract tests and numbered migration sequence validation |
| `nono profile validate d2-signalloom/apps/agentmaxxing-host-sensor/profile.json` | Valid | 0 | Strict nono profile validation checking JSON syntax and 17 policy groups |

## Verification Details

1. **Nono 0.73.0 Confinement Profile (`d2-signalloom/apps/agentmaxxing-host-sensor/profile.json`)**:
   - Conforms to nono 0.73.0 profile schema (`https://nono.sh/schema/profile.json`).
   - Filesystem allowlist strictly restricted to designated workspace roots:
     - `/var/lib/agentmaxxing/work`
     - `/var/lib/agentmaxxing/output`
     - `/var/lib/agentmaxxing/audit`
     - `/run/agentmaxxing`
   - Filesystem read-only roots strictly pinned to approved binaries and trust stores:
     - `/opt/agentmaxxing`
     - `/etc/ssl/certs`
     - `/srv/agentmaxxing/input`
     - `/usr`, `/lib`, `/lib64`, `/etc/resolv.conf`, `/etc/hosts`
   - Explicit sensitive filesystem denylist:
     - `/root`, `/etc/shadow`, `/etc/gshadow`, `/etc/sudoers`, `/etc/pam.d`, `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`, `~/.config/gcloud`
   - Network egress allowlist:
     - Outbound traffic proxy-filtered to approved domains: `signal-ingest.signalloom.controlplane.io`, `api.agentmaxxing.com` on TCP port `443`.
   - Environment variables scrubbed:
     - Denies `SSH_AUTH_SOCK`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `GITHUB_TOKEN`, `GH_TOKEN`, `KUBECONFIG`, `VAULT_TOKEN`, `GNUPGHOME`.

2. **Hardened Systemd Unit File (`agentmaxxing-agent.service`)**:
   - `NoNewPrivileges=yes` prevents privilege elevation via setuid/setgid binaries.
   - Filesystem sandboxing: `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`, `PrivateDevices=yes`.
   - Kernel and namespace protection: `ProtectKernelTunables=yes`, `ProtectKernelModules=yes`, `ProtectControlGroups=yes`, `RestrictNamespaces=yes`, `RestrictSUIDSGID=yes`, `RestrictRealtime=yes`, `LockPersonality=yes`, `MemoryDenyWriteExecute=yes`.
   - Capability bounding set cleared: `CapabilityBoundingSet=`, `AmbientCapabilities=`.
   - Explicit path pinning: `ReadWritePaths`, `ReadOnlyPaths`, `InaccessiblePaths`.
   - Cgroup v2 resource limits: `MemoryMax=512M`, `TasksMax=64`, `CPUQuota=200%`.
   - Integrated preflight gate: `ExecStartPre=/opt/agentmaxxing/scripts/digest_gate.sh`.
   - Confinement startup: `ExecStart=/opt/agentmaxxing/scripts/start.sh`.

3. **Binary Digest Preflight Verification Gate (`scripts/digest_gate.sh`)**:
   - Inspects Linux kernel Landlock LSM availability via `/sys/kernel/security/lsm` or `landlock_create_ruleset` syscall (nr 444).
   - Validates pinned nono 0.73.0 binary digest (`71581b92e7683c86276bbbd91c80b059e0fe2d7b1aa95b1176870456ee22ad5c`).
   - Computes SHA-256 hash of agent executable before startup.
   - Refuses execution if hash does not match approved digest or if binary is world-writable.

4. **Confinement Denial Probes (Real Kernel Landlock Probes)**:
   - Filesystem Write Denial Probe: Attempted write to `/tmp/unallowed_probe.txt` under nono sandbox returned `Permission denied` (exit code 1).
   - Sensitive File Read Denial Probe: Attempted read of `/etc/shadow` under nono sandbox returned `Permission denied` (exit code 1).
   - Unauthorized Network Connect Denial Probe: Attempted TCP socket connect to unapproved destination `1.1.1.1:80` returned `PermissionError: [Errno 13] Permission denied` (exit code 1).

## Delivery Boundaries

- Isolated worktree execution only.
- No remote push or PR created.
- No database schema or migration broken.
- No customer payload data collected or exported.
