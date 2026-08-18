#!/usr/bin/env bats
#
# Fleet Manager, as the browser actually reaches it.
#
# ─── Why this file exists next to fleet-manager-contract.bats ────────────────
#
# fleet-manager-contract.bats has 22 tests and all 22 were green on the day the
# Fleet page rendered "Fleet API 502" over a raw nginx error body. They were not
# broken and they were not wrong; they simply answer a different question. They
# ask "is this manifest well-formed?" and the manifest was perfect. Nothing
# asked "does this workload exist?", and it did not: apps/fleet-manager/base was
# named by no kustomization Flux reconciles, so the slice sat complete in the
# repo for two weeks — source, unit tests, manifests, contract suite — and never
# reached a cluster. The only deploy path was a `kubectl apply -k` escape hatch
# that no bring-up target and no CI stage called.
#
# A manifest-existence test cannot catch that, because the manifest exists. That
# is the whole point of this file: it asks the running system.
#
# ─── Why 200 is not the assertion, and content-type is ───────────────────────
#
# The first failure of this bug was not a 502 at all. Before nginx had a
# /fleet-api/ location the request fell through to the SPA catch-all and nginx
# answered the API call with index.html at **200 OK** — so `res.ok` was TRUE and
# the client died downstream on
#   Unexpected token '<', "<!doctype "... is not valid JSON
# which names the symptom and buries the cause. fleetApi.ts:74-84 carries that
# history and uses content-type as the discriminator, because a 200 that is not
# JSON is not an answer from this API. This suite asserts the same discriminator
# so a future route collision cannot pass by returning the wrong 200.
#
# ─── Contract source ─────────────────────────────────────────────────────────
#
# The asserted keys are the `FleetTopology` interface in
# apps/dashboard-signalloom/src/api/fleetApi.ts. If that interface changes, this
# file is supposed to fail — it is the consumer contract, not a restatement of
# whatever the server currently emits.
#
# Precondition: kubectl port-forward -n fe-signalloom svc/dashboard-signalloom 5173:8080
# Override with SIGNALLOOM_UI_URL. Skips gracefully when the dashboard is absent.

setup() {
  base="${SIGNALLOOM_UI_URL:-http://localhost:5173}"
  ns="${SIGNALLOOM_NAMESPACE:-fe-signalloom}"

  command -v jq >/dev/null || skip "jq is required to assert the JSON contract"

  # Check the BODY, not just the status, for the reason dashboard-routes.bats
  # documents at length: a Vite dev server on the same port answers everything
  # with index.html, including /readyz, so a status-only probe never skips and
  # the suite reports failures against a server that was never the dashboard.
  local ready
  ready="$(curl -fsS "$base/readyz" 2>/dev/null || true)"
  [ -n "$ready" ] || skip "dashboard not reachable at $base (port-forward required)"
  if [ "$ready" != "ready" ]; then
    skip "$base is not the nginx dashboard — /readyz returned '$(printf '%.40s' "$ready")' rather than 'ready'. Point SIGNALLOOM_UI_URL at the real service."
  fi

  topology_url="$base/fleet-api/v1/fleet/topology"
}

# Fetches the topology once into $BATS_TEST_TMPDIR, emitting "<code> <ctype>".
# Body and metadata are captured in a single request so a flaky intermediate
# cannot make the status and the body disagree.
fetch_topology() {
  curl -s -o "$BATS_TEST_TMPDIR/body" \
    -w '%{http_code} %{content_type}' \
    "$topology_url"
}

@test "FLEET-LIVE topology endpoint returns 200" {
  run fetch_topology
  [ "$status" -eq 0 ]

  local code="${output%% *}"
  if [ "$code" != "200" ]; then
    printf 'GET %s returned HTTP %s, not 200.\n\n' "$topology_url" "$code" >&2
    printf 'First 200 bytes of the body:\n%s\n\n' "$(head -c 200 "$BATS_TEST_TMPDIR/body")" >&2
    printf '502 from nginx means the /fleet-api/ proxy resolved\n' >&2
    printf 'fleet-manager.%s.svc.cluster.local and could not connect — the\n' "$ns" >&2
    printf 'Service has no endpoints, or the workload was never deployed.\n' >&2
    printf 'Check: kubectl -n %s get deploy,svc,endpoints -l app.kubernetes.io/name=fleet-manager\n' "$ns" >&2
    return 1
  fi
}

@test "FLEET-LIVE topology answers as JSON, not the SPA fallback" {
  run fetch_topology
  [ "$status" -eq 0 ]

  local ctype="${output#* }"
  case "$ctype" in
    *json*) : ;;
    *)
      printf 'GET %s answered with content-type "%s".\n\n' "$topology_url" "$ctype" >&2
      printf 'text/html here is the failure fleetApi.ts:74-84 describes: no nginx\n' >&2
      printf 'location matched /fleet-api/, so the SPA catch-all served index.html.\n' >&2
      printf 'The client sees res.ok === true and fails later inside res.json().\n' >&2
      return 1
      ;;
  esac
}

@test "FLEET-LIVE topology body is parseable JSON" {
  run fetch_topology
  [ "$status" -eq 0 ]

  run jq -e . "$BATS_TEST_TMPDIR/body"
  [ "$status" -eq 0 ]
}

@test "FLEET-LIVE topology carries every FleetTopology key the client reads" {
  run fetch_topology
  [ "$status" -eq 0 ]

  # fleetApi.ts: interface FleetTopology. All four are non-optional, so a
  # missing one is a broken contract even when the response is valid JSON.
  local key
  for key in agents edges aggregateRisk cascadeHistory; do
    run jq -e --arg k "$key" 'has($k)' "$BATS_TEST_TMPDIR/body"
    [ "$status" -eq 0 ] || {
      printf 'topology response has no "%s" key.\n' "$key" >&2
      printf 'FleetTopology in fleetApi.ts declares it non-optional.\n' >&2
      return 1
    }
  done

  # agents and edges are arrays; the Fleet page maps over both.
  run jq -e '(.agents | type) == "array" and (.edges | type) == "array"' "$BATS_TEST_TMPDIR/body"
  [ "$status" -eq 0 ]
}

@test "FLEET-LIVE topology reports a non-empty agent fleet" {
  run fetch_topology
  [ "$status" -eq 0 ]

  # An empty fleet is the shape a silently-unbound RoleBinding produces: the
  # API server answers 403, client-go surfaces that as an EMPTY result rather
  # than an error, and the page renders a valid, believable, wrong answer.
  # The shipped fleet-config ConfigMap defines several agents, so zero is a
  # defect and not a legitimate state here.
  run jq -e '(.agents | length) > 0' "$BATS_TEST_TMPDIR/body"
  [ "$status" -eq 0 ] || {
    printf 'topology returned zero agents.\n' >&2
    printf 'Either the fleet-config ConfigMap did not mount, or fleet-manager\n' >&2
    printf 'holds no grant in fe-signalloom-agents and is reading 403 as empty.\n' >&2
    return 1
  }
}

@test "FLEET-LIVE every agent carries the AgentState fields the client renders" {
  run fetch_topology
  [ "$status" -eq 0 ]

  # fleetApi.ts: interface AgentState. Only the non-optional fields are asserted
  # — gracePeriod and riskClass are declared optional and must stay optional.
  run jq -e '
    [ .agents[]
      | has("id") and has("name") and has("type")
        and has("team") and has("trustProfile") and has("state")
    ] | all
  ' "$BATS_TEST_TMPDIR/body"
  [ "$status" -eq 0 ] || {
    printf 'at least one agent is missing a required AgentState field.\n' >&2
    printf 'Required by fleetApi.ts: id, name, type, team, trustProfile, state.\n' >&2
    printf 'Got: %s\n' "$(jq -c '.agents[0] // "no agents"' "$BATS_TEST_TMPDIR/body")" >&2
    return 1
  }
}

@test "FLEET-LIVE aggregateRisk carries the numeric RiskSummary fields" {
  run fetch_topology
  [ "$status" -eq 0 ]

  # The Fleet page formats these as currency. A string here renders as NaN
  # rather than failing, so the type is part of the contract, not just the key.
  run jq -e '
    (.aggregateRisk.ale | type) == "number"
    and (.aggregateRisk.var95 | type) == "number"
    and ([.aggregateRisk.trend] | inside(["up","down","stable"]))
  ' "$BATS_TEST_TMPDIR/body"
  [ "$status" -eq 0 ] || {
    printf 'aggregateRisk does not match RiskSummary in fleetApi.ts.\n' >&2
    printf 'Got: %s\n' "$(jq -c '.aggregateRisk' "$BATS_TEST_TMPDIR/body")" >&2
    return 1
  }
}

@test "FLEET-LIVE the fleet-manager Service has at least one ready endpoint" {
  command -v kubectl >/dev/null || skip "kubectl is required"
  kubectl cluster-info >/dev/null 2>&1 || skip "no reachable cluster"

  # Asserted separately from the HTTP tests on purpose. The proxy failing and
  # the workload being absent are different bugs with different fixes, and a
  # suite that only reports "502" sends the next engineer to nginx.conf when the
  # answer is that nothing was ever deployed.
  run kubectl -n "$ns" get endpoints fleet-manager \
    -o jsonpath='{.subsets[*].addresses[*].ip}'
  [ "$status" -eq 0 ] || {
    printf 'no Endpoints object named fleet-manager in namespace %s.\n' "$ns" >&2
    printf 'The Service was never created, so nginx has nothing to proxy to.\n' >&2
    return 1
  }
  [ -n "$output" ] || {
    printf 'Service fleet-manager exists in %s but has zero ready endpoints.\n' "$ns" >&2
    printf 'The Deployment is absent, unscheduled, or failing its readiness probe.\n' >&2
    return 1
  }
}

@test "FLEET-LIVE fleet-manager is delivered by Flux, not hand-applied" {
  command -v kubectl >/dev/null || skip "kubectl is required"
  kubectl cluster-info >/dev/null 2>&1 || skip "no reachable cluster"

  # Flux must own this workload. A hand-applied copy satisfies every test above
  # and then vanishes on the next reconcile or drifts from the repo silently,
  # which is how the escape-hatch target masked the missing wiring in the first
  # place. Ownership is the difference between deployed and deployed-by-GitOps.
  run kubectl -n "$ns" get deployment fleet-manager \
    -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}'
  [ "$status" -eq 0 ]
  [ -n "$output" ] || {
    printf 'Deployment fleet-manager carries no Flux kustomize label.\n' >&2
    printf 'It was hand-applied (make demo-signalloom-fleet-up) rather than\n' >&2
    printf 'reconciled. Flux reverts or prunes it on the next pass. It must be\n' >&2
    printf 'reached through apps/fe-signalloom/base/kustomization.yaml.\n' >&2
    return 1
  }
}
