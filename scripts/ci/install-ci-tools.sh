#!/usr/bin/env bash
# install-ci-tools.sh — Idempotent, version-pinned tool installer for CI VMs.
#
# Pre-built binaries where available (no go install, no compile on the VM).
# Every tool is version-gated: re-running is a no-op when versions match.
#
# Called by vm-pipeline.sh immediately before `setup.sh --tools-only`, and
# standalone via `make ci-tools`. This installer is a COMPLEMENT to setup.sh,
# not a replacement: it does not install skopeo, witness, yq, govulncheck,
# vexctl or jq, all of which setup.sh does and the pipeline needs. Running it
# first means setup.sh's `have <tool>` guards no-op for everything already
# placed here, so the tools this file can fetch as pinned pre-built binaries
# never reach setup.sh's `go install` (compile-on-VM) path.
set -euo pipefail

BIN="/usr/local/bin"
OS="linux"
ARCH="amd64"

# Two distinct privilege questions, and conflating them is a live trap (the
# same one setup.sh documents around skopeo). SUDO answers "can I write to
# ${BIN}?" — it is empty whenever ${BIN} is already writable, which is exactly
# what vm-pipeline.sh arranges with `chmod a+w` before calling this. PKG_SUDO
# answers "am I root?", which is what apt-get and any write outside ${BIN}
# (bats installs into /usr/local/{bin,lib,libexec}) actually require.
SUDO=""
[ -w "${BIN}" ] || SUDO="sudo"
PKG_SUDO=""
[ "$(id -u)" -eq 0 ] || PKG_SUDO="sudo"

log() { printf '\033[1;36m[ci-tools]\033[0m %s\n' "$*"; }

# ── Docker (must be pre-installed by the VM image) ────────────────────
if ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
  log "ERROR: Docker daemon is not running"
  log "Start with: sudo systemctl start docker"
  exit 1
fi

# ── Go 1.24.5 ────────────────────────────────────────────────────────
GO_VERSION="1.24.5"
if ! go version 2>/dev/null | grep -q "go${GO_VERSION}"; then
  log "installing Go ${GO_VERSION}"
  # Untarring over an existing /usr/local/go leaves the previous toolchain's
  # stale files behind (upstream's own install docs require the rm first).
  # Reachable here: setup.sh pins Go 1.23.10, so a VM provisioned before this
  # installer existed has 1.23.10 on disk when 1.24.5 lands on top.
  ${PKG_SUDO} rm -rf /usr/local/go
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | ${PKG_SUDO} tar -C /usr/local -xzf -
fi
export PATH="/usr/local/go/bin:${PATH}"

# ── kind 0.29.0 ──────────────────────────────────────────────────────
KIND_VERSION="0.29.0"
if ! kind version 2>/dev/null | grep -q "${KIND_VERSION}"; then
  log "installing kind ${KIND_VERSION}"
  ${SUDO} curl -fsSL -o "${BIN}/kind" "https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/kind-${OS}-${ARCH}"
  ${SUDO} chmod +x "${BIN}/kind"
fi

# ── kubectl (matches kind node image) ────────────────────────────────
KUBECTL_VERSION="1.33.2"
if ! kubectl version --client 2>/dev/null | grep -q "v${KUBECTL_VERSION}"; then
  log "installing kubectl ${KUBECTL_VERSION}"
  ${SUDO} curl -fsSL -o "${BIN}/kubectl" "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl"
  ${SUDO} chmod +x "${BIN}/kubectl"
fi

# ── kustomize 5.8.1 ──────────────────────────────────────────────────
KUSTOMIZE_VERSION="5.8.1"
if ! kustomize version 2>/dev/null | grep -q "${KUSTOMIZE_VERSION}"; then
  log "installing kustomize ${KUSTOMIZE_VERSION}"
  ${SUDO} rm -f "${BIN}/kustomize"
  curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_${OS}_${ARCH}.tar.gz" | ${SUDO} tar -xzf - -C "${BIN}" kustomize
  ${SUDO} chmod +x "${BIN}/kustomize"
fi

# ── helm 3.18.4 (must match setup.sh's HELM_VERSION) ─────────────────
# Wiring this installer in makes its pins live for the first time, and this one
# was the only pin that moved BACKWARDS: setup.sh installs 3.18.4, so a 3.17.3
# pin here would silently downgrade helm on every existing CI VM. The other
# disagreements are forward (go 1.23.10→1.24.5, kustomize 5.6.0→5.8.1, bats
# 1.11.0→1.14.0) and are the intended newer pins.
HELM_VERSION="3.18.4"
if ! helm version 2>/dev/null | grep -q "v${HELM_VERSION}"; then
  log "installing helm ${HELM_VERSION}"
  ${SUDO} rm -f "${BIN}/helm"
  curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-${OS}-${ARCH}.tar.gz" | ${SUDO} tar -xzf - --strip-components=1 -C "${BIN}" "${OS}-${ARCH}/helm"
  ${SUDO} chmod +x "${BIN}/helm"
fi

# ── flux 2.6.4 ───────────────────────────────────────────────────────
FLUX_VERSION="2.6.4"
if ! flux version --client 2>/dev/null | grep -q "${FLUX_VERSION}"; then
  log "installing flux ${FLUX_VERSION}"
  ${SUDO} rm -f "${BIN}/flux"
  curl -fsSL "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_${OS}_${ARCH}.tar.gz" | ${SUDO} tar -xzf - -C "${BIN}" flux
  ${SUDO} chmod +x "${BIN}/flux"
fi

# ── crane 0.20.3 ─────────────────────────────────────────────────────
CRANE_VERSION="0.20.3"
if ! crane version 2>/dev/null | grep -q "${CRANE_VERSION}"; then
  log "installing crane ${CRANE_VERSION}"
  ${SUDO} rm -f "${BIN}/crane"
  curl -fsSL "https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz" | ${SUDO} tar -xzf - -C "${BIN}" crane
  ${SUDO} chmod +x "${BIN}/crane"
fi

# ── cosign 3.0.6 (matches local dev; needs --use-signing-config + --registry-referrers-mode)
COSIGN_VERSION="3.0.6"
if ! cosign version 2>/dev/null | grep -q "v${COSIGN_VERSION}"; then
  log "installing cosign ${COSIGN_VERSION}"
  ${SUDO} curl -fsSL -o "${BIN}/cosign" "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-${OS}-${ARCH}"
  ${SUDO} chmod +x "${BIN}/cosign"
fi

# ── syft 1.28.0 ──────────────────────────────────────────────────────
SYFT_VERSION="1.28.0"
if ! syft version 2>/dev/null | grep -q "${SYFT_VERSION}"; then
  log "installing syft ${SYFT_VERSION}"
  curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | ${SUDO} sh -s -- -b "${BIN}" "v${SYFT_VERSION}"
fi

# ── grype 0.95.0 ─────────────────────────────────────────────────────
GRYPE_VERSION="0.95.0"
if ! grype version 2>/dev/null | grep -q "${GRYPE_VERSION}"; then
  log "installing grype ${GRYPE_VERSION}"
  curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | ${SUDO} sh -s -- -b "${BIN}" "v${GRYPE_VERSION}"
fi

# ── bats 1.14.0 ──────────────────────────────────────────────────────
BATS_VERSION="1.14.0"
if ! bats --version 2>/dev/null | grep -q "${BATS_VERSION}"; then
  log "installing bats ${BATS_VERSION}"
  tmp="$(mktemp -d)"
  git clone --depth 1 --branch "v${BATS_VERSION}" https://github.com/bats-core/bats-core.git "${tmp}/bats" 2>/dev/null
  ${PKG_SUDO} "${tmp}/bats/install.sh" /usr/local
  rm -rf "${tmp}"
fi

# ── python3 (for compliance scan) ────────────────────────────────────
if ! python3 --version >/dev/null 2>&1; then
  log "installing python3"
  ${PKG_SUDO} apt-get update -qq && ${PKG_SUDO} apt-get install -y -qq python3 >/dev/null
fi

# ── Summary ──────────────────────────────────────────────────────────
log "all tools installed:"
for t in go kind kubectl kustomize helm flux crane cosign syft grype bats python3 docker; do
  # head -1 must sit outside the || chain. Inside it, `head` supplies the
  # pipeline's exit status under `pipefail`, so a tool that prints a version to
  # stdout and *then* exits non-zero (kubectl version, which also tries to
  # reach a cluster) both reports its version and falls through to `echo "?"`,
  # appending a spurious "?" line for a tool that installed perfectly.
  ver=$($t version 2>/dev/null || $t --version 2>/dev/null || echo "?")
  printf "  %-12s %s\n" "$t" "$(printf '%s' "$ver" | head -1)"
done
