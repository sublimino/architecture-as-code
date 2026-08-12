#!/usr/bin/env bats
# There must be exactly ONE creator of the cardvault agent pod.
#
# The fe-signalloom `apps` Kustomization sets `targetNamespace: fe-signalloom`,
# which OVERRIDES the `namespace: fe-signalloom-agents` that agents-cardvault.yaml
# declares. So listing that manifest in the Flux kustomization produces a second
# agent-cardvault in the wrong namespace, alongside the one
# scripts/supercred-demo.sh applies — two live pods claiming one SPIFFE ID, and a
# duplicate "Cardvault Agent" on the Agents page.
#
# Deleting the stray pod is not a fix: Flux owns that copy and recreates it on the
# next reconcile. Observed 2026-08-12 — deleted, then back within the hour.
#
# The demo script must be the sole creator, because only it can place the pod in
# the namespace the SPIFFE ID, the SPIRE selectors and the OpenBao role all name.

setup() {
  repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  kustomization="${repo_root}/d2-signalloom/apps/fe-signalloom/base/kustomization.yaml"
  demo_script="${repo_root}/scripts/supercred-demo.sh"
  manifest="${repo_root}/d2-signalloom/apps/fe-signalloom/base/agents-cardvault.yaml"
}

@test "SUPERCRED the agent pod manifest is NOT Flux-managed by the apps kustomization" {
  [ -f "$kustomization" ]
  # The SA is fine (namespace-correct under targetNamespace); the POD is not.
  run grep -E '^[[:space:]]*-[[:space:]]*agents-cardvault\.yaml[[:space:]]*$' "$kustomization"
  [ "$status" -ne 0 ]
}

@test "SUPERCRED the demo script is the creator of the agent pod" {
  grep -Fq 'kubectl apply -f d2-signalloom/apps/fe-signalloom/base/agents-cardvault.yaml' "$demo_script"
}

@test "SUPERCRED the agent manifest still declares the namespace the identity names" {
  # If this drifts, the pod lands somewhere the SPIRE selectors and OpenBao role
  # do not describe, and the demo fails authentication rather than duplicating.
  grep -Fq 'namespace: fe-signalloom-agents' "$manifest"
  grep -Fq 'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent' "$demo_script"
}

@test "SUPERCRED the ServiceAccount stays Flux-managed" {
  # The demo depends on it existing before step 1 runs, and unlike the pod it is
  # namespace-correct under targetNamespace.
  grep -Eq '^[[:space:]]*-[[:space:]]*agents-cardvault-sa\.yaml[[:space:]]*$' "$kustomization"
}

@test "SUPERCRED the single-creator audit can actually fail" {
  # A guard nobody has watched fail is not a guard.
  run bash -c '
    f="$(mktemp)"
    printf "resources:\n  - agents-cardvault.yaml\n" > "$f"
    grep -E "^[[:space:]]*-[[:space:]]*agents-cardvault\.yaml[[:space:]]*$" "$f" >/dev/null
    rc=$?
    rm -f "$f"
    exit "$rc"'
  [ "$status" -eq 0 ]
}
