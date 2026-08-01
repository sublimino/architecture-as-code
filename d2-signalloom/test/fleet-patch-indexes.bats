#!/usr/bin/env bats
#
# The local fleet overlay swaps each ResourceSet's cosign verify block over to
# the local key pair by patching a HARD-CODED POSITIONAL INDEX:
#
#   - op: add
#     path: /spec/resources/10/spec/verify
#
# Insert a resource above that index and the patch silently lands on an
# unrelated object. The OCIRepository keeps its GitHub-keyless verify block, and
# Flux then rejects every locally-pushed artifact:
#
#   VerificationError: failed to verify the signature using provider
#   'cosign keyless': no matching attestations
#
# The Kustomization simply stays on the previous revision. `make
# push-local-signalloom` still exits 0, nothing logs an error against the
# offending change, and no manifest in d2-signalloom/apps/fe-signalloom/ can
# reach a local cluster again. This asserts every patched index still points at
# an OCIRepository.

setup() {
	repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
	overlay_dir="$repo_root/d2-osramp-fleet/tenants/local"
	kustomization="$overlay_dir/kustomization.yaml"

	command -v yq >/dev/null || skip "yq is required to read the fleet overlay"
	[ -f "$kustomization" ] || skip "local fleet overlay not found"
}

# Emits one line per verify-patch: "<resourceset> <index> <kind-at-index>".
# Resolves each ResourceSet from the very files the overlay composes, so a
# renamed or moved source is reported rather than skipped.
patched_indexes() {
	local ks_json="$BATS_TEST_TMPDIR/ks.json"
	yq -o=json eval '.' "$kustomization" >"$ks_json"

	# Convert every composed source to a JSON array of documents.
	local docs_dir="$BATS_TEST_TMPDIR/docs"
	mkdir -p "$docs_dir"
	local i=0 rel path
	while read -r rel; do
		[ -n "$rel" ] || continue
		path="$overlay_dir/$rel"
		[ -f "$path" ] || continue
		yq ea -o=json '[.]' "$path" >"$docs_dir/$i.json"
		i=$((i + 1))
	done < <(yq eval '.resources[]' "$kustomization")

	# NOTE: <<- strips leading TABS, so Python's own indentation must be SPACES.
	python3 - "$ks_json" "$docs_dir" <<-'PY'
	import json, os, re, sys

	ks = json.load(open(sys.argv[1]))
	docs_dir = sys.argv[2]

	by_name = {}
	for entry in sorted(os.listdir(docs_dir)):
	    for doc in json.load(open(os.path.join(docs_dir, entry))):
	        if isinstance(doc, dict) and doc.get("kind") == "ResourceSet":
	            by_name[doc["metadata"]["name"]] = doc

	for patch in ks.get("patches", []):
	    name = patch.get("target", {}).get("name")
	    body = patch.get("patch", "")
	    for raw in re.findall(r"path:\s*/spec/resources/(\d+)/spec/verify", body):
	        index = int(raw)
	        rs = by_name.get(name)
	        if rs is None:
	            print(f"{name} {index} RESOURCESET-NOT-FOUND")
	            continue
	        resources = rs.get("spec", {}).get("resources", [])
	        if index >= len(resources):
	            print(f"{name} {index} INDEX-OUT-OF-RANGE({len(resources)})")
	            continue
	        print(f"{name} {index} {resources[index].get('kind', 'UNKNOWN')}")
	PY
}

# Where the OCIRepository actually sits, for a useful failure message.
actual_oci_index() {
	local rel path
	while read -r rel; do
		[ -n "$rel" ] || continue
		path="$overlay_dir/$rel"
		[ -f "$path" ] || continue
		yq ea "select(.metadata.name == \"$1\") | .spec.resources | to_entries | .[] | select(.value.kind == \"OCIRepository\") | .key" "$path" 2>/dev/null
	done < <(yq eval '.resources[]' "$kustomization")
}

@test "the overlay patches at least the three known ResourceSets" {
	run patched_indexes
	[ "$status" -eq 0 ]
	[[ "$output" == *"infra "* ]]
	[[ "$output" == *"signalloom-infra "* ]]
	[[ "$output" == *"signalloom-apps "* ]]
}

@test "every patched verify index points at an OCIRepository" {
	local name index kind bad=()
	while read -r name index kind; do
		[ -n "$name" ] || continue
		if [ "$kind" != "OCIRepository" ]; then
			bad+=("$name index $index is $kind (OCIRepository is at index $(actual_oci_index "$name" | tr '\n' ',' | sed 's/,$//'))")
		fi
	done < <(patched_indexes)

	[ "${#bad[@]}" -eq 0 ] || {
		printf 'fleet overlay verify patch is misaligned:\n'
		printf '  %s\n' "${bad[@]}"
		printf 'the cosign verify swap will land on the wrong resource and Flux will\n'
		printf 'reject locally-pushed artifacts. Fix the index in %s,\n' "$kustomization"
		printf 'or append new resources to the END of spec.resources instead.\n'
		return 1
	}
}

@test "signalloom-apps keeps its OCIRepository at the patched index" {
	# Named explicitly: this is the one that regressed, and it is the ResourceSet
	# that delivers every manifest under d2-signalloom/apps/fe-signalloom/.
	run bash -c "yq ea 'select(.metadata.name == \"signalloom-apps\") | .spec.resources[10].kind' '$overlay_dir/signalloom.yaml'"
	[ "$status" -eq 0 ]
	[[ "$output" == "OCIRepository" ]]
}
