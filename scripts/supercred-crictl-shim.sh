#!/usr/bin/env bash
set -euo pipefail

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

render_argv() {
	if [ "$#" -eq 0 ]; then
		printf '<empty>'
		return 0
	fi

	local arg rendered=""
	for arg in "$@"; do
		printf -v rendered '%s%q ' "$rendered" "$arg"
	done
	printf '%s' "${rendered% }"
}

unsupported() {
	local argv
	argv="$(render_argv "$@")"
	printf 'supercred-crictl-shim: unsupported docker argv: %s\n' "$argv" >&2
	exit 1
}

emit_crictl_images() {
	local node="$1"
	local node_json

	if ! node_json="$("$KUBECTL_BIN" get node "$node" -o json)"; then
		return 1
	fi

	NODE_JSON="$node_json" python3 - <<'PY'
import json
import os
import sys

try:
    payload = json.loads(os.environ["NODE_JSON"])
except json.JSONDecodeError as exc:
    print(f"supercred-crictl-shim: failed to parse kubectl node JSON: {exc}", file=sys.stderr)
    sys.exit(1)

print("IMAGE TAG IMAGE ID SIZE")

images = payload.get("status", {}).get("images") or []

# node.status.images is CAPPED and SORTED BY SIZE. The kubelet's
# --node-status-max-images defaults to 50, and it reports the fifty LARGEST
# images, so on any node holding more than that the small ones simply are not
# in the object. Absence from this list is therefore not evidence of absence
# on the node.
#
# This is not hypothetical and it is not the null-names bug fixed below.
# Observed 2026-08-03 on a healthy kind node: `crictl images` on the node
# listed all four SuperCred images, while node.status.images held exactly 50
# entries and omitted cardvault:local (8.9MB) and policy-engine:local (14.9MB)
# purely because they were too small to make the top fifty. The preflight then
# blocked the whole demo with "images are not all present" against a node that
# had every one of them.
#
# A caller cannot distinguish "not on the node" from "truncated off the end of
# a size-sorted list" unless the shim says so, so it says so. The marker goes
# to stderr to leave the table on stdout byte-identical for existing parsers.
if len(images) >= 50:
    print(
        f"supercred-crictl-shim: WARNING node.status.images is at the kubelet cap "
        f"({len(images)} entries, --node-status-max-images default 50). This list is "
        f"sorted by size and TRUNCATED, so a small image can be present on the node "
        f"and absent here. Treat a miss as inconclusive, not as missing.",
        file=sys.stderr,
    )

for image in images:
    # `names` is present-but-NULL for any image the node holds only by digest,
    # which is routine -- a kind node had one at index 2 of 50. `.get("names",
    # [])` returns None there, not the default, so the loop raised TypeError and
    # the shim died PART WAY THROUGH the table: it printed the first two images,
    # exited 1, and every image after the null was invisible. The caller reads
    # this listing with awk and sees a short table, so the failure presented as
    # "SuperCred images are not all present on <node>" against a node that had
    # them all -- the same fail-closed-on-a-healthy-cluster shape the SIGPIPE
    # comment in supercred-images.sh records, arriving by a different route.
    for name in image.get("names") or []:
        # Digest refs and untagged refs do not have repo:tag semantics. Skipping
        # them is safer than inventing a tag the caller would treat as runnable.
        if "@" in name:
            continue
        last_slash = name.rfind("/")
        last_colon = name.rfind(":")
        if last_colon <= last_slash:
            continue

        repository = name[:last_colon]
        tag = name[last_colon + 1 :]
        if not repository or not tag:
            continue

        print(f"{repository} {tag} - -")
PY
}

# Fail closed on every unsupported argv. A shim that exits 0 for an unhandled
# command turns `supercred-images.sh verify` into a gate that always passes.
if [ "$#" -eq 4 ] \
	&& [ "$1" = "exec" ] \
	&& [ "$3" = "crictl" ] \
	&& [ "$4" = "images" ]; then
	emit_crictl_images "$2"
	exit 0
fi

unsupported "$@"
