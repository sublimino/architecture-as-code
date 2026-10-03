#!/usr/bin/env bats
#
# The kusari stub is the SLDC containment target, and containment must keep a
# frozen agent's process alive for forensics (H1: zero restarts).
#
# A frozen agent cannot answer an httpGet liveness probe, and nothing answers
# it in its place: the sentinel's "probe preservation" records the probes and
# serves none. Live, 2026-10-03, the kubelet killed the frozen container 45 s
# into its hold (Killing: failed liveness probe) and every restart's runc init
# froze inside the frozen pod. So the target declares no liveness probe
# (decision K4, as the distributed lab ran it); readiness stays, so a frozen
# agent leaves the Service.

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
  rendered="$(KUBECONFIG=/dev/null kubectl kustomize "$repo_root/d2-signalloom/infra/agent-swarm/kusari-agent")"
}

agent_container() {
  yq -e 'select(.kind == "Deployment" and .metadata.name == "agent-kusari")
         | .spec.template.spec.containers[] | select(.name == "agent")' <<<"$rendered"
}

@test "the containment target declares no liveness probe (H1)" {
  run agent_container
  [ "$status" -eq 0 ]
  run yq '.livenessProbe // "none"' <<<"$output"
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
}

@test "the containment target keeps its readiness probe, so a frozen agent leaves the Service" {
  run agent_container
  [ "$status" -eq 0 ]
  run yq -r '.readinessProbe.httpGet.path' <<<"$output"
  [ "$status" -eq 0 ]
  [ "$output" = "/healthz" ]
}
