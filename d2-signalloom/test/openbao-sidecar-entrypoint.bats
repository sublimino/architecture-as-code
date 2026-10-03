#!/usr/bin/env bats
#
# No openbao container in the estate starts through the image's entrypoint.
#
# Live, 2026-10-03: every fresh agent-cardvault pod was frozen within 3 s of
# creation. Its openbao-agent sidecar ran the openbao image's
# docker-entrypoint.sh, whose chown checks run `id -u openbao` and so read
# /etc/passwd inside the agent pod, and the signalloom warden freezes a watched
# pod on exactly that open. Every agent with the same sidecar carries the
# same trap on restart. So every container running the openbao image sets
# its own `command` (bao, never the script), and every `bao agent` sets HOME
# so bao's home lookup (go-homedir) never falls back to the user database.
#
# Found by IMAGE across every rendered kustomization under d2-signalloom, not
# by a list of agents, so a new agent cannot quietly reintroduce it.

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
}

# openbao_containers prints one JSON object per openbao container in the
# estate: {where, name, command, args, home}.
openbao_containers() {
  local k d
  fd -t f '^kustomization.yaml$' "$repo_root/d2-signalloom" --exclude test | sort | while read -r k; do
    d="${k%/kustomization.yaml}"
    KUBECONFIG=/dev/null kubectl kustomize --load-restrictor LoadRestrictionsNone "$d" 2>/dev/null \
      | yq -o=json -I=0 'select(. != null)' \
      | jq -c '
          select(.kind != null)
          | . as $o
          | ($o.spec.template.spec // $o.spec.jobTemplate.spec.template.spec // {}) as $ps
          | (($ps.containers // []) + ($ps.initContainers // []))[]
          | select((.image // "") | test("(^|/)openbao/openbao[:@]"))
          | {where: ($o.kind + "/" + ($o.metadata.namespace // "") + "/" + $o.metadata.name),
             name: .name, command: (.command // []), args: (.args // []),
             home: ([.env[]? | select(.name == "HOME") | .value] | first // "")}'
  done | jq -sc 'unique_by(.where + "|" + .name) | .[]'
}

@test "every openbao container in the estate runs bao itself, never the image entrypoint" {
  local all bad
  all="$(openbao_containers)"
  # The eight known `bao agent` sidecars at least: agent-cardvault,
  # cpai-engineer, prod-deploy-gate, prompt-commit-summarizer,
  # swarm-governor, triage-ci-worker, zulip-chat-agent, fleet-manager.
  [ "$(jq -s '[.[] | select((.command + .args) | index("agent"))] | length' <<<"$all")" -ge 8 ] \
    || { echo "too few bao agent sidecars found:"; echo "$all"; return 1; }
  # Any own command bypasses the entrypoint (the inf-bao bootstrap Jobs run a
  # `sh -ec` script); a `bao agent` must be bao itself.
  bad="$(jq -r 'select((.command | length) == 0
                      or ((.command + .args) | map(test("docker-entrypoint|dumb-init")) | any)
                      or (((.command + .args) | index("agent")) and ((.command[0] | split("/") | last) != "bao")))
                | "\(.where) \(.name): command=\(.command) args=\(.args)"' <<<"$all")"
  [ -z "$bad" ] || { printf 'openbao containers started through the image entrypoint:\n%s\n' "$bad"; return 1; }
}

@test "every bao agent in the estate sets HOME" {
  local bad
  bad="$(openbao_containers | jq -r 'select(((.command + .args) | index("agent")) and .home == "") | "\(.where) \(.name)"')"
  [ -z "$bad" ] || { printf 'bao agents without HOME:\n%s\n' "$bad"; return 1; }
}
