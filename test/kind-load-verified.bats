#!/usr/bin/env bats
#
# The defect: `kind load docker-image` exits 0 having transferred nothing, so
# the node ends up with a manifest and no layers. `ctr images ls` lists such an
# image; `crictl images` does not; kubelet cannot run it. Three layers away
# that surfaces as a Flux convergence timeout naming no image at all.
#
# These tests run entirely against fake docker/kind binaries — no cluster, no
# daemon — because the whole point is to exercise the FAILURE path, and a real
# kind that happens to work today would exercise nothing. Fakes let the silent
# failure be reproduced on demand.
#
# The fakes are deliberately the same shape as test/supercred-images.bats, so
# the two files can be read together.

setup() {
	script="$BATS_TEST_DIRNAME/../scripts/kind-load-verified.sh"
	bin="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$bin"

	# What the fake node reports through crictl — the CRI's view, i.e. what can
	# actually run. Newline separated refs.
	export CRICTL_STATE="$BATS_TEST_TMPDIR/crictl-images"
	export CALL_LOG="$BATS_TEST_TMPDIR/calls.log"
	: >"$CRICTL_STATE"
	: >"$CALL_LOG"

	cat >"$bin/docker" <<-'FAKE'
		#!/usr/bin/env bash
		echo "docker $*" >>"$CALL_LOG"
		case "$1" in
		  save)
		    # Materialise the archive so the caller's redirect has something to read.
		    for ((i = 1; i <= $#; i++)); do
		      if [ "${!i}" = "-o" ]; then j=$((i + 1)); : >"${!j}"; fi
		    done
		    exit "${DOCKER_SAVE_STATUS:-0}" ;;
		  exec)
		    shift
		    [ "$1" = "-i" ] && shift
		    shift  # node name
		    case "$1" in
		      crictl)
		        printf 'IMAGE TAG IMAGE-ID SIZE\n'
		        while IFS= read -r ref; do
		          [ -n "$ref" ] || continue
		          # Real crictl prints fully-qualified repositories.
		          case "${ref%:*}" in */*) full="$ref" ;; *) full="docker.io/library/$ref" ;; esac
		          printf '%s %s abc123 10MB\n' "${full%:*}" "${full##*:}"
		        done <"$CRICTL_STATE"
		        ;;
		      ctr)
		        case "$*" in
		          *"images import"*)
		            cat >/dev/null
		            # An import alone does NOT make the image visible to the CRI.
		            # Only the label does — mirroring the real containerd, and the
		            # reason the naive recovery path fails silently.
		            [ -n "${CTR_IMPORT_IMAGE:-}" ] && echo "$CTR_IMPORT_IMAGE" >>"$BATS_TEST_TMPDIR/imported"
		            exit "${CTR_IMPORT_STATUS:-0}" ;;
		          *"images label"*)
		            if [ -s "$BATS_TEST_TMPDIR/imported" ] && [ "${CTR_LABEL_STATUS:-0}" = 0 ]; then
		              cat "$BATS_TEST_TMPDIR/imported" >>"$CRICTL_STATE"
		              : >"$BATS_TEST_TMPDIR/imported"
		            fi
		            exit "${CTR_LABEL_STATUS:-0}" ;;
		        esac ;;
		    esac ;;
		esac
		exit 0
	FAKE

	cat >"$bin/kind" <<-'FAKE'
		#!/usr/bin/env bash
		echo "kind $*" >>"$CALL_LOG"
		# The real failure, exactly: prints progress, exits 0, transfers nothing
		# unless KIND_LOADS names the images it actually delivers.
		for img in ${KIND_LOADS:-}; do echo "$img" >>"$CRICTL_STATE"; done
		echo "Image: ... not yet present on node, loading..."
		exit "${KIND_LOAD_STATUS:-0}"
	FAKE

	chmod +x "$bin/docker" "$bin/kind"
	export PATH="$bin:$PATH"
	export CLUSTER_NAME=testcluster
	export KIND_LOAD_NODE=testcluster-control-plane
	touch "$BATS_TEST_TMPDIR/imported"
}

# ─── The happy path stays the happy path ────────────────────────────────────

@test "KINDLOAD a successful load is verified and does not touch the recovery path" {
	KIND_LOADS="fake-integration-proxy:dev" run bash "$script" fake-integration-proxy:dev
	[ "$status" -eq 0 ]
	[[ "$output" == *"present on testcluster-control-plane"* ]]
	# No archive round-trip when the loader did its job.
	run grep -c "docker save" "$CALL_LOG"
	[ "$output" = "0" ]
}

@test "KINDLOAD several images load in ONE kind invocation" {
	# Not cosmetic: the Makefile previously issued one `kind load` per image and
	# each is a full daemon round-trip. Collapsing them is why this wrapper can
	# replace the old calls without costing build time.
	KIND_LOADS="a:dev b:dev" run bash "$script" a:dev b:dev
	[ "$status" -eq 0 ]
	run grep -c "^kind load" "$CALL_LOG"
	[ "$output" = "1" ]
}

# ─── The defect itself ──────────────────────────────────────────────────────

@test "KINDLOAD a silent zero-byte load is DETECTED, not trusted" {
	# kind exits 0 and delivers nothing — the exact production failure. Without
	# recovery available this must fail loudly rather than report success.
	CTR_IMPORT_STATUS=1 run bash "$script" fake-integration-proxy:dev
	[ "$status" -ne 0 ]
	[[ "$output" == *"did NOT reach"* ]]
}

@test "KINDLOAD a silent zero-byte load is RECOVERED via the archive path" {
	CTR_IMPORT_IMAGE="fake-integration-proxy:dev" run bash "$script" fake-integration-proxy:dev
	[ "$status" -eq 0 ]
	[[ "$output" == *"via archive recovery"* ]]
	# The archive must be an OCI index: docker save WITHOUT --platform. The
	# single-platform form imports into something ctr lists and crictl does not,
	# which is the same dead end reached by a different route.
	run grep "docker save" "$CALL_LOG"
	[ "$status" -eq 0 ]
	[[ "$output" != *"--platform"* ]]
}

@test "KINDLOAD recovery labels the image CRI-managed, or it stays invisible" {
	# The load-bearing step. An imported-but-unlabelled image is present in
	# containerd and absent from crictl, so the pod still cannot start. This is
	# what makes the difference between a recovery that works and one that only
	# looks like it did.
	CTR_IMPORT_IMAGE="fake-integration-proxy:dev" run bash "$script" fake-integration-proxy:dev
	[ "$status" -eq 0 ]
	run grep "images label" "$CALL_LOG"
	[ "$status" -eq 0 ]
	[[ "$output" == *"io.cri-containerd.image=managed"* ]]
}

@test "KINDLOAD an import that succeeds but never becomes CRI-visible FAILS" {
	# Import returns 0, label fails, so crictl never lists it. The script must
	# not read "the commands succeeded" as "the image is usable" — that
	# inference is the entire defect, one level down.
	CTR_IMPORT_IMAGE="fake-integration-proxy:dev" CTR_LABEL_STATUS=1 \
		run bash "$script" fake-integration-proxy:dev
	[ "$status" -ne 0 ]
	[[ "$output" == *"not runnable"* ]]
}

@test "KINDLOAD verification uses the CRI view, not the content store" {
	# Guards the choice of check. `ctr images ls` lists a half-transferred image
	# and would make every one of these tests pass while the cluster stayed
	# broken.
	KIND_LOADS="fake-integration-proxy:dev" run bash "$script" fake-integration-proxy:dev
	[ "$status" -eq 0 ]
	run grep -c "crictl images" "$CALL_LOG"
	[ "$output" -ge 1 ]
	run grep -c "ctr -n k8s.io images ls" "$CALL_LOG"
	[ "$output" = "0" ]
}

# ─── Reference handling ─────────────────────────────────────────────────────

@test "KINDLOAD a fully-qualified registry reference is matched as printed" {
	# crictl prints docker.io/library/foo for a bare foo, but prints a
	# registry-qualified repo unchanged. Normalising both to docker.io/library
	# would make the fe-signalloom image look permanently missing and send every
	# build down the recovery path.
	local ref=zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/fe-signalloom:latest
	KIND_LOADS="$ref" run bash "$script" "$ref"
	[ "$status" -eq 0 ]
	[[ "$output" == *"present on"* ]]
	run grep -c "docker save" "$CALL_LOG"
	[ "$output" = "0" ]
}

@test "KINDLOAD a partial delivery recovers only the image that is missing" {
	CTR_IMPORT_IMAGE="netassert-controller:dev" KIND_LOADS="fake-integration-proxy:dev" \
		run bash "$script" fake-integration-proxy:dev netassert-controller:dev
	[ "$status" -eq 0 ]
	# Exactly one archive round-trip: the delivered image must not be re-imported.
	run grep -c "docker save" "$CALL_LOG"
	[ "$output" = "1" ]
	run grep "docker save" "$CALL_LOG"
	[[ "$output" == *"netassert-controller:dev"* ]]
}

# ─── Failure reporting ──────────────────────────────────────────────────────

@test "KINDLOAD failure names the downstream consequence, not just the image" {
	# The failure surfaces three layers away as a Flux convergence timeout that
	# names no image. Anyone who reaches this message should not have to make
	# that connection themselves — it cost two CI runs and most of a night.
	CTR_IMPORT_STATUS=1 run bash "$script" fake-integration-proxy:dev
	[ "$status" -ne 0 ]
	[[ "$output" == *"ImagePullBackOff"* ]]
	[[ "$output" == *"infra-configs"* ]]
	[[ "$output" == *"fe-signalloom"* ]]
}

@test "KINDLOAD a nonzero kind exit still verifies rather than aborting" {
	# kind failing is not proof the image is absent, and kind succeeding is not
	# proof it is present. Only the CRI view decides either way.
	KIND_LOAD_STATUS=1 KIND_LOADS="fake-integration-proxy:dev" \
		run bash "$script" fake-integration-proxy:dev
	[ "$status" -eq 0 ]
	[[ "$output" == *"present on"* ]]
}

@test "KINDLOAD with no arguments fails with usage rather than loading nothing" {
	run bash "$script"
	[ "$status" -ne 0 ]
	[[ "$output" == *"usage:"* ]]
}

@test "KINDLOAD recovery waits for the CRI to adopt the image, rather than checking once" {
	# Adoption is not synchronous. A single immediate re-verify reports a
	# WORKING recovery as a failure, which is worse than a plain failure —
	# it sends the reader looking in the wrong place entirely.
	#
	# The fake makes the image appear only on the second poll.
	cat >"$bin/docker" <<-'SLOW'
		#!/usr/bin/env bash
		echo "docker $*" >>"$CALL_LOG"
		case "$1" in
		  save) for ((i=1;i<=$#;i++)); do [ "${!i}" = "-o" ] && { j=$((i+1)); : >"${!j}"; }; done; exit 0 ;;
		  exec)
		    shift; [ "$1" = "-i" ] && shift; shift
		    case "$1" in
		      crictl)
		        printf 'IMAGE TAG IMAGE-ID SIZE\n'
		        n=$(( $(cat "$BATS_TEST_TMPDIR/polls" 2>/dev/null || echo 0) + 1 ))
		        echo "$n" >"$BATS_TEST_TMPDIR/polls"
		        # Absent on the first poll after labelling, present afterwards.
		        [ -f "$BATS_TEST_TMPDIR/labelled" ] && [ "$n" -gt 2 ] && \
		          printf 'docker.io/library/slow-image dev abc123 10MB\n'
		        ;;
		      ctr)
		        case "$*" in
		          *"images import"*) cat >/dev/null; exit 0 ;;
		          *"images label"*)  : >"$BATS_TEST_TMPDIR/labelled"; exit 0 ;;
		        esac ;;
		    esac ;;
		esac
		exit 0
	SLOW
	chmod +x "$bin/docker"

	KIND_LOAD_CRI_ADOPT_TIMEOUT=10 run bash "$script" slow-image:dev
	[ "$status" -eq 0 ]
	[[ "$output" == *"via archive recovery"* ]]
}
