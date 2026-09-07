# Worktree Landlock Confinement Runbook (CRKC Rule SP-1)

This runbook documents host-level Linux kernel Landlock process confinement for coding agents executing within Git worktrees, implementing **CRKC Rule SP-1**.

## Overview & Threat Model

Autonomous coding agents executing inside ephemeral or dedicated worktrees require access to project files and Git metadata to author changes, run tests, and commit progress. However, granting unconfined execution exposes the host to critical risks:
1. **Host Credential Exfiltration**: Accidental or malicious access to `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config/gcloud`, or `~/.kube/config`.
2. **Uncoordinated Push / Remote Leakage**: Execution of `git push` or arbitrary socket egress to external destinations.
3. **Interactive Pinentry Lockups**: Invocation of `gpg` without `--no-gpg-sign`, stalling non-interactive agent harnesses on unattached TTYs.
4. **Escape Beyond Worktree Boundaries**: Modification of parent repos or sibling workspaces.

Rule SP-1 enforces kernel Landlock LSM access control via `nono` (`nono/profiles/worktree-agent.json`) and the `bin/agent-git` wrapper.

---

## Architectural Confinement Properties

### 1. Filesystem Confinement
- **Allowed Read-Write**:
  - Canonical worktree paths: `~/src/.worktrees/` and `~/.cline/worktrees/`.
  - Parent repository `.git` object store: required for Git commit and object tree generation.
- **Denied Credential Stores**:
  - `~/.ssh/`, `~/.gnupg/`, `~/.aws/`, `~/.config/gcloud/`, `~/.config/gh/`, `~/.kube/config`, `~/.netrc`, `~/.git-credentials`.
- **Environment Scrubbing**:
  - Unsets `SSH_AUTH_SOCK`, `GNUPGHOME`, `GITHUB_TOKEN`, `GH_TOKEN`, and `GIT_ASKPASS`.

### 2. Network Confinement
- **Default Policy**: All outbound network connections are blocked at the Linux kernel layer via Landlock network rules (`network.block = true`).
- **Allowed Local Stack Ports**: Loopback ingress ports required for local testing and estate monitoring (e.g., ports 5001, 5173, 6443, 8080, 8200, 31337).
- **Transport Block**: Attempts to `git push` over HTTPS (443), SSH (22), or Git protocol (9418) fail immediately at `connect(2)` with `EPERM` / `EACCES`.

### 3. Agent Git Wrapper (`bin/agent-git`)
- Intercepts `git commit` to automatically inject `--no-gpg-sign` unless already explicitly provided.
- Refuses `git push` subcommands deterministically with an explicit safety message before invoking the binary.
- Enforces execution within valid worktree roots only.

---

## Verification & Test Harness

### Running the Confinement Harness
Run the 21-probe automated confinement test suite:
```bash
bash scripts/test-worktree-confinement.sh
```
This writes structured evidence to `docs/signalloom/evidence/worktree-confinement-proof.json`.

### Running BATS Tests
Execute the 36-test BATS verification suite:
```bash
bats test/worktree-landlock-confinement.bats
```

---

## Troubleshooting Guide

### 1. Troubleshooting "Permission Denied" on Worktree Path
- **Symptom**: Agent cannot read or write to `/home/andy/src/.worktrees/<id>/`.
- **Cause**: Path is outside the `filesystem.allow` glob or the worktree path contains unresolved symlinks.
- **Troubleshooting Steps**:
  1. Inspect `nono/profiles/worktree-agent.json` under `filesystem.allow`.
  2. Verify the real path using `readlink -f <path>`.
  3. Ensure the parent directory is listed in the profile.

### 2. Troubleshooting GPG Pinentry Hangs
- **Symptom**: `git commit` hangs indefinitely waiting for a GPG passphrase prompt.
- **Cause**: Commit invoked without `--no-gpg-sign` while GPG signing is enabled in Git config.
- **Troubleshooting Steps**:
  1. Ensure `bin/agent-git` is prepended to `PATH`.
  2. Verify that `filesystem.deny` in the profile explicitly blocks `~/.gnupg/` and `/run/user/1000/gnupg/`, which fails GPG immediately instead of hanging.
  3. Run `git commit --no-gpg-sign` directly.

### 3. Troubleshooting Blocked Network Calls
- **Symptom**: Agent receives `connect: permission denied` when attempting to reach an internal service.
- **Cause**: Target port is not present in `network.open_port` list.
- **Troubleshooting Steps**:
  1. Check the destination port using `netstat -tlpn` or `ss -tlpn`.
  2. If the service is a legitimate local foundation component, add the port to `network.open_port` in `nono/profiles/worktree-agent.json`.
  3. External internet hosts must never be allow-listed for agent worktrees.

### 4. Troubleshooting Stale Git Index Locks
- **Symptom**: `fatal: Unable to create .git/index.lock: File exists`.
- **Cause**: Previous agent process crashed or was terminated while holding an index lock.
- **Troubleshooting Steps**:
  1. Check if any process is actively holding the lock: `lsof .git/index.lock`.
  2. If no process is running, safely remove the stale lock file: `rm -f .git/index.lock`.
