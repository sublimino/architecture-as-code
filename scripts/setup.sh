#!/usr/bin/env bash
# One-shot setup for the OSRAMP demo: installs every required tool (skipping
# anything already present), then creates the shared local foundation. The
# e2e-local GitHub Actions workflow runs this same script, so local and CI
# setup cannot drift.
#
# Usage:
#   ./scripts/setup.sh                install missing tools, then `make up`
#   ./scripts/setup.sh --tools-only   install missing tools and stop
#   ./scripts/setup.sh --up-only      skip installs, create the shared foundation
#
# Linux and macOS (WSL2 on Windows). Docker must already be installed and
# running; everything else is handled here.
set -euo pipefail

cd "$(dirname "$0")/.."

MODE="${1:-all}"

KIND_VERSION="v0.29.0"
KUBECTL_VERSION="v1.33.2"
KUSTOMIZE_VERSION="v5.6.0"
FLUX_VERSION="2.6.4"
HELM_VERSION="v3.18.4"
COSIGN_VERSION="v2.5.3"
SYFT_VERSION="v1.28.0"
GRYPE_VERSION="v0.95.0"
GO_VERSION="1.23.10"
GOVULNCHECK_VERSION="v1.1.4"
VEXCTL_VERSION="v0.3.0"
BATS_VERSION="v1.11.0"

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m); case "${ARCH}" in x86_64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; esac

if [ -w /usr/local/bin ]; then
  BIN_DIR="/usr/local/bin"; SUDO=""
elif command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
  BIN_DIR="/usr/local/bin"; SUDO="sudo"
else
  BIN_DIR="${HOME}/.local/bin"; SUDO=""
  mkdir -p "${BIN_DIR}"
  case ":${PATH}:" in *":${BIN_DIR}:"*) ;; *) export PATH="${BIN_DIR}:${PATH}"
    echo "note: add ${BIN_DIR} to your PATH permanently" ;; esac
fi

have() { command -v "$1" >/dev/null 2>&1; }
fetch_bin() { # name url
  echo "installing $1"
  curl -fsSL "$2" -o "/tmp/$1" && chmod +x "/tmp/$1" && ${SUDO} mv "/tmp/$1" "${BIN_DIR}/$1"
}

install_tools() {
  have docker || { echo "docker is required and must be installed first"; exit 1; }
  docker info >/dev/null 2>&1 || { echo "the docker daemon is not running; start it and rerun"; exit 1; }

  have kind || fetch_bin kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}"
  have kubectl || fetch_bin kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl"
  have jq || fetch_bin jq "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-${OS}-${ARCH}"

  if ! have kustomize; then
    echo "installing kustomize"
    curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_${OS}_${ARCH}.tar.gz" \
      | tar -xz -C /tmp kustomize && ${SUDO} mv /tmp/kustomize "${BIN_DIR}/kustomize"
  fi

  if ! have helm; then
    echo "installing helm"
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-${OS}-${ARCH}.tar.gz" \
      | tar -xz -C /tmp "${OS}-${ARCH}/helm" && ${SUDO} mv "/tmp/${OS}-${ARCH}/helm" "${BIN_DIR}/helm"
  fi

  if ! have flux; then
    echo "installing flux ${FLUX_VERSION}"
    curl -fsSL "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_${OS}_${ARCH}.tar.gz" \
      | tar -xz -C /tmp flux && ${SUDO} mv /tmp/flux "${BIN_DIR}/flux"
  fi
  have cosign || fetch_bin cosign "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-${OS}-${ARCH}"
  have syft || { echo "installing syft"; curl -fsSL https://raw.githubusercontent.com/anchore/syft/main/install.sh | ${SUDO} sh -s -- -b "${BIN_DIR}" "${SYFT_VERSION}"; }
  have grype || { echo "installing grype"; curl -fsSL https://raw.githubusercontent.com/anchore/grype/main/install.sh | ${SUDO} sh -s -- -b "${BIN_DIR}" "${GRYPE_VERSION}"; }
  have witness || { echo "installing witness"; curl -fsSL https://raw.githubusercontent.com/in-toto/witness/main/install-witness.sh | INSTALL_DIR="${BIN_DIR}" ${SUDO} bash; }

  if ! have go; then
    echo "installing go ${GO_VERSION}"
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.${OS}-${ARCH}.tar.gz" -o /tmp/go.tar.gz
    ${SUDO} rm -rf /usr/local/go 2>/dev/null || rm -rf "${HOME}/.local/go"
    if [ -n "${SUDO}" ] || [ -w /usr/local ]; then
      ${SUDO} tar -C /usr/local -xzf /tmp/go.tar.gz
      export PATH="/usr/local/go/bin:${PATH}"
    else
      tar -C "${HOME}/.local" -xzf /tmp/go.tar.gz
      export PATH="${HOME}/.local/go/bin:${PATH}"
    fi
  fi

  have govulncheck || { echo "installing govulncheck"; GOBIN="${BIN_DIR}" go install "golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION}"; }
  have vexctl || { echo "installing vexctl"; GOBIN="${BIN_DIR}" go install "github.com/openvex/vexctl@${VEXCTL_VERSION}"; }
  have crane || { echo "installing crane"; GOBIN="${BIN_DIR}" go install "github.com/google/go-containerregistry/cmd/crane@v0.20.3"; }

  if ! have bats; then
    echo "installing bats"
    curl -fsSL "https://github.com/bats-core/bats-core/archive/refs/tags/${BATS_VERSION}.tar.gz" | tar -xz -C /tmp
    if [ -n "${SUDO}" ] || [ -w /usr/local ]; then
      ${SUDO} bash "/tmp/bats-core-${BATS_VERSION#v}/install.sh" /usr/local
    else
      bash "/tmp/bats-core-${BATS_VERSION#v}/install.sh" "${HOME}/.local"
    fi
  fi

  echo
  echo "tool versions:"
  for tool in kind kubectl kustomize flux helm cosign jq syft grype witness govulncheck vexctl bats go; do
    printf '  %-12s %s\n' "${tool}" "$(command -v ${tool} >/dev/null && ${tool} version --short 2>/dev/null | head -1 || command -v ${tool} || echo MISSING)"
  done
}

case "${MODE}" in
  --tools-only) install_tools ;;
  --up-only) make up ;;
  all|"")
    install_tools
    echo
    echo "=== creating the shared cluster foundation"
    make up
    echo
    echo "shared cluster healthy. No demos are running. Next steps:"
    echo "  make demo-signalloom-up   start the Signalloom demo"
    echo "  make demo-osramp-up       start the OSRAMP demo"
    echo "  make demo-olly-up         start the olly demo"
    echo "  make test                 OSRAMP end-to-end suite after demo-osramp-up"
    echo "  make vex-demo    Phase 1 VEX triage"
    echo "  make console     the interactive map at http://localhost:8675"
    ;;
  *) echo "unknown option ${MODE}"; exit 1 ;;
esac
