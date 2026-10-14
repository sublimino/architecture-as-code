#!/usr/bin/env bats
#
# Every openbao-agent in the estate authenticates from a JWT-SVID FILE that a
# helper in its own pod writes, never from the SPIRE socket.
#
# Live, 2026-10-03: every agent-swarm openbao-agent sidecar (triage-ci-worker,
# swarm-governor, prod-deploy-gate, cpai-engineer, triage-ci-worker,
# prompt-commit-summarizer) had its jwt method's `path` on
# /run/spire/sockets/agent.sock. The jwt method reads a file holding a JWT, so
# each logged "jwt file is not a regular file or symlink / latest known jwt is
# empty" and backed off for minutes: none ever authenticated, so nothing was
# ever rendered into /vault/secrets for the agents built to read it, while the
# containers reported Ready. fleet-manager's sidecar works: a helper writes
# the SVID into a memory volume and the agent reads that file.
#
# For every `bao agent` container (found by image across every rendered
# kustomization, not by a list), its agent.hcl jwt method must:
#   - read a file in a Memory emptyDir it mounts read-only (never a socket),
#   - written by ANOTHER container in the same pod that mounts that volume
#     writable and names the path in its command,
#   - with remove_jwt_after_reading = false (the default deletes the file
#     after the first read, so a refreshed SVID would never be re-read),
# and the writer's --audience must equal the bound_audiences of the role the
# agent logs in as (read from the role's own `bao write auth/jwt/role/<role>`).

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
}

# Pending Andy's decision on removing agent-cardvault's sidecar (it has no
# consumers; the agent logs in by itself). Pinned, and asserted still needed
# below, so it cannot outlive the decision silently.
EXCEPTIONS='["Deployment/fe-signalloom-agents/agent-cardvault"]'

rendered_estate() {
  local k d
  fd -t f '^kustomization.yaml$' "$repo_root/d2-signalloom" --exclude test | sort | while read -r k; do
    d="${k%/kustomization.yaml}"
    KUBECONFIG=/dev/null kubectl kustomize --load-restrictor LoadRestrictionsNone "$d" 2>/dev/null \
      | yq -o=json -I=0 'select(. != null)'
  done | jq -sc '[.[] | select(.kind != null)] | unique_by(.kind + "/" + (.metadata.namespace // "") + "/" + .metadata.name)'
}

# verdicts prints one JSON object per `bao agent` container: where, config,
# path, role, problems[].
verdicts() {
  rendered_estate | jq -c --argjson exc "$EXCEPTIONS" '
    . as $all
    | ([$all[] | select(.kind == "ConfigMap") | {key: .metadata.name, value: (.data["agent.hcl"] // "")}] | from_entries) as $cms
    | ([$all[] | .. | strings | capture("bao write auth/jwt/role/(?<role>[a-z0-9-]+) - <<.ROLE.\\s*(?<json>\\{[\\s\\S]*?\\})\\s*ROLE"; "g")]
        | map({key: .role, value: ((.json | fromjson? // {}) | .bound_audiences)}) | from_entries) as $aud
    | $all[]
    | . as $o
    | ($o.spec.template.spec // $o.spec.jobTemplate.spec.template.spec // empty) as $ps
    | select($ps.containers != null)
    | ($o.kind + "/" + ($o.metadata.namespace // "") + "/" + $o.metadata.name) as $where
    | $ps.containers[] as $c
    | select(($c.image // "") | test("(^|/)openbao/openbao[:@]"))
    | select((($c.command // []) + ($c.args // [])) | index("agent"))
    | ([$c.volumeMounts[]? | select(.mountPath == "/etc/openbao") | .name] | first) as $cfgvol
    | ([$ps.volumes[]? | select(.name == $cfgvol) | .configMap.name] | first // "") as $cfg
    | ($cms[$cfg] // "") as $hcl
    | (($hcl | capture("method \"jwt\"[\\s\\S]*?\\bpath\\s*=\\s*\"(?<p>[^\"]+)\"") | .p) // "") as $path
    | (($hcl | capture("method \"jwt\"[\\s\\S]*?\\brole\\s*=\\s*\"(?<r>[^\"]+)\"") | .r) // "") as $role
    | ($path | split("/") | .[:-1] | join("/")) as $dir
    | ([$c.volumeMounts[]? | select(.mountPath == $dir)] | first) as $amount
    | ([$ps.volumes[]? | select(.name == ($amount.name // "-"))] | first) as $vol
    | [$ps.containers[] | select(.name != $c.name)
        | select([.volumeMounts[]? | select(.name == ($amount.name // "-") and (.readOnly // false) == false)] | length > 0)
        | select((((.command // []) + (.args // [])) | join(" ")) | contains($path))] as $writers
    | ([$writers[] | ((.command // []) + (.args // [])) | join(" ") | capture("--audience\\s+(?<a>\\S+)") | .a] | first // "") as $wa
    | ($aud[$role]) as $ra
    | {where: $where, config: $cfg, path: $path, role: $role, excepted: ($exc | index($where) != null),
       problems: (
         (if $hcl == "" then ["no agent.hcl found for /etc/openbao"] else [] end)
         + (if $path == "" or ($path | test("\\.sock$|/sockets/")) then ["jwt path is the SPIRE socket or unset: \($path)"] else [] end)
         + (if ($vol.emptyDir.medium // "") != "Memory" then ["\($dir) is not a Memory emptyDir"] else [] end)
         + (if ($amount.readOnly // false) != true then ["openbao-agent does not mount \($dir) read-only"] else [] end)
         + (if ($writers | length) == 0 then ["no other container in the pod writes \($path)"] else [] end)
         + (if ($hcl | test("remove_jwt_after_reading\\s*=\\s*false")) | not then ["remove_jwt_after_reading is not false"] else [] end)
         + (if $ra == null then ["role \($role) has no bound_audiences in the estate"]
            elif ([$ra] | flatten | index($wa)) == null then ["writer audience \($wa) is not role \($role)\u0027s bound_audiences \($ra)"] else [] end)
       )}'
}

@test "every openbao-agent reads its JWT-SVID from a helper-written memory file" {
  local all bad
  all="$(verdicts)"
  # fleet-manager plus the six agent-swarm consumers at least.
  [ "$(jq -s '[.[] | select(.excepted | not)] | length' <<<"$all")" -ge 7 ] \
    || { echo "too few openbao-agents found:"; echo "$all"; return 1; }
  bad="$(jq -r 'select((.excepted | not) and (.problems | length) > 0) | "\(.where) [\(.config)]: \(.problems | join("; "))"' <<<"$all")"
  [ -z "$bad" ] || { printf '%s\n' "$bad"; return 1; }
}

@test "each exception is still needed (it still exists and is still unfixed)" {
  local all n stale
  all="$(verdicts)"
  for n in $(jq -r '.[]' <<<"$EXCEPTIONS"); do
    stale="$(jq -r --arg w "$n" 'select(.where == $w) | (.problems | length)' <<<"$all")"
    [ -n "$stale" ] || { echo "exception ${n} no longer exists: drop it"; return 1; }
    [ "$stale" -gt 0 ] || { echo "exception ${n} is now compliant: drop it"; return 1; }
  done
}
