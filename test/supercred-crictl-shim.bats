#!/usr/bin/env bats

setup() {
	script="$BATS_TEST_DIRNAME/../scripts/supercred-crictl-shim.sh"
	bin="$BATS_TEST_TMPDIR/bin"
	stdout_file="$BATS_TEST_TMPDIR/stdout"
	stderr_file="$BATS_TEST_TMPDIR/stderr"
	mkdir -p "$bin"

	cat >"$bin/kubectl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 5 ] \
	|| [ "$1" != "get" ] \
	|| [ "$2" != "node" ] \
	|| [ "$4" != "-o" ] \
	|| [ "$5" != "json" ]; then
	printf 'kubectl stub received unexpected argv: %s\n' "$*" >&2
	exit 97
fi

if [ -n "${KUBECTL_FAIL_MESSAGE:-}" ]; then
	printf '%s\n' "$KUBECTL_FAIL_MESSAGE" >&2
	exit "${KUBECTL_FAIL_STATUS:-1}"
fi

# The default is assigned on its own line, NOT inline as
# "${KUBECTL_NODE_JSON:-{\"status\":...}}". Bash ends a ${...:-default}
# expansion at the first unescaped '}', so a JSON default gets truncated
# mid-value and the remainder is emitted as literal trailing text. That made
# the stub print valid JSON followed by a stray '}', and the shim correctly
# rejected it as "Extra data" -- a broken fixture failing a working shim.
node_json="${KUBECTL_NODE_JSON:-}"
if [ -z "$node_json" ]; then
	node_json='{"status":{"images":[]}}'
fi
printf '%s\n' "$node_json"
STUB

	chmod +x "$bin/kubectl"
	export PATH="$bin:$PATH"
}

capture_command() {
	run bash -c "PATH='$PATH' '$script' $* >'$stdout_file' 2>'$stderr_file'"
}

@test "present image rows satisfy the caller's awk match unchanged" {
	export KUBECTL_NODE_JSON='{"status":{"images":[{"names":["docker.io/library/cardvault:local","docker.io/library/policy-engine:local"]}]}}'

	run bash -c "PATH='$PATH' '$script' exec demo-node crictl images | awk '\$1\":\"\$2 == \"docker.io/library/cardvault:local\" { found = 1 } END { exit !found }'"
	[ "$status" -eq 0 ]

	run "$script" exec demo-node crictl images
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "IMAGE TAG IMAGE ID SIZE" ]
	[[ "$output" == *$'\ndocker.io/library/cardvault local - -'* ]]
}

@test "absent images yield a clean table and no awk match" {
	export KUBECTL_NODE_JSON='{"status":{"images":[{"names":["docker.io/library/policy-engine:local"]}]}}'

	run "$script" exec demo-node crictl images
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "IMAGE TAG IMAGE ID SIZE" ]

	run bash -c "PATH='$PATH' '$script' exec demo-node crictl images | awk '\$1\":\"\$2 == \"docker.io/library/cardvault:local\" { found = 1 } END { exit !found }'"
	[ "$status" -ne 0 ]
}

@test "kubectl failures surface the real error and never emit a success table" {
	export KUBECTL_FAIL_MESSAGE='Error from server (NotFound): nodes "missing-node" not found'
	export KUBECTL_FAIL_STATUS=1

	run bash -c "PATH='$PATH' '$script' exec missing-node crictl images >'$stdout_file' 2>'$stderr_file'"
	[ "$status" -ne 0 ]

	run cat "$stdout_file"
	[ "$status" -eq 0 ]
	[ -z "$output" ]

	run cat "$stderr_file"
	[ "$status" -eq 0 ]
	[[ "$output" == *'nodes "missing-node" not found'* ]]
}

@test "unsupported argv fails closed with the rejected command named" {
	run bash -c "PATH='$PATH' '$script' ps >'$stdout_file' 2>'$stderr_file'"
	[ "$status" -ne 0 ]

	run cat "$stdout_file"
	[ "$status" -eq 0 ]
	[ -z "$output" ]

	run cat "$stderr_file"
	[ "$status" -eq 0 ]
	[[ "$output" == *'unsupported docker argv: ps'* ]]

	run bash -c "PATH='$PATH' '$script' exec demo-node crictl images -o json >'$stdout_file' 2>'$stderr_file'"
	[ "$status" -ne 0 ]

	run cat "$stderr_file"
	[ "$status" -eq 0 ]
	[[ "$output" == *'unsupported docker argv: exec demo-node crictl images -o json'* ]]
}

@test "digest refs and untagged refs are skipped instead of mis-split" {
	export KUBECTL_NODE_JSON='{"status":{"images":[{"names":["docker.io/library/cardvault@sha256:deadbeef","registry.internal:5000/team/policy-engine","docker.io/library/cardvault:local"]}]}}'

	run "$script" exec demo-node crictl images
	[ "$status" -eq 0 ]
	[[ "$output" == *'docker.io/library/cardvault local - -'* ]]
	[[ "$output" != *'sha256'* ]]
	[[ "$output" != *'registry.internal:5000/team/policy-engine '* ]]
}

# A node that holds an image only by digest reports `"names": null` for it --
# present key, null value -- so `.get("names", [])` never returns its default.
# The shim raised TypeError mid-table: it emitted the rows BEFORE the null,
# exited 1, and silently dropped every row after it. Because the caller matches
# this listing with awk, that surfaced as "SuperCred images are not all present
# on <node>" against a node that had every image loaded, which blocked steps 1,
# 2, 4 and `all` from the dashboard on 2026-08-03.
#
# The image AFTER the null is the whole point of the fixture: an assertion that
# only checks the one before it passes on the broken shim.
@test "a null names entry does not truncate the table" {
	export KUBECTL_NODE_JSON='{"status":{"images":[{"names":["docker.io/library/cardvault-agent:local"]},{"names":null,"sizeBytes":322035286},{"names":["docker.io/library/policy-engine:local"]}]}}'

	run "$script" exec demo-node crictl images
	[ "$status" -eq 0 ]
	[[ "$output" == *'docker.io/library/cardvault-agent local - -'* ]]
	[[ "$output" == *'docker.io/library/policy-engine local - -'* ]]
}

@test "a null images list is an empty table, not a crash" {
	export KUBECTL_NODE_JSON='{"status":{"images":null}}'

	run "$script" exec demo-node crictl images
	[ "$status" -eq 0 ]
	[[ "$output" == *'IMAGE TAG IMAGE ID SIZE'* ]]
}

@test "tag splitting uses the last colon so registry ports stay in the repository column" {
	export KUBECTL_NODE_JSON='{"status":{"images":[{"names":["registry.internal:5000/team/policy-engine:local"]}]}}'

	run "$script" exec demo-node crictl images
	[ "$status" -eq 0 ]
	[[ "$output" == *'registry.internal:5000/team/policy-engine local - -'* ]]
}
