#!/usr/bin/env bash
set -euo pipefail

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

# Namespaces searched for the second, CONCLUSIVE evidence source (see
# emit_crictl_images). Defaults to the namespaces the SuperCred demo's own
# workloads run in. Cluster-scope `get pods --all-namespaces` is deliberately
# NOT used: the runner's ServiceAccount is bound per-namespace and a
# cluster-scope list comes back Forbidden, which would make the whole probe
# collapse to the capped node list again.
IMAGE_EVIDENCE_NAMESPACES="${SUPERCRED_IMAGE_EVIDENCE_NAMESPACES:-inf-signalloom fe-signalloom fe-signalloom-agents}"

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

	# Second evidence source, and the reason a truncated node list stopped
	# mattering.
	#
	# node.status.images cannot answer "is this image on the node" (it is capped
	# and size-sorted), but a CONTAINER THAT HAS STARTED can: the SuperCred
	# workloads run with imagePullPolicy Never/IfNotPresent against :local tags
	# that exist nowhere but the node, so the kubelet could not have started the
	# container unless the image was already unpacked and runnable there. That is
	# exactly the property `crictl images` is consulted for, arrived at from the
	# API server instead of the node's container runtime -- which the runner pod
	# has no route to.
	#
	# Pods are filtered to spec.nodeName == the node being asked about, so this
	# stays correct on a multi-node cluster.
	local pods_dir ns index=0 pods_json
	pods_dir="$(mktemp -d)"
	# shellcheck disable=SC2064  # expand $pods_dir now, not at trap time
	trap "rm -rf '$pods_dir'" RETURN
	for ns in $IMAGE_EVIDENCE_NAMESPACES; do
		# A namespace that does not exist, or that this ServiceAccount cannot
		# read, contributes no evidence and is not an error: the node list below
		# still answers, and a miss is still reported as inconclusive rather
		# than as absent.
		if pods_json="$("$KUBECTL_BIN" get pods -n "$ns" -o json 2>/dev/null)"; then
			printf '%s' "$pods_json" >"$pods_dir/$index.json"
		fi
		index=$((index + 1))
	done

	NODE_JSON="$node_json" PODS_DIR="$pods_dir" TARGET_NODE="$node" python3 - <<'PY'
import json
import os
import sys

try:
    payload = json.loads(os.environ["NODE_JSON"])
except json.JSONDecodeError as exc:
    print(f"supercred-crictl-shim: failed to parse kubectl node JSON: {exc}", file=sys.stderr)
    sys.exit(1)

rows: list[str] = []
seen: set[str] = set()


def add_row(name: str) -> bool:
    """Emit one `repo tag - -` row for an image reference. True when it is new."""
    # Digest refs and untagged refs do not have repo:tag semantics. Skipping
    # them is safer than inventing a tag the caller would treat as runnable.
    if "@" in name:
        return False
    last_slash = name.rfind("/")
    last_colon = name.rfind(":")
    if last_colon <= last_slash:
        return False

    repository = name[:last_colon]
    tag = name[last_colon + 1 :]
    if not repository or not tag:
        return False

    row = f"{repository} {tag} - -"
    if row in seen:
        return False
    seen.add(row)
    rows.append(row)
    return True


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
#
# The started-container evidence gathered below is what usually stops this
# warning from mattering: it answers conclusively for every image the demo
# actually runs, so the caller reaches `listing_is_truncated` only when an
# image is neither in the top-fifty nor backing a started container -- which
# is the one case that genuinely is inconclusive.
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
        add_row(name)


# ─── Started-container evidence ─────────────────────────────────────────────
#
# A container that has started is proof its image was present and runnable on
# the node at start time -- stronger evidence than a listing, and immune to the
# kubelet's cap. Only containers that actually reached a running or terminated
# state count: `waiting` covers ErrImageNeverPull and ImagePullBackOff, which
# are precisely the states that mean the image is NOT there.
target_node = os.environ.get("TARGET_NODE", "")
pods_dir = os.environ.get("PODS_DIR", "")
evidence: list[str] = []

if pods_dir and os.path.isdir(pods_dir):
    for entry in sorted(os.listdir(pods_dir)):
        try:
            with open(os.path.join(pods_dir, entry), encoding="utf-8") as handle:
                pod_payload = json.load(handle)
        except (OSError, json.JSONDecodeError) as exc:
            # One unreadable namespace must not take the whole probe down; the
            # node listing above still answers and a miss stays inconclusive.
            print(
                f"supercred-crictl-shim: could not read pod evidence from {entry}: {exc}",
                file=sys.stderr,
            )
            continue

        for pod in pod_payload.get("items") or []:
            if (pod.get("spec", {}) or {}).get("nodeName") != target_node:
                continue
            status = pod.get("status", {}) or {}
            statuses = []
            for key in ("initContainerStatuses", "containerStatuses", "ephemeralContainerStatuses"):
                statuses.extend(status.get(key) or [])
            for container_status in statuses:
                image_ref = container_status.get("image") or ""
                if not image_ref:
                    continue
                state = container_status.get("state") or {}
                started = "running" in state or bool(
                    (state.get("terminated") or {}).get("startedAt")
                )
                if not started:
                    continue
                if add_row(image_ref):
                    evidence.append(image_ref)

if evidence:
    # Say where the extra rows came from. A row the node object did not report
    # is a real claim about the node, so the reader gets to see its basis.
    print(
        "supercred-crictl-shim: NOTE these images are absent from node.status.images "
        "but PROVEN present on "
        f"{target_node} by a container that started from them: {' '.join(sorted(evidence))}",
        file=sys.stderr,
    )

print("IMAGE TAG IMAGE ID SIZE")
for row in rows:
    print(row)
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
