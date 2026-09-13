# Operator Installation & Operations Guide: AgentMaxxing Linux Confinement Service

This guide provides system administrators and host operators with procedures to install, configure, verify, and operate the external AgentMaxxing Linux agent under fail-closed nono 0.73.0 Landlock confinement and systemd security controls.

## 1. Prerequisites

- **Host Operating System:** Linux kernel >= 5.13 with Landlock LSM enabled (verify with `grep landlock /sys/kernel/security/lsm` or Landlock ABI probe).
- **Service Account:** Dedicated non-privileged system user `agentmaxxing-sensor`.
- **Nono Sandbox:** Installed at `/usr/bin/nono` (version `0.73.0`, SHA-256: `71581b92e7683c86276bbbd91c80b059e0fe2d7b1aa95b1176870456ee22ad5c`).
- **Approved Digest:** Verified SHA-256 digest of the AgentMaxxing agent binary.

## 2. Directory Structure Setup

Create dedicated host directories with restricted permissions:

```bash
# Service user and group
sudo useradd -r -s /usr/sbin/nologin -d /var/lib/agentmaxxing -M agentmaxxing-sensor

# Binaries and configuration
sudo mkdir -p /opt/agentmaxxing/{bin,etc,scripts}
sudo mkdir -p /srv/agentmaxxing/input
sudo mkdir -p /var/lib/agentmaxxing/{work,output,audit}
sudo mkdir -p /run/agentmaxxing

# Permissions (least privilege)
sudo chown -R root:root /opt/agentmaxxing
sudo chown -R root:agentmaxxing-sensor /srv/agentmaxxing/input
sudo chown -R agentmaxxing-sensor:agentmaxxing-sensor /var/lib/agentmaxxing
sudo chown -R agentmaxxing-sensor:agentmaxxing-sensor /run/agentmaxxing

sudo chmod 755 /opt/agentmaxxing
sudo chmod 750 /srv/agentmaxxing/input
sudo chmod 700 /var/lib/agentmaxxing/work /var/lib/agentmaxxing/output /var/lib/agentmaxxing/audit
```

## 3. Installation of Scripts & Profile

Deploy the confinement components from `d2-signalloom/apps/agentmaxxing-host-sensor`:

```bash
# Copy scripts and profile
sudo cp d2-signalloom/apps/agentmaxxing-host-sensor/scripts/digest_gate.sh /opt/agentmaxxing/scripts/
sudo cp d2-signalloom/apps/agentmaxxing-host-sensor/scripts/start.sh /opt/agentmaxxing/scripts/
sudo cp d2-signalloom/apps/agentmaxxing-host-sensor/profile.json /opt/agentmaxxing/profile.json

sudo chmod 755 /opt/agentmaxxing/scripts/*.sh
sudo chmod 644 /opt/agentmaxxing/profile.json

# Deploy agent binary and write expected digest
sudo cp /path/to/approved-agent /opt/agentmaxxing/bin/agent
sudo chmod 755 /opt/agentmaxxing/bin/agent
sha256sum /opt/agentmaxxing/bin/agent | sudo tee /opt/agentmaxxing/etc/agent.digest
sudo chmod 644 /opt/agentmaxxing/etc/agent.digest
```

## 4. Systemd Service Installation

Install and activate the hardened service unit:

```bash
# Copy systemd service unit
sudo cp d2-signalloom/apps/agentmaxxing-host-sensor/agentmaxxing-agent.service /etc/systemd/system/

# Reload systemd manager configuration
sudo systemctl daemon-reload

# Enable service to start on boot
sudo systemctl enable agentmaxxing-agent.service

# Start the agent service
sudo systemctl start agentmaxxing-agent.service

# Check service status
sudo systemctl status agentmaxxing-agent.service
```

## 5. Verification & Health Probes

Run the verification probes to ensure confinement and gates operate correctly:

```bash
# 1. Inspect journal logs for preflight verification
sudo journalctl -u agentmaxxing-agent.service -n 50 --no-pager

# 2. Test preflight gate independently
/opt/agentmaxxing/scripts/digest_gate.sh

# 3. Validate nono profile integrity
nono profile validate /opt/agentmaxxing/profile.json
```

## 6. Binary Upgrades & Digest Rotation

When upgrading the AgentMaxxing agent binary:

1. Stop the running service: `sudo systemctl stop agentmaxxing-agent.service`
2. Deploy the new binary: `sudo cp /path/to/new-agent /opt/agentmaxxing/bin/agent`
3. Update the digest file: `sha256sum /opt/agentmaxxing/bin/agent | sudo tee /opt/agentmaxxing/etc/agent.digest`
4. Verify preflight passes: `/opt/agentmaxxing/scripts/digest_gate.sh`
5. Restart the service: `sudo systemctl start agentmaxxing-agent.service`

## 7. Troubleshooting

- **Service fails with `AGENT BINARY DIGEST MISMATCH`:**
  The binary at `/opt/agentmaxxing/bin/agent` has changed without an update to `/opt/agentmaxxing/etc/agent.digest`. Recompute the digest or verify binary integrity.
- **Service fails with `Kernel LSM stack lacks 'landlock'`:**
  Ensure the host kernel supports Landlock and that `landlock` is enabled in kernel boot parameters (`lsm=landlock,...`).
- **Agent fails to write to output directory:**
  Ensure `/var/lib/agentmaxxing/output` is owned by `agentmaxxing-sensor:agentmaxxing-sensor` with mode `0700`.
