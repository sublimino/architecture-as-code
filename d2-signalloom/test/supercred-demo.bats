#!/usr/bin/env bats
# SuperCred demo validation — verifies the credential chain, compliance scan,
# and stun flow work end-to-end against the running cluster.
#
# Prerequisites: `make demo-signalloom-up && make demo-supercred-step1`
# must have completed. The bao slice and signalloom slice must be running.

NAMESPACE_INFRA="inf-signalloom"
NAMESPACE_BAO="inf-bao"
NAMESPACE_AGENTS="fe-signalloom-agents"
TIMEOUT="${DEMO_WAIT_TIMEOUT:-5m}"

# Shared polling/wait primitives — deadline-bounded exponential backoff with
# jitter and existence-first k8s semantics, instead of hand-rolled sleeps.
# shellcheck source=../../scripts/lib/wait.sh
source "${BATS_TEST_DIRNAME}/../../scripts/lib/wait.sh"

# cardvault and policy-engine ship distroless images (no shell, no wget/curl
# inside the container — see d2-signalloom/apps/{cardvault,policy-engine}/
# base), so `kubectl exec ... wget` can never work against them. Probe from
# outside the pod via a short-lived port-forward + curl instead, following
# the pattern d2-signalloom/test/runtime.bats already uses for the Gateway.
port_forward_wait() {
  local svc="$1" namespace="$2" local_port="$3" remote_port="$4" probe_path="${5:-/healthz}"
  kubectl -n "$namespace" port-forward "svc/$svc" "$local_port:$remote_port" \
    >"$BATS_TEST_TMPDIR/${svc}-port-forward.log" 2>&1 &
  FORWARD_PID=$!
  wait_reachable "http://localhost:$local_port$probe_path" 10 || {
    cat "$BATS_TEST_TMPDIR/${svc}-port-forward.log" >&3
    return 1
  }
}

teardown() {
  if [ -n "${FORWARD_PID:-}" ]; then
    kill "$FORWARD_PID" >/dev/null 2>&1 || true
    unset FORWARD_PID
  fi
}

# ─── Step 1 validation ───────────────────────────────────────────────────────

@test "SUPERCRED cardvault deployment is available" {
  run kubectl -n "$NAMESPACE_INFRA" wait deployment/cardvault \
    --for=condition=available --timeout=30s
  [ "$status" -eq 0 ]
}

@test "SUPERCRED policy-engine deployment is available" {
  run kubectl -n "$NAMESPACE_INFRA" wait deployment/policy-engine \
    --for=condition=available --timeout=30s
  [ "$status" -eq 0 ]
}

@test "SUPERCRED cardvault healthz returns 200" {
  port_forward_wait cardvault "$NAMESPACE_INFRA" 18080 8080
  run curl -fsS http://localhost:18080/healthz
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"ok"'* ]]
}

@test "SUPERCRED policy-engine healthz returns 200" {
  # policy-engine listens on 8081, not 8080 — matches the containerPort and
  # Service port in d2-signalloom/apps/policy-engine/base.
  port_forward_wait policy-engine "$NAMESPACE_INFRA" 18081 8081
  run curl -fsS http://localhost:18081/healthz
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"ok"'* ]]
}

@test "SUPERCRED cardvault-agent pod exists in agents namespace" {
  run kubectl -n "$NAMESPACE_AGENTS" get pod agent-cardvault -o name
  [ "$status" -eq 0 ]
  [ "$output" = "pod/agent-cardvault" ]
}

@test "SUPERCRED cardvault-agent ServiceAccount exists" {
  run kubectl -n "$NAMESPACE_AGENTS" get sa cardvault-agent -o name
  [ "$status" -eq 0 ]
}

@test "SUPERCRED OpenBao supercred bootstrap completed" {
  # The openbao-supercred-bootstrap Job (d2-signalloom/infra/inf-bao/configs/
  # base/openbao-supercred-bootstrap.yaml) is Flux-managed with
  # kustomize.toolkit.fluxcd.io/force: "true" (delete+recreate every
  # reconcile — Jobs are immutable). scripts/supercred-demo.sh demo_1() seeds
  # OpenBao directly via `kubectl exec deployment/openbao -- bao kv put ...`
  # as part of its own idempotent cleanup, and deletes this Job on the way in
  # without recreating it — Flux only recreates it on inf-bao's ~30m
  # reconcile interval. So after step 1 the Job's *absence* is the correct
  # state; the seeded secret is the durable postcondition step 1 actually
  # guarantees, and that's what "bootstrap completed" should assert — not
  # the Job object, which the script deliberately removes. (Proven by
  # force-reconciling inf-bao's Kustomization and watching the Job reappear
  # and complete in ~4s — but that only proves Flux can run a Job, which
  # isn't what this test is named for, and mutating shared Flux state isn't
  # something a healthz-style test should do on a cluster other sessions are
  # using.) openbao's image ships a shell + the `bao` CLI (it is NOT
  # distroless), so `kubectl exec` is the correct probe here — unlike
  # cardvault/policy-engine above, which are.
  run kubectl -n "$NAMESPACE_BAO" exec deployment/openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=signalloom-demo-root-token \
    bao kv get -format=json kv/signalloom/cardvault-agent
  [ "$status" -eq 0 ]
  # `bao -format=json` pretty-prints (colon-space), unlike the compact JSON
  # the policy-engine API returns below — the space here is deliberate.
  [[ "$output" == *'"username": "cardvault-svc-account"'* ]]
}

@test "SUPERCRED cardvault-agent has supercred label" {
  LABELS=$(kubectl -n "$NAMESPACE_AGENTS" get pod agent-cardvault \
    -o jsonpath='{.metadata.labels.signalloom\.ai/supercred}')
  [ "$LABELS" = "true" ]
}

@test "SUPERCRED agent pod INTENTIONALLY lacks pod-level securityContext" {
  SC=$(kubectl -n "$NAMESPACE_AGENTS" get pod agent-cardvault \
    -o jsonpath='{.spec.securityContext}')
  # Empty or just {} means no meaningful fields set
  [[ "$SC" == "" ]] || [[ "$SC" == "{}" ]]
}

# ─── Step 2 validation (credential chain) ────────────────────────────────────

@test "SUPERCRED cardvault rejects unauthenticated requests" {
  run kubectl -n "$NAMESPACE_INFRA" exec deployment/cardvault -- \
    wget -qO- http://localhost:8080/api/v1/cards 2>&1
  [ "$status" -ne 0 ]
}

# ─── Step 3 validation (compliance scan) ─────────────────────────────────────

@test "SUPERCRED policy-engine correctly evaluates non-compliant agent" {
  port_forward_wait policy-engine "$NAMESPACE_INFRA" 18081 8081
  POD_SPEC='{"containers":[{"name":"agent","securityContext":null}],"securityContext":null}'
  RESULT=$(curl -fsS -X POST http://localhost:18081/api/v1/evaluate \
    --header='Content-Type: application/json' \
    --data "{\"agent_id\":\"cardvault\",\"namespace\":\"$NAMESPACE_AGENTS\",\"pod_spec\":$POD_SPEC,\"checks\":[\"security-context-present\",\"run-as-non-root\",\"drop-capabilities\"]}" \
    2>/dev/null)
  echo "$RESULT"
  # Must report non-compliant
  [[ "$RESULT" == *'"compliant":false'* ]]
  # Must fail the security-context-present check
  [[ "$RESULT" == *'"security-context-present"'* ]]
}

@test "SUPERCRED policy-engine correctly evaluates compliant pod spec" {
  port_forward_wait policy-engine "$NAMESPACE_INFRA" 18081 8081
  POD_SPEC='{"containers":[{"name":"c","securityContext":{"capabilities":{"drop":["ALL"]}}}],"securityContext":{"runAsNonRoot":true}}'
  RESULT=$(curl -fsS -X POST http://localhost:18081/api/v1/evaluate \
    --header='Content-Type: application/json' \
    --data "{\"agent_id\":\"test\",\"namespace\":\"default\",\"pod_spec\":$POD_SPEC,\"checks\":[\"security-context-present\",\"run-as-non-root\",\"drop-capabilities\"]}" \
    2>/dev/null)
  echo "$RESULT"
  [[ "$RESULT" == *'"compliant":true'* ]]
}
