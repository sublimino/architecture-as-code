# AgentMaxxing Linux Host Sensor & Confinement

This component provides the host-level isolation, nono 0.73.0 confinement profile, systemd service unit, binary digest gate, and startup wrapper for the external AgentMaxxing Linux agent.

## Architecture

The external AgentMaxxing Linux agent runs directly on partner Linux host infrastructure under defense-in-depth confinement:

1. **Systemd Unit Hardening (`agentmaxxing-agent.service`)**:
   - `NoNewPrivileges=yes` prevents suid/sgid elevation.
   - `ProtectSystem=strict` and `ProtectHome=yes` isolate base system and user files.
   - Pinned `ReadOnlyPaths` (`/opt/agentmaxxing`, `/etc/ssl/certs`, `/srv/agentmaxxing/input`, `/usr`, `/lib`, `/lib64`).
   - Pinned `ReadWritePaths` (`/var/lib/agentmaxxing/work`, `/var/lib/agentmaxxing/output`, `/var/lib/agentmaxxing/audit`, `/run/agentmaxxing`).
   - `InaccessiblePaths` (`/root`, `/etc/shadow`, `/etc/gshadow`, `/etc/sudoers`).
   - Cgroup v2 resource limits (`MemoryMax=512M`, `TasksMax=64`, `CPUQuota=200%`).

2. **Binary Digest Preflight Gate (`scripts/digest_gate.sh`)**:
   - Validates Linux kernel Landlock LSM support.
   - Validates nono 0.73.0 binary presence and pinned SHA-256 digest (`71581b92e7683c86276bbbd91c80b059e0fe2d7b1aa95b1176870456ee22ad5c`).
   - Computes SHA-256 digest of the agent executable before execution.
   - Fails closed if the binary has been modified, tampered with, or does not match the approved digest.

3. **Nono 0.73.0 Confinement Profile (`profile.json`)**:
   - Landlock LSM confinement strictly limiting filesystem writes to designated workspace roots.
   - Default deny for all unauthorized network egress.
   - Approved egress allowlist:
     - `signal-ingest.signalloom.controlplane.io:443` (TCP/TLS)
     - `api.agentmaxxing.com:443` (TCP/TLS)
   - Environment stripping of sensitive secrets and cloud credentials (`AWS_*`, `SSH_*`, `GITHUB_*`, `KUBECONFIG`, `VAULT_TOKEN`).

## File Manifest

| File | Purpose |
| :--- | :--- |
| `profile.json` | Nono 0.73.0 confinement profile |
| `agentmaxxing-agent.service` | Hardened systemd service unit |
| `scripts/digest_gate.sh` | Preflight binary digest verification gate |
| `scripts/start.sh` | Confinement execution entrypoint |
| `README.md` | Component documentation and operator overview |

## Testing

Run the test suite:
```bash
make demo-agentmaxxing-host-test
```
