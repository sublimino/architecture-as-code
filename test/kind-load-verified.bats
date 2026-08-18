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

# ─── Why one derived ID was not enough ──────────────────────────────────────
#
# Everything above is true and still let the 2026-08-18 defect through, because
# both sides of the comparison were derived by ONE function from ONE input. The
# fixture asserted that `docker image inspect --format '{{.Id}}'` and the
# crictl IMAGE ID column are the same identifier. On a Docker daemon using the
# containerd image store they are not, and never can be:
#
#   docker .Id       the MANIFEST (or index) digest of the image
#   crictl IMAGE ID  the CONFIG digest
#
# Different values for the same image, always. Measured on signalloom-ci
# (Docker 29.7.1, driver-type io.containerd.snapshotter.v1): a correctly loaded
# fe-signalloom reported .Id sha256:24b2503b… against crictl f03fa9444ad8…,
# where f03fa944… is exactly what that build logged as `exporting config`. The
# guard called a perfect load "a DIFFERENT image" and aborted both CI lanes at
# phase=build-images with 0 of 27 stages run.
#
# Removing the provenance attestation does NOT fix it — .Id is the manifest
# digest even with no index at all — and the config digest appears nowhere in
# `docker image inspect` output, so there is no field to read it from either.
# The comparison has to move to diffIDs, which live in the image config and are
# therefore the same on both sides whatever the store.
#
# So the fakes now model THREE things per image: the manifest digest docker
# reports, the config digest crictl reports, and the diffIDs both agree on.
# By default the first two are identical, exactly as before, so every test
# written against the single-ID fixture keeps meaning what it meant. Setting
# $CONTAINERD_STORE diverges them the way a real containerd-store daemon does,
# which is the case no fixture in this repo could previously express.

# The three identities, plus the diffID list, now live in one place shared with
# signalfusion-images.bats and supercred-images.bats. Kept as a local alias so
# the assertions below still read in this file's own terms.
fake_image_id() { fake_id_legacy "$1"; }

setup() {
	script="$BATS_TEST_DIRNAME/../scripts/kind-load-verified.sh"
	bin="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$bin"

	# One model of docker and crictl across all three suites that exercise
	# image-identity.sh. Exported so the fake `docker` written below can source
	# it, and sourced here so assertions derive the same values the fake does.
	export FAKE_IMAGE_CLI="$BATS_TEST_DIRNAME/lib/fake-image-cli.bash"
	# shellcheck source=test/lib/fake-image-cli.bash
	source "$FAKE_IMAGE_CLI"

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
		# The image-identity surface is shared with signalfusion-images.bats and
		# supercred-images.bats — see test/lib/fake-image-cli.bash for why one
		# model rather than three.
		source "$FAKE_IMAGE_CLI"
		case "$1" in
		  image)
		    shift
		    fake_docker_image_cmd "$@"
		    exit $? ;;
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
		        shift
		        fake_crictl_cmd "$@"
		        exit $? ;;
		      ctr)
		        case "$*" in
		          # The CONTENT STORE, which is a different thing from the CRI view.
		          # $CTR_CONTENT names refs whose bytes are already on the node —
		          # the state measured on signalloom-ci-2 on 2026-08-18, where ctr
		          # held 102 images and crictl could run 40 of them.
		          *"images ls"*)
		            for r in ${CTR_CONTENT:-}; do
		              echo "docker.io/library/$r application/vnd.oci.image.index.v1+json sha256:deadbeef"
		            done
		            exit 0 ;;
		          *"images import"*)
		            cat >/dev/null
		            # An import alone does NOT make the image visible to the CRI.
		            # Only the label does — mirroring the real containerd, and the
		            # reason the naive recovery path fails silently.
		            [ -n "${CTR_IMPORT_IMAGE:-}" ] && echo "$CTR_IMPORT_IMAGE" >>"$BATS_TEST_TMPDIR/imported"
		            exit "${CTR_IMPORT_STATUS:-0}" ;;
		          *"images label"*)
		            if [ "${CTR_LABEL_STATUS:-0}" = 0 ]; then
		              # Labelling adopts whatever bytes are on the node, whether
		              # they arrived by import just now or were already in the
		              # content store. The second case is the whole point: the
		              # bytes were never missing, only the label was.
		              if [ -s "$BATS_TEST_TMPDIR/imported" ]; then
		                cat "$BATS_TEST_TMPDIR/imported" >>"$CRICTL_STATE"
		                : >"$BATS_TEST_TMPDIR/imported"
		              fi
		              for r in ${CTR_CONTENT:-}; do echo "$r" >>"$CRICTL_STATE"; done
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
	# The evidence a reader needs, in the terms the check now works in. This
	# used to assert that both IMAGE IDs were printed; identity no longer reads
	# the crictl ID column at all, so asserting it would pin a value the guard
	# does not consult — a test passing on something other than the thing it
	# names, which is the defect class this suite exists for.
	[[ "$output" == *"local rootfs layers"* ]]
	[[ "$output" == *"node  rootfs layers"* ]]
	[[ "$output" == *"first divergence at layer"* ]]
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

@test "KINDLOAD the two digest columns are NOT compared against each other" {
	# Replaces "the node's truncated ID is compared as a PREFIX of the local
	# one", which encoded the broken assumption and had to go: docker's .Id and
	# crictl's IMAGE ID are different digest TYPES, so no comparison between
	# them — prefix, equality or otherwise — can ever be correct.
	#
	# The inverse assertion, and the one that catches a reintroduction. The node
	# advertises an IMAGE ID with nothing whatsoever in common with the local
	# .Id, while the layers match exactly. Identity comes from the layers, so
	# this is a PASS. Anyone who reinstates an .Id-vs-IMAGE-ID comparison turns
	# this red.
	echo "fake-integration-proxy:dev deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" >"$CRICTL_STATE"

	CRICTL_DIFFID_SEED_REF=1 run bash "$script" fake-integration-proxy:dev
	[ "$status" -eq 0 ]
	[[ "$output" != *"DIFFERENT image"* ]]
	[[ "$output" == *"PASS"* ]]
}

@test "KINDLOAD a local image whose diffIDs cannot be read is COULD-NOT-VERIFY" {
	# NO_LOCAL_DIFFIDS. The local image exists — so this is not NO_LOCAL_IMAGE —
	# but its layer list comes back empty. Nothing to compare is not agreement,
	# and an identity check that treats two empty lists as equal passes
	# vacuously against every image in the estate.
	DOCKER_NO_LAYERS=1 KIND_LOADS="fake-integration-proxy:dev" \
		run bash "$script" fake-integration-proxy:dev
	[[ "$output" != *"PASS"* ]]
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
		diffids() {
		  local seed="$1" i
		  for i in 0 1 2; do
		    printf 'sha256:%s\n' "$(printf 'layer%s:%s' "$i" "$seed" | sha256sum | cut -c1-64)"
		  done
		}
		case "$1" in
		  image)
		    if [[ "$*" == *"RootFS.Layers"* ]]; then
		      diffids "${!#}"; exit 0
		    fi
		    printf 'sha256:%s\n' "$(derive_id "${!#}")"; exit 0 ;;
		  save) for ((i=1;i<=$#;i++)); do [ "${!i}" = "-o" ] && { j=$((i+1)); : >"${!j}"; }; done; exit 0 ;;
		  exec)
		    shift; [ "$1" = "-i" ] && shift; shift
		    case "$1" in
		      crictl)
		        # Only `crictl images` counts as a poll. An inspecti read must not
		        # advance the adoption clock, or the thing under test changes
		        # meaning the moment the implementation adds a second read.
		        if [ "$2" = "inspecti" ]; then
		          n=$(cat "$BATS_TEST_TMPDIR/polls" 2>/dev/null || echo 0)
		          if [ -f "$BATS_TEST_TMPDIR/labelled" ] && [ "$n" -gt 2 ]; then
		            printf '{"status":{},"info":{"imageSpec":{"rootfs":{"type":"layers","diff_ids":['
		            sep=''
		            while read -r l; do printf '%s"%s"' "$sep" "$l"; sep=','; done < <(diffids slow-image:dev)
		            printf ']}}}}\n'
		            exit 0
		          fi
		          echo 'FATA[0000] no such image' >&2; exit 1
		        fi
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

# ─── The containerd image store: two identifiers, one image ─────────────────
#
# Every test below FAILS against the 2026-08-18 check, which compared docker's
# .Id against the crictl IMAGE ID column. See the header for the measurement.
# They are the cases the single-derived-ID fixture could not express, so they
# are the ones that let a false "DIFFERENT image" abort two CI lanes.

@test "KINDLOAD containerd store: a manifest digest and a config digest are the SAME image" {
	# The regression, in a fixture. The node holds exactly what was just built.
	# docker reports the manifest digest, crictl reports the config digest, and
	# a guard that compares those two calls a perfect load a mismatch.
	CONTAINERD_STORE=1 KIND_LOADS="fake-integration-proxy:dev" \
		run bash "$script" fake-integration-proxy:dev
	[ "$status" -eq 0 ]
	[[ "$output" != *"DIFFERENT image"* ]]
	[[ "$output" == *"PASS"* ]]
}

@test "KINDLOAD containerd store: a STALE image is still caught" {
	# The other half, and the reason the fix cannot simply be "stop comparing".
	# The node holds a genuinely different image, so its layers differ too.
	echo "fake-integration-proxy:dev deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" >"$CRICTL_STATE"

	CONTAINERD_STORE=1 run bash "$script" fake-integration-proxy:dev
	[ "$status" -ne 0 ]
	[[ "$output" == *"DIFFERENT image"* ]]
}

@test "KINDLOAD identity is read from diffIDs, not from a digest column" {
	# Asserts the MECHANISM, not just the verdict. Both tests above are also
	# satisfied by a guard that compares nothing at all in the matching case and
	# gets lucky in the stale one, so without this the suite can go green
	# against an implementation that quietly dropped the identity check.
	CONTAINERD_STORE=1 KIND_LOADS="fake-integration-proxy:dev" \
		run bash "$script" fake-integration-proxy:dev
	[ "$status" -eq 0 ]
	run grep -c "RootFS.Layers" "$CALL_LOG"
	[ "$output" -ge 1 ]
	run grep -c "crictl inspecti" "$CALL_LOG"
	[ "$output" -ge 1 ]
}

@test "KINDLOAD diffID ORDER is part of the identity" {
	# Same layer set, different order, is not the same image. A comparison that
	# sorts or set-matches would pass this and must not.
	CONTAINERD_STORE=1 CRICTL_INSPECTI_REVERSE=1 KIND_LOADS="fake-integration-proxy:dev" \
		run bash "$script" fake-integration-proxy:dev
	[ "$status" -ne 0 ]
	# Naming the verdict, not merely a nonzero exit: a bare status check passes
	# for ANY failure, including the script not existing, which is the vacuous
	# shape scripts/check-vacuous-assertions.sh rejects.
	[[ "$output" == *"DIFFERENT image"* ]]
}

@test "KINDLOAD an inspecti that fails is COULD-NOT-VERIFY, never a pass" {
	# Fail-closed on the second sample. Presence comes from the listing and
	# identity from inspecti; if the identity read errors, the image is present
	# but unproven. Reporting that as verified would reintroduce the whole
	# class of defect one level down.
	CONTAINERD_STORE=1 CRICTL_INSPECTI_STATUS=1 KIND_LOADS="fake-integration-proxy:dev" \
		run bash "$script" fake-integration-proxy:dev
	[[ "$output" != *"PASS"* ]]
}

@test "KINDLOAD an inspecti returning no diffIDs is COULD-NOT-VERIFY, never a pass" {
	# The empty-list variant: the call succeeds and answers nothing. An identity
	# check that treats "no layers on either side" as equality passes vacuously,
	# which is the failure mode scripts/check-vacuous-assertions.sh exists for.
	CONTAINERD_STORE=1 CRICTL_INSPECTI_EMPTY=1 KIND_LOADS="fake-integration-proxy:dev" \
		run bash "$script" fake-integration-proxy:dev
	[[ "$output" != *"PASS"* ]]
}

# ─── Label-first recovery ───────────────────────────────────────────────────
#
# Measured on signalloom-ci-2, 2026-08-18, during a cold run that aborted in
# build-images. The diagnostics caught the failure in the act:
#
#   ctr, content store:  docker.io/library/fake-integration-proxy:dev sha256:fe4a005f…
#   crictl, CRI view:    (empty)
#   totals: ctr=88 crictl=33
#   node disk: 8% used, 178G avail
#
# and the recovery that fixed it reported:
#
#   Importing  elapsed: 0.3 s  total: 0.0 B  (0.0 B/s)
#
# Zero bytes. The bytes were never missing — only the
# io.cri-containerd.image=managed label was. So the export-and-reimport is doing
# expensive work for a condition that is not the one present.

@test "KINDLOAD content already on the node is adopted by LABELLING, not by re-exporting it" {
	# The load leaves nothing runnable (KIND_LOADS unset) but the bytes ARE in
	# the content store. Recovery must label what is there.
	CONTAINERD_STORE=1 CTR_CONTENT="fake-integration-proxy:dev" \
		run bash "$script" fake-integration-proxy:dev
	[ "$status" -eq 0 ]
	[[ "$output" == *"PASS"* ]]
	# The point of the change: no tar was written and nothing was re-imported to
	# move 0.0 B. Asserting the ABSENCE of the expensive path, because a recovery
	# that still exports would satisfy a status-only check and pass vacuously.
	run grep -c "images import" "$CALL_LOG"
	[ "$output" -eq 0 ]
	run grep -c "^docker save" "$CALL_LOG"
	[ "$output" -eq 0 ]
}

@test "KINDLOAD content genuinely absent still takes the full export path" {
	# The fallback must survive. If the bytes really are missing, labelling
	# cannot conjure them and the export is the only thing that can work.
	CONTAINERD_STORE=1 CTR_IMPORT_IMAGE="fake-integration-proxy:dev" \
		run bash "$script" fake-integration-proxy:dev
	[ "$status" -eq 0 ]
	[[ "$output" == *"PASS"* ]]
	run grep -c "images import" "$CALL_LOG"
	[ "$output" -gt 0 ]
}

@test "KINDLOAD content absent and the export failing still fails CLOSED" {
	# Neither path can deliver. The run must fail and say so — a recovery that
	# cannot recover must never report success.
	CONTAINERD_STORE=1 CTR_IMPORT_STATUS=1 \
		run bash "$script" fake-integration-proxy:dev
	[ "$status" -ne 0 ]
	[[ "$output" == *"FAILED"* ]]
	[[ "$output" != *"✓ PASS — all"* ]]
}
