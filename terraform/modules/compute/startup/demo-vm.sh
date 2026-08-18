#!/usr/bin/env bash
#
# Signal Loom demo VM bootstrap.
#
# Runs once, as root, via metadata_startup_script. Installs the prerequisites
# for the Kind-based Signal Loom demo — Docker, kind, kubectl — and stops. It
# deliberately does NOT deploy the demo: that is the pipeline's job, and a
# startup script that also deploys is a startup script nobody can re-run.
#
# CONTAINS NO CREDENTIALS, BY CONSTRUCTION. The instance authenticates to
# Google APIs through its attached service account via the metadata server.
# Anything this script needs from Secret Manager it fetches at runtime under
# that identity. A literal here would be readable by anyone with
# compute.instances.get on the project, because startup scripts are stored in
# instance metadata in plain text.
#
# Egress note: with the network module's defaults this script CANNOT reach
# download.docker.com or the Kubernetes release servers, because public HTTPS
# egress is denied until an operator names destinations in
# egress_public_https_destinations. That failure is intentional and loud. See
# terraform/modules/network/README.md.

set -euo pipefail

readonly KIND_VERSION="v0.24.0"
readonly LOG_TAG="signalloom-bootstrap"
readonly MARKER="/var/lib/signalloom/.bootstrapped"

log() {
  echo "[${LOG_TAG}] $*"
  logger -t "$LOG_TAG" -- "$*" || true
}

die() {
  log "FATAL: $*"
  exit 1
}

# Downloads a file and verifies it against the publisher's own .sha256 sidecar.
# No checksum literal lives in this script: a pinned hash here goes stale at
# the next version bump and gets deleted rather than updated, which is how
# verification quietly disappears.
fetch_verified() {
  local url="$1" dest="$2" workdir
  workdir="$(mktemp -d)"

  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
    --output "${workdir}/payload" "$url" \
    || die "download failed: ${url}"

  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
    --output "${workdir}/payload.sha256" "${url}.sha256" \
    || die "checksum download failed: ${url}.sha256"

  local expected actual
  expected="$(tr -d '[:space:]' <"${workdir}/payload.sha256" | cut -c1-64)"
  actual="$(sha256sum "${workdir}/payload" | cut -d' ' -f1)"

  [[ "$expected" == "$actual" ]] \
    || die "checksum mismatch for ${url}: expected ${expected}, got ${actual}"

  install -m 0755 "${workdir}/payload" "$dest"
  rm -rf "$workdir"
  log "installed ${dest}"
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "docker already present, skipping"
    return 0
  fi

  log "installing docker"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    ca-certificates curl gnupg apt-transport-https

  install -m 0755 -d /etc/apt/keyrings
  curl --fail --silent --show-error --location \
    https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  local codename
  # shellcheck source=/dev/null  # provided by the base image, not by this repo
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${codename} stable" \
    >/etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
}

install_kind() {
  if command -v kind >/dev/null 2>&1; then
    log "kind already present, skipping"
    return 0
  fi
  log "installing kind ${KIND_VERSION}"
  fetch_verified \
    "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64" \
    /usr/local/bin/kind
}

install_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    log "kubectl already present, skipping"
    return 0
  fi

  local version
  version="$(curl --fail --silent --show-error --location \
    https://dl.k8s.io/release/stable.txt)" \
    || die "could not resolve the stable kubectl version"

  log "installing kubectl ${version}"
  fetch_verified \
    "https://dl.k8s.io/release/${version}/bin/linux/amd64/kubectl" \
    /usr/local/bin/kubectl
}

# Kind's control plane needs more inotify capacity than the Debian default
# allows once several Signal Loom components are running.
tune_kernel_for_kind() {
  log "raising inotify limits for kind"
  cat >/etc/sysctl.d/99-signalloom-kind.conf <<'SYSCTL'
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
SYSCTL
  sysctl --system >/dev/null
}

main() {
  if [[ -f "$MARKER" ]]; then
    log "already bootstrapped, nothing to do"
    return 0
  fi

  [[ "$(id -u)" -eq 0 ]] || die "must run as root"

  install_docker
  install_kind
  install_kubectl
  tune_kernel_for_kind

  install -d -m 0755 "$(dirname "$MARKER")"
  date --iso-8601=seconds >"$MARKER"
  log "bootstrap complete"
}

main "$@"
