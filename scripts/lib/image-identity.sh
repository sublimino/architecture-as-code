#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # IMAGE_IDENTITY_* globals are this library's return channel
# image-identity.sh — is the image on the node THE ONE WE JUST BUILT?
#
# ─── The defect this exists to close ────────────────────────────────────────
#
# Three scripts independently grew the same verification:
#
#   image_on_node() {
#     local want="docker.io/library/${image%%:*}:${image##*:}"
#     "$DOCKER_BIN" exec "$NODE" crictl images 2>/dev/null \
#       | awk -v want="$want" '$1":"$2 == want { found = 1 } END { exit !found }'
#   }
#
# It compares NAME AND TAG ONLY. Tags are mutable, so ANY image carrying that
# tag satisfies it — including the one from the previous build, still sitting on
# the node because `kind load` exited 0 having transferred nothing.
#
# Measured on the live osramp cluster on 2026-08-17, after
# `make demo-signalloom-up` completed with exit 0:
#
#   host docker : signal-ingest:local  sha256:ac70e5d4e068…  14.5MB  (9 min old)
#   kind node   : signal-ingest:local  7913092728b75          5.33MB  (a DIFFERENT image)
#
# and loading it by hand then produced kind's own confirmation that the fresh
# image had never arrived:
#
#   Image: "signal-ingest:local" with ID "sha256:ac70e5d4e068…" not yet present
#   on node "osramp-control-plane", loading...
#
# Every check was green. The cluster ran a different binary. With a bare `:local`
# tag and `imagePullPolicy: IfNotPresent` the kubelet never re-pulls, so a
# workload can run arbitrarily old code indefinitely with nothing to say so.
#
# This is the "green tests tested the wrong artifact" failure promoted into the
# build system: the pipeline's own success line became evidence of nothing.
#
# ─── Presence and identity are two different questions ──────────────────────
#
# Both matter and they fail differently, so this library answers both and never
# collapses them:
#
#   PRESENT   the CRI can run *an* image under this tag. This is the question
#             scripts/supercred-demo.sh's preflight asks, from inside a pod that
#             has no docker daemon and therefore no local image to compare
#             against. Answered by `crictl images` — deliberately not
#             `ctr images ls`, which lists a half-transferred image whose layers
#             never arrived.
#
#   IDENTITY  the image under this tag is byte-for-byte the one the local
#             daemon just built. This is the question a build must ask and the
#             one nobody was asking.
#
# ─── Three outcomes, never two ──────────────────────────────────────────────
#
# A check that can only say PASS or FAIL has to guess when it cannot see. Both
# guesses have cost a day in this repo:
#
#   guess FAIL   2026-08-03. node.status.images is capped at
#                --node-status-max-images (default 50) and sorted by SIZE, so
#                cardvault:local (8.9MB) fell off the end of a list the node was
#                genuinely holding. The preflight blocked the entire demo.
#
#   guess PASS   2026-08-17, the defect above. The gate could not tell a fresh
#                image from a stale one, assumed fresh, and shipped stale.
#
# So the outcome is one of three, named:
#
#   PASS             identity proven — node image ID equals the local one
#   FAIL             identity disproven — absent, or a DIFFERENT image
#   COULD-NOT-VERIFY the data cannot answer — a truncated listing that does not
#                    contain the image, no local image to compare against, or a
#                    listing with no usable IMAGE ID column
#
# COULD-NOT-VERIFY is never silently upgraded to PASS. The caller decides
# policy and must say which of the three it got.
#
# ─── Why this never repairs ─────────────────────────────────────────────────
#
# On a mismatch, callers MUST fail. A gate that reloads the image and then
# reports success is the same gate that shipped the stale binary: the build goes
# green, the broken loader stays broken, and the next person inherits it. Verify
# and fail. The remedy goes in the error message, not in the gate.
#
# ─── Why identity is diffIDs and NOT image IDs ──────────────────────────────
#
# The obvious comparison — docker's image ID against crictl's IMAGE ID — is
# WRONG, and wrong in a way that passes on a laptop and can never pass on CI.
# The two sides do not name the same thing:
#
#   docker image inspect '{{.Id}}'   overlay2 store  → the CONFIG digest
#                                    containerd store → the MANIFEST/INDEX digest
#   crictl images / inspecti         always          → the CONFIG digest
#
# So on Docker's containerd image store the two values are structurally
# different identifiers for the SAME image and the comparison fails 100% of the
# time, deterministically. Measured on signalloom-ci-2, 2026-08-18:
#
#   docker .Id            sha256:59aad5ea7cf4…   (index digest)
#   crictl IMAGE ID       sha256:29d454929e03…   (config digest)
#   docker save .Config   sha256:29d454929e03…   ← identical to crictl
#
# The node held precisely the image just built; the guard called it "a DIFFERENT
# image" and aborted CI in build-images with 0 of 27 stages run, on both the warm
# and the cold lane. Andy's laptop is overlay2, where `.Id` IS the config digest,
# which is why it was never seen locally.
#
# Two fixes that look right and are not:
#
#   `--provenance=false`   collapses the OCI index to a single manifest, so the
#                          mediaType changes and it LOOKS fixed. `.Id` is still
#                          the manifest digest. Measured: withprov .Id c1b53274…,
#                          noprov .Id daf11ba8…, config b675f3a0… both times.
#
#   read the config digest Not available. The config digest appears NOWHERE in
#   from docker inspect    `docker image inspect` output (grep count 0).
#
#   compare `ctr` instead  `ctr -n k8s.io images ls` DOES agree with docker's
#                          `.Id`, which makes crictl look like the broken side.
#                          It is not. ctr reads the content store and lists
#                          images whose manifest arrived while the layers did
#                          not — exactly the half-transferred state this file
#                          exists to catch. Switching to ctr buys a green
#                          comparison and a pod that cannot start.
#
# So identity is the ROOTFS DIFFID LIST, which lives in the image config and is
# therefore identical across both local stores and the CRI:
#
#   local  docker image inspect '{{range .RootFS.Layers}}…'
#   node   crictl inspecti <ref> → .info.imageSpec.rootfs.diff_ids[]
#
# Compared as an EXACT ORDERED LIST. Not a prefix — both sides are full length —
# and order matters, because the same layer set in a different order is a
# different filesystem. This is a strictly stronger check than either digest: it
# compares the actual layer content the kubelet will run.
#
# ─── The empty-vs-empty trap ────────────────────────────────────────────────
#
# The comparison is guarded so it cannot pass vacuously. A diffID list must be
# non-empty, and every entry hex-only and full length, before it is compared at
# all. Without that guard the local list for an image that does not exist
# locally is empty, the node list for an unreadable image is also empty, and
# "" == "" reports a perfect match for two things that were never looked at —
# which is the exact bug class this file was written to close, re-entering
# through the fix.
#
# ─── Sampling, and why the second exec is safe ──────────────────────────────
#
# "One sample, not two" (see image_identity_read_node) forbids deriving an
# authoritative state from two samples that can disagree. The diffID read is a
# SECOND `docker exec`, and it stays inside that rule because the two samples
# answer disjoint questions and only one direction is reachable:
#
#   presence  comes from the single `crictl images` listing, and NOTHING else
#   identity  comes from `crictl inspecti`, and NOTHING else
#
# They are never cross-checked against each other, so no verdict is ever
# assembled from both. Every failure mode of the second sample — inspecti
# erroring, returning no diff_ids, or jq being absent — is COULD-NOT-VERIFY, so
# the extra sample can only ever DOWNGRADE a verdict and can never manufacture a
# PASS.
#
# The shim never reaches it. scripts/supercred-crictl-shim.sh accepts exactly
# `docker exec <node> crictl images` and fails closed on any other argv, so an
# `inspecti` call would break the in-cluster path. It cannot be reached from
# there: the pod has no local docker image, so verify() returns
# COULD-NOT-VERIFY/NO_LOCAL_IMAGE before any inspecti call is made. The in-pod
# caller wants image_identity_present_on_node anyway, which never inspects.
#
#   crictl images            <13 hex>   (TRUNCATED — still used for PRESENCE)
#   supercred-crictl-shim.sh -          (no ID at all)
#
# `--no-trunc` is NOT used on the presence listing, for the shim reason above.

# ─── Normalisation ──────────────────────────────────────────────────────────

# Print the reference the way crictl prints it. A bare `name:tag` is normalised
# to docker.io/library/name:tag; anything already carrying a registry or a path
# is printed as given.
image_identity_canonical_ref() {
	local image="$1" repo="${1%:*}" tag="${1##*:}"
	case "$repo" in
	*/*) printf '%s:%s' "$repo" "$tag" ;;
	*) printf 'docker.io/library/%s:%s' "$repo" "$tag" ;;
	esac
}

# Print a comparable image ID, or NOTHING when the input cannot serve as one.
#
# Returning empty for unusable input is deliberate and load-bearing: every
# comparison below refuses to run on an empty ID, so an unreadable value can
# only ever produce COULD-NOT-VERIFY, never a match.
image_identity_normalise_id() {
	local id="${1:-}"
	id="${id#sha256:}"
	id="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
	# `-` (the shim's placeholder), `<none>`, and anything non-hex are not IDs.
	case "$id" in
	'' | *[!0-9a-f]*) return 0 ;;
	esac
	# 12 hex characters is the shortest abbreviation any container runtime
	# prints. Anything shorter is not an abbreviation, it is noise, and a short
	# prefix comparison would match unrelated images.
	[ "${#id}" -ge 12 ] || return 0
	printf '%s' "$id"
}

# ─── Reading the two sides ──────────────────────────────────────────────────

# The local daemon's ID for a tag. Empty when there is no such local image —
# which is the normal case inside the demo runner pod, where `docker` is
# scripts/supercred-crictl-shim.sh and understands only `exec <node> crictl
# images`.
image_identity_local_id() {
	local image="$1" raw
	raw="$("${DOCKER_BIN:-docker}" image inspect --format '{{.Id}}' "$image" 2>/dev/null)" || return 0
	image_identity_normalise_id "$raw"
}

# ─── diffIDs — the identity axis ────────────────────────────────────────────

# Validate and normalise a newline-separated diffID list, or print NOTHING.
#
# All-or-nothing on purpose. A list that parsed partially is not a weaker
# answer, it describes a DIFFERENT filesystem — so one malformed entry voids the
# whole list rather than silently shortening it into something that could
# compare equal to a truncated read of the other side.
image_identity_normalise_diffids() {
	local line out="" n=0
	while IFS= read -r line; do
		line="${line#sha256:}"
		line="$(printf '%s' "$line" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
		[ -n "$line" ] || continue
		# Full-length hex only. Unlike the 13-character IDs crictl prints in its
		# table, diff_ids are never abbreviated on either side, so anything short
		# is corruption rather than an abbreviation to be accommodated.
		case "$line" in
		*[!0-9a-f]*) return 0 ;;
		esac
		[ "${#line}" -eq 64 ] || return 0
		out="${out}${line}"$'\n'
		n=$((n + 1))
	done
	[ "$n" -gt 0 ] || return 0
	printf '%s' "$out"
}

# The local daemon's rootfs diffIDs for a tag.
#
# A Go template, not jq: the local side stays free of any JSON dependency, and
# `.RootFS.Layers` is the same list on the overlay2 and containerd stores alike
# — which is the entire reason identity moved onto this axis.
#
# Empty when there is no such local image. That is the normal case under
# scripts/supercred-crictl-shim.sh, and it is load-bearing: verify() checks the
# local side FIRST, so the in-pod path returns NO_LOCAL_IMAGE before it can
# reach the node-side inspecti the shim would reject.
image_identity_local_diffids() {
	local image="$1" raw
	raw="$("${DOCKER_BIN:-docker}" image inspect \
		--format '{{range .RootFS.Layers}}{{println .}}{{end}}' "$image" 2>/dev/null)" || return 0
	printf '%s\n' "$raw" | image_identity_normalise_diffids
}

# The node's rootfs diffIDs, via the CRI's own view of what it will run — the
# same authority `crictl images` carries for presence.
#
# Fails closed in every direction. A missing jq, a non-zero inspecti, a payload
# with no diff_ids: all print nothing, and the caller turns nothing into
# COULD-NOT-VERIFY. None of them can produce a match.
image_identity_node_diffids() {
	local image="$1" ref raw
	command -v jq >/dev/null 2>&1 || return 0
	ref="$(image_identity_canonical_ref "$image")"
	raw="$("${DOCKER_BIN:-docker}" exec "${NODE:?image-identity: NODE is not set}" \
		crictl inspecti "$ref" 2>/dev/null)" || return 0
	printf '%s' "$raw" \
		| jq -r '.info.imageSpec.rootfs.diff_ids[]?' 2>/dev/null \
		| image_identity_normalise_diffids
}

# Read the node's `crictl images` ONCE, into two globals:
#
#   IMAGE_IDENTITY_LISTING     the table (stdout)
#   IMAGE_IDENTITY_TRUNCATED   yes | no, from the warning the shim writes to
#                              stderr when node.status.images is at the
#                              kubelet's --node-status-max-images cap. That list
#                              is sorted by size, so small images fall off the
#                              end while sitting happily on the node.
#
# One sample, not two. The predecessor read the table and then ran a SECOND
# `docker exec` to ask whether it had been truncated — two samples of a changing
# system, which between them can report a state that never existed.
#
# stderr goes to a file rather than through `… 2>&1 >/dev/null | grep -q`.
# `grep -q` exits on first match, closing the pipe and killing the upstream
# `docker exec` with SIGPIPE (141), which under `set -o pipefail` becomes the
# pipeline's status — so "is it truncated?" answered NO for a listing that had
# just said it was truncated. Same defect as the one documented in
# scripts/supercred-images.sh, on the stderr leg instead of the stdout one.
image_identity_read_node() {
	local err status=0
	err="$(mktemp -t image-identity-stderr-XXXXXX)"
	IMAGE_IDENTITY_LISTING="$(
		"${DOCKER_BIN:-docker}" exec "${NODE:?image-identity: NODE is not set}" crictl images 2>"$err"
	)" || status=$?
	if grep -q "node.status.images is at the kubelet cap" "$err"; then
		IMAGE_IDENTITY_TRUNCATED="yes"
	else
		IMAGE_IDENTITY_TRUNCATED="no"
	fi
	rm -f "$err"
	return "$status"
}

# The node's `crictl images` table, as text.
image_identity_node_listing() {
	image_identity_read_node || true
	printf '%s' "$IMAGE_IDENTITY_LISTING"
}

# True when the listing last read is known to be incomplete, in which case a
# miss proves nothing.
image_identity_listing_is_truncated() {
	[ -n "${IMAGE_IDENTITY_TRUNCATED:-}" ] || image_identity_read_node || true
	[ "${IMAGE_IDENTITY_TRUNCATED:-no}" = "yes" ]
}

# Print `PRESENT <id>` or `ABSENT`, reading the listing to EOF.
#
# The match runs inside a single awk rather than piping into `grep -q`. grep -q
# exits on first match, closing the pipe and killing the upstream with SIGPIPE
# (141), which under `set -o pipefail` becomes the pipeline's status — so the
# check reported FAILURE for an image that was present, and did so more reliably
# the more images the node had. That is recorded at length in
# scripts/supercred-images.sh; it is not hypothetical.
#
# Columns are compared as columns. `crictl images` is columnar, and a substring
# match against the whole line lets an unrelated column satisfy the tag: on the
# live node, `docker.io/library/postgres 16-alpine de3a4eab8fdfa 116MB`
# satisfies `postgres:116` (the SIZE) and `postgres:de3` (the IMAGE ID).
image_identity_node_state() {
	local want listing="$2"
	want="$(image_identity_canonical_ref "$1")"
	awk -v want="$want" '
		$1 == "IMAGE" { next }
		$1":"$2 == want && !found { found = 1; id = $3 }
		END { if (found) printf "PRESENT %s\n", id; else print "ABSENT" }
	' <<<"$listing"
}

# ─── The verdict ────────────────────────────────────────────────────────────

# image_identity_verify IMAGE
#
# Reads the node once via image_identity_read_node unless the caller has already
# done so this iteration (IMAGE_IDENTITY_LISTING set). Taking the listing as a
# parameter was tempting and wrong: the truncation flag comes from the SAME
# `docker exec`, so a caller could hand in one sample's table while the flag
# still described another's, and the pair would describe a node that never was.
#
# Sets, for the caller to read:
#   IMAGE_IDENTITY_RESULT    PASS | FAIL | COULD-NOT-VERIFY
#   IMAGE_IDENTITY_OUTCOME   MATCH | MISMATCH | ABSENT | NO_LOCAL_IMAGE
#                            | NO_NODE_ID | NO_LOCAL_DIFFIDS | NO_NODE_DIFFIDS
#                            | LISTING_TRUNCATED
#   IMAGE_IDENTITY_PRESENT   yes | no | unknown   (presence, independent of identity)
#   IMAGE_IDENTITY_LOCAL_ID  normalised local ID, or empty  (DIAGNOSTIC ONLY —
#   IMAGE_IDENTITY_NODE_ID   normalised node ID, or empty     these two are NOT
#                            the identity axis; see the header. Comparing them
#                            is the defect this file was rewritten to close.)
#   IMAGE_IDENTITY_LOCAL_DIFFIDS  newline-separated rootfs diffIDs, or empty
#   IMAGE_IDENTITY_NODE_DIFFIDS   newline-separated rootfs diffIDs, or empty
#   IMAGE_IDENTITY_DETAIL    one line naming exactly what was compared
#
# Returns 0 for PASS, 1 for FAIL, 2 for COULD-NOT-VERIFY.
image_identity_verify() {
	local image="$1"

	IMAGE_IDENTITY_RESULT=""
	IMAGE_IDENTITY_OUTCOME=""
	IMAGE_IDENTITY_PRESENT="unknown"
	IMAGE_IDENTITY_LOCAL_ID=""
	IMAGE_IDENTITY_NODE_ID=""
	IMAGE_IDENTITY_LOCAL_DIFFIDS=""
	IMAGE_IDENTITY_NODE_DIFFIDS=""
	IMAGE_IDENTITY_DETAIL=""

	[ -n "${IMAGE_IDENTITY_LISTING+set}" ] || image_identity_read_node || true

	local state node_raw=""
	read -r state node_raw <<<"$(image_identity_node_state "$image" "$IMAGE_IDENTITY_LISTING")"

	IMAGE_IDENTITY_LOCAL_ID="$(image_identity_local_id "$image")"
	IMAGE_IDENTITY_NODE_ID="$(image_identity_normalise_id "$node_raw")"

	if [ "$state" != "PRESENT" ]; then
		# Absent from a listing that cannot be trusted to be complete answers
		# nothing. Absent from a complete one is a real, hard answer.
		if image_identity_listing_is_truncated; then
			IMAGE_IDENTITY_PRESENT="unknown"
			IMAGE_IDENTITY_RESULT="COULD-NOT-VERIFY"
			IMAGE_IDENTITY_OUTCOME="LISTING_TRUNCATED"
			IMAGE_IDENTITY_DETAIL="$image is not in ${NODE:-the node}'s image listing, but that listing is TRUNCATED (kubelet --node-status-max-images cap, size-sorted) — this is inconclusive, not absent"
			return 2
		fi
		IMAGE_IDENTITY_PRESENT="no"
		IMAGE_IDENTITY_RESULT="FAIL"
		IMAGE_IDENTITY_OUTCOME="ABSENT"
		IMAGE_IDENTITY_DETAIL="$image is not runnable on ${NODE:-the node} — no such tag in the CRI's image listing"
		# Say which of the two states this is. An empty listing makes EVERY image
		# "absent", which is a confident answer derived from no data — and reads
		# as a build problem when it is a "cannot reach the node" problem. The
		# verdict stays FAIL (failing closed on an unreadable node is right, and
		# is the pre-existing behaviour), but it stops pointing at the wrong
		# thing.
		if [ -z "${IMAGE_IDENTITY_LISTING//[[:space:]]/}" ]; then
			IMAGE_IDENTITY_DETAIL="cannot read an image listing from ${NODE:-the node} at all, so $image is unproven rather than disproven — is this a kind cluster, and is \`${DOCKER_BIN:-docker} exec ${NODE:-<node>} crictl images\` permitted from here?"
		fi
		return 1
	fi

	IMAGE_IDENTITY_PRESENT="yes"

	if [ -z "$IMAGE_IDENTITY_LOCAL_ID" ]; then
		IMAGE_IDENTITY_RESULT="COULD-NOT-VERIFY"
		IMAGE_IDENTITY_OUTCOME="NO_LOCAL_IMAGE"
		IMAGE_IDENTITY_DETAIL="$image is present on ${NODE:-the node}, but there is no local image of that name to compare it against — presence proven, identity unproven"
		return 2
	fi

	if [ -z "$IMAGE_IDENTITY_NODE_ID" ]; then
		IMAGE_IDENTITY_RESULT="COULD-NOT-VERIFY"
		IMAGE_IDENTITY_OUTCOME="NO_NODE_ID"
		IMAGE_IDENTITY_DETAIL="$image is present on ${NODE:-the node}, but the listing carries no usable IMAGE ID (got '${node_raw:-<empty>}') — presence proven, identity unproven"
		return 2
	fi

	# Identity is the diffID list. Read the local side FIRST: under the crictl
	# shim there is no local image, and returning here is what keeps the in-pod
	# path from ever issuing the `inspecti` the shim would reject.
	IMAGE_IDENTITY_LOCAL_DIFFIDS="$(image_identity_local_diffids "$image")"
	if [ -z "$IMAGE_IDENTITY_LOCAL_DIFFIDS" ]; then
		IMAGE_IDENTITY_RESULT="COULD-NOT-VERIFY"
		IMAGE_IDENTITY_OUTCOME="NO_LOCAL_DIFFIDS"
		IMAGE_IDENTITY_DETAIL="$image exists locally but its rootfs diffIDs are unreadable — presence proven, identity unproven"
		return 2
	fi

	IMAGE_IDENTITY_NODE_DIFFIDS="$(image_identity_node_diffids "$image")"
	if [ -z "$IMAGE_IDENTITY_NODE_DIFFIDS" ]; then
		IMAGE_IDENTITY_RESULT="COULD-NOT-VERIFY"
		IMAGE_IDENTITY_OUTCOME="NO_NODE_DIFFIDS"
		IMAGE_IDENTITY_DETAIL="$image is present on ${NODE:-the node}, but its rootfs diffIDs are unreadable — presence proven, identity unproven. Is jq installed, and does \`${DOCKER_BIN:-docker} exec ${NODE:-<node>} crictl inspecti $(image_identity_canonical_ref "$image")\` work from here?"
		return 2
	fi

	# Exact, ordered list equality. NOT a prefix test: diff_ids are full length
	# on both sides, and order is part of the identity — the same layers stacked
	# in a different order are a different filesystem.
	if [ "$IMAGE_IDENTITY_LOCAL_DIFFIDS" = "$IMAGE_IDENTITY_NODE_DIFFIDS" ]; then
		IMAGE_IDENTITY_RESULT="PASS"
		IMAGE_IDENTITY_OUTCOME="MATCH"
		IMAGE_IDENTITY_DETAIL="$image on ${NODE:-the node} is the locally built image ($(printf '%s' "$IMAGE_IDENTITY_LOCAL_DIFFIDS" | grep -c . ) matching rootfs layers)"
		return 0
	fi

	IMAGE_IDENTITY_RESULT="FAIL"
	IMAGE_IDENTITY_OUTCOME="MISMATCH"
	IMAGE_IDENTITY_DETAIL="$image on ${NODE:-the node} is a DIFFERENT image from the one built locally
       local rootfs layers  $(printf '%s' "$IMAGE_IDENTITY_LOCAL_DIFFIDS" | grep -c .)
       node  rootfs layers  $(printf '%s' "$IMAGE_IDENTITY_NODE_DIFFIDS" | grep -c .)
       first divergence at layer $(diff <(printf '%s' "$IMAGE_IDENTITY_LOCAL_DIFFIDS") <(printf '%s' "$IMAGE_IDENTITY_NODE_DIFFIDS") 2>/dev/null | grep -m1 -oE '^[0-9]+' || echo '?')
       The tag is the same and the content is not. \`kind load\` exited without
       transferring, so the node kept the previous build and the workload will
       keep running it — imagePullPolicy IfNotPresent on a bare :local tag never
       re-pulls.

       This compares rootfs diffIDs, not image IDs. If you are about to \"fix\"
       this by comparing docker's .Id to crictl's IMAGE ID, read the header:
       those are different digest types on the containerd image store and can
       never match."
	return 1
}

# Presence only, for callers that have no local image to compare against (the
# demo runner pod). Kept as a separate, explicitly named entry point so that
# nobody reaches for it by accident where identity is the real question.
image_identity_present_on_node() {
	local image="$1" state node_raw=""
	[ -n "${IMAGE_IDENTITY_LISTING+set}" ] || image_identity_read_node || true
	read -r state node_raw <<<"$(image_identity_node_state "$image" "$IMAGE_IDENTITY_LISTING")"
	[ "$state" = "PRESENT" ]
}

# Drop the cached sample. Anything that polls — a recovery loop waiting for the
# CRI to adopt an image — MUST call this between iterations, or it will spend
# the whole timeout re-reading the one table it read before the change it is
# waiting for.
image_identity_invalidate() {
	unset IMAGE_IDENTITY_LISTING IMAGE_IDENTITY_TRUNCATED
}
