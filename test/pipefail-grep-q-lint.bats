#!/usr/bin/env bats
#
# Guard for the `producer | grep -q` under pipefail class: grep -q exits at the
# first match, the producer is SIGPIPEd, pipefail returns 141, and a MATCH reads
# as no match. scripts/lint-pipefail-grep-q.sh fails on every such site that is
# neither rewritten (`grep -q PAT <<<"$(producer)"`) nor marked
# `# pipefail-safe: <reason>`. The fixtures below pin each rule; the first test
# holds the repository to it.
#
# @target scripts/lint-pipefail-grep-q.sh

bats_require_minimum_version 1.5.0

setup() {
	root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	lint="$root/scripts/lint-pipefail-grep-q.sh"
	fx="$BATS_TEST_TMPDIR/fx"
	mkdir -p "$fx"
}

script() { # name, body lines...
	local f="$fx/$1"; shift
	printf '%s\n' "$@" >"$f"
}

@test "the repository has no unmarked early-exit grep under pipefail" {
	run --separate-stderr "$lint"
	[ "$status" -eq 0 ] || { printf '%s\n' "$output" "$stderr" >&2; return 1; }
	[[ "$output" == "lint-pipefail-grep-q: SCANNED CLEAN: "* ]]
}

@test "a piped grep -q after set -o pipefail is a finding, named by file and line" {
	script gate.sh '#!/usr/bin/env bash' 'set -euo pipefail' 'if kind get clusters | grep -qx osramp; then kind delete cluster; fi'
	run --separate-stderr "$lint" "$fx"
	[ "$status" -eq 1 ]
	[ "$output" = "$fx/gate.sh:3: if kind get clusters | grep -qx osramp; then kind delete cluster; fi" ]
	[[ "$stderr" == *"1 unmarked site(s)"* ]]
}

@test "the here-string rewrite is clean" {
	script gate.sh '#!/usr/bin/env bash' 'set -euo pipefail' 'if grep -qx osramp <<<"$(kind get clusters)"; then kind delete cluster; fi'
	run "$lint" "$fx"
	[ "$status" -eq 0 ]
}

@test "a pipe BEFORE set -o pipefail is not a finding" {
	script gate.sh '#!/usr/bin/env bash' 'ps aux | grep -q sshd' 'set -o pipefail'
	run "$lint" "$fx"
	[ "$status" -eq 0 ]
}

@test "rg -q, grep --quiet and combined flags are findings too" {
	script gate.sh '#!/usr/bin/env bash' 'set -o pipefail' 'env | rg -q HOME' 'env | grep --quiet HOME' 'env | grep -Fxq HOME'
	run "$lint" "$fx"
	[ "$status" -eq 1 ]
	[ "$(grep -c "$fx/gate.sh" <<<"$output")" -eq 3 ]
}

@test "a marker with a reason clears the site, on the same line or the line above" {
	script gate.sh '#!/usr/bin/env bash' 'set -o pipefail' \
		'printf "%s" "$id" | grep -q x # pipefail-safe: one short id, one write' \
		'# pipefail-safe: one short id, one write' 'printf "%s" "$id" | grep -q y'
	run "$lint" "$fx"
	[ "$status" -eq 0 ]
}

@test "a marker without a reason is not a marker" {
	script gate.sh '#!/usr/bin/env bash' 'set -o pipefail' 'env | grep -q HOME # pipefail-safe:'
	run "$lint" "$fx"
	[ "$status" -eq 1 ]
}

@test "pipelines quoted as data are not findings, including multi-line strings" {
	script gate.sh '#!/usr/bin/env bash' 'set -o pipefail' \
		'remote_run "ss -ltn | grep -q :80 && echo UP"' \
		'bash -c "' 'ss -ltn | grep -q :80' '"' \
		'x="$(tr -d '"'"'"'"'"' <f)"' 'env | grep -q HOME'
	run --separate-stderr "$lint" "$fx"
	[ "$status" -eq 1 ]
	[ "$output" = "$fx/gate.sh:8: env | grep -q HOME" ]
}

@test "a pipeline in a \$( ) is code, and is a finding" {
	script gate.sh '#!/usr/bin/env bash' 'set -o pipefail' 'present="$(kubectl get pods | grep -q Running && echo yes)"'
	run "$lint" "$fx"
	[ "$status" -eq 1 ]
}

@test "the second bar of || reads a file and is not a finding" {
	script gate.sh '#!/usr/bin/env bash' 'set -o pipefail' 'grep -q a f || grep -q b g'
	run "$lint" "$fx"
	[ "$status" -eq 0 ]
}

@test "a file sourced by a pipefail script inherits pipefail from line 1" {
	script lib.sh 'has() { kind get clusters | grep -qx "$1"; }'
	script main.sh '#!/usr/bin/env bash' 'set -euo pipefail' 'source "$(dirname "$0")/lib.sh"'
	run --separate-stderr "$lint" "$fx"
	[ "$status" -eq 1 ]
	[ "$output" = "$fx/lib.sh:1: has() { kind get clusters | grep -qx \"\$1\"; }" ]
}

@test "a Makefile whose SHELL carries pipefail puts every recipe under it" {
	mkdir -p "$fx/m"
	printf 'SHELL = /usr/bin/env bash -o pipefail\nx:\n\tdocker ps | grep -q zot\n' >"$fx/m/Makefile"
	run --separate-stderr "$lint" "$fx/m"
	[ "$status" -eq 1 ]
	[ "$output" = "$fx/m/Makefile:3: docker ps | grep -q zot" ]
}

@test "a line that enables pipefail inline is judged even inside quotes" {
	cat >"$fx/t.bats" <<'BATS'
run bash -c 'set -o pipefail; seq 1 9 | grep -q 1'
BATS
	run "$lint" "$fx"
	[ "$status" -eq 1 ]
}

@test "an empty file set is CANNOT SCAN (exit 2), never a pass" {
	mkdir -p "$fx/empty"
	run --separate-stderr "$lint" "$fx/empty"
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"CANNOT SCAN: the file set is EMPTY"* ]]
	run --separate-stderr "$lint" "$fx/no-such-dir"
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"no such path"* ]]
}
