#!/usr/bin/env bash
# vm-startup.sh — GCP VM startup script (runs ONCE at initial provisioning).
#
# Installs Docker, Node, bun, uv, Playwright deps, and fetches the deploy
# key. After provisioning, touches /home/ci/.provisioned as a completion
# marker. The actual test pipeline is vm-pipeline.sh, invoked via SSH.

set -euo pipefail

readonly CI_USER="ci"
readonly METADATA_URL="http://metadata.google.internal/computeMetadata/v1"
readonly METADATA_HEADER="Metadata-Flavor: Google"

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

# ── CI user ──────────────────────────────────────────────────────────
useradd -m -s /bin/bash "$CI_USER" 2>/dev/null || true
usermod -aG docker "$CI_USER"

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

# ── Deploy key from Secret Manager ───────────────────────────────────
echo "==> Fetching deploy key..."
secret_name="$(get_metadata secret-name)"
project="$(get_metadata ci-project)"

mkdir -p "/home/${CI_USER}/.ssh"

gcloud secrets versions access latest \
  --secret="$secret_name" \
  --project="$project" \
  > "/home/${CI_USER}/.ssh/deploy_key"

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

# ── Clone repo ───────────────────────────────────────────────────────
echo "==> Cloning osramp-demo..."
sudo -u "$CI_USER" git clone \
  git@github.com:controlplaneio/osramp-demo.git \
  "/home/${CI_USER}/osramp-demo"

# ── Install CI tools (kind, kubectl, flux, helm, cosign, bats, etc.) ─
echo "==> Installing CI tools..."
cd "/home/${CI_USER}/osramp-demo"
sudo -u "$CI_USER" bash ./scripts/setup.sh --tools-only

# ── Mark provisioning complete ───────────────────────────────────────
touch "/home/${CI_USER}/.provisioned"
chown "${CI_USER}:${CI_USER}" "/home/${CI_USER}/.provisioned"

echo "==> Provisioning complete: $(date -Iseconds)"
echo "==> Docker $(docker --version), Node $(node --version), bun $(bun --version 2>/dev/null || echo n/a)"
