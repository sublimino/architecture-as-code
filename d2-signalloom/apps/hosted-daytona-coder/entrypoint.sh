#!/usr/bin/env bash
# Entrypoint for Daytona devcontainer workspace pods.
#
# Sets up the Git workspace, configures SSH access, and starts
# VS Code Server for the human pairing session.
set -euo pipefail

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
GIT_BRANCH="${GIT_BRANCH:-main}"
SSH_PORT="${SSH_PORT:-2222}"

echo "[daytona-workspace] Starting workspace setup..."
echo "[daytona-workspace] Workspace: ${WORKSPACE_DIR}"
echo "[daytona-workspace] Branch: ${GIT_BRANCH}"

# Ensure workspace directory exists (PVC mount).
mkdir -p "${WORKSPACE_DIR}"

# Configure Git for the workspace.
if [ -d "${WORKSPACE_DIR}/.git" ]; then
    echo "[daytona-workspace] Existing Git repo found, checking out ${GIT_BRANCH}..."
    cd "${WORKSPACE_DIR}"
    git fetch --all --prune 2>/dev/null || true
    git checkout "${GIT_BRANCH}" 2>/dev/null || echo "[daytona-workspace] Branch ${GIT_BRANCH} not found, staying on current branch."
else
    echo "[daytona-workspace] No Git repo found in workspace; ready for clone."
fi

# Configure SSH server for remote access.
mkdir -p /home/vscode/.ssh
if [ -n "${SSH_AUTHORIZED_KEYS:-}" ]; then
    echo "${SSH_AUTHORIZED_KEYS}" > /home/vscode/.ssh/authorized_keys
    chmod 600 /home/vscode/.ssh/authorized_keys
fi

echo "[daytona-workspace] Setup complete."
echo "[daytona-workspace] SSH: port ${SSH_PORT}"
echo "[daytona-workspace] VS Code Server: port 8443"
echo "[daytona-workspace] Web Terminal: port 8443/terminal"

# Start VS Code Server (or fall back to sleep for the demo).
if command -v code-server >/dev/null 2>&1; then
    exec code-server \
        --bind-addr "0.0.0.0:8443" \
        --auth none \
        --disable-telemetry \
        "${WORKSPACE_DIR}"
else
    echo "[daytona-workspace] code-server not found; keeping container alive for SSH access."
    exec sleep infinity
fi
