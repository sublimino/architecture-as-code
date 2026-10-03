#!/usr/bin/env bats
#
# Every agent-swarm openbao-agent that logs in as signalloom-agent-generic can
# actually read the secrets its templates ask for, and only its own.
#
# Offline, against a dev OpenBao (d2-signalloom/test/openbao-agent-generic-role-lab.sh),
# 2026-10-03, the original design could never authorise a read:
#   - the policy templated the SPIFFE ID into the path
#     (secret/data/agents/{{...metadata.sub}}/*). Every request path that
#     carries a SPIFFE ID holds "//", which OpenBao's HTTP layer cleans with a
#     301 to "spiffe:/..." -- a path the policy never matches (2.1.1, the
#     cluster's server), and OpenBao 2.7 refuses the policy outright
#     ("template substitution contains forbidden value: /");
#   - it named the auth mount `auth_jwt`, which is not an accessor;
#   - it granted the kv/ mount; the seeder and templates use secret/;
#   - every template nested `{{ env "SPIFFE_ID" }}` inside a string literal,
#     a parse error the agent hits only once it holds a token, and with
#     exit_on_retry_failure that is an exit -- a CrashLoop the moment the JWT
#     path was fixed.
# The fix keys each agent's secrets on a slash-free entity NAME (its service
# account), pre-created by the role Job with the SPIFFE ID as its jwt alias.
#
# For every openbao-agent whose agent.hcl logs in as signalloom-agent-generic:
#   - its pod's service account has a SPIRE entry (spire-agent-swarm-entries
#     AGENTS) and the pod carries the entry's signalloom.ai/agent=true label;
#   - the role Job pre-creates an entity of that name (AGENT_ENTITIES);
#   - every template reads a LITERAL secret/data/agents/<that sa>/<key>,
#     and scripts/swarm-seed-secrets.sh seeds <sa> <key>.
# And the templated policy substitutes only identity.entity.name.

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
  role_yaml="$repo_root/d2-signalloom/infra/inf-bao/controllers/base/openbao-agent-generic-role.yaml"
  entries_yaml="$repo_root/d2-signalloom/infra/inf-bao/controllers/base/spire-agent-swarm-entries.yaml"
  seeder="$repo_root/scripts/swarm-seed-secrets.sh"
}

# The root renders the sidecar ConfigMaps; each agent's workload is its own
# kustomization (its own Flux Kustomization), so render every one.
rendered_swarm() {
  local k
  fd -t f '^kustomization.yaml$' "$repo_root/d2-signalloom/infra/agent-swarm" | sort | while read -r k; do
    KUBECONFIG=/dev/null kubectl kustomize --load-restrictor LoadRestrictionsNone "${k%/kustomization.yaml}" 2>/dev/null \
      | yq -o=json -I=0 'select(. != null)'
  done | jq -sc '[.[] | select(.kind != null)] | unique_by(.kind + "/" + (.metadata.namespace // "") + "/" + .metadata.name)'
}

# Pending Andy's decision on removing agent-cardvault's sidecar: it logs in as
# signalloom-agent-generic but renders nothing (the agent logs in by itself).
# Same exception as openbao-agent-jwt-source.bats; asserted still needed below.
EXCEPTIONS='["Deployment/agent-cardvault"]'

role_script() { yq '.data["agent-generic-role.sh"] | select(. != null)' "$role_yaml"; }

# One JSON object per generic-role openbao-agent: where, sa, labelled, paths[].
generic_consumers() {
  rendered_swarm | jq -c '
    . as $all
    | ([$all[] | select(.kind == "ConfigMap") | {key: .metadata.name, value: (.data["agent.hcl"] // "")}] | from_entries) as $cms
    | $all[] | . as $o
    | ($o.spec.template // empty) as $t
    | select($t.spec.containers != null)
    | $t.spec.containers[] as $c
    | select(($c.image // "") | test("(^|/)openbao/openbao[:@]"))
    | select((($c.command // []) + ($c.args // [])) | index("agent"))
    | ([$c.volumeMounts[]? | select(.mountPath == "/etc/openbao") | .name] | first) as $v
    | ([$t.spec.volumes[]? | select(.name == $v) | .configMap.name] | first // "") as $cfg
    | ($cms[$cfg] // "") as $hcl
    | select($hcl | test("role\\s*=\\s*\"signalloom-agent-generic\""))
    | {where: ($o.kind + "/" + $o.metadata.name), config: $cfg,
       sa: ($t.spec.serviceAccountName // "default"),
       labelled: (($t.metadata.labels // {})["signalloom.ai/agent"] == "true"),
       secrets: [$hcl | scan("with secret\\s+(\\S[^}]*?)\\s*\\}\\}") | .[0]]}'
}

@test "each generic-role agent has a SPIRE entry, a pre-created entity, and seeded literal paths of its own" {
  local consumers agents entities seeded bad
  consumers="$(generic_consumers | jq -c --argjson exc "$EXCEPTIONS" 'select(.where as $w | $exc | index($w) | not)')"
  [ "$(jq -s length <<<"$consumers")" -ge 6 ] || { echo "too few generic-role agents:"; echo "$consumers"; return 1; }
  agents="$(yq '.data[] | select(type == "!!str")' "$entries_yaml" \
    | awk '/^ *AGENTS=\(/{f=1; next} f && /^ *\)/{f=0} f' | sed -e 's/#.*//' | tr -s ' \t' '\n' | rg -v -e '^$' | jq -R . | jq -sc .)"
  entities="$(role_script | sed -nE 's/^ *AGENT_ENTITIES="([^"]*)".*/\1/p' | tr -s ' ' '\n' | rg -v -e '^$' | jq -R . | jq -sc .)"
  seeded="$(sed -nE 's/^ *seed_secret "([^"]+)" "([^"]+)".*/\1\/\2/p' "$seeder" | jq -R . | jq -sc .)"
  bad="$(jq -r --argjson agents "$agents" --argjson ent "$entities" --argjson seeded "$seeded" '
    . as $x
    | [ (if ($agents | index($x.sa)) == null then "sa \($x.sa) has no SPIRE entry (AGENTS)" else empty end),
        (if $x.labelled | not then "pod lacks signalloom.ai/agent=true (the SPIRE entry selector)" else empty end),
        (if ($ent | index($x.sa)) == null then "no pre-created entity for \($x.sa) (AGENT_ENTITIES)" else empty end),
        (if ($x.secrets | length) == 0 then "renders no secret" else empty end),
        ($x.secrets[]
          | (capture("^\"secret/data/agents/(?<sa>[a-z0-9-]+)/(?<key>[a-z0-9/_-]+)\"$") // null) as $m
          | if $m == null then "secret path is not a literal secret/data/agents/<sa>/<key>: \(.)"
            elif $m.sa != $x.sa then "reads another identity: \(.)"
            elif ($seeded | index("\($m.sa)/\($m.key)")) == null then "not seeded by swarm-seed-secrets.sh: \(.)"
            else empty end)
      ] | select(length > 0) | "\($x.where) [\($x.config)]: \(join("; "))"' <<<"$consumers")"
  [ -n "$agents" ] && [ "$agents" != "[]" ] || { echo "parsed no AGENTS from $entries_yaml"; return 1; }
  [ -z "$bad" ] || { printf '%s\n' "$bad"; return 1; }
}

@test "each exception is still needed (it still exists and still renders nothing)" {
  local all n
  all="$(generic_consumers)"
  for n in $(jq -r '.[]' <<<"$EXCEPTIONS"); do
    jq -e --arg w "$n" 'select(.where == $w)' <<<"$all" >/dev/null || { echo "exception ${n} no longer exists: drop it"; return 1; }
    jq -e --arg w "$n" 'select(.where == $w and (.secrets | length) == 0)' <<<"$all" >/dev/null \
      || { echo "exception ${n} now renders secrets: drop it"; return 1; }
  done
}

@test "the templated policy substitutes only the slash-free entity name, on the secret/ mount" {
  local paths
  paths="$(role_script | awk '/bao policy write signalloom-agent-templated/{f=1; next} f && /^ *POLICY *$/{f=0} f' \
    | rg -v -e '^\s*#' | rg -o -e 'path\s+"[^"]+"')"
  [ -n "$paths" ] || { echo "no policy paths parsed"; return 1; }
  [ "$paths" = 'path "secret/data/agents/{{identity.entity.name}}/*"' ] \
    || { echo "unexpected policy paths:"; echo "$paths"; return 1; }
}

@test "the role Job re-runs when its script changes (config-hash tracks the script)" {
  local want got
  want="$(role_script | sha256sum | cut -c1-12)"
  got="$(yq 'select(.kind == "Job") | .spec.template.metadata.annotations["signalloom.io/config-hash"]' "$role_yaml")"
  [ "$want" = "$got" ] || { echo "config-hash $got, script hashes to $want: bump it"; return 1; }
}
