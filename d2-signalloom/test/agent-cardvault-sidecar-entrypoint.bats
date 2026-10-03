#!/usr/bin/env bats
#
# agent-cardvault's openbao-agent sidecar runs `bao agent` directly, never
# through the openbao image's docker-entrypoint.sh.
#
# Live, 2026-10-03: every fresh agent-cardvault pod was frozen within 3 s of
# creation. The sidecar's entrypoint script runs `id -u openbao` (its chown
# checks), which reads /etc/passwd from inside the agent pod, and the stun
# sentinel freezes a watched pod on exactly that open. The pod could never
# run its chain. Starting bao directly skips the script; HOME is set so bao's
# home-directory lookup (go-homedir) never falls back to the user database.
# The agent's OWN reads of /etc/passwd stay detections (the point of the
# sentinel); this only removes a read the agent never asked for.

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
  rendered="$(KUBECONFIG=/dev/null kubectl kustomize "$repo_root/d2-signalloom/infra/agent-swarm/agent-cardvault")"
}

sidecar() {
  yq -e 'select(.kind == "Deployment" and .metadata.name == "agent-cardvault")
         | .spec.template.spec.containers[] | select(.image == "openbao/openbao*")' <<<"$rendered"
}

@test "the openbao sidecar starts bao directly, not the image entrypoint" {
  run sidecar
  [ "$status" -eq 0 ]
  local c="$output"
  run yq -r '(.command // []) | join(" ")' <<<"$c"
  [ "$output" = "bao agent -config=/etc/openbao/agent.hcl" ]
  run yq -r '((.command // []) + (.args // [])) | join(" ")' <<<"$c"
  [[ "$output" != *docker-entrypoint* && "$output" != *dumb-init* ]]
}

@test "the openbao sidecar sets HOME, so bao never looks a user up" {
  run sidecar
  [ "$status" -eq 0 ]
  run yq -r '.env[] | select(.name == "HOME") | .value' <<<"$output"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}
