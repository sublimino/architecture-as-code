#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared sandbox builder for the VM state contract gate.
#
# IN test/helpers/, NOT test/lib/. A bare `lib` entry in ~/.gitignore_global
# matches ANY directory called lib at any depth, so a helper written to
# test/lib/ works locally and is silently never committed. That has already cost
# this repo a shared helper once.
#
# ── What this exists to make possible ───────────────────────────────────────
#
# The gate asserts facts about a VM. The whole point of the gate is that those
# facts CANNOT be read from source. So the suite cannot test it by reading it
# either — it has to RUN it, against a machine whose state the test controls.
#
# That machine is a mktemp directory. Every boundary the gate touches is an
# injectable environment variable for exactly this reason, so the suite can
# build a filesystem where /usr/local/bin is unwritable, docker is broken, or
# kind is the wrong version, and watch the real gate react. No VM, no network,
# no privileges, and each case is a two-line mutation of a known-good sandbox.
#
# The alternative — asserting that the gate's SOURCE contains the right greps —
# is the mistake that produced this whole task. test/ci-installer-privileges.bats
# is a well-written suite of exactly that shape and it did not stop the bug,
# because the fact that decides the outcome is not in the source.

# Build a sandbox in which every fact passes. Sets VMSC_* in the caller's
# environment and exports a PATH whose stubs shadow any real tool.
vmsc_sandbox() { # root_dir
  local root="$1"

  mkdir -p "${root}/bin" "${root}/work/reports" "${root}/stub" \
    "${root}/repo/terraform/modules/compute/startup"

  # The pin source. Carries the SAME prose trap the real demo-vm.sh carries:
  # the literal v0.24.0 inside a comment, above the real pin. A pin extractor
  # that is not line-anchored reads that comment and asserts the version the
  # gate exists to reject, so every sandbox reproduces the hazard by default
  # rather than only in the one test that remembers to add it.
  cat >"${root}/repo/terraform/modules/compute/startup/demo-vm.sh" <<'PINEOF'
#!/usr/bin/env bash
# kind was pinned here at v0.24.0 while install-ci-tools.sh pinned 0.29.0 and
# the pipeline required it. KUBECTL_VERSION="v9.9.9" also appears in prose here.
readonly KIND_VERSION="v0.29.0"
readonly KUBECTL_VERSION="v1.33.2"
PINEOF

  vmsc_stub kind "kind version 0.29.0"
  vmsc_stub kubectl "Client Version: v1.33.2"
  vmsc_stub node "v22.23.2"
  vmsc_stub bun "1.3.14"
  vmsc_stub uv "uv 0.12.5"
  vmsc_stub docker "Server Version: 27.0.0"

  export VMSC_BIN_DIR="${root}/bin"
  export VMSC_WORK_ROOT="${root}/work"
  export VMSC_REPORT_DIR="${root}/work/reports"
  export VMSC_PIN_FILE="${root}/repo/terraform/modules/compute/startup/demo-vm.sh"
  # `true` stands in for passwordless sudo being available. Injected rather than
  # probed so the suite never depends on the developer's own sudoers.
  export VMSC_SUDO_PROBE="true"

  # ── The gate's PATH is HERMETIC, and this is not fussiness ────────────────
  #
  # The first version of this helper appended the stub dir to the caller's PATH.
  # Six tests then passed for the wrong reason: `vmsc_remove_tool node` deleted
  # the stub, the gate searched on down PATH, found the DEVELOPER'S OWN node,
  # and reported the fact as healthy. The suite was asserting that this laptop
  # has node installed. On a machine without it the same tests would have gone
  # green for the right reason, so the defect was invisible to a pass and
  # invisible to a fail — it only showed up as the mutation tests refusing to go
  # red, which is precisely the signal §7b says to treat as a finding.
  #
  # So the gate runs with a PATH containing exactly two directories: the stubs
  # this suite placed, and symlinks to the handful of system utilities the gate
  # itself shells out to. Nothing else is reachable. Removing a stub now removes
  # the tool, on every machine, whatever the developer happens to have.
  #
  # PATH is NOT exported into the bats process — bats' own internals need the
  # real one. It is applied to the gate invocation only, in vmsc_run_gate.
  mkdir -p "${root}/sys"
  local util src
  for util in grep head tr sed awk id hostname ls touch rm cat uname dirname; do
    src="$(command -v "$util" 2>/dev/null)" || continue
    ln -sf "$src" "${root}/sys/${util}"
  done
  export VMSC_PATH="${root}/stub:${root}/sys"

  # The interpreter is resolved from the REAL PATH, now, and invoked by absolute
  # path later. `env PATH=<hermetic> bash …` looks bash up in the hermetic PATH,
  # finds nothing, and exits 127 — which bats reports as "Command not found"
  # against the gate, so it reads as the gate being missing rather than the
  # interpreter. Ten tests failed that way, all pointing at the wrong file.
  VMSC_BASH="$(command -v bash)"
  export VMSC_BASH
}

# A stub that prints a line and exits 0.
vmsc_stub() { # name output
  printf '#!/bin/sh\necho %s\nexit 0\n' "$(printf '%q' "$2")" >"${VMSC_SANDBOX}/stub/$1"
  chmod +x "${VMSC_SANDBOX}/stub/$1"
}

# A stub that prints to stderr and exits non-zero — a present but broken tool.
vmsc_stub_broken() { # name output rc
  printf '#!/bin/sh\necho %s >&2\nexit %s\n' "$(printf '%q' "$2")" "$3" >"${VMSC_SANDBOX}/stub/$1"
  chmod +x "${VMSC_SANDBOX}/stub/$1"
}

# Remove a tool from the sandbox PATH.
#
# Deleting the stub is sufficient ONLY because VMSC_PATH is hermetic — see the
# long note in vmsc_sandbox. On a PATH that still reached the system
# directories this would silently mean "fall back to whatever this machine has"
# rather than "absent", and six tests passed that way before the PATH was
# closed. The two are inseparable: do not widen VMSC_PATH without replacing
# this with a shadowing shim.
vmsc_remove_tool() { # name
  rm -f "${VMSC_SANDBOX}/stub/$1"
}

# Run the gate under the sandbox. Never let a non-zero exit kill the caller —
# a failing gate is the EXPECTED outcome in most tests here.
#
# PATH is set on the invocation rather than exported, so bats' own machinery
# keeps the real one.
vmsc_run_gate() {
  run env "PATH=${VMSC_PATH}" "${VMSC_BASH}" "${VMSC_GATE}" "$@"
}

# Assert one fact's status in the gate's text output. Matches the whole
# bracketed status plus the fact id as one token, so a PASS line for
# F7a-work-root-writable can never satisfy an assertion about
# F7b-reports-writable, and the substring "PASS" appearing in a remedy
# paragraph can never satisfy anything.
vmsc_fact_is() { # id status
  printf '%s\n' "$output" | grep -qE "^ +\[$2\] +$1( |\$)"
}

# The whole verdict as "ID STATUS" lines, sorted. Used to compare two runs
# against each other rather than against a hardcoded expectation — see the
# discrimination test.
vmsc_status_map() {
  printf '%s\n' "$output" \
    | sed -n 's/^ *\[\(PASS\|FAIL\)\] *\([A-Za-z0-9-]*\).*/\2 \1/p' \
    | sort
}
