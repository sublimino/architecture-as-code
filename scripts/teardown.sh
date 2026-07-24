#!/usr/bin/env bash
# The inverse of setup.sh: tear the demo environment down, and optionally
# remove the tools setup.sh installed. Best-effort throughout — every step
# is guarded so a partially-built environment still cleans up.
#
# Usage:
#   ./scripts/teardown.sh              delete the cluster + local build state
#   ./scripts/teardown.sh --all        also uninstall the CLIs setup.sh added
#   ./scripts/teardown.sh --tools-only only uninstall the CLIs, keep the rest
#
# Note: --all / --tools-only removes these binaries by name regardless of
# whether setup.sh or you installed them. Skip those flags to keep your tools.
set -uo pipefail

cd "$(dirname "$0")/.."

CLUSTER_NAME="${CLUSTER_NAME:-osramp}"
MODE="${1:-env}"

# Mirror setup.sh's install-dir detection so we remove from the same place.
if [ -w /usr/local/bin ]; then
  BIN_DIR="/usr/local/bin"; SUDO=""
elif command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
  BIN_DIR="/usr/local/bin"; SUDO="sudo"
else
  BIN_DIR="${HOME}/.local/bin"; SUDO=""
fi

teardown_env() {
  # 1. Delete the kind cluster (takes every in-cluster workload with it).
  if command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    echo "deleting kind cluster '${CLUSTER_NAME}'"
    kind delete cluster --name "${CLUSTER_NAME}" || true
  else
    echo "kind cluster '${CLUSTER_NAME}' not present"
  fi

  # 2. Remove the images this repo builds and loads into kind.
  if command -v docker >/dev/null 2>&1; then
    echo "removing built demo images"
    docker image rm -f \
      archiver:dev listener:dev processor:dev \
      olly-sentinel:dev olly-elk-mcp:dev olly-stubs:dev >/dev/null 2>&1 || true
  fi

  # 3. Remove generated local state (never any secrets we should keep).
  echo "removing generated local files"
  rm -rf .keys vex/out grypebin grype.zip >/dev/null 2>&1 || true
  # Leftover from the old (fixed) flux install bug, if present.
  rm -rf ./2.6.4 >/dev/null 2>&1 || true
  # Drop the kube context kind created.
  command -v kubectl >/dev/null 2>&1 && \
    kubectl config delete-context "kind-${CLUSTER_NAME}" >/dev/null 2>&1 || true

  echo "environment torn down. (.env is left untouched.)"
}

remove_tools() {
  echo "removing CLIs from ${BIN_DIR}"
  for t in kind kubectl kustomize flux helm cosign jq syft grype witness govulncheck vexctl crane bats; do
    if [ -e "${BIN_DIR}/${t}" ]; then
      echo "  removing ${t}"
      ${SUDO} rm -f "${BIN_DIR}/${t}"
    fi
  done
  # Go is extracted as a whole tree by setup.sh; remove whichever it used.
  for godir in /usr/local/go "${HOME}/.local/go"; do
    if [ -d "${godir}" ]; then
      echo "  removing go (${godir})"
      ${SUDO} rm -rf "${godir}"
    fi
  done
  echo "tools removed."
}

case "${MODE}" in
  --tools-only) remove_tools ;;
  --all)        teardown_env; echo; remove_tools ;;
  env|"")       teardown_env ;;
  *) echo "unknown option ${MODE} (use --all or --tools-only)"; exit 1 ;;
esac
