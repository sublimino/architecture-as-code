#!/usr/bin/env bats

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  real_kubectl="$(command -v kubectl)"
  bin="$BATS_TEST_TMPDIR/bin"
  log="$BATS_TEST_TMPDIR/commands.log"
  mkdir -p "$bin"
  cat >"$bin/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$COMMAND_LOG"
if [[ "$*" == *'get daemonset -o json'* ]]; then
  if [[ "${AGENT_TRUST_FAKE_CNI:-none}" == kindnet ]]; then
    printf '%s\n' '{"items":[{"metadata":{"name":"kindnet"}}]}'
  else
    printf '%s\n' '{"items":[]}'
  fi
fi
if [[ "$*" == *'api-resources --api-group=networking.k8s.io -o name'* ]]; then printf 'networkpolicies\n'; fi
if [[ "$*" == *'get pods -l app.kubernetes.io/name=agent-trust-triage'* ]]; then printf 'true\n'; fi
if [[ "$*" == *'get deployment openbao -o json'* ]]; then printf '%s\n' '{"spec":{"template":{"spec":{"containers":[{"name":"openbao","env":[{"name":"BAO_DEV_ROOT_TOKEN_ID","value":"fixture-admin-token"}]}]}}}}'; fi
# Carries bound_subject/bound_audiences/token_policies as well as the lifetime.
# The old fixture returned lifetime only, so verify's identity-binding assertions
# had nothing to bind against — dropping bound_subject from role creation left
# every gate green while any SVID with the right audience could log in as the
# planner.
if [[ "$*" == *'bao read -format=json auth/jwt/role/agent-trust-'* ]]; then
  at_args="$*"; at_role="${at_args##*auth/jwt/role/agent-trust-}"; at_role="${at_role%% *}"
  at_sub="spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/${at_role}"
  [[ "${AGENT_TRUST_FAKE_UNBOUND_ROLE:-0}" == 1 && "$at_role" == planner ]] && at_sub=""
  printf '{"data":{"token_type":"batch","token_ttl":300,"token_max_ttl":300,"token_period":0,"bound_subject":"%s","bound_audiences":["openbao-supercredential"],"token_policies":["agent-trust-acme-payments"]}}\n' "$at_sub"
fi
# Matches the planner selector without pinning its full text. The script excludes
# probe pods via `,app.kubernetes.io/component!=probe`, and a shim pinned to the
# bare selector silently returned nothing the moment that exclusion was added --
# turning eleven tests red for a reason unrelated to what they assert.
if [[ "$*" == *'get pods -l app.kubernetes.io/name=agent-trust-planner'*'-o json'* ]]; then
  printf '%s\n' '{"items":[{"metadata":{"name":"planner-0"},"status":{"containerStatuses":[{"ready":true}]}}]}'
fi
if [[ "$*" == *'exec planner-0 -- /usr/local/bin/spire-agent api fetch jwt'* ]]; then
  printf '%s\n' '[{"svids":[{"svid":"fixture-jwt"}]}]'
fi
if [[ "$*" == *'sh -ec'* && "$*" == *'bao write -format=json auth/jwt/login role=agent-trust-planner'* ]]; then
  if [[ "${AGENT_TRUST_FAKE_RENEWABLE_TOKEN:-0}" == 1 ]]; then
    printf '%s\n' '{"auth":{"renewable":true,"lease_duration":300,"client_token":"fixture-service"}}'
  else
    printf '%s\n' '{"auth":{"renewable":false,"lease_duration":300,"client_token":"fixture-batch"}}'
  fi
fi
if [[ "$*" == *'sh -ec'* && "$*" == *'bao token renew'* ]]; then
  if [[ "${AGENT_TRUST_FAKE_RENEW_TRANSPORT_FAILURE:-0}" == 1 ]]; then printf 'connection refused\n' >&2; exit 1; fi
  if [[ "${AGENT_TRUST_FAKE_RENEW_SUCCESS:-0}" == 1 ]]; then printf 'renewed\n'; exit 0; fi
  printf 'batch tokens cannot be renewed\n' >&2
  exit 2
fi
if [[ "$*" == *'get pod -l app.kubernetes.io/name=spire-server -o jsonpath='* ]]; then printf 'spire-server-0'; fi
# The trust anchor: SPIRE's live JWT-SVID keys, and the keys OpenBao will accept
# a signature from. Real P-256 material, because verify canonicalises both sides
# through openssl and a placeholder would fail for the wrong reason.
# AGENT_TRUST_FAKE_ROTATED_JWT_KEY reproduces the 2026-08-14 outage exactly:
# SPIRE signs with a key OpenBao's bring-up snapshot never saw.
if [[ "$*" == *'spire-server bundle show -format spiffe'* ]]; then
  at_jwks='{"use":"jwt-svid","kty":"EC","crv":"P-256","x":"UpawTyaemo3XLu2reqdiHkJq8LBHhNJvd1TXaHkp42g","y":"gchYAtHh1VMr-IQZFLnxVGzWpooTAGi6RrjTcZU_1VE"}'
  if [[ "${AGENT_TRUST_FAKE_ROTATED_JWT_KEY:-0}" == 1 ]]; then
    at_jwks="$at_jwks"',{"use":"jwt-svid","kty":"EC","crv":"P-256","x":"UxSKjHKNP8uZl8SOkYfSUMzNJ-tnRzmWFHuvRjtlgpM","y":"vUgmUjuFcmSfXsQ65CqdihUBGRnXPR79Gsn7jIRqSVo"}'
  fi
  printf '{"keys":[%s]}\n' "$at_jwks"
fi
if [[ "$*" == *'bao read -format=json auth/jwt/config'* ]]; then
  printf '%s\n' '{"data":{"jwt_validation_pubkeys":["-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEUpawTyaemo3XLu2reqdiHkJq8LBH\nhNJvd1TXaHkp42iByFgC0eHVUyv4hBkUufFUbNamihMAaLpGuNNxlT/VUQ==\n-----END PUBLIC KEY-----"]}}'
fi
# Must echo the SELECTORS, not just an Entry ID. verify asserts k8s:ns/k8s:sa
# because those are the workload-attestation property; a fixture that returns a
# bare "Entry ID" would let the selector assertions pass against a response that
# never carried a selector at all — the exact gate-that-cannot-fail this shim
# exists to exercise.
if [[ "$*" == *'spire-server entry show -spiffeID'* ]]; then
  at_args="$*"; at_id="${at_args##*-spiffeID }"; at_id="${at_id%% *}"
  case "$at_id" in
    */payments/agent/planner)      at_ns=agent-trust-acme-payments;              at_sa=agent-trust-planner ;;
    */payments/agent/triage)       at_ns=agent-trust-acme-payments;              at_sa=agent-trust-triage ;;
    */risk/agent/risk-reader)      at_ns=agent-trust-acme-risk;                  at_sa=agent-trust-risk-reader ;;
    */investigations/agent/investigator) at_ns=agent-trust-northstar-investigations; at_sa=agent-trust-investigator ;;
    *) at_ns=unknown; at_sa=unknown ;;
  esac
  [[ "${AGENT_TRUST_FAKE_MISSING_SA_SELECTOR:-0}" == 1 && "$at_sa" == agent-trust-planner ]] && at_sa=""
  printf 'Entry ID : fixture-entry\n'
  printf 'SPIFFE ID : %s\n' "$at_id"
  printf 'Selector : k8s:ns:%s\n' "$at_ns"
  [[ -n "$at_sa" ]] && printf 'Selector : k8s:sa:%s\n' "$at_sa"
fi
if [[ "$*" == *'exec deployment/'* ]]; then
  if [[ "${AGENT_TRUST_FAKE_UNEXPECTED_ALLOW:-0}" == 1 && "$*" == *'deployment/agent-trust-risk-reader'* ]]; then exit 0; fi
  # Breakage that exits 1 exactly like a dropped packet does. Scoped to the nc
  # probes so the call-a2a exec is untouched. The stderr strings are copied from
  # real failures: busybox nc emits "bad address", and kubectl emits the exec and
  # not-found messages.
  if [[ "$*" == *' nc -z '* && "${AGENT_TRUST_FAKE_DNS_FAILURE:-0}" == 1 && "$*" == *'deployment/agent-trust-risk-reader'* ]]; then
    printf "nc: bad address 'agent-trust-triage.agent-trust-acme-payments.svc'\n" >&2; exit 1
  fi
  if [[ "$*" == *' nc -z '* && "${AGENT_TRUST_FAKE_NC_MISSING:-0}" == 1 && "$*" == *'deployment/agent-trust-risk-reader'* ]]; then
    printf 'OCI runtime exec failed: exec failed: unable to start container process: exec: "nc": executable file not found in $PATH\n' >&2; exit 126
  fi
  if [[ "$*" == *' nc -z '* && "${AGENT_TRUST_FAKE_PROBE_POD_ABSENT:-0}" == 1 && "$*" == *'deployment/agent-trust-risk-reader'* ]]; then
    printf 'error: unable to upgrade connection: container not found ("risk-reader")\n' >&2; exit 1
  fi
  if [[ "$*" == *'deployment/agent-trust-risk-reader'* || "$*" == *'deployment/agent-trust-investigator'* || "$*" == *' 1.1.1.1 443'* ]]; then exit 1; fi
fi
if [[ "$*" == *'get resourceset -o json'* ]]; then
  printf '%s\n' '{"items":[{"metadata":{"name":"signalloom-infra"},"spec":{"inputs":[{"tenant":"inf-bao","tag":"latest"}]}},{"metadata":{"name":"signalloom-apps"},"spec":{"inputs":[{"tenant":"fe-signalloom","tag":"latest"}]}},{"metadata":{"name":"olly"},"spec":{"inputs":[]}}]}'
fi
if [[ "${AGENT_TRUST_FAKE_ABSENT:-0}" == 1 && "$*" == *'get namespace agent-trust-'* ]]; then exit 1; fi
# Without this the shim reports the A2A key material as already present, so
# prepare_a2a_keys returns early, a2a_keys_created stays false, and the rollback
# path has nothing to unwind. A test asserting that cleanup against the default
# fixture is asserting a no-op -- both sides agree by construction and the
# assertion cannot fail. This flag makes the material absent so the run really
# creates it and the rollback really has to remove it.
if [[ "${AGENT_TRUST_FAKE_A2A_ABSENT:-0}" == 1 && "$*" == *'get secret agent-trust-a2a-private'* ]]; then exit 1; fi
if [[ "${AGENT_TRUST_FAKE_A2A_ABSENT:-0}" == 1 && "$*" == *'get configmap agent-trust-a2a-public'* ]]; then exit 1; fi
if [[ "${AGENT_TRUST_FAKE_DOWN_FAILURE:-0}" == 1 && "$*" == *'metadata.annotations.agent-trust'* ]]; then printf 'true'; fi
# Discriminate on the actual jsonpath rather than answering '[]' to every query
# about this object. The blanket form made any jsonpath the script asked for
# look like an empty input list, so a wait on the reconcile annotation -- the
# state `down` now asserts -- silently never matched and spun its full 600s
# deadline. A fixture that answers a question it was not asked turns a wrong
# query into a hang, which reads as a broken deadline rather than a broken shim.
if [[ "$*" == *'get resourceset/agent-trust -o jsonpath='*'fluxcd\.controlplane\.io/reconcile'* ]]; then
  printf 'disabled'
elif [[ "$*" == *'get resourceset/agent-trust -o jsonpath={.spec.inputs}'* ]]; then
  printf '[]'
elif [[ "$*" == *'get resourceset/agent-trust -o jsonpath='* && "$*" != *'metadata.annotations.agent-trust'* ]]; then
  printf '[]'
fi
if [[ "${AGENT_TRUST_FAKE_DOWN_FAILURE:-0}" == 1 && "$*" == *'delete namespace agent-trust-platform'* ]]; then exit 1; fi
SCRIPT
cat >"$bin/flux" <<'SCRIPT'
#!/usr/bin/env bash
printf 'flux %s\n' "$*" >>"$COMMAND_LOG"
if [[ "${AGENT_TRUST_FAKE_RECONCILE_FAILURE:-0}" == 1 && "$*" == *'reconcile kustomization agent-trust'* ]]; then exit 1; fi
SCRIPT
  chmod +x "$bin/kubectl" "$bin/flux"
}

line_number() {
  local first line=""
  first="$(grep -n -F "$1" "$log" | cut -d: -f1 | { IFS= read -r line || true; printf '%s' "$line"; })"
  printf '%s\n' "$first"
}

# Was "preflights Bao before PATCHING the opt-in ResourceSet", and it asserted
# the whole snapshot-and-restore choreography: `get resourceset -o json`, then a
# patch of signalloom-infra's and signalloom-apps' spec.inputs, then a patch of
# agent-trust's. That machinery existed to survive a fleet refresh that reapplied
# `inputs: []` over the siblings. The inputs are declared now, the refresh
# reinforces them, and none of those writes happen -- so the ordering hazard the
# choreography defended against is gone rather than merely re-timed.
#
# What survives is the actual requirement in the name: Bao is preflighted before
# the slice is switched on. Plus the stronger new one -- this lifecycle writes no
# ResourceSet's spec.inputs, its own or a sibling's.
@test "lifecycle preflights Bao before enabling the opt-in ResourceSet" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" "$root/scripts/agent-trust-local.sh" up
  [ "$status" -eq 0 ]
  [[ "$output" == *"Agent Trust local reconciliation converged"* ]]
  grep -Fq 'reconcile kustomization flux-system -n flux-system --with-source' "$log"
  grep -Fq 'suspend kustomization tenants -n flux-system' "$log"
  grep -Fq 'get resourceset agent-trust' "$log"

  # No sibling's inputs are read for later restoration, and none are written.
  run grep -F 'get resourceset -o json' "$log"
  [ "$status" -ne 0 ]
  run grep -E 'patch resourceset/(signalloom-infra|signalloom-apps|olly|apps) --type merge' "$log"
  [ "$status" -ne 0 ]

  # Bao readiness is still gated on the sibling's STATUS -- waited on, not
  # written to. That is the whole substitution: status in, spec untouched.
  grep -Fq 'wait resourceset/signalloom-infra --for=condition=ready' "$log"
  grep -Fq 'wait kustomization/infra-configs --for=condition=ready' "$log"
  # Activation itself: clearing the disable annotation, not a spec write.
  grep -Fq 'annotate resourceset/agent-trust fluxcd.controlplane.io/reconcile-' "$log"
  grep -Fq 'reconcile kustomization agent-trust -n agent-trust-platform --with-source' "$log"
  grep -Fq 'bao write "auth/jwt/role/agent-trust-${agent}"' "$log"
  grep -Fq 'bao read -format=json auth/jwt/role/agent-trust-planner' "$log"
  grep -Fq 'spire-server entry show -spiffeID spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/planner' "$log"
  grep -Fq 'rollout status deploy/agent-trust-triage' "$log"
  grep -Fq 'get service agent-trust-triage' "$log"
  # Ordering. This used to be suspend < restore < bao_preflight, where `restore`
  # was the sibling-inputs patch that had to land inside the suspended window or
  # a reconcile would blank it. With no restore step the chain is simply:
  # refresh the fleet, quiesce the owning reconcilers, then gate on Bao. The
  # third link is the one that carried the requirement in this test's name.
  refresh=$(line_number 'reconcile kustomization flux-system -n flux-system --with-source')
  suspend=$(line_number 'suspend kustomization tenants -n flux-system')
  bao_preflight=$(line_number 'wait resourceset/signalloom-infra --for=condition=ready')
  enable=$(line_number 'annotate resourceset/agent-trust fluxcd.controlplane.io/reconcile-')
  [ "$refresh" -lt "$suspend" ]
  [ "$suspend" -lt "$bao_preflight" ]
  # The requirement the test is named for: Bao is ready before the slice is on.
  [ "$bao_preflight" -lt "$enable" ]
}

@test "Agent Trust Flux bootstrap grants roles and rolebindings before reconciliation" {
  fleet="$root/d2-osramp-fleet/tenants/base/agent-trust.yaml"
  run yq -o=json 'select(.kind == "ResourceSet") | .spec.resources[] | select(.kind == "ClusterRole" and .metadata.name == "agent-trust-flux-workloads")' "$fleet"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"roles"'* ]]
  [[ "$output" == *'"rolebindings"'* ]]
  [[ "$output" == *'"pods"'* ]]
  [[ "$output" == *'"patch"'* ]]
}

# ── spec.inputs is Flux's, not this script's ────────────────────────────────
#
# tenants/base/agent-trust.yaml declares spec.inputs, so the flux-system/tenants
# Kustomization owns that field and the reconciler may revert any write to it at
# any time. Every path in this lifecycle therefore has to express activation and
# deactivation through the reconcile annotation, which is absent from the source
# manifest and so is NOT reconciler-owned.
#
# The three tests below assert that separately for activation, rollback and
# teardown, and the fourth asserts it once at source level so a fourth path
# added later cannot quietly reintroduce the patch.
#
# Was "repeat activation changes nonce without changing logical inputs". The
# nonce existed to mutate spec.inputs enough to force a rebuild. With the inputs
# declared, reconcile.fluxcd.io/requestedAt does that without touching a field
# the script does not own.
@test "repeat activation re-enables and requests reconciliation without writing inputs" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" \
    "$root/scripts/agent-trust-local.sh" up
  [ "$status" -eq 0 ]
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" \
    "$root/scripts/agent-trust-local.sh" up
  [ "$status" -eq 0 ]

  # Both runs clear the disable annotation -- that is what re-activates the
  # slice, because the controller returns on obj.IsDisabled() before building.
  mapfile -t enables < <(grep -F 'annotate resourceset/agent-trust fluxcd.controlplane.io/reconcile-' "$log")
  [ "${#enables[@]}" -eq 2 ]

  # Both runs request a reconcile, which is what the nonce used to accomplish.
  mapfile -t requests < <(grep -F 'annotate resourceset/agent-trust reconcile.fluxcd.io/requestedAt=' "$log")
  [ "${#requests[@]}" -eq 2 ]

  # And neither writes spec.inputs.
  run grep -F 'patch resourceset/agent-trust --type merge' "$log"
  [ "$status" -ne 0 ]
}

# Was "rolls activation back to INACTIVE INPUTS", asserting the message
# "restoring ResourceSet inputs to []" and a patch to `{"spec":{"inputs":[]}}`.
#
# That rollback restored into the exact state this branch exists to eliminate.
# `inputs: []` is not an inactive ResourceSet -- flux-operator's
# BuildResourceSet renders the template ONCE against a nil map when the input
# list is empty, so the object does not go quiet, it goes terminally Stalled
# with `map has no entry for key "tenant"`. The old rollback was not restoring
# anything: it converted a half-activated slice into an unbuildable one, with
# every namespace it had already created still present, because a Stalled
# ResourceSet does not prune. It looked like deactivation and was not.
#
# What rollback is actually FOR is the imperative side-effects that Flux does
# not own -- the OpenBao roles and SPIRE entries, the A2A key material, the
# namespace this script created itself, and resuming root reconciliation. Those
# are still real and still asserted here. The ResourceSet half is now the
# annotation, which is a state the operator implements.
@test "failed reconciliation disables the slice and unwinds what Flux does not own" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_RECONCILE_FAILURE=1 \
    "$root/scripts/agent-trust-local.sh" up
  [ "$status" -ne 0 ]
  [[ "$output" == *"disabling the ResourceSet"* ]]

  # The ResourceSet is left in an off-state the controller honours...
  grep -Fq 'annotate resourceset/agent-trust fluxcd.controlplane.io/reconcile=disabled --overwrite' "$log"
  # ...and NOT in the unbuildable one, which is what it used to be left in.
  run grep -F 'patch resourceset/agent-trust --type merge' "$log"
  [ "$status" -ne 0 ]

  # Root reconciliation is handed back, which is the one unwind that always runs.
  grep -Fq 'flux resume kustomization flux-system -n flux-system' "$log"
  grep -Fq 'flux resume kustomization tenants -n flux-system' "$log"

  # The failure is injected at `flux reconcile kustomization agent-trust`, i.e.
  # before configure_identity_plane, so the OpenBao roles were never written and
  # must not be deleted. Asserting their cleanup here would pass only because
  # nothing had happened.
  run grep -F 'bao delete auth/jwt/role/agent-trust-planner' "$log"
  [ "$status" -ne 0 ]
}

# The other half of "unwinds what Flux does not own": material this run actually
# created. Split out because it needs a fixture in which the A2A keys are ABSENT
# to begin with -- against the default shim they read as already present,
# prepare_a2a_keys returns early, and any assertion about their removal passes
# without the removal ever being reachable.
@test "rollback deletes the A2A material the failed run created" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" \
    AGENT_TRUST_FAKE_A2A_ABSENT=1 AGENT_TRUST_FAKE_RECONCILE_FAILURE=1 \
    "$root/scripts/agent-trust-local.sh" up
  [ "$status" -ne 0 ]

  # Precondition: this run genuinely created the material, so there is something
  # to unwind. Without this the deletion assertions below would be vacuous.
  grep -Fq 'create secret generic agent-trust-a2a-private' "$log"
  grep -Fq 'create configmap agent-trust-a2a-public' "$log"

  grep -Fq 'delete secret agent-trust-a2a-private' "$log"
  grep -Fq 'delete configmap agent-trust-a2a-public' "$log"
}

# Source-level guard, so a fourth path cannot reintroduce the drift without
# tripping something. The three behavioural tests above prove the paths that
# exist today do the right thing; this one covers the paths that do not exist
# yet. Scanning the script from the test file keeps the forbidden literal out of
# the file being scanned -- a guard that greps for a pattern it also contains
# fires on itself and reads exactly like a real finding.
@test "the lifecycle never writes the Flux-owned spec.inputs field" {
  run grep -n 'spec\\*":{\\*"inputs' "$root/scripts/agent-trust-local.sh"
  [ "$status" -ne 0 ] || {
    printf 'agent-trust-local.sh writes spec.inputs:\n%s\n' "$output" >&2
    printf 'That field is declared in tenants/base/agent-trust.yaml, so the\n' >&2
    printf 'tenants Kustomization owns it and will revert the write. Express\n' >&2
    printf 'activation and deactivation through fluxcd.controlplane.io/reconcile.\n' >&2
    return 1
  }

  # Prove the guard can see the thing it is looking for, rather than passing
  # because the pattern never matches anything at all.
  local canary="$BATS_TEST_TMPDIR/canary.sh"
  printf '%s\n' 'kubectl patch resourceset/x --type merge -p "{\"spec\":{\"inputs\":[]}}"' >"$canary"
  run grep -n 'spec\\*":{\\*"inputs' "$canary"
  [ "$status" -eq 0 ]
}

@test "network test fails closed when no CNI daemonset is present" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" "$root/scripts/agent-trust-local.sh" network-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNVERIFIED"* ]]
  ! grep -Fq 'exec deployment/' "$log"
}

@test "kindnet is admitted to dataplane probes without name-based enforcement inference" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet \
    "$root/scripts/agent-trust-local.sh" network-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"NetworkPolicy evidence passed"* ]]
  [[ "$output" == *"five-minute non-renewable batch token"* ]]
  grep -Fq 'api-resources --api-group=networking.k8s.io -o name' "$log"
  grep -Fq 'sh -ec' "$log"
  grep -Fq 'bao token renew' "$log"
  grep -Fq 'exec deployment/agent-trust-planner -- nc -z -w 5 agent-trust-triage 8080' "$log"
  grep -Fq 'exec deployment/agent-trust-planner -- /usr/local/bin/signalloom-spire-proof call-a2a -audience openbao-supercredential' "$log"
  grep -Fq 'exec deployment/agent-trust-risk-reader -- nc -z -w 5 agent-trust-triage.agent-trust-acme-payments.svc 8080' "$log"
}

@test "renewable OpenBao token fails authenticated network evidence" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet AGENT_TRUST_FAKE_RENEWABLE_TOKEN=1 \
    "$root/scripts/agent-trust-local.sh" network-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"renewable or exceeds five minutes"* ]]
  ! grep -Fq 'signalloom-spire-proof call-a2a' "$log"
}

@test "renewal transport failure cannot prove a batch-token denial" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet AGENT_TRUST_FAKE_RENEW_TRANSPORT_FAILURE=1 \
    "$root/scripts/agent-trust-local.sh" network-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"renewal denial could not be proven"* ]]
  ! grep -Fq 'signalloom-spire-proof call-a2a' "$log"
}

@test "unexpectedly renewable batch token fails authenticated evidence" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet AGENT_TRUST_FAKE_RENEW_SUCCESS=1 \
    "$root/scripts/agent-trust-local.sh" network-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpectedly renewed"* ]]
  ! grep -Fq 'signalloom-spire-proof call-a2a' "$log"
}

# A denial is only evidence if the probe could have succeeded. `nc` exits 1 for a
# dropped packet, an unresolvable name, a missing binary and a dead container
# alike — so without these three, every deny assertion in the suite passes on any
# breakage and the run still prints "enforced NetworkPolicy evidence passed".
# Verified against busybox:1.36, the image the scaffold pods actually run:
# `nc -z -w 2 240.0.0.1 9999` and `nc -z -w 2 nope.invalid 9999` both exit 1.

@test "a denial that is really a DNS failure is UNVERIFIED, not evidence" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet \
    AGENT_TRUST_FAKE_DNS_FAILURE=1 "$root/scripts/agent-trust-local.sh" network-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNVERIFIED"* ]]
  [[ "$output" == *"DNS failed"* ]]
  [[ "$output" != *"NetworkPolicy evidence passed"* ]]
}

@test "a denial produced by a missing nc binary is UNVERIFIED, not evidence" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet \
    AGENT_TRUST_FAKE_NC_MISSING=1 "$root/scripts/agent-trust-local.sh" network-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNVERIFIED"* ]]
  [[ "$output" == *"probe itself is unusable"* ]]
  [[ "$output" != *"NetworkPolicy evidence passed"* ]]
}

@test "a denial from a pod that is not running is UNVERIFIED, not evidence" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet \
    AGENT_TRUST_FAKE_PROBE_POD_ABSENT=1 "$root/scripts/agent-trust-local.sh" network-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNVERIFIED"* ]]
  [[ "$output" == *"is not running"* ]]
  [[ "$output" != *"NetworkPolicy evidence passed"* ]]
}

# The probe CronJobs carry the planner's app label so the NetworkPolicies that
# select on it actually apply to them -- without it they could never reach
# OpenBao or triage and failed on every run. But that label also makes them match
# `kubectl get pods -l app.kubernetes.io/name=agent-trust-planner`, and
# verify_nonrenewable_planner_token errors unless EXACTLY ONE ready pod matches.
# A probe running concurrently would therefore break the demo intermittently with
# "expected one ready planner pod". The component exclusion is what prevents that,
# and nothing else in the suite would notice if it were dropped.
# The two properties this slice exists to demonstrate — SPIFFE workload
# attestation and OpenBao subject binding — were the two the verification path
# never checked. `verify` asserted a SPIRE entry EXISTS (not its selectors) and
# that an OpenBao role is short-lived (not whose it is). Either could be removed
# entirely with verify, the network probes, bats and test_contracts.py all green:
# drop `-selector k8s:sa:...` and any pod in agent-trust-acme-payments can fetch
# the planner's SVID; drop `bound_subject=` and any SVID with the right audience
# logs in as the planner and reads the payments KV path.

@test "a SPIRE entry missing its ServiceAccount selector fails verification" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet \
    AGENT_TRUST_FAKE_MISSING_SA_SELECTOR=1 "$root/scripts/agent-trust-local.sh" verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing selector k8s:sa:agent-trust-planner"* ]]
  [[ "$output" == *"could assume this identity"* ]]
}

@test "an OpenBao role not bound to its SPIFFE subject fails verification" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet \
    AGENT_TRUST_FAKE_UNBOUND_ROLE=1 "$root/scripts/agent-trust-local.sh" verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"not bound to its SPIFFE subject"* ]]
}

# The binding assertions above answer "whose identity is this role for". They
# cannot answer "can OpenBao still check the signature", and that is the gap this
# closes. On 2026-08-14 SPIRE rotated its JWT signing key, auth/jwt/config kept
# the snapshot taken at bring-up, and openbao-planner and planner-triage-a2a
# failed every five minutes for three and a half hours while the SPIRE selectors,
# bound_subject, bound_audiences and token lifetime all stayed exactly right.
# Both sides are derived from the artefacts that decide — SPIRE's live bundle and
# OpenBao's live config — so this cannot be satisfied by a stale expectation.
@test "a rotated SPIRE JWT signing key OpenBao does not hold fails verification" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet \
    AGENT_TRUST_FAKE_ROTATED_JWT_KEY=1 "$root/scripts/agent-trust-local.sh" verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot validate the JWT-SVIDs SPIRE is signing now"* ]]
  [[ "$output" == *"rotated its JWT signing key"* ]]
}

@test "an unrotated trust anchor passes verification" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet \
    "$root/scripts/agent-trust-local.sh" verify
  [ "$status" -eq 0 ]
  [[ "$output" != *"cannot validate the JWT-SVIDs"* ]]
}

# Two derivations of "the same key" would drift the way the snapshot did, so the
# writer and the gate must share one.
@test "the identity plane sync and the verification gate share one derivation" {
  grep -Fq 'sync_openbao_jwt_validation' "$root/scripts/agent-trust-local.sh"
  grep -Fq 'sync_openbao_jwt_validation' "$root/scripts/demo-lifecycle.sh"
  grep -Fq 'assert_openbao_accepts_spire_jwt_keys' "$root/scripts/agent-trust-local.sh"
  # The JWK->DER conversion exists once, in the shared library, not in either caller.
  run grep -c 'SubjectPublicKeyInfo header' "$root/scripts/lib/spire-trust-anchor.sh"
  [ "$output" -eq 1 ]
  ! grep -Fq 'SubjectPublicKeyInfo header' "$root/scripts/demo-lifecycle.sh"
}

@test "the planner pod lookup excludes probe pods it would otherwise collide with" {
  grep -Fq 'app.kubernetes.io/name=agent-trust-planner,app.kubernetes.io/component!=probe' \
    "$root/scripts/agent-trust-local.sh"
}

@test "every planner-labelled probe also carries the component label that exempts it" {
  local probes="$root/d2-agent-trust/manifests/topology-probes.yaml"
  run python3 -c '
import sys, yaml
bad = []
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d or d.get("kind") != "CronJob":
        continue
    labels = d["spec"]["jobTemplate"]["spec"]["template"]["metadata"].get("labels", {})
    if labels.get("app.kubernetes.io/name") == "agent-trust-planner" \
       and labels.get("app.kubernetes.io/component") != "probe":
        bad.append(d["metadata"]["name"])
print(",".join(bad))
' "$probes"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unexpectedly allowed denied dataplane path fails network evidence" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet AGENT_TRUST_FAKE_UNEXPECTED_ALLOW=1 \
    "$root/scripts/agent-trust-local.sh" network-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpectedly allowed"* ]]
}

@test "lifecycle contains no fixed readiness sleeps and teardown is owned-only" {
  script="$root/scripts/agent-trust-local.sh"

  # `! cmd` was dead here. bats fails a test on a bare `!` only when it is the
  # LAST line of the body -- anywhere else the negation suppresses the failure
  # and the assertion is decoration. Verified directly: `! true` as the final
  # line fails the test, `! true` followed by any other line passes. So the
  # no-fixed-sleeps guard, the headline half of this test's name, has never been
  # able to fire. `run` plus an explicit status check works at any position.
  run grep -nE '(^|[;[:space:]])sleep[[:space:]]+[0-9]' "$script"
  [ "$status" -ne 0 ]

  # Teardown parks the ResourceSet in the off-state the operator implements.
  # This asserted a patch of spec.inputs to []. That is not an off-state --
  # BuildResourceSet renders once against a nil map when the input list is
  # empty, so it stalls the object instead of quiescing it -- and spec.inputs is
  # now declared in tenants/base/agent-trust.yaml, so writing it is drift the
  # tenants Kustomization reverts.
  grep -Fq 'fluxcd.controlplane.io/reconcile=disabled --overwrite' "$script"

  grep -Fq 'kubectl delete namespace "$namespace"' "$script"
  run grep -F 'delete namespace "$bao_namespace"' "$script"
  [ "$status" -ne 0 ]
}

@test "down deactivates the ResourceSet then removes only owned namespaces" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_ABSENT=1 \
    "$root/scripts/agent-trust-local.sh" down
  [ "$status" -eq 0 ]
  [[ "$output" == *"pre-existing inf-bao deployment remains intact"* ]]
  # Deactivation is the reconcile annotation now. Emptying inputs is retained so
  # the observable spec.inputs state is unchanged for existing callers, but it is
  # no longer what stops the slice: tenants/base/agent-trust.yaml declares the
  # inputs, so spec.inputs is a Flux-owned field that the tenants Kustomization
  # will revert. Asserting the annotation is asserting the thing that holds.
  grep -Fq 'annotate resourceset/agent-trust fluxcd.controlplane.io/reconcile=disabled --overwrite' "$log"
  run grep -F 'patch resourceset/agent-trust --type merge' "$log"
  [ "$status" -ne 0 ]
  grep -q 'get resourceset/agent-trust -o jsonpath=.*fluxcd' "$log"
  grep -Fq 'delete namespace agent-trust-platform --ignore-not-found --wait=true' "$log"
  grep -Fq 'delete namespace agent-trust-northstar-investigations --ignore-not-found --wait=true' "$log"
  ! grep -Fq 'delete namespace inf-bao' "$log"
  grep -Fq 'bao delete auth/jwt/role/agent-trust-planner' "$log"
}

@test "failed teardown still resumes root Fleet reconciliation" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_DOWN_FAILURE=1 \
    "$root/scripts/agent-trust-local.sh" down
  [ "$status" -ne 0 ]
  grep -Fq 'flux resume kustomization flux-system -n flux-system' "$log"
  grep -Fq 'flux resume kustomization tenants -n flux-system' "$log"
}

@test "ResourceSet uses limited Agent Trust RBAC and signed OCI wiring" {
  resource="$root/d2-osramp-fleet/tenants/base/agent-trust.yaml"
  # Was `grep -Fq 'inputs: []'`. That asserted the slice ships unbuildable.
  grep -Fq 'tenant: "agent-trust-platform"' "$resource"
  grep -Fq 'name: signalloom-infra' "$resource"
  grep -Fq 'namespace: inf-bao' "$resource"
  grep -Fq 'name: agent-trust-flux' "$resource"
  grep -Fq 'resources: [namespaces]' "$resource"
  [ "$(grep -c 'kind: Namespace' "$resource")" -eq 6 ]
  [ "$(grep -c 'kind: RoleBinding' "$resource")" -eq 12 ]
  grep -Fq 'verbs: [get, list, watch, create]' "$resource"
  grep -Fq 'verbs: [get, update, patch, delete]' "$resource"
  grep -Fq 'resourceNames:' "$resource"
  grep -Fq 'resources: [deployments, replicasets]' "$resource"
  ! grep -Fq 'cluster-admin' "$resource"
  grep -Fq 'provider: cosign' "$resource"
  grep -Fq 'artifactSubjectWorkflow' "$resource"
  grep -Fq 'push_and_sign "signalloom/agent-trust" "d2-agent-trust/manifests"' "$root/scripts/push-local.sh"
  grep -Fq 'repository: signalloom/agent-trust' "$root/.github/workflows/push-artifacts.yaml"
  grep -Fq 'name: allow-agent-trust-openbao' "$resource"
  grep -Fq 'agent-trust.signalloom.io/project: payments' "$resource"
  grep -Fq 'app.kubernetes.io/name: agent-trust-planner' "$resource"
  grep -Fq 'app.kubernetes.io/name: agent-trust-triage' "$resource"
  grep -Fq 'port: 8200' "$resource"
  grep -Fq '"serve-a2a"' "$root/d2-agent-trust/manifests/boundaries.yaml"
  grep -Fq 'readinessProbe: {httpGet: {path: /readyz, port: a2a}' "$root/d2-agent-trust/manifests/boundaries.yaml"
  ! grep -R -Fq 'activationNonce' "$root/d2-agent-trust/manifests"
}

# Was "renders INACTIVE Agent Trust", asserting `.spec.inputs | length == 0`.
# That assertion was the defect written down as a requirement. `inputs: []` is
# not an inactive ResourceSet -- flux-operator's BuildResourceSet renders the
# template ONCE against a nil map when the input list is empty, and with
# `Option("missingkey=error")` every `<< inputs.tag >>` is then a terminal build
# failure. The object shipped permanently Stalled, and the script that was
# supposed to repair it ran behind a readiness gate that could not open until
# the repair had already happened. Three cold CI runs produced zero of six
# agent-trust-* namespaces; this test was green through all of them.
#
# The completeness invariant now lives in test/resourceset-inputs-declarative.bats,
# which sweeps every ResourceSet in every overlay. What is asserted here is the
# narrower fact this test is named for: the local fleet renders an Agent Trust
# slice that can build, with local signature verification wired to it.
@test "local fleet renders buildable Agent Trust with local signature verification" {
  rendered="$BATS_TEST_TMPDIR/tenants-local.yaml"
  run "$real_kubectl" kustomize --load-restrictor LoadRestrictionsNone "$root/d2-osramp-fleet/tenants/local"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$rendered"
  run yq -e 'select(.kind == "ResourceSet" and .metadata.name == "agent-trust") | (.spec.inputs | length) > 0' "$rendered"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  # Every key the template dereferences has to be present in the input set, not
  # merely some keys -- a partially-populated input set stalls on exactly the
  # same error while passing any "is it activated" check.
  # The parentheses are load-bearing: `and` binds looser than `|` in yq, so
  # without them only the first has() applies to the input set and the other two
  # are evaluated against each document root -- false for every document,
  # including the one being tested.
  run yq -e 'select(.kind == "ResourceSet" and .metadata.name == "agent-trust") | .spec.inputs[0] | (has("tag") and has("artifactSubjectWorkflow") and has("artifactSubjectGitRef"))' "$rendered"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  # Selected by kind, not by position. This asserted .spec.resources[16] until
  # the topology collector's ClusterRole and its fake-proxy ClusterRoleBinding
  # were added above the OCIRepository and shifted it to 18 -- index 16 is now
  # ClusterRole/agent-trust-topology-namespaces, so the test failed while the
  # manifest was correct. The cosign patch in tenants/local/kustomization.yaml
  # is positional and has to be realigned by hand (cosign-patch-index.bats
  # guards that), but nothing forces this assertion to move with it, and a
  # stale index here fails loudly at best and silently checks the wrong
  # resource at worst.
  run yq -e 'select(.kind == "ResourceSet" and .metadata.name == "agent-trust") | .spec.resources[] | select(.kind == "OCIRepository") | .spec.verify.secretRef.name == "cosign-pub"' "$rendered"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  run yq -e 'select(.kind == "ResourceSet" and .metadata.name == "agent-trust") | .spec.dependsOn[] | select(.name == "signalloom-infra" or (.name == "infra-configs" and .namespace == "inf-bao")) | .readyExpr | contains("conditions")' "$rendered"
  [ "$status" -eq 0 ]
  [[ "$output" == *"true"* ]]
}

@test "Agent Trust Make target publishes bounded artifacts only" {
  run make -n demo-agent-trust-up
  [ "$status" -eq 0 ]
  [[ "$output" == *"push-local-fleet"* ]]
  [[ "$output" == *"push-local-agent-trust"* ]]
  [[ "$output" == *"signalloom-spire-helper"* ]]
  [[ "$output" != *"push-local-signalloom"* ]]
}

# The dashboard ships an Agent Trust Topology panel unconditionally, but the
# ResourceSet that backs it is declared with `inputs: []` and only materialises
# when this lifecycle patches concrete values into it. `demo-signalloom-up`
# never did, so every standard bring-up produced a cluster in which none of the
# six agent-trust-* namespaces existed, the topology collector was refused by
# RBAC that is itself delivered by the undeployed slice, and the panel fell back
# to a derived diagram for the entire life of the demo.
#
# Shipping a panel whose backing slice the standard bring-up never activates is
# the defect. Nothing above this line could see it: every other assertion in
# this file, in d2-agent-trust/test/test_contracts.py and in
# fake-integration-proxy/test/test_trust_topology.py checks an ARTEFACT --
# rendered YAML, script text, an injected fetch -- and all of those were correct.
# None of them checked whether the default lifecycle ever runs the thing.
@test "the standard Signal Loom bring-up activates the Agent Trust slice its dashboard panel reads" {
  run make -n demo-signalloom-up
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-trust-local.sh up"* ]]
  [[ "$output" == *"push-local-agent-trust"* ]]
}
