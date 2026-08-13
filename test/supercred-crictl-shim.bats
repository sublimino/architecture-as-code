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

# `get pods -n NS -o json` is the started-container evidence probe. Each
# namespace's payload comes from PODS_JSON_<ns-with-dashes-as-underscores>;
# a namespace with no variable set is answered with a Forbidden error, which
# is what the runner's ServiceAccount actually gets for namespaces outside its
# RoleBindings and must therefore be the stub's default.
if [ "$#" -eq 6 ] \
	&& [ "$1" = "get" ] \
	&& [ "$2" = "pods" ] \
	&& [ "$3" = "-n" ] \
	&& [ "$5" = "-o" ] \
	&& [ "$6" = "json" ]; then
	var="PODS_JSON_${4//-/_}"
	if [ -n "${!var:-}" ]; then
		printf '%s\n' "${!var}"
		exit 0
	fi
	printf 'Error from server (Forbidden): pods is forbidden in namespace %s\n' "$4" >&2
	exit 1
fi

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

# ─── Started-container evidence ─────────────────────────────────────────────
#
# node.status.images is capped at --node-status-max-images (default 50) and
# sorted by size, so the SMALLEST images fall off the end while sitting
# perfectly happily on the node. On 2026-08-03 that made cardvault:local (8.9MB)
# invisible to the preflight, and on 2026-08-13 the dashboard's Instructor
# Controls printed three yellow "! not visible ... TRUNCATED ... inconclusive"
# lines mid-demo for an image that was demonstrably present.
#
# The runner pod has no route to the node's container runtime (no docker
# socket, and nodes/proxy is Forbidden for its ServiceAccount), so the second
# evidence source is a container that STARTED from the image: under
# imagePullPolicy Never/IfNotPresent against a :local tag the kubelet could not
# have started it unless the image was unpacked and runnable on that node.

setup_evidence_namespaces() {
	export SUPERCRED_IMAGE_EVIDENCE_NAMESPACES="inf-signalloom"
}

@test "an image below the kubelet cap is proven present by a container that started from it" {
	setup_evidence_namespaces
	# 50 entries: at the cap, so the shim reports the listing as truncated.
	export KUBECTL_NODE_JSON="$(python3 -c '
import json
images = [{"names": [f"docker.io/library/filler-{i}:v1"]} for i in range(50)]
print(json.dumps({"status": {"images": images}}))')"
	export PODS_JSON_inf_signalloom='{"items":[{"metadata":{"name":"cardvault-1","namespace":"inf-signalloom"},"spec":{"nodeName":"demo-node"},"status":{"containerStatuses":[{"name":"cardvault","image":"docker.io/library/cardvault:local","state":{"running":{"startedAt":"2026-08-13T00:00:00Z"}}}]}}]}'

	run bash -c "PATH='$PATH' '$script' exec demo-node crictl images | awk '\$1\":\"\$2 == \"docker.io/library/cardvault:local\" { found = 1 } END { exit !found }'"
	[ "$status" -eq 0 ]
}

@test "the proven-present note names the image and its basis on stderr" {
	setup_evidence_namespaces
	export KUBECTL_NODE_JSON='{"status":{"images":[]}}'
	export PODS_JSON_inf_signalloom='{"items":[{"metadata":{"name":"cardvault-1"},"spec":{"nodeName":"demo-node"},"status":{"containerStatuses":[{"name":"cardvault","image":"docker.io/library/cardvault:local","state":{"running":{"startedAt":"2026-08-13T00:00:00Z"}}}]}}]}'

	run bash -c "PATH='$PATH' '$script' exec demo-node crictl images >'$stdout_file' 2>'$stderr_file'"
	[ "$status" -eq 0 ]

	run cat "$stderr_file"
	[[ "$output" == *'PROVEN present on demo-node by a container that started from them'* ]]
	[[ "$output" == *'docker.io/library/cardvault:local'* ]]
}

# The inverse, and the assertion that stops this probe from becoming a lie:
# ErrImageNeverPull and ImagePullBackOff both leave the container in `waiting`,
# and those are exactly the states that mean the image is NOT on the node. A
# probe that counted every containerStatus would report a missing image as
# present — strictly worse than the truncated listing it replaces.
@test "a container waiting on ErrImageNeverPull is NOT evidence the image is present" {
	setup_evidence_namespaces
	export KUBECTL_NODE_JSON='{"status":{"images":[]}}'
	export PODS_JSON_inf_signalloom='{"items":[{"metadata":{"name":"cardvault-1"},"spec":{"nodeName":"demo-node"},"status":{"containerStatuses":[{"name":"cardvault","image":"docker.io/library/cardvault:local","state":{"waiting":{"reason":"ErrImageNeverPull"}}}]}}]}'

	run bash -c "PATH='$PATH' '$script' exec demo-node crictl images | awk '\$1\":\"\$2 == \"docker.io/library/cardvault:local\" { found = 1 } END { exit !found }'"
	[ "$status" -ne 0 ]
}

@test "a terminated container that started counts as evidence" {
	setup_evidence_namespaces
	export KUBECTL_NODE_JSON='{"status":{"images":[]}}'
	export PODS_JSON_inf_signalloom='{"items":[{"metadata":{"name":"agent-run-1"},"spec":{"nodeName":"demo-node"},"status":{"containerStatuses":[{"name":"agent","image":"docker.io/library/cardvault-agent:local","state":{"terminated":{"startedAt":"2026-08-13T00:00:00Z","exitCode":1}}}]}}]}'

	run "$script" exec demo-node crictl images
	[ "$status" -eq 0 ]
	[[ "$output" == *'docker.io/library/cardvault-agent local - -'* ]]
}

# Without the spec.nodeName filter this probe would claim an image is on the
# node being asked about because it started on a DIFFERENT one — silently wrong
# on any multi-node cluster, and undetectable from the output.
@test "a container started on another node is not evidence about this node" {
	setup_evidence_namespaces
	export KUBECTL_NODE_JSON='{"status":{"images":[]}}'
	export PODS_JSON_inf_signalloom='{"items":[{"metadata":{"name":"cardvault-1"},"spec":{"nodeName":"other-node"},"status":{"containerStatuses":[{"name":"cardvault","image":"docker.io/library/cardvault:local","state":{"running":{"startedAt":"2026-08-13T00:00:00Z"}}}]}}]}'

	run bash -c "PATH='$PATH' '$script' exec demo-node crictl images | awk '\$1\":\"\$2 == \"docker.io/library/cardvault:local\" { found = 1 } END { exit !found }'"
	[ "$status" -ne 0 ]
}

# The runner's ServiceAccount is bound per-namespace, so a namespace it cannot
# read is routine. It must cost the caller nothing beyond that namespace's
# evidence — the node listing still answers, and a miss stays inconclusive
# rather than becoming a hard "missing".
@test "a namespace the ServiceAccount cannot read degrades to the node listing" {
	export SUPERCRED_IMAGE_EVIDENCE_NAMESPACES="inf-signalloom forbidden-ns"
	export KUBECTL_NODE_JSON='{"status":{"images":[{"names":["docker.io/library/policy-engine:local"]}]}}'
	export PODS_JSON_inf_signalloom='{"items":[{"metadata":{"name":"cardvault-1"},"spec":{"nodeName":"demo-node"},"status":{"containerStatuses":[{"name":"cardvault","image":"docker.io/library/cardvault:local","state":{"running":{"startedAt":"2026-08-13T00:00:00Z"}}}]}}]}'

	run "$script" exec demo-node crictl images
	[ "$status" -eq 0 ]
	[[ "$output" == *'docker.io/library/policy-engine local - -'* ]]
	[[ "$output" == *'docker.io/library/cardvault local - -'* ]]
}

@test "init containers that started also count as evidence" {
	setup_evidence_namespaces
	export KUBECTL_NODE_JSON='{"status":{"images":[]}}'
	export PODS_JSON_inf_signalloom='{"items":[{"metadata":{"name":"boot-1"},"spec":{"nodeName":"demo-node"},"status":{"initContainerStatuses":[{"name":"init","image":"docker.io/library/policy-engine:local","state":{"terminated":{"startedAt":"2026-08-13T00:00:00Z","exitCode":0}}}]}}]}'

	run "$script" exec demo-node crictl images
	[ "$status" -eq 0 ]
	[[ "$output" == *'docker.io/library/policy-engine local - -'* ]]
}

@test "an image in both the node listing and a started container appears once" {
	setup_evidence_namespaces
	export KUBECTL_NODE_JSON='{"status":{"images":[{"names":["docker.io/library/cardvault:local"]}]}}'
	export PODS_JSON_inf_signalloom='{"items":[{"metadata":{"name":"cardvault-1"},"spec":{"nodeName":"demo-node"},"status":{"containerStatuses":[{"name":"cardvault","image":"docker.io/library/cardvault:local","state":{"running":{"startedAt":"2026-08-13T00:00:00Z"}}}]}}]}'

	run bash -c "PATH='$PATH' '$script' exec demo-node crictl images | grep -c '^docker.io/library/cardvault local'"
	[ "$status" -eq 0 ]
	[ "$output" = "1" ]
}
