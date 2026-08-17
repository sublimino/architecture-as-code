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
#
# ─── Why the fakes model IMAGE IDs ──────────────────────────────────────────
#
# They used to print a constant `abc123` in the IMAGE ID column. That made every
# image on the node indistinguishable from every other, so the entire second
# defect — the node holding a DIFFERENT image under the right tag, measured on
# the live cluster on 2026-08-17 — was invisible to this suite by construction.
# A fixture that cannot express the failure cannot test for it.
#
# So both sides carry an ID now. The local daemon and the node derive the SAME
# deterministic ID from the reference unless a test deliberately diverges them,
# which keeps every existing scenario meaning what it meant. The node's column
# is truncated to 13 characters, as real crictl truncates it, so the prefix
# comparison in scripts/lib/image-identity.sh is genuinely exercised rather than
# assumed.

# The ID an image "really" has, derived from its reference so both sides of the
# comparison agree without a shared state file.
fake_image_id() { printf '%s' "$1" | sha256sum | cut -c1-64; }

setup() {
	script="$BATS_TEST_DIRNAME/../scripts/kind-load-verified.sh"
	bin="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$bin"

	# What the fake node reports through crictl — the CRI's view, i.e. what can
	# actually run. One ref per line, optionally followed by an IMAGE ID to
	# override the derived one (that is how a stale image is staged).
	export CRICTL_STATE="$BATS_TEST_TMPDIR/crictl-images"
	# The local daemon holds everything by default — the caller has just built
	# these images. $DOCKER_MISSING names refs it does NOT hold, which is a real
	# state: a `verify` run from a checkout that never built them.
	export CALL_LOG="$BATS_TEST_TMPDIR/calls.log"
	: >"$CRICTL_STATE"
	: >"$CALL_LOG"

	cat >"$bin/docker" <<-'FAKE'
		#!/usr/bin/env bash
		echo "docker $*" >>"$CALL_LOG"
		derive_id() { printf '%s' "$1" | sha256sum | cut -c1-64; }
		case "$1" in
		  image)
		    # docker image inspect --format '{{.Id}}' REF
		    ref="${!#}"
		    for absent in ${DOCKER_MISSING:-}; do
		      if [ "$absent" = "$ref" ]; then
		        echo "Error: No such image: $ref" >&2
		        exit 1
		      fi
		    done
		    printf 'sha256:%s\n' "$(derive_id "$ref")"
		    exit 0 ;;
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
		        [ -n "${CRICTL_TRUNCATED:-}" ] && \
		          echo "supercred-crictl-shim: WARNING node.status.images is at the kubelet cap (50 entries)" >&2
		        printf 'IMAGE TAG IMAGE ID SIZE\n'
		        while IFS=' ' read -r ref id; do
		          [ -n "$ref" ] || continue
		          # Real crictl prints fully-qualified repositories.
		          case "${ref%:*}" in */*) full="$ref" ;; *) full="docker.io/library/$ref" ;; esac
		          # …and TRUNCATES the IMAGE ID to 13 characters.
		          [ -n "$id" ] || id="$(derive_id "$ref")"
		          printf '%s %s %s 10MB\n' "${full%:*}" "${full##*:}" "${id:0:13}"
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
	# Assert the SCRIPT's verdict, and assert the ID it verified against.
	#
	# This used to assert `*"present on testcluster-control-plane"*`, which the
	# fake kind binary satisfied all by itself with its own progress line —
	# "Image: ... not yet present on node, loading...". The assertion passed
	# whatever the script concluded, including nothing at all. Same class of
	# defect as the one under test: a check matching something other than the
	# thing it names.
	[[ "$output" == *"PASS"*"are the images built locally"* ]]
	[[ "$output" == *"$(fake_image_id fake-integration-proxy:dev | cut -c1-13)"* ]]
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
	[[ "$output" == *"PASS"*"is the locally built image"* ]]
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
	[[ "$output" == *"PASS"*"is the locally built image"* ]]
	# The nonzero status is surfaced rather than swallowed — a load that
	# ANNOUNCED failure is a different bug report from one that claimed success.
	[[ "$output" == *"kind load exited 1"* ]]
}

@test "KINDLOAD with no arguments fails with usage rather than loading nothing" {
	run bash "$script"
	[ "$status" -ne 0 ]
	[[ "$output" == *"usage:"* ]]
}

# ─── Identity, not presence ─────────────────────────────────────────────────
#
# Every test below FAILS against the pre-2026-08-17 check, which compared
# name and tag only:
#
#   image_on_node() {
#     local want="docker.io/library/${image%%:*}:${image##*:}"
#     "$DOCKER_BIN" exec "$NODE" crictl images 2>/dev/null \
#       | awk -v want="$want" '$1":"$2 == want { found = 1 } END { exit !found }'
#   }
#
# Under that check the node's tag is present, so it returns 0, so the script
# exits 0 and reports the build verified. That is the bug, reproduced.

@test "KINDLOAD a STALE image under the right tag is a FAILURE, not a pass" {
	# The 2026-08-17 defect, in a fixture. The node already holds an image under
	# `fake-integration-proxy:dev`, and it is NOT the one just built. kind exits
	# 0 having transferred nothing — KIND_LOADS is empty, so the fake delivers
	# nothing, exactly as the real loader did.
	echo "fake-integration-proxy:dev deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" >"$CRICTL_STATE"

	run bash "$script" fake-integration-proxy:dev
	[ "$status" -ne 0 ]
	[[ "$output" == *"DIFFERENT image"* ]]
	# Both IDs printed, so the reader can act without re-deriving them.
	[[ "$output" == *"$(fake_image_id fake-integration-proxy:dev)"* ]]
	[[ "$output" == *"deadbeefdeadb"* ]]
}

@test "KINDLOAD a stale image is NOT silently repaired" {
	# The non-negotiable half. A gate that re-imports the right image and then
	# reports success leaves the broken loader in place and the next person
	# inherits it — which is how this survived long enough to reach production.
	# Recovery works in this fixture (CTR_IMPORT_IMAGE is set), so if the script
	# were willing to repair a mismatch, it would, and it would exit 0.
	echo "fake-integration-proxy:dev deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" >"$CRICTL_STATE"

	CTR_IMPORT_IMAGE="fake-integration-proxy:dev" run bash "$script" fake-integration-proxy:dev
	[ "$status" -ne 0 ]
	[[ "$output" == *"Nothing has been repaired"* ]]
	# No archive round-trip was even attempted.
	run grep -c "docker save" "$CALL_LOG"
	[ "$output" = "0" ]
}

@test "KINDLOAD a truncated listing that omits the image is COULD-NOT-VERIFY, not pass and not fail" {
	# node.status.images is capped at --node-status-max-images (default 50) and
	# sorted by size, so a small image is absent from the DATA while present on
	# the node. Guessing FAIL here blocked the whole demo on 2026-08-03;
	# guessing PASS is the defect this branch exists to close. So: neither.
	CRICTL_TRUNCATED=1 run bash "$script" fake-integration-proxy:dev
	[ "$status" -eq 3 ]
	[[ "$output" == *"COULD-NOT-VERIFY"* ]]
	[[ "$output" == *"TRUNCATED"* ]]
	[[ "$output" != *"PASS —"* ]]
	# Nothing was repaired on the strength of a listing that could not answer.
	run grep -c "docker save" "$CALL_LOG"
	[ "$output" = "0" ]
}

@test "KINDLOAD an untruncated listing that omits the image is a plain FAILURE" {
	# The control for the test above. Same absence, trustworthy listing, so the
	# absence is real and must be reported as such. Without this, "truncated
	# means inconclusive" could be implemented as "absence always means
	# inconclusive" and nothing here would notice.
	CTR_IMPORT_STATUS=1 run bash "$script" fake-integration-proxy:dev
	[ "$status" -eq 1 ]
	[[ "$output" == *"absent, or are NOT the image built locally"* ]]
	[[ "$output" != *"COULD-NOT-VERIFY"* ]]
}

@test "KINDLOAD an ID column with no usable value cannot pass by comparing two blanks" {
	# scripts/supercred-crictl-shim.sh emits `-` in the IMAGE ID column, because
	# it reads the API server and has no ID to report. An implementation that
	# normalised that to "" and compared it against a local "" would report a
	# perfect match for two things it never looked at — the same vacuous-pass
	# bug class, re-entering through its own fix.
	echo "fake-integration-proxy:dev -" >"$CRICTL_STATE"
	DOCKER_MISSING="fake-integration-proxy:dev" run bash "$script" fake-integration-proxy:dev
	[ "$status" -eq 3 ]
	[[ "$output" == *"COULD-NOT-VERIFY"* ]]
	[[ "$output" != *"PASS —"* ]]
}

@test "KINDLOAD a short IMAGE ID is not accepted as an abbreviation" {
	# A 6-character value is not a truncated sha256, it is noise, and a prefix
	# comparison against it would match a large family of unrelated images. The
	# old fakes printed exactly this (`abc123`) in every row.
	echo "fake-integration-proxy:dev abc123" >"$CRICTL_STATE"
	run bash "$script" fake-integration-proxy:dev
	[ "$status" -eq 3 ]
	[[ "$output" == *"COULD-NOT-VERIFY"* ]]
	[[ "$output" == *"no usable IMAGE ID"* ]]
}

@test "KINDLOAD the node's truncated ID is compared as a PREFIX of the local one" {
	# crictl prints 13 characters; docker prints 64. Comparing them for equality
	# would fail every correct build, and comparing them the other way round —
	# local as a prefix of node — would let a short node value match anything.
	# The fake truncates to 13, so a green happy path IS this assertion; this
	# test pins the direction by staging a node ID that is a prefix of a
	# DIFFERENT image's ID.
	local other
	other="$(fake_image_id some-other-image:dev)"
	echo "fake-integration-proxy:dev $other" >"$CRICTL_STATE"
	run bash "$script" fake-integration-proxy:dev
	[ "$status" -eq 1 ]
	[[ "$output" == *"DIFFERENT image"* ]]
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
		derive_id() { printf '%s' "$1" | sha256sum | cut -c1-64; }
		case "$1" in
		  image) printf 'sha256:%s\n' "$(derive_id "${!#}")"; exit 0 ;;
		  save) for ((i=1;i<=$#;i++)); do [ "${!i}" = "-o" ] && { j=$((i+1)); : >"${!j}"; }; done; exit 0 ;;
		  exec)
		    shift; [ "$1" = "-i" ] && shift; shift
		    case "$1" in
		      crictl)
		        printf 'IMAGE TAG IMAGE ID SIZE\n'
		        n=$(( $(cat "$BATS_TEST_TMPDIR/polls" 2>/dev/null || echo 0) + 1 ))
		        echo "$n" >"$BATS_TEST_TMPDIR/polls"
		        # Absent on the first poll after labelling, present afterwards.
		        [ -f "$BATS_TEST_TMPDIR/labelled" ] && [ "$n" -gt 2 ] && \
		          printf 'docker.io/library/slow-image dev %s 10MB\n' "$(derive_id slow-image:dev | cut -c1-13)"
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
