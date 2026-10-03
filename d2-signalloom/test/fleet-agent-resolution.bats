#!/usr/bin/env bats
#
# Every fleet DAG agent that has a workload in the estate resolves to it the
# way fleet-manager's resolvePod does (apps/fleet-manager/k8sclient.go): a Pod
# named exactly the agent id, or else exactly one pod carrying
# signalloom.ai/agent-name=<id minus "agent-">; and that pod is one the stun
# sentinel watches (signalloom.ai/agent=true, requireSentinelWatched).
#
# Live, 2026-10-03: the sentinel froze agent-cardvault-95bf5d9dd-q7vpk and
# asked fleet-manager to record the stun. fleet-manager mapped the pod to
# fleet id agent-cardvault, then found no pod named agent-cardvault and no pod
# labelled signalloom.ai/agent-name=cardvault -- the cardvault Deployment
# never carried the label (kusari's does). Every plane answered "enforcement
# target not found" / "identity derived, not observed", the cascade was
# `unavailable`, fleet-manager answered 500, and the sentinel logged
# fleet_stun_failed freeze_held_unrecorded: a freeze no record explains.
#
# Every fleet id must have a workload somewhere in the estate: an id with
# none is a stun target that can only ever answer not_found.

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
  fleet_cm="$repo_root/d2-signalloom/apps/fleet-manager/base/configmap.yaml"
}

fleet_agents() {
  yq 'select(.metadata.name == "fleet-config") | .data["fleet.yaml"]' "$fleet_cm" \
    | yq -o=json -I=0 '.' | jq -c '[.agents[] | {id, namespace: (.namespace // "fe-signalloom-agents")}]'
}

# Every pod template in the estate: kind/name, namespace, workload name, labels.
pod_templates() {
  local k
  fd -t f '^kustomization.yaml$' "$repo_root/d2-signalloom" --exclude test | sort | while read -r k; do
    KUBECONFIG=/dev/null kubectl kustomize --load-restrictor LoadRestrictionsNone "${k%/kustomization.yaml}" 2>/dev/null \
      | yq -o=json -I=0 'select(. != null)'
  done | jq -sc '[.[] | select(.kind != null)]
    | unique_by(.kind + "/" + (.metadata.namespace // "") + "/" + .metadata.name)
    | [.[] | if .kind == "Pod" then {where: ("Pod/" + .metadata.name), ns: .metadata.namespace, pod: .metadata.name, name: .metadata.name, labels: (.metadata.labels // {})}
             elif (.spec.template.spec.containers? != null) then {where: (.kind + "/" + .metadata.name), ns: .metadata.namespace, pod: null, name: .metadata.name, labels: (.spec.template.metadata.labels // {})}
             else empty end]'
}

verdicts() {
  jq -c --argjson fleet "$(fleet_agents)" '
    . as $pt
    | $fleet[] | . as $a
    | ($a.id | ltrimstr("agent-")) as $short
    | [$pt[] | select(.ns == $a.namespace)] as $inns
    # Workloads that are this agent by any reasonable reading of the manifests.
    | [$inns[] | select(.name == $a.id or .labels["app.kubernetes.io/name"] == $a.id or .labels["signalloom.ai/agent-name"] == $short)] as $mine
    # What resolvePod would actually find: the bare Pod by name, else the label.
    | ([$inns[] | select(.pod == $a.id)] | if length > 0 then . else [$inns[] | select(.labels["signalloom.ai/agent-name"] == $short)] end) as $found
    | {id: $a.id, workloads: [$mine[].where], resolves: [$found[].where],
       problems: (
         if ($mine | length) == 0 then ["no workload in \($a.namespace)"]
         elif ($found | length) == 0 then ["workload(s) \([$mine[].where] | join(",")) found by neither a Pod named \($a.id) nor signalloom.ai/agent-name=\($short)"]
         elif ($found | length) > 1 then ["ambiguous: \([$found[].where] | join(","))"]
         elif ($found[0].labels["signalloom.ai/agent"] // "") != "true" then ["\($found[0].where) lacks signalloom.ai/agent=true; the sentinel does not watch it"]
         else [] end)}' <<<"$(pod_templates)"
}

@test "every fleet DAG agent with a workload resolves to exactly one sentinel-watched pod" {
  local all bad
  all="$(verdicts)"
  [ "$(jq -s 'length' <<<"$all")" -ge 6 ] || { echo "too few fleet agents with workloads:"; echo "$all"; return 1; }
  bad="$(jq -r 'select((.problems | length) > 0) | "\(.id): \(.problems | join("; "))"' <<<"$all")"
  [ -z "$bad" ] || { printf '%s\n' "$bad"; return 1; }
}
