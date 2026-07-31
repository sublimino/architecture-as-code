#!/usr/bin/env bash
# vm-startup.sh — GCP VM startup script (runs ONCE at initial provisioning).
#
# Installs Docker, Node, bun, uv, Playwright deps, and fetches the deploy
# key. After provisioning, touches /home/ci/.provisioned as a completion
# marker. The actual test pipeline is vm-pipeline.sh, invoked via SSH.

set -eo pipefail

readonly CI_USER="ci"
readonly METADATA_URL="http://metadata.google.internal/computeMetadata/v1"
readonly METADATA_HEADER="Metadata-Flavor: Google"

export HOME="${HOME:-/root}"
exec > >(tee -a /var/log/ci-startup.log) 2>&1

get_metadata() {
  curl -sf -H "$METADATA_HEADER" "${METADATA_URL}/instance/attributes/$1"
}

echo "==> Signalloom CI VM — initial provisioning"
echo "==> Started: $(date -Iseconds)"

export DEBIAN_FRONTEND=noninteractive

# ── System packages ──────────────────────────────────────────────────
apt-get update -qq
apt-get install -yqq \
  ca-certificates curl gnupg lsb-release git jq unzip \
  python3 python3-pip python3-venv make gcc g++

# ── Docker CE ────────────────────────────────────────────────────────
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -yqq \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin

systemctl enable --now docker

# ── CI user (with passwordless sudo for tool installers) ─────────────
useradd -m -s /bin/bash "$CI_USER" 2>/dev/null || true
usermod -aG docker "$CI_USER"
echo "${CI_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${CI_USER}"
chmod 440 "/etc/sudoers.d/${CI_USER}"

# ── Node.js 22 ───────────────────────────────────────────────────────
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -yqq nodejs

# ── Playwright Chromium deps ─────────────────────────────────────────
npx playwright install-deps chromium 2>/dev/null || true

# ── uv (Python package manager) ─────────────────────────────────────
curl -LsSf https://astral.sh/uv/install.sh | sh
cp /root/.local/bin/uv /usr/local/bin/uv 2>/dev/null || true

# ── bun ──────────────────────────────────────────────────────────────
curl -fsSL https://bun.sh/install | bash
cp /root/.bun/bin/bun /usr/local/bin/bun 2>/dev/null || true
ln -sf /usr/local/bin/bun /usr/local/bin/bunx 2>/dev/null || true

# ── Deploy key from Secret Manager (non-fatal — code can be SCP'd) ───
echo "==> Fetching deploy key..."
if secret_name="$(get_metadata secret-name 2>/dev/null)" && \
   project="$(get_metadata ci-project 2>/dev/null)"; then

  mkdir -p "/home/${CI_USER}/.ssh"

  if gcloud secrets versions access latest \
    --secret="$secret_name" \
    --project="$project" \
    > "/home/${CI_USER}/.ssh/deploy_key" 2>/dev/null; then

    chmod 600 "/home/${CI_USER}/.ssh/deploy_key"

    cat > "/home/${CI_USER}/.ssh/config" <<'SSHEOF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/deploy_key
  StrictHostKeyChecking accept-new
SSHEOF

    chmod 600 "/home/${CI_USER}/.ssh/config"
    chown -R "${CI_USER}:${CI_USER}" "/home/${CI_USER}/.ssh"
    echo "==> Deploy key fetched"
  else
    echo "WARNING: Could not fetch deploy key from Secret Manager — SCP code manually"
  fi
else
  echo "WARNING: No secret-name/ci-project metadata — SCP code manually"
fi

# ── Clone repo (non-fatal — code can be SCP'd after boot) ────────────
if [[ -f "/home/${CI_USER}/.ssh/deploy_key" ]]; then
  echo "==> Cloning osramp-demo..."
  sudo -u "$CI_USER" git clone \
    git@github.com:controlplaneio/osramp-demo.git \
    "/home/${CI_USER}/osramp-demo" 2>/dev/null || {
      echo "WARNING: Clone failed — push code via SCP after boot"
    }
else
  echo "==> Skipping clone (no deploy key) — push code via SCP after boot"
fi

# ── Install CI tools if repo is present ──────────────────────────────
if [[ -d "/home/${CI_USER}/osramp-demo/scripts" ]]; then
  echo "==> Installing CI tools..."
  cd "/home/${CI_USER}/osramp-demo"
  sudo -u "$CI_USER" bash ./scripts/setup.sh --tools-only || {
    echo "WARNING: Tools install failed — will retry on first pipeline run"
  }
else
  echo "==> Skipping tools install (no repo yet)"
fi

# ── Mark provisioning complete ───────────────────────────────────────
touch "/home/${CI_USER}/.provisioned"
chown "${CI_USER}:${CI_USER}" "/home/${CI_USER}/.provisioned"

echo "==> Provisioning complete: $(date -Iseconds)"
echo "==> Docker $(docker --version), Node $(node --version), bun $(bun --version 2>/dev/null || echo n/a)"
