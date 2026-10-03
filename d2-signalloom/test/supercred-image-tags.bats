#!/usr/bin/env bats
#
# Every manifest that runs a SuperCred image names the tag the build loads.
#
# Live, 2026-10-03: agent-cardvault's token-reuse fix never ran. `make
# demo-signalloom-supercred-images` (scripts/supercred-images.sh) builds and
# kind-loads cardvault-agent:local, while the agent-cardvault Deployment ran
# cardvault-agent:latest with imagePullPolicy Never, a five-day-old
# hand-loaded build nothing rebuilds. A rebuild therefore never reached it.
#
# The built name:tag pairs are read from the script's DEMO_IMAGES; every
# `image:` for one of those names, in the agent-swarm and app manifests
# Flux renders, must carry the same tag.

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
}

# built prints the name:tag pairs supercred-images.sh builds and loads.
built() {
  sed -n '/^DEMO_IMAGES=(/,/^)/p' "$repo_root/scripts/supercred-images.sh" \
    | sed -n 's/^[[:space:]]*"\([^|"]*\)|.*/\1/p'
}

# deployed prints "file<TAB>name:tag" for every image reference in manifests.
deployed() {
  rg -n --no-heading -o -e '^\s*image:\s*\S+' "$repo_root/d2-signalloom/infra" "$repo_root/d2-signalloom/apps" "$repo_root/d2-osramp-fleet" \
    --glob '*.yaml' --glob '!**/test/**' \
    | sed -E 's#^([^:]+):[0-9]+:[[:space:]]*image:[[:space:]]*"?([^"[:space:]]+)"?#\1\t\2#'
}

@test "supercred-images.sh builds a cardvault-agent image" {
  run built
  [ "$status" -eq 0 ]
  [[ "$output" == *"cardvault-agent:"* ]]
}

@test "every manifest runs the tag of each SuperCred image the build loads" {
  local pair name tag file ref bad="" seen=0
  while IFS= read -r pair; do
    name="${pair%%:*}"; tag="${pair#*:}"
    while IFS=$'\t' read -r file ref; do
      [ "${ref%%:*}" = "$name" ] || continue
      seen=$(( seen + 1 ))
      [ "$ref" = "$name:$tag" ] || bad="${bad}${file#"$repo_root"/}: ${ref} (the build loads ${name}:${tag})"$'\n'
    done < <(deployed)
  done < <(built)
  # The cardvault-agent Deployment and the fe-signalloom Job at least.
  [ "$seen" -ge 2 ] || { echo "only ${seen} references found"; return 1; }
  [ -z "$bad" ] || { printf 'manifests running a tag the build never loads:\n%s' "$bad"; return 1; }
}
