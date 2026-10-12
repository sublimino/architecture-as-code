#!/usr/bin/env bash
#
# slsi-bundle-fake-crane.bash - a deterministic stand-in for crane, so the OSD-1
# first-party export can be tested with no registry and no network.
#
# @id     slsi-bundle-fake-crane
# @target scripts/package-tenant-bundle.sh (SLSI_CRANE_BIN seam)
# @tests  test/slsi-bundle-osd.bats
#
# It implements exactly the two subcommands the export uses and nothing else, so
# a third call shape fails loudly here rather than being quietly tolerated:
#
#   crane digest --platform all <ref>      prints sha256:<64 hex of the ref>
#   crane pull --format=oci --annotate-ref <repo@digest> <layout>
#                                          writes <layout>/blobs/sha256/<digest>
#
# FAKE_CRANE_UNRESOLVABLE=1 makes `digest` fail, which is the fault injection the
# suite uses to prove the DIGEST-UNRESOLVED sentinel is produced and attributed
# rather than absorbed.
set -o pipefail

_fc_sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

mode="${1:-}"
shift || true

case "${mode}" in
digest)
	[ -z "${FAKE_CRANE_UNRESOLVABLE:-}" ] || {
		echo "fake-crane: digest unresolvable (fault injected)" >&2
		exit 1
	}
	# The export passes the reference last; anything before it is a flag or a
	# flag value and is not a reference.
	ref="${!#}"
	[ -n "${ref}" ] || { echo "fake-crane: digest needs a reference" >&2; exit 2; }
	printf 'sha256:%s\n' "$(_fc_sha "${ref}")"
	;;
pull)
	layout="${!#}"
	ref=""
	for a in "$@"; do
		case "${a}" in
		*@sha256:*) ref="${a}" ;;
		esac
	done
	[ -n "${ref}" ] || { echo "fake-crane: pull needs a digest reference" >&2; exit 2; }
	[ -n "${layout}" ] || { echo "fake-crane: pull needs a layout path" >&2; exit 2; }
	hash="${ref#*@sha256:}"
	mkdir -p "${layout}/blobs/sha256"
	printf '{"imageLayoutVersion":"1.0.0"}\n' >"${layout}/oci-layout"
	# A childless image index: enough for the layout walk to treat it as a
	# reachable descriptor with no dangling children, which is all the export
	# and its closure recount observe.
	printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[],"annotations":{"org.opencontainers.image.ref.name":"%s"}}\n' \
		"${ref}" >"${layout}/blobs/sha256/${hash}"
	;;
*)
	echo "fake-crane: unsupported subcommand '${mode}' (only digest and pull are modelled)" >&2
	exit 2
	;;
esac
