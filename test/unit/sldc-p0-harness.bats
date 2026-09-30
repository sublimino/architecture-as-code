#!/usr/bin/env bats
# test/unit/sldc-p0-harness.bats
# @target scripts/verify-sldc-p0-baseline.sh
#
# SLDC-P0 preflight. The first two tests are host gates (real toolchain and
# kernel). The rest run a copy of the script inside a throwaway git repo with
# fake toolchain binaries, so refusal paths are asserted exactly and the
# committed ci-evidence manifest is never rewritten by a test run.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

version_ge() {
    local v1="${1#v}"; v1="${v1#go}"
    local v2="${2#v}"; v2="${v2#go}"
    [ "$(printf '%s\n' "$v2" "$v1" | sort -V | head -n1)" = "$v2" ]
}

@test "host gate: kind, kubectl, flux, go, bun, bats meet their minimum versions" {
    run kind version
    [ "$status" -eq 0 ]
    version_ge "$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' <<<"$output" | head -1)" "0.24.0"
    run kubectl version --client=true
    [ "$status" -eq 0 ]
    version_ge "$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' <<<"$output" | head -1)" "1.30.0"
    run flux --version
    [ "$status" -eq 0 ]
    version_ge "$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$output" | head -1)" "2.3.0"
    run go version
    [ "$status" -eq 0 ]
    version_ge "$(grep -oE 'go[0-9]+\.[0-9]+(\.[0-9]+)?' <<<"$output" | head -1)" "go1.24"
    run bun --version
    [ "$status" -eq 0 ]
    version_ge "$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$output" | head -1)" "1.1.0"
}

@test "host gate: kernel >= 5.8 with a unified cgroup v2 hierarchy" {
    version_ge "$(uname -r | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?')" "5.8.0"
    [ "$(stat -fc %T /sys/fs/cgroup/)" = "cgroup2fs" ]
}

# A git repo holding a copy of the script, and a PATH of real coreutils plus
# fake toolchain binaries that report passing versions.
setup_sandbox() {
    SB="$BATS_TEST_TMPDIR/repo"; BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$SB/scripts" "$BIN"
    cp "$REPO_ROOT/scripts/verify-sldc-p0-baseline.sh" "$SB/scripts/"
    git -C "$SB" init -q
    git -C "$SB" -c user.name=t -c user.email=t@t -c commit.gpgsign=false add -A
    git -C "$SB" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm init
    local t
    for t in bash env git uname stat grep sort head awk date mkdir dirname cat python3 tr sed; do
        ln -s "$(command -v "$t")" "$BIN/$t"
    done
    fake kind 'echo "kind v0.29.0 go1.24 linux/amd64"'
    fake kubectl 'echo "Client Version: v1.33.0"'
    fake flux 'echo "flux version 2.6.0"'
    fake go 'echo "go version go1.25.1 linux/amd64"'
    fake bun 'echo "1.2.20"'
    fake bats 'echo "Bats 1.13.0"'
    fake docker 'case "$*" in version*) echo 28.1.0 ;; *MemTotal*) echo 1024 ;; *) echo x ;; esac'
}
fake() { printf '#!/bin/bash\n%s\n' "$2" >"$BIN/$1"; chmod +x "$BIN/$1"; }
run_preflight() { run "$@" env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN" bash "$SB/scripts/verify-sldc-p0-baseline.sh"; }
manifest() { jq -r "$1" "$SB/ci-evidence/sldc-p0-preflight-manifest.json"; }

@test "preflight: passing toolchain on a clean tree writes a passed manifest into its own repo" {
    setup_sandbox
    run_preflight
    [ "$status" -eq 0 ]
    [ "$(manifest '[.task_id, .status, .git.clean_working_tree, .toolchain.kind.version] | join(" ")')" = "SLDC-P0 passed true v0.29.0" ]
    [ "$(manifest .git.commit_sha)" = "$(git -C "$SB" rev-parse HEAD)" ]
}

@test "preflight: a dirty working tree is recorded as not clean" {
    setup_sandbox
    echo drift >"$SB/untracked.txt"
    run_preflight
    [ "$status" -eq 0 ]
    [ "$(manifest .git.clean_working_tree)" = "false" ]
}

@test "preflight: a missing flux binary exits 127, names it, and writes no manifest" {
    setup_sandbox
    rm "$BIN/flux"
    run_preflight -127
    [ "$status" -eq 127 ]
    [[ "$output" == *"FATAL: 'flux' binary not found on PATH."* ]]
    [ ! -e "$SB/ci-evidence/sldc-p0-preflight-manifest.json" ]
}

@test "preflight: kind below v0.24.0 exits 1 and writes no manifest" {
    setup_sandbox
    fake kind 'echo "kind v0.23.9 go1.22 linux/amd64"'
    run_preflight
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL: Kind version v0.23.9 is below required v0.24.0"* ]]
    [ ! -e "$SB/ci-evidence/sldc-p0-preflight-manifest.json" ]
}

@test "preflight: go 1.9 is below go1.24 (version sort, not lexical)" {
    setup_sandbox
    fake go 'echo "go version go1.9 linux/amd64"'
    run_preflight
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL: Go version go1.9 is below required go1.24"* ]]
}

@test "preflight: an unreachable docker daemon exits 1 and writes no manifest" {
    setup_sandbox
    fake docker 'exit 1'
    run_preflight
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL: Docker daemon unreachable or permission denied."* ]]
    [ ! -e "$SB/ci-evidence/sldc-p0-preflight-manifest.json" ]
}
