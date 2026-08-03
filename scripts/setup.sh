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
KUSTOMIZE_VERSION="v5.8.1"   # install-ci-tools.sh installs 5.8.1 first; this said 5.6.0 and never applied
FLUX_VERSION="2.6.4"
HELM_VERSION="v3.18.4"
COSIGN_VERSION="v3.0.6"
SYFT_VERSION="v1.28.0"
SYFT_SHA256="3edee7fe1ceb1f78360e547f57048930d57f00c7ec3d0b8bdfb902805f048468"
GRYPE_VERSION="v0.95.0"
GRYPE_SHA256="82f22c660dcc0b49a9b45ec060a8d0f7b7fb75b33aecf6cc08060062bbf012ce"
GO_VERSION="1.24.5"   # install-ci-tools.sh installs 1.24.5 first; this said 1.23.10 and never applied
GOVULNCHECK_VERSION="v1.1.4"
VEXCTL_VERSION="v0.3.0"
WITNESS_VERSION="0.9.1"   # tarball naming omits the v; see the install block below
BATS_VERSION="v1.14.0"   # install-ci-tools.sh installs 1.14.0 first; this said 1.11.0 and never applied

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

# go install writes the linked binary straight into GOBIN, so pointing GOBIN at
# ${BIN_DIR} skips the ${SUDO} that every other installer here routes its final
# write through. On the non-root-with-sudo branch above — which is exactly the
# CI VM — that is an unprivileged write into /usr/local/bin and it fails with
# `permission denied`. Running `go install` under sudo is not the fix: sudo
# drops GOPATH/GOCACHE and go is often absent from root's PATH. Build into a
# throwaway GOBIN, then move with the same escalation fetch_bin uses.
# Anchore release tarball, verified before it is unpacked. The checksum is
# checked while the download is still an opaque blob, so a mismatch aborts
# before tar ever reads it, and nothing downloaded is ever executed. Only the
# final install into ${BIN_DIR} escalates.
# Fail-closed by construction, not by relying on `set -e` — errexit is
# disabled inside a function called in a tested context, and this one is
# (`have syft || anchore_bin ...`). See install-ci-tools.sh for the tamper
# test that caught the earlier version returning success on a bad hash.
anchore_bin() { # name version sha256
  echo "installing $1 $2"
  local tmp rc=0
  tmp="$(mktemp -d)"
  curl -fsSL -o "${tmp}/$1.tar.gz" \
    "https://github.com/anchore/$1/releases/download/v$2/$1_$2_${OS}_${ARCH}.tar.gz" \
    && echo "$3  ${tmp}/$1.tar.gz" | sha256sum -c --status - \
    && tar -C "${tmp}" -xzf "${tmp}/$1.tar.gz" "$1" \
    && ${SUDO} install -m 0755 "${tmp}/$1" "${BIN_DIR}/$1" \
    || rc=1
  rm -rf "${tmp}"
  [ "$rc" -eq 0 ] || echo "ERROR: $1 $2 failed verification or install; refusing to continue" >&2
  return "$rc"
}
go_install_bin() { # name package@version
  local tmp
  tmp="$(mktemp -d)"
  GOBIN="${tmp}" go install "$2" && ${SUDO} mv "${tmp}/$1" "${BIN_DIR}/$1"
  local rc=$?
  rm -rf "${tmp}"
  return $rc
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
  # Both piped raw.githubusercontent.com/anchore/<tool>/main/install.sh into
  # `sudo sh`. The version was pinned; the installer was not — `main` is a
  # moving branch head, so the program running as root differed run to run
  # with nothing recording which one. The pinned version is no defence: it is
  # an ARGUMENT to an unpinned program, and the program holds the privileges.
  # Same defect the witness pin below fixed, and worse for running as root.
  # See install-ci-tools.sh for the full reasoning and the pinned checksums.
  have syft || anchore_bin syft "${SYFT_VERSION#v}" "${SYFT_SHA256}"
  have grype || anchore_bin grype "${GRYPE_VERSION#v}" "${GRYPE_SHA256}"
  # Pinned tarball, not the install script off `main`.
  #
  # This was the only tool in either installer with NO version: it piped
  # install-witness.sh from the main branch, so what CI got depended on when it
  # ran. For a supply-chain attestation tool that is the wrong tool to leave
  # floating, and it makes a green run unreproducible by construction.
  have witness || {
    echo "installing witness ${WITNESS_VERSION}"
    curl -fsSL "https://github.com/in-toto/witness/releases/download/v${WITNESS_VERSION}/witness_${WITNESS_VERSION}_${OS}_${ARCH}.tar.gz" \
      | ${SUDO} tar -xzf - -C "${BIN_DIR}" witness
    ${SUDO} chmod +x "${BIN_DIR}/witness"
  }

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

  # skopeo publishes no upstream release binaries, so it is the one tool here
  # that must come from the platform package manager rather than fetch_bin.
  # Required by scripts/build-sign-dashboard.sh, which make signalloom-images
  # invokes. Note the deliberate PKG_SUDO: the ${SUDO} above means "needed to
  # write to BIN_DIR" and is empty whenever /usr/local/bin happens to be
  # writable (which is exactly what vm-pipeline.sh arranges before calling
  # this script), whereas a package install always needs real root.
  have skopeo || {
    echo "installing skopeo"
    PKG_SUDO=""; [ "$(id -u)" -eq 0 ] || PKG_SUDO="sudo"
    if have apt-get; then
      ${PKG_SUDO} apt-get update -qq && ${PKG_SUDO} apt-get install -y -qq skopeo
    elif have dnf; then
      ${PKG_SUDO} dnf install -y skopeo
    elif have brew; then
      brew install skopeo
    else
      echo "skopeo is required but no supported package manager was found." >&2
      echo "Install it manually: https://github.com/containers/skopeo/blob/main/install.md" >&2
      exit 1
    fi
  }

  have yq || { echo "installing yq"; fetch_bin yq "https://github.com/mikefarah/yq/releases/download/v4.44.6/yq_${OS}_${ARCH}"; }
  have govulncheck || { echo "installing govulncheck"; go_install_bin govulncheck "golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION}"; }
  have vexctl || { echo "installing vexctl"; go_install_bin vexctl "github.com/openvex/vexctl@${VEXCTL_VERSION}"; }
  have crane || { echo "installing crane"; go_install_bin crane "github.com/google/go-containerregistry/cmd/crane@v0.20.3"; }

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
  for tool in kind kubectl kustomize flux helm cosign jq yq skopeo syft grype witness govulncheck vexctl bats go; do
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
