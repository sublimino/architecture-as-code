#!/usr/bin/env bats
#
# The defect these guard against: `kind load docker-image` exits 0 having
# transferred nothing, leaving a manifest in containerd's content store with no
# layers. `ctr images ls` lists such an image; `crictl images` does not. Any
# check built on `ctr images ls` therefore passes while the pod sits in
# ImagePullBackOff.

setup() {
	script="$BATS_TEST_DIRNAME/../scripts/supercred-images.sh"
	bin="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$bin"

	# Images the fake node reports through crictl, newline separated.
	export CRICTL_STATE="$BATS_TEST_TMPDIR/crictl-images"
	# Images the fake node reports through ctr — the content-store view.
	export CTR_STATE="$BATS_TEST_TMPDIR/ctr-images"
	export CALL_LOG="$BATS_TEST_TMPDIR/calls.log"
	: >"$CRICTL_STATE"
	: >"$CTR_STATE"
	: >"$CALL_LOG"

	cat >"$bin/docker" <<-'FAKE'
		#!/usr/bin/env bash
		echo "docker $*" >>"$CALL_LOG"
		case "$1" in
		  build)
		    exit "${DOCKER_BUILD_STATUS:-0}" ;;
		  buildx)
		    # Materialise an archive so the caller's redirect has something to read.
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
		        printf 'IMAGE TAG IMAGE-ID SIZE\n'
		        while IFS= read -r ref; do
		          [ -n "$ref" ] || continue
		          # real crictl reports fully-qualified repos
		          case "$ref" in */*) full="$ref" ;; *) full="docker.io/library/$ref" ;; esac
		          printf '%s %s abc123 10MB\n' "${full%:*}" "${full##*:}"
		        done <"$CRICTL_STATE"
		        ;;
		      ctr)
		        # `images import` promotes the image into the CRI view.
		        case "$*" in
		          *"images import"*)
		            cat >/dev/null
		            if [ -n "${CTR_IMPORT_IMAGE:-}" ]; then
		              echo "$CTR_IMPORT_IMAGE" >>"$CRICTL_STATE"
		            fi
		            exit "${CTR_IMPORT_STATUS:-0}" ;;
		          *)
		            cat "$CTR_STATE" ;;
		        esac ;;
		    esac ;;
		esac
		exit 0
	FAKE

	cat >"$bin/kind" <<-'FAKE'
		#!/usr/bin/env bash
		echo "kind $*" >>"$CALL_LOG"
		# Mirrors the real failure: prints progress, exits 0, transfers nothing
		# unless KIND_LOADS names the images it actually delivers.
		for img in ${KIND_LOADS:-}; do echo "$img" >>"$CRICTL_STATE"; done
		exit 0
	FAKE

	chmod +x "$bin/docker" "$bin/kind"
	export DOCKER_BIN="$bin/docker"
	export KIND_BIN="$bin/kind"
	export SUPERCRED_NODE="osramp-control-plane"
}

# Every entry in SUPERCRED_IMAGES. Keep in step with that array: verify()
# iterates it, so an image missing here reads as "not on the node".
all_images() {
	printf '%s\n' cardvault:local policy-engine:local cardvault-agent:local \
		supercred-demo-runner:local
}

@test "verify passes when every image is runnable on the node" {
	all_images >"$CRICTL_STATE"

	run "$script" verify
	[ "$status" -eq 0 ]
	[[ "$output" == *"cardvault-agent:local present"* ]]
}

@test "verify passes on a node carrying a realistically long image listing" {
	# REGRESSION (SIGPIPE x pipefail). image_on_node() used to end in
	# `awk ... | grep -Fqx`. `grep -q` exits at the first match, closing the
	# pipe and killing the upstream docker/awk with SIGPIPE (141); `set -o
	# pipefail` then made 141 the pipeline's status, so a PRESENT image was
	# reported MISSING. preflight_images consequently failed closed on a
	# healthy cluster and blocked supercred steps 1, 2, 4 and `all`.
	#
	# It is a race between grep exiting and the producer finishing its write,
	# so it only bites once the listing is long enough for the producer still
	# to be writing -- which every other test in this file avoids by emitting
	# a handful of lines. That is precisely why the defect shipped green.
	# A real node carries ~100 images; reproduce that.
	all_images >"$CRICTL_STATE"
	for i in $(seq 1 400); do
		printf 'docker.io/library/filler-%s:v1\n' "$i" >>"$CRICTL_STATE"
	done

	run "$script" verify
	[ "$status" -eq 0 ]
	[[ "$output" == *"cardvault:local present"* ]]
	[[ "$output" == *"policy-engine:local present"* ]]
	[[ "$output" == *"cardvault-agent:local present"* ]]
}

@test "verify still detects a missing image within a long listing" {
	# The mirror of the test above: proves the long-listing fix did not turn
	# image_on_node into a function that simply always succeeds.
	printf '%s\n' cardvault:local policy-engine:local >"$CRICTL_STATE"
	for i in $(seq 1 400); do
		printf 'docker.io/library/filler-%s:v1\n' "$i" >>"$CRICTL_STATE"
	done

	run "$script" verify
	[ "$status" -ne 0 ]
	[[ "$output" == *"missing from osramp-control-plane: cardvault-agent:local"* ]]
}

@test "verify fails loudly when an image is missing from the node" {
	printf '%s\n' cardvault:local policy-engine:local >"$CRICTL_STATE"

	run "$script" verify
	[ "$status" -ne 0 ]
	[[ "$output" == *"missing from osramp-control-plane: cardvault-agent:local"* ]]
	[[ "$output" == *"make demo-signalloom-supercred-images"* ]]
}

@test "an image visible to ctr but not crictl counts as missing" {
	# The exact poisoned state this defect produced: manifest in the content
	# store, layers absent. A ctr-based check would wrongly pass here.
	printf '%s\n' cardvault:local policy-engine:local >"$CRICTL_STATE"
	printf '%s\n' docker.io/library/cardvault-agent:local >"$CTR_STATE"

	run "$script" verify
	[ "$status" -ne 0 ]
	[[ "$output" == *"missing from osramp-control-plane: cardvault-agent:local"* ]]
}

@test "load fails loudly when kind load exits 0 having transferred nothing" {
	export KIND_LOADS=""
	export CTR_IMPORT_IMAGE=""

	run "$script" load
	[ "$status" -ne 0 ]
	[[ "$output" == *"not runnable"* ]]
	[[ "$output" == *"crictl images"* ]]
}

@test "load recovers an image kind load silently dropped" {
	# Every image EXCEPT cardvault-agent lands via kind load; that one is the
	# single silently-dropped image the recovery path must pick up. Keeping it
	# to exactly one is what makes the `buildx build == 1` assertion below mean
	# "recovered precisely the missing image, and rebuilt nothing else".
	export KIND_LOADS="cardvault:local policy-engine:local supercred-demo-runner:local"
	export CTR_IMPORT_IMAGE="cardvault-agent:local"

	run "$script" load
	[ "$status" -eq 0 ]
	[[ "$output" == *"attempting recovery"* ]]
	[[ "$output" == *"all SuperCred images verified runnable"* ]]

	# Recovery must rebuild straight into an archive, never via the docker store.
	run grep -c 'buildx build' "$CALL_LOG"
	[ "$output" -eq 1 ]
	grep -q 'type=docker,dest=' "$CALL_LOG"
	grep -q 'images import --all-platforms' "$CALL_LOG"
}

@test "no recovery is attempted when kind load delivers everything" {
	export KIND_LOADS="cardvault:local policy-engine:local cardvault-agent:local supercred-demo-runner:local"

	run "$script" load
	[ "$status" -eq 0 ]
	[[ "$output" != *"attempting recovery"* ]]
	run grep -c 'buildx build' "$CALL_LOG"
	[ "$output" -eq 0 ]
}

@test "build pins an explicit platform for every image" {
	run "$script" build
	[ "$status" -eq 0 ]
	run grep -c -- '--platform linux/' "$CALL_LOG"
	# One per entry in SUPERCRED_IMAGES: cardvault, policy-engine,
	# cardvault-agent, supercred-demo-runner. Adding an image without a
	# platform pin still fails this test.
	[ "$output" -eq 4 ]
}

@test "a failed docker build aborts instead of loading a stale image" {
	export DOCKER_BUILD_STATUS=1

	run "$script" load
	[ "$status" -ne 0 ]
	[[ "$output" == *"docker build failed"* ]]
	run grep -c 'kind load' "$CALL_LOG"
	[ "$output" -eq 0 ]
}

@test "an unknown subcommand reports usage" {
	run "$script" frobnicate
	[ "$status" -ne 0 ]
	[[ "$output" == *"Usage:"* ]]
}

@test "IMAGES recovery labels the image CRI-managed, or it is imported and unusable" {
	# The defect this pins, observed live on the CI VM 2026-08-04:
	# reload_via_archive imported cardvault-agent:local successfully, `ctr
	# images ls` listed it, `crictl images` did not, and the deploy failed. The
	# recovery had never once worked, and it reported success every time.
	#
	# containerd's CRI plugin only surfaces images carrying this label, so the
	# label is the step that makes a recovered image runnable rather than merely
	# present.
	CTR_IMPORT_IMAGE="cardvault-agent:local" KIND_LOADS="cardvault:local policy-engine:local supercred-demo-runner:local" \
		run bash "$script" load
	[ "$status" -eq 0 ]
	run grep "images label" "$CALL_LOG"
	[ "$status" -eq 0 ]
	[[ "$output" == *"io.cri-containerd.image=managed"* ]]
	[[ "$output" == *"cardvault-agent"* ]]
}

@test "IMAGES recovery unpacks into the snapshotter the CRI reads" {
	# Same failure by a different route: an import without --snapshotter leaves
	# the layers unextracted, so the image is listed and still not runnable.
	CTR_IMPORT_IMAGE="cardvault-agent:local" KIND_LOADS="cardvault:local policy-engine:local supercred-demo-runner:local" \
		run bash "$script" load
	[ "$status" -eq 0 ]
	run grep "images import" "$CALL_LOG"
	[[ "$output" == *"--snapshotter=overlayfs"* ]]
}
