# fake-image-cli.bash — one model of docker and crictl for every suite that
# exercises scripts/lib/image-identity.sh.
#
# ─── Why this file exists ───────────────────────────────────────────────────
#
# image_identity_verify has three callers — kind-load-verified.sh,
# signalfusion-images.sh and supercred-images.sh — and each grew its own hand
# written fake docker. Three copies of the same model, and all three encoded the
# same false premise: that `docker image inspect --format '{{.Id}}'` and the
# crictl IMAGE ID column are the same identifier, because a single derive_id()
# produced both sides from one sha256 of the tag.
#
# They are not the same identifier. On a Docker daemon using the containerd
# image store, .Id is the MANIFEST (or index) digest and crictl reports the
# CONFIG digest. Measured on signalloom-ci, Docker 29.7.1: a correctly loaded
# fe-signalloom reported .Id sha256:24b2503b… against crictl f03fa9444ad8…,
# where f03fa944… is what that same build logged as `exporting config`. The
# guard called a perfect load "a DIFFERENT image" and aborted both CI lanes in
# phase=build-images with 0 of 27 stages run, while 3 bats suites stayed green.
#
# Removing the provenance attestation does not help — .Id is the manifest digest
# even with no index — and the config digest appears nowhere in `docker image
# inspect` output. Identity therefore comes from rootfs diffIDs, which live in
# the image config and read the same on either store.
#
# One file rather than three because drifting fakes are how this class of defect
# returns. A suite that models the two digest types as one value cannot express
# the failure, and a fixture that cannot express a failure cannot test for it.
#
# ─── Contract ───────────────────────────────────────────────────────────────
#
# Sourced BOTH by the .bats file (so assertions can derive the same values) and
# by the fake `docker` script it writes to $BATS_TEST_TMPDIR/bin. Callers own
# their own suite-specific verbs — build, buildx, ctr, kubectl — and delegate
# only the image-identity surface here.
#
#   fake_docker_image_cmd "$@"    handles `docker image inspect …`
#   fake_crictl_cmd "$@"          handles `crictl images` and `crictl inspecti`
#
# Environment knobs, all opt-in so a suite that sets none behaves exactly as it
# did before this file existed:
#
#   CONTAINERD_STORE         diverge .Id (manifest) from the crictl ID (config).
#                            Unset  → both are the legacy sha256-of-ref, so
#                            pre-existing tests keep their original meaning.
#   DOCKER_MISSING           space-separated refs the local daemon does NOT hold
#   DOCKER_NO_LAYERS         local image exists but reports no diffIDs
#   CRICTL_TRUNCATED         emit the kubelet --node-status-max-images warning
#   CRICTL_INSPECTI_STATUS   exit code for `crictl inspecti`
#   CRICTL_INSPECTI_EMPTY    inspecti succeeds with diff_ids: []
#   CRICTL_INSPECTI_REVERSE  same layers, reversed order
#   CRICTL_DIFFID_SEED_REF   stage the ID COLUMN divergent while LAYERS match
#
# $CRICTL_STATE is the node's view: one `ref` per line, optionally `ref id`,
# where the second field overrides the derived ID — that is how a stale image is
# staged, and it seeds the node's diffIDs too, so a stale image differs in its
# LAYERS and not merely in a digest string.

# ─── The three identities an image has ──────────────────────────────────────

# The legacy single ID: what both sides reported before this was understood.
fake_id_legacy() { printf '%s' "$1" | sha256sum | cut -c1-64; }

# What docker reports as .Id under the containerd image store.
fake_id_manifest() { printf 'manifest:%s' "$1" | sha256sum | cut -c1-64; }

# What crictl reports in its IMAGE ID column, on either store.
fake_id_config() { printf 'config:%s' "$1" | sha256sum | cut -c1-64; }

# The ordered rootfs diffID list — the identity both sides can actually agree
# on. Order is part of the identity: the same layers in a different order are
# not the same image, so a comparison that sorts is wrong.
fake_diffids() {
	local seed="$1" i
	for i in 0 1 2; do
		printf 'sha256:%s\n' "$(printf 'layer%s:%s' "$i" "$seed" | sha256sum | cut -c1-64)"
	done
}

# What the LOCAL daemon reports as .Id for a reference.
fake_local_id() {
	if [ -n "${CONTAINERD_STORE:-}" ]; then fake_id_manifest "$1"; else fake_id_legacy "$1"; fi
}

# What the NODE reports in the crictl IMAGE ID column for a reference, absent an
# explicit override in $CRICTL_STATE.
fake_node_id() {
	if [ -n "${CONTAINERD_STORE:-}" ]; then fake_id_config "$1"; else fake_id_legacy "$1"; fi
}

# crictl prints fully-qualified repositories; a bare name:tag becomes
# docker.io/library/name:tag, a registry-qualified one is printed unchanged.
fake_canonical_ref() {
	case "${1%:*}" in */*) printf '%s' "$1" ;; *) printf 'docker.io/library/%s' "$1" ;; esac
}

# The seed the NODE's layers derive from: the $CRICTL_STATE override when there
# is one, so a stale image differs in content and not only in a digest.
# Returns 1 when the node does not hold the reference at all.
fake_node_seed() {
	local want="$1" ref id full
	while IFS=' ' read -r ref id; do
		[ -n "$ref" ] || continue
		full="$(fake_canonical_ref "$ref")"
		if [ "$want" = "$ref" ] || [ "$want" = "$full" ]; then
			if [ -n "${CRICTL_DIFFID_SEED_REF:-}" ]; then printf '%s' "$ref"; else printf '%s' "${id:-$ref}"; fi
			return 0
		fi
	done <"$CRICTL_STATE"
	return 1
}

# ─── The two commands under test ────────────────────────────────────────────

# `docker image inspect --format '{{.Id}}' REF`
# `docker image inspect --format '{{range .RootFS.Layers}}{{println .}}{{end}}' REF`
#
# The layer form is deliberately NOT json: image-identity.sh reads it with a Go
# template precisely so the local side carries no jq dependency.
fake_docker_image_cmd() {
	local ref="${!#}" absent
	for absent in ${DOCKER_MISSING:-}; do
		if [ "$absent" = "$ref" ]; then
			echo "Error: No such image: $ref" >&2
			return 1
		fi
	done
	if [[ "$*" == *"RootFS.Layers"* ]]; then
		[ -n "${DOCKER_NO_LAYERS:-}" ] && return 0
		fake_diffids "$ref"
		return 0
	fi
	printf 'sha256:%s\n' "$(fake_local_id "$ref")"
	return 0
}

# `crictl images` (presence, truncation-aware) and `crictl inspecti REF`
# (identity). Presence and identity are read from separate samples on purpose —
# see the "One sample, not two" note in image-identity.sh — and every failure of
# the identity read is COULD-NOT-VERIFY rather than a pass.
fake_crictl_cmd() {
	local ref id full want seed sep line
	if [ "${1:-}" = "inspecti" ]; then
		want="${!#}"
		seed="$(fake_node_seed "$want")" || {
			echo "FATA[0000] no such image \"$want\"" >&2
			return 1
		}
		[ "${CRICTL_INSPECTI_STATUS:-0}" = 0 ] || return "${CRICTL_INSPECTI_STATUS}"
		if [ -n "${CRICTL_INSPECTI_EMPTY:-}" ]; then
			printf '{"status":{},"info":{"imageSpec":{"rootfs":{"type":"layers","diff_ids":[]}}}}\n'
			return 0
		fi
		printf '{"status":{},"info":{"imageSpec":{"rootfs":{"type":"layers","diff_ids":['
		sep=''
		while read -r line; do
			printf '%s"%s"' "$sep" "$line"
			sep=','
		done < <(if [ -n "${CRICTL_INSPECTI_REVERSE:-}" ]; then fake_diffids "$seed" | tac; else fake_diffids "$seed"; fi)
		printf ']}}}}\n'
		return 0
	fi

	[ -n "${CRICTL_TRUNCATED:-}" ] && \
		echo "supercred-crictl-shim: WARNING node.status.images is at the kubelet cap (50 entries)" >&2
	printf 'IMAGE TAG IMAGE ID SIZE\n'
	while IFS=' ' read -r ref id; do
		[ -n "$ref" ] || continue
		full="$(fake_canonical_ref "$ref")"
		[ -n "$id" ] || id="$(fake_node_id "$ref")"
		# Real crictl TRUNCATES the IMAGE ID to 13 characters.
		printf '%s %s %s 10MB\n' "${full%:*}" "${full##*:}" "${id:0:13}"
	done <"$CRICTL_STATE"
	return 0
}
