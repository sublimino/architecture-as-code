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

all_three() {
	printf '%s\n' cardvault:local policy-engine:local cardvault-agent:local
}

@test "verify passes when all three images are runnable on the node" {
	all_three >"$CRICTL_STATE"

	run "$script" verify
	[ "$status" -eq 0 ]
	[[ "$output" == *"cardvault-agent:local present"* ]]
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
	export KIND_LOADS="cardvault:local policy-engine:local"
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
	export KIND_LOADS="cardvault:local policy-engine:local cardvault-agent:local"

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
	[ "$output" -eq 3 ]
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
