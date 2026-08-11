#!/usr/bin/env bats
# The cosign verify patches address spec.resources by POSITION, so adding a
# resource anywhere above an OCIRepository silently invalidates one.
#
# This has broken three times now: 542478a realigned it after the fleet-agents
# merge, an earlier commit realigned signalloom-infra from 25 to 26, and the
# agent-trust index went 16 -> 18 when the topology collector's ClusterRole and
# ClusterRoleBinding were added above it.
#
# The failure is nasty out of proportion to the cause. kustomize reports
#
#   add operation does not apply: doc is missing path:
#   "/spec/resources/16/spec/verify": missing value
#
# which names neither the ResourceSet nor the resource that moved, and it only
# appears when the whole fleet is rendered -- long after the edit that caused it.
# Worse is the case where the index still EXISTS but now points at a different
# resource: the patch then applies cleanly and silently attaches signature
# verification to the wrong object, or drops it from the OCIRepository entirely.
#
# This computes the real index and compares, so the edit fails immediately and
# says which patch to change.

setup() {
  repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  overlay="${repo_root}/d2-osramp-fleet/tenants/local/kustomization.yaml"
}

# Prints "<resourceset> <declared-index> <actual-index>" per cosign patch.
_index_report() {
  python3 - "$repo_root" "$overlay" <<'PY'
import re, sys, yaml, pathlib

repo, overlay = sys.argv[1], sys.argv[2]
text = pathlib.Path(overlay).read_text()

# Each patch block names its ResourceSet, then adds /spec/resources/N/spec/verify.
declared = {}
for block in text.split("- target:")[1:]:
    name = re.search(r"name:\s*([\w-]+)", block)
    idx = re.search(r"/spec/resources/(\d+)/spec/verify", block)
    if name and idx:
        declared[name.group(1)] = int(idx.group(1))

sources = [
    "d2-osramp-fleet/tenants/base/infra.yaml",
    "d2-osramp-fleet/tenants/base/agent-trust.yaml",
    "d2-osramp-fleet/tenants/local/signalloom.yaml",
]
actual = {}
for rel in sources:
    path = pathlib.Path(repo) / rel
    if not path.exists():
        continue
    for doc in yaml.safe_load_all(path.read_text()):
        if not doc or doc.get("kind") != "ResourceSet":
            continue
        name = doc["metadata"]["name"]
        for i, res in enumerate(doc.get("spec", {}).get("resources", []) or []):
            if res.get("kind") == "OCIRepository":
                actual[name] = i
                break

for name, want in sorted(declared.items()):
    print(f"{name} {want} {actual.get(name, -1)}")
PY
}

@test "every cosign verify patch points at its ResourceSet's OCIRepository" {
  run _index_report
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  local drift=0
  while read -r name want got; do
    [ -z "$name" ] && continue
    if [ "$want" != "$got" ]; then
      echo "MISMATCH: ${name} patch targets /spec/resources/${want} but its OCIRepository is at ${got}" >&2
      echo "  fix d2-osramp-fleet/tenants/local/kustomization.yaml, and the index note in its header" >&2
      drift=1
    fi
  done <<< "$output"

  [ "$drift" -eq 0 ]
}

@test "the index audit can actually detect drift" {
  # A guard nobody has watched fail is not a guard, so exercise the comparison
  # itself against a known-bad pair.
  #
  # Note the here-string. `printf ... | while read` puts the loop in a SUBSHELL,
  # so its `exit 1` sets the subshell's status and the enclosing script still
  # exits 0 — the self-test passed while asserting nothing. The real audit above
  # uses a here-string for the same reason.
  run bash -c '
    drift=0
    while read -r name want got; do
      [ -z "$name" ] && continue
      [ "$want" != "$got" ] && drift=1
    done <<< "$(printf "agent-trust 16 18\nsignalloom-apps 10 10\n")"
    exit "$drift"'
  [ "$status" -eq 1 ]
}
