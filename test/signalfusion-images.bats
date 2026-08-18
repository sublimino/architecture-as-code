#!/usr/bin/env bats
#
# scripts/signalfusion-images.sh had no test suite at all, which is why nobody
# noticed that the "verified build" in its header verified the wrong thing.
#
# ─── The defect, measured ───────────────────────────────────────────────────
#
# Its own image is the one that proved it. On 2026-08-17, after
# `make demo-signalloom-up` completed with exit 0:
#
#   host docker : signal-ingest:local  sha256:ac70e5d4e068…  14.5MB  (9 min old)
#   kind node   : signal-ingest:local  7913092728b75          5.33MB  (different)
#
# and loading it by hand produced kind's own confirmation that the fresh image
# had never arrived:
#
#   Image: "signal-ingest:local" with ID "sha256:ac70e5d4e068…" not yet present
#   on node "osramp-control-plane", loading...
#
# The check compared name and tag only, so the stale image satisfied it. Every
# stage was green and the cluster ran a different binary.
#
# Everything below runs against fake docker/kind binaries — no cluster, no
# daemon. The point is to exercise the FAILURE paths, and a real kind that
# happens to work today exercises none of them.

# The ID an image "really" has, derived from its reference so the local daemon
# and the node agree without a shared state file.
fake_image_id() { printf '%s' "$1" | sha256sum | cut -c1-64; }

setup() {
	script="$BATS_TEST_DIRNAME/../scripts/signalfusion-images.sh"
	bin="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$bin"

	# One model of docker and crictl across all three suites that exercise
	# image-identity.sh. Exported so the fake `docker` written below can source
	# it, and sourced here so assertions derive the same values the fake does.
	export FAKE_IMAGE_CLI="$BATS_TEST_DIRNAME/lib/fake-image-cli.bash"
	# shellcheck source=test/lib/fake-image-cli.bash
	source "$FAKE_IMAGE_CLI"

	# The CRI's view of the node. A line is `ref` or `ref id`; the second field
	# overrides the derived ID, which is how a STALE image is staged.
	export CRICTL_STATE="$BATS_TEST_TMPDIR/crictl-images"
	export CALL_LOG="$BATS_TEST_TMPDIR/calls.log"
	: >"$CRICTL_STATE"
	: >"$CALL_LOG"

	cat >"$bin/docker" <<-'FAKE'
		#!/usr/bin/env bash
		echo "docker $*" >>"$CALL_LOG"
		# The image-identity surface is shared with kind-load-verified.bats and
		# supercred-images.bats. Three hand-written copies of it is how all three
		# came to encode the same false premise — that docker's .Id and crictl's
		# IMAGE ID are one identifier — while staying green over a defect that
		# aborted both CI lanes. See test/lib/fake-image-cli.bash.
		source "$FAKE_IMAGE_CLI"
		case "$1" in
		  image)
		    shift
		    fake_docker_image_cmd "$@"
		    exit $? ;;
		  build)  exit "${DOCKER_BUILD_STATUS:-0}" ;;
		  buildx)
		    for arg in "$@"; do
		      case "$arg" in type=docker,dest=*) : >"${arg#type=docker,dest=}" ;; esac
		    done
		    exit "${DOCKER_BUILDX_STATUS:-0}" ;;
		  exec)
		    shift
		    [ "$1" = "-i" ] && shift
		    shift  # node name
		    case "$1" in
		      crictl)
		        shift
		        fake_crictl_cmd "$@"
		        exit $? ;;
		      ctr)
		        case "$*" in
		          *"images import"*)
		            cat >/dev/null
		            [ -n "${CTR_IMPORT_IMAGE:-}" ] && echo "$CTR_IMPORT_IMAGE" >>"$CRICTL_STATE"
		            exit "${CTR_IMPORT_STATUS:-0}" ;;
		        esac ;;
		    esac ;;
		esac
		exit 0
	FAKE

	cat >"$bin/kind" <<-'FAKE'
		#!/usr/bin/env bash
		echo "kind $*" >>"$CALL_LOG"
		# The real failure exactly: prints progress, exits 0, transfers nothing
		# unless KIND_LOADS names the images it actually delivers.
		for img in ${KIND_LOADS:-}; do echo "$img" >>"$CRICTL_STATE"; done
		echo 'Image: "signal-ingest:local" with ID "sha256:deadbeef" not yet present on node, loading...'
		exit "${KIND_LOAD_STATUS:-0}"
	FAKE

	chmod +x "$bin/docker" "$bin/kind"
	export DOCKER_BIN="$bin/docker"
	export KIND_BIN="$bin/kind"
	export PATH="$bin:$PATH"
	export SIGNALFUSION_NODE="osramp-control-plane"
	export SIGNALFUSION_CRI_ADOPT_TIMEOUT=3
}

# ─── The happy path ─────────────────────────────────────────────────────────

@test "SF load PASSES when the node holds the image just built" {
	KIND_LOADS="signal-ingest:local" run "$script" load
	[ "$status" -eq 0 ]
	[[ "$output" == *"PASS — all Signal Fusion images"*"are the images just built locally"* ]]
	# What it verified against is printed, so the claim is checkable. This used
	# to assert the crictl IMAGE ID; identity no longer reads that column, so
	# asserting it would pin a value the guard does not consult.
	[[ "$output" == *"matching rootfs layers"* ]]
	# No archive round-trip when the loader did its job.
	run grep -c 'buildx build' "$CALL_LOG"
	[ "$output" -eq 0 ]
}

# ─── The defect ─────────────────────────────────────────────────────────────

@test "SF a STALE image under the right tag is a FAILURE, not a pass" {
	# 2026-08-17, in a fixture. The node already holds an image tagged
	# signal-ingest:local and it is NOT the one just built. kind exits 0 having
	# transferred nothing — KIND_LOADS is empty — exactly as the real loader did.
	#
	# Against the old name-and-tag check the tag is present, so it returned 0,
	# so this script exited 0 and reported the build verified. That is the bug.
	echo "signal-ingest:local 7913092728b7500000000000000000000000000000000000000000000000cafe" >"$CRICTL_STATE"

	run "$script" load
	[ "$status" -ne 0 ]
	[[ "$output" == *"DIFFERENT image"* ]]
	# The evidence a reader needs, in the terms the check now works in. It used
	# to assert both IMAGE IDs; the crictl ID column is no longer consulted for
	# identity, so pinning it would be a test passing on something other than
	# the thing it names — the defect class this suite exists to catch.
	[[ "$output" == *"local rootfs layers"* ]]
	[[ "$output" == *"node  rootfs layers"* ]]
	[[ "$output" == *"first divergence at layer"* ]]
}

@test "SF a stale image is NOT silently repaired" {
	# The non-negotiable half. Recovery WORKS in this fixture — CTR_IMPORT_IMAGE
	# is set — so if the script were willing to repair a mismatch it would, and
	# it would exit 0. A gate that reloads and then reports success leaves the
	# broken loader in place, which is how this survived to reach production.
	echo "signal-ingest:local 7913092728b7500000000000000000000000000000000000000000000000cafe" >"$CRICTL_STATE"

	CTR_IMPORT_IMAGE="signal-ingest:local" run "$script" load
	[ "$status" -ne 0 ]
	[[ "$output" == *"NOT recovering"* ]]
	[[ "$output" == *"Nothing has been repaired"* ]]
	run grep -c 'buildx build' "$CALL_LOG"
	[ "$output" -eq 0 ]
}

# ─── Three outcomes ─────────────────────────────────────────────────────────

@test "SF a truncated listing that omits the image is COULD-NOT-VERIFY" {
	# node.status.images is capped at --node-status-max-images (default 50) and
	# sorted by size, so a small image is absent from the DATA while present on
	# the node. Guessing FAIL blocked the whole demo on 2026-08-03; guessing PASS
	# is the defect above. So: neither, and exit 3 says which.
	CRICTL_TRUNCATED=1 run "$script" load
	[ "$status" -eq 3 ]
	[[ "$output" == *"COULD-NOT-VERIFY"* ]]
	[[ "$output" == *"TRUNCATED"* ]]
	[[ "$output" != *"PASS —"* ]]
	# Nothing was churned on the strength of a listing that could not answer.
	run grep -c 'buildx build' "$CALL_LOG"
	[ "$output" -eq 0 ]
}

@test "SF an untruncated listing that omits the image is a plain FAILURE" {
	# The control. Same absence, trustworthy listing, so the absence is real.
	# Without this, "truncated means inconclusive" could be implemented as
	# "absence always means inconclusive" and nothing here would notice.
	CTR_IMPORT_STATUS=1 run "$script" load
	[ "$status" -eq 1 ]
	[[ "$output" == *"absent, or are NOT the image just"* ]]
	[[ "$output" != *"COULD-NOT-VERIFY"* ]]
}

@test "SF the three outcomes have three distinct exit codes" {
	# Pinned as a set, because the value of naming them is lost the moment two
	# collapse back into one.
	KIND_LOADS="signal-ingest:local" run "$script" load
	local pass="$status"
	: >"$CRICTL_STATE"; : >"$CALL_LOG"
	CTR_IMPORT_STATUS=1 run "$script" load
	local fail="$status"
	: >"$CRICTL_STATE"; : >"$CALL_LOG"
	CRICTL_TRUNCATED=1 run "$script" load
	local unknown="$status"

	[ "$pass" -eq 0 ]
	[ "$fail" -eq 1 ]
	[ "$unknown" -eq 3 ]
}

# ─── Recovery still works where it is legitimate ────────────────────────────

@test "SF an image kind load silently DROPPED is still recovered" {
	# Absence, not mismatch. Recovery is correct here and must not have been
	# collateral damage of the mismatch rule.
	CTR_IMPORT_IMAGE="signal-ingest:local" run "$script" load
	[ "$status" -eq 0 ]
	[[ "$output" == *"attempting recovery"* ]]
	[[ "$output" == *"PASS —"* ]]
	run grep -c 'buildx build' "$CALL_LOG"
	[ "$output" -eq 1 ]
}

@test "SF recovery rebuilds into an archive rather than via the docker store" {
	CTR_IMPORT_IMAGE="signal-ingest:local" run "$script" load
	[ "$status" -eq 0 ]
	grep -q 'type=docker,dest=' "$CALL_LOG"
	grep -q 'images import --all-platforms' "$CALL_LOG"
	grep -q 'io.cri-containerd.image=managed' "$CALL_LOG"
}

# ─── Surfacing what used to be discarded ────────────────────────────────────

@test "SF a nonzero kind exit is reported rather than swallowed" {
	# `|| true` used to throw this away. It is not sufficient evidence — the
	# whole defect is a load that exits 0 having done nothing — but a load that
	# ANNOUNCED failure is a different bug report from one that claimed success.
	KIND_LOAD_STATUS=1 KIND_LOADS="signal-ingest:local" run "$script" load
	[ "$status" -eq 0 ]
	[[ "$output" == *"kind load exited 1"* ]]
	[[ "$output" == *"PASS —"* ]]
}

@test "SF a failed docker build aborts instead of loading a stale image" {
	DOCKER_BUILD_STATUS=1 run "$script" load
	[ "$status" -ne 0 ]
	[[ "$output" == *"docker build failed"* ]]
	run grep -c 'kind load' "$CALL_LOG"
	[ "$output" -eq 0 ]
}

@test "SF an unreadable node is named as such, not reported as a missing image" {
	# An empty listing makes EVERY image "absent" — a confident answer derived
	# from no data, which reads as a build problem when it is a "cannot reach the
	# node" problem. The verdict stays FAIL (failing closed on an unreadable node
	# is right) but it must stop pointing at the wrong thing.
	cat >"$bin/docker" <<-'DEAD'
		#!/usr/bin/env bash
		echo "docker $*" >>"$CALL_LOG"
		case "$1" in
		  image) printf 'sha256:%s\n' "$(printf '%s' "${!#}" | sha256sum | cut -c1-64)"; exit 0 ;;
		  build|buildx) exit 0 ;;
		  exec) echo "Error: No such container: osramp-control-plane" >&2; exit 1 ;;
		esac
		exit 0
	DEAD
	chmod +x "$bin/docker"

	run "$script" verify-identity
	[ "$status" -eq 1 ]
	[[ "$output" == *"cannot read an image listing"* ]]
	[[ "$output" != *"no such tag"* ]]
}

@test "SF an unknown subcommand reports usage" {
	run "$script" frobnicate
	[ "$status" -ne 0 ]
	[[ "$output" == *"Usage:"* ]]
}

@test "SF verify asks PRESENCE and says so, without a local image to compare" {
	# The state the demo runner is permanently in: it reaches the node through
	# scripts/supercred-crictl-shim.sh, has no docker daemon, and so has no local
	# image to compare against. Presence is the only answerable question there,
	# and reporting it as an identity check that passed would be a lie.
	echo "signal-ingest:local" >"$CRICTL_STATE"
	DOCKER_MISSING="signal-ingest:local" run "$script" verify
	[ "$status" -eq 0 ]
	[[ "$output" == *"presence only — identity not checked"* ]]
}

@test "SF verify-identity refuses to pass on presence alone" {
	# Same node, same listing, stronger question. Without a local image there is
	# nothing to compare against, so the honest answer is COULD-NOT-VERIFY — NOT
	# a pass inherited from the presence check above.
	echo "signal-ingest:local" >"$CRICTL_STATE"
	DOCKER_MISSING="signal-ingest:local" run "$script" verify-identity
	[ "$status" -eq 3 ]
	[[ "$output" == *"COULD-NOT-VERIFY"* ]]
	[[ "$output" == *"presence proven, identity unproven"* ]]
}
