#!/usr/bin/env bats
# test/unit/sldc-p0-harness.bats
#
# Automated BATS smoke test validating environment prerequisites,
# toolchain binary availability, commit signing practice, and preflight script.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
    cd "$REPO_ROOT"
}

version_ge() {
    local v1="${1#v}"; v1="${v1#go}"
    local v2="${2#v}"; v2="${v2#go}"
    [ "$(printf '%s\n' "$v2" "$v1" | sort -V | head -n1)" = "$v2" ]
}

@test "Toolchain Availability Gate: kind, kubectl, flux, go, bun, bats" {
    run kind version
    [ "$status" -eq 0 ]
    kind_ver="$(echo "$output" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    version_ge "$kind_ver" "0.24.0"

    run kubectl version --client=true
    [ "$status" -eq 0 ]
    kubectl_ver="$(echo "$output" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    version_ge "$kubectl_ver" "1.30.0"

    run flux --version
    [ "$status" -eq 0 ]
    flux_ver="$(echo "$output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    version_ge "$flux_ver" "2.3.0"

    run go version
    [ "$status" -eq 0 ]
    go_ver="$(echo "$output" | grep -oE 'go[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
    version_ge "$go_ver" "go1.24"

    run bun --version
    [ "$status" -eq 0 ]
    bun_ver="$(echo "$output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    version_ge "$bun_ver" "1.1.0"

    run bats --version
    [ "$status" -eq 0 ]
}

@test "Host Kernel and Cgroup v2 Readiness Gate" {
    run uname -r
    [ "$status" -eq 0 ]
    kernel_base="$(echo "$output" | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?')"
    version_ge "$kernel_base" "5.8.0"

    run stat -fc %T /sys/fs/cgroup/
    [ "$status" -eq 0 ]
    [ "$output" = "cgroup2fs" ]
}

@test "Unsigned Commit Practice Verification: recent commits use --no-gpg-sign" {
    run git log --pretty="%h %G? %s" -6
    [ "$status" -eq 0 ]
    while IFS= read -r line; do
        sig="$(echo "$line" | awk '{print $2}')"
        [ "$sig" = "N" ]
    done <<< "$output"
}

@test "Deliberate Mutation Testing Check: missing toolchain binary fails with exit 127" {
    run -127 env PATH=/tmp/empty_path kind --version
    [ "$status" -eq 127 ]
}

@test "Preflight Baseline Script: executes and produces valid manifest" {
    run ./scripts/verify-sldc-p0-baseline.sh
    [ "$status" -eq 0 ]

    [ -f "ci-evidence/sldc-p0-preflight-manifest.json" ]
    
    # Assert JSON validity and status passed
    run bun -e '
      const fs = require("fs");
      const m = JSON.parse(fs.readFileSync("ci-evidence/sldc-p0-preflight-manifest.json", "utf8"));
      if (m.task_id !== "SLDC-P0") throw new Error("bad task_id");
      if (m.status !== "passed") throw new Error("status not passed");
      if (!m.toolchain.kind.satisfies_min) throw new Error("kind min not met");
      if (!m.toolchain.go.satisfies_min) throw new Error("go min not met");
      console.log("manifest valid");
    '
    [ "$status" -eq 0 ]
    [ "$output" = "manifest valid" ]
}
