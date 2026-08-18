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

# Downloads a file and verifies it against the publisher's own checksum sidecar.
# No checksum literal lives in this script: a pinned hash here goes stale at
# the next version bump and gets deleted rather than updated, which is how
# verification quietly disappears.
#
# The sidecar suffix is an argument because the two publishers disagree:
# dl.k8s.io serves "<artifact>.sha256", the kind releases serve
# "<artifact>.sha256sum". Hardcoding either one 404s on the other, and a 404 on
# the checksum is exactly the case that must abort rather than degrade.
fetch_verified() {
  local url="$1" dest="$2" sum_suffix="${3:-.sha256}" workdir
  workdir="$(mktemp -d)"

  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
    --output "${workdir}/payload" "$url" \
    || die "download failed: ${url}"

  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
    --output "${workdir}/payload.sum" "${url}${sum_suffix}" \
    || die "checksum download failed: ${url}${sum_suffix}"

  # Both publishers emit either "<hash>" or "<hash>  <filename>". Stripping all
  # whitespace and taking the leading 64 hex characters handles both.
  local expected actual
  expected="$(tr -d '[:space:]' <"${workdir}/payload.sum" | cut -c1-64)"
  actual="$(sha256sum "${workdir}/payload" | cut -d' ' -f1)"

  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] \
    || die "checksum sidecar for ${url} did not contain a sha256 digest"

  [[ "$expected" == "$actual" ]] \
    || die "checksum mismatch for ${url}: expected ${expected}, got ${actual}"

  install -m 0755 "${workdir}/payload" "$dest"
  rm -rf "$workdir"
  log "installed ${dest}"
}

# The prerequisites the pipeline cannot bootstrap itself, and nothing more.
#
# Every entry below is needed BEFORE scripts/ci/install-ci-tools.sh can run,
# which is the first thing the pipeline invokes. Each is here because something
# in the repo demonstrably calls it, not because it seemed likely:
#
#   git             install-ci-tools.sh installs bats by `git clone`, and
#                   vm-pipeline.sh runs `git init -q` so Kustomize will resolve
#                   the tree as a repository. Neither can install git first.
#   make            the pipeline drives the demo entirely through make targets
#                   (`make ci-tools`, `make demo-signalloom-up`). A VM with no
#                   make has nothing to run.
#   ca-certificates every fetch below and in the installer is HTTPS.
#   curl            fetch_verified, install-ci-tools.sh, and the Go tarball.
#   gnupg           dearmours the Docker apt key further down.
#   apt-transport-https  the Docker apt source is HTTPS.
#
# Deliberately NOT here: jq, unzip, gcc/g++, python3, node. The first three
# belong to scripts/setup.sh, python3 is apt-installed by install-ci-tools.sh
# itself, and node arrives with the Playwright setup. Adding them would move
# the provisioning/deployment line without moving the responsibility, and this
# script's whole contract is that it stops at prerequisites.
#
# Runs unconditionally rather than inside install_docker. It used to be folded
# into that function, which early-returns when docker is already present — so
# on any image shipping docker, curl and gnupg were silently never installed
# and fetch_verified failed at the first download. The marker file at the top
# of main() is what makes re-running cheap; a second guard inside a function
# only makes it incomplete.
install_base_packages() {
  log "installing base prerequisites"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    ca-certificates curl gnupg apt-transport-https git make
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "docker already present, skipping"
    return 0
  fi

  log "installing docker"
  export DEBIAN_FRONTEND=noninteractive

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
    /usr/local/bin/kind \
    ".sha256sum"
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

# ---------------------------------------------------------------------------
# Docker socket access for OS Login users
#
# ─── The failure, measured on the running VM ───────────────────────────────
#
#   $ systemctl is-active docker   -> active
#   $ id -nG                       -> sa_102755196918063701885 video
#   $ docker info
#   permission denied while trying to connect to the docker API at
#   unix:///var/run/docker.sock
#
# The daemon is up and healthy; the caller simply cannot open the socket.
# scripts/ci/install-ci-tools.sh then exits 1 with "Docker daemon is not
# running" and scripts/setup.sh with "the docker daemon is not running; start
# it and rerun". BOTH MESSAGES ARE WRONG ABOUT THE CAUSE, and someone will act
# on them and restart a daemon that was never down.
#
# ─── Why the obvious fix is dead code here ─────────────────────────────────
#
# scripts/ci/vm-startup.sh (the v1 CI VM) solves this with
# `usermod -aG docker ci`, and that works there because v1 creates a fixed
# local user. This VM enforces OS Login, so the account is provisioned by the
# guest agent AT FIRST LOGIN — strictly later than this script — and its name
# (sa_<numeric-id> for a service account, <user>_<domain> for a human) is not
# knowable at boot. A `usermod` naming a fixed user here would match nobody,
# succeed silently, and be exactly the correct-looking line that guards nothing.
#
# ─── What was rejected, and why ────────────────────────────────────────────
#
# Widening the socket itself (SocketMode=0666 via a docker.socket drop-in, or a
# world-readable ACL) has no user-name problem and no relogin race, and it was
# still rejected. Docker socket access is ROOT-EQUIVALENT: anyone who can write
# that socket can start a privileged container that mounts the host filesystem.
# 0666 grants that to every local account, including any OS Login principal
# granted plain roles/compute.osLogin without sudo. On an environment whose
# entire demonstration subject is security posture, that is the one change a
# hostile reviewer would open with, and it buys only what the two mechanisms
# below already provide.
#
# ─── What is implemented, in order of preference ───────────────────────────
#
#   1. configure_oslogin_groups — tells the guest agent to place newly
#      provisioned OS Login accounts in `docker`. Applied at ACCOUNT CREATION,
#      which happens before the user's first shell, so there is no relogin
#      race and no permission is widened.
#
#   2. install_docker_group_selfheal — a /etc/profile.d snippet that adds the
#      CURRENT user to `docker` if the guest agent did not. This is the
#      backstop, and its limitation is real and stated out loud below: group
#      membership applies to the NEXT session, so a login that had to fall back
#      to this will see the failure once and succeed on reconnect.
#
# Both are idempotent and neither embeds a username.
# ---------------------------------------------------------------------------

configure_oslogin_groups() {
  local cfg="/etc/default/instance_configs.cfg"

  # The guest agent skips groups that do not exist when the account is
  # provisioned, so docker must already be present. install_docker runs first
  # in main(); this ordering is asserted by test/terraform-vm-profile.bats
  # rather than left to whoever next edits main().
  if ! getent group docker >/dev/null 2>&1; then
    log "WARNING: docker group absent; OS Login users will not receive it"
    return 0
  fi

  if [[ -f "$cfg" ]] && grep -qE '^groups[[:space:]]*=.*\bdocker\b' "$cfg"; then
    log "OS Login supplementary groups already include docker"
    return 0
  fi

  # Written whole rather than edited in place. The file is absent on a stock
  # image, and a sed against a file that may not exist is the kind of edit that
  # reports success having changed nothing.
  cat >"$cfg" <<'CFG'
# Managed by the Signal Loom demo VM startup script.
#
# `groups` places newly provisioned OS Login accounts in these supplementary
# groups. docker is the one that matters: without it, every OS Login user gets
# "permission denied ... /var/run/docker.sock" and the CI tooling misreports it
# as a stopped daemon. The rest are the guest agent's own defaults, restated
# because writing this key replaces the default list rather than adding to it.
[Accounts]
groups = adm,dip,docker,lxd,plugdev,video
CFG

  log "configured OS Login supplementary groups to include docker"
}

install_docker_group_selfheal() {
  # The backstop for the case where the guest agent did not apply the group.
  #
  # Honest about its own limitation: usermod changes the account, not the
  # session that is already running, so the membership takes effect on the NEXT
  # login. A first session that had to fall back to this will still fail to
  # reach the socket. It says so on the terminal rather than leaving the user
  # to discover it, because "permission denied" plus silence is what produced
  # the misdiagnosis in the first place.
  #
  # Runs `sudo -n` only — never prompts. An OS Login principal without sudo
  # gets a message naming the exact command an administrator must run, which is
  # strictly better than a socket error naming nothing.
  cat >/etc/profile.d/99-signalloom-docker-group.sh <<'PROFILE'
# shellcheck shell=sh
# Signal Loom: ensure this OS Login user can reach the Docker socket.
# Installed by the demo VM startup script. Idempotent; safe to source twice.
if command -v docker >/dev/null 2>&1 && ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
  if sudo -n usermod -aG docker "$(id -un)" 2>/dev/null; then
    echo "signalloom: added $(id -un) to the docker group."
    echo "signalloom: group membership applies to your NEXT session — reconnect"
    echo "signalloom: before running the pipeline, or docker will report"
    echo "signalloom: 'permission denied ... /var/run/docker.sock' and the CI"
    echo "signalloom: tooling will misreport it as a stopped daemon."
  else
    echo "signalloom: WARNING - $(id -un) is not in the docker group and this"
    echo "signalloom: session cannot add it. The Docker daemon is running; the"
    echo "signalloom: socket is simply unreachable for you. An administrator"
    echo "signalloom: should run: sudo usermod -aG docker $(id -un)"
  fi
fi
PROFILE
  chmod 0644 /etc/profile.d/99-signalloom-docker-group.sh
  log "installed the docker-group self-heal profile snippet"
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

  install_base_packages
  install_docker

  # Both must follow install_docker: the guest agent skips a group that does
  # not exist yet, and the self-heal snippet is pointless without a socket.
  configure_oslogin_groups
  install_docker_group_selfheal

  install_kind
  install_kubectl
  tune_kernel_for_kind

  install -d -m 0755 "$(dirname "$MARKER")"
  date --iso-8601=seconds >"$MARKER"
  log "bootstrap complete"
}

main "$@"
