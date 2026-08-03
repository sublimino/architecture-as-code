#!/usr/bin/env bats
#
# The installers run on three different privilege shapes: root in a container
# (SUDO=""), an unprivileged user with passwordless sudo (SUDO="sudo" — the CI
# VM), and an unprivileged user without sudo (BIN_DIR falls back to ~/.local/bin).
# Only the container shape gets exercised locally, so a write into /usr/local/bin
# that forgets ${SUDO} passes every local test and then fails on a cold VM.
#
# That is exactly what happened: all three `go install` lines set
# GOBIN="${BIN_DIR}" and ran unprivileged, but only govulncheck ever reached the
# broken path because install-ci-tools.sh prebuilds vexctl and crane first and
# the `have` guard short-circuits them. A warm VM hid it too — govulncheck was
# already on disk from an earlier run. It surfaced only on a genuinely cold VM,
# as `open /usr/local/bin/govulncheck: permission denied`.
#
# These are static assertions over the installer sources. They need no VM, no
# network and no privileges, so they run in the same stage as the other
# contract tests and fail in seconds rather than eleven minutes into a cold run.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SETUP_SH="${REPO_ROOT}/scripts/setup.sh"
  INSTALL_CI="${REPO_ROOT}/scripts/ci/install-ci-tools.sh"
}

@test "setup.sh: no go install targets BIN_DIR directly via GOBIN" {
  # GOBIN="${BIN_DIR}" go install is the precise defect. go install writes the
  # binary itself, so there is no later ${SUDO} mv to rescue it.
  run grep -n 'GOBIN="\${BIN_DIR}"' "${SETUP_SH}"
  [ "$status" -ne 0 ]
}

@test "setup.sh: every go install routes its binary through go_install_bin" {
  # Any bare `go install` reintroduces the bug under a different spelling.
  # Comment lines are stripped first — this file and setup.sh both discuss the
  # defect in prose, and prose is not an installer.
  offenders="$(grep -vE '^[[:space:]]*#' "${SETUP_SH}" \
    | grep -E '(^|[^_])go install ' \
    | grep -v 'GOBIN="${tmp}"' || true)"
  [ -z "$offenders" ]
}

@test "setup.sh: go_install_bin moves into BIN_DIR with SUDO" {
  run grep -q '\${SUDO} mv "\${tmp}/\$1" "\${BIN_DIR}/\$1"' "${SETUP_SH}"
  [ "$status" -eq 0 ]
}

@test "setup.sh: go_install_bin builds into a temporary GOBIN, not BIN_DIR" {
  run grep -q 'GOBIN="\${tmp}" go install' "${SETUP_SH}"
  [ "$status" -eq 0 ]
}

@test "install-ci-tools.sh: every write into BIN is privilege-escalated" {
  # Each line that redirects or extracts into ${BIN} must carry ${SUDO}.
  # curl -o "${BIN}/x" and tar -C "${BIN}" are the two shapes used.
  while IFS= read -r line; do
    case "$line" in
      *'${SUDO}'*) continue ;;
      *) printf 'unprivileged write into BIN: %s\n' "$line" >&2; false ;;
    esac
  done < <(grep -E -- '-o "\$\{BIN\}/|-C "\$\{BIN\}"' "${INSTALL_CI}")
}

@test "install-ci-tools.sh: pinned versions are literal, never latest or a branch" {
  # A pin that resolves to latest/main/HEAD is not a pin. Guard the declared
  # version variables rather than trusting review to notice a drifted value.
  run grep -nE '^[A-Z_]+_VERSION="(latest|main|master|HEAD)"' "${INSTALL_CI}"
  [ "$status" -ne 0 ]

  # Every *_VERSION must look like a semver triple.
  while IFS= read -r line; do
    value="${line#*=\"}"; value="${value%%\"*}"
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  done < <(grep -E '^[A-Z_]+_VERSION="' "${INSTALL_CI}")
}
