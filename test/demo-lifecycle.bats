#!/usr/bin/env bats

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  bin="$BATS_TEST_TMPDIR/bin"
  log="$BATS_TEST_TMPDIR/kubectl.log"
  mkdir -p "$bin"
  cat >"$bin/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_LOG"
if [[ "$*" == *get* ]]; then
  case "${KUBECTL_STATE:-empty}" in
    empty) printf '{"items":[]}' ;;
    consumer) printf '{"items":[{"kind":"Kustomization","metadata":{"namespace":"fe-signalloom","name":"apps","labels":{"bao.controlplane.io/consumer":"fe-signalloom"}}}]}' ;;
    unknown) printf 'api unavailable' >&2; exit 1 ;;
  esac
fi
if [[ "$*" == *exec* ]]; then
  if [[ "$*" == *'token generate'* ]]; then
    printf 'Token: local-demo-token\n'
  elif [[ "$*" == *'entry create'* ]]; then
    printf 'spiffe://signalloom.demo/ns/fe-signalloom/sa/fe-signalloom\n'
  elif [[ "$*" == *'bundle show -format spiffe'* ]]; then
    if [[ "${KUBECTL_JWT_KEYS:-one}" == two ]]; then
      printf '{"keys":[{"use":"jwt-svid","kty":"EC","crv":"P-256","x":"Sm_8qNnrAGgIreZrJYZoxYSBoLnQrIR5wuvRXpM-moM","y":"Bw4Nxy8aEwIlVQZxjoHr2qAXCpbQ2J2-syBUYOXkYzA"},{"use":"jwt-svid","kty":"EC","crv":"P-256","x":"Sm_8qNnrAGgIreZrJYZoxYSBoLnQrIR5wuvRXpM-moM","y":"Bw4Nxy8aEwIlVQZxjoHr2qAXCpbQ2J2-syBUYOXkYzA"}]}'
    else
      printf '{"keys":[{"use":"jwt-svid","kty":"EC","crv":"P-256","x":"Sm_8qNnrAGgIreZrJYZoxYSBoLnQrIR5wuvRXpM-moM","y":"Bw4Nxy8aEwIlVQZxjoHr2qAXCpbQ2J2-syBUYOXkYzA"}]}'
    fi
  fi
fi
SCRIPT
  chmod +x "$bin/kubectl"
  cat >"$bin/flux" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
  chmod +x "$bin/flux"
}

@test "compatibility aliases and every canonical lifecycle target are real Make targets" {
  # MAKE=true, and it is load-bearing rather than tidy.
  #
  # GNU Make treats any recipe line containing $(MAKE) as implicitly
  # `+`-prefixed, so `make -n` EXECUTES that line instead of printing it. A dry
  # run is therefore not side-effect-free. `demo-osramp-test` recurses into the
  # top-level `test:` target, which 8db25090e wrapped in
  # assert-bats-ran-something.sh — so this "dry run" really ran bats and hard
  # failed on an all-skip, and the failure looked like a missing Make target.
  #
  # Overriding MAKE makes the recursed command `true`, which keeps the run dry
  # while leaving every non-recursive recipe line printed exactly as before —
  # the two asserted below still appear. What this test is FOR is target
  # existence: a renamed or deleted target still fails here with
  # "No rule to make target", which is the regression it was written to catch.
  #
  # The underlying hazard is in the Makefile, not here: a recipe that recurses
  # cannot be reviewed by dry run, which matters most for destructive targets.
  # Prefer a direct invocation over $(MAKE) where reviewability counts.
  run make -n MAKE=true cluster-up cluster-down flux-bootstrap flux-test demo-bao-up demo-bao-test-config demo-bao-test demo-bao-down demo-signalloom-up demo-signalloom-test-config demo-signalloom-test demo-signalloom-down demo-osramp-up demo-osramp-test-config demo-osramp-test demo-osramp-down demo-olly-up demo-olly-test-config demo-olly-test demo-olly-down demo-signalloom-stack-up demo-signalloom-stack-down demo-signalloom-stack-purge
  [ "$status" -eq 0 ]
  [[ "$output" != *"No rule to make target"* ]]
  [[ "$output" == *"demo-lifecycle.sh bao-up"* ]]
  [[ "$output" == *"create-kind-cluster.sh"* ]]
}

@test "root up creates only the shared foundation before advertising demos" {
  run make -n up

  [ "$status" -eq 0 ]
  [[ "$output" == *"push-local-foundation"* ]]
  [[ "$output" == *"bootstrap-local"* ]]
  [[ "$output" == *"healthcheck"* ]]
  [[ "$output" == *"demo-help"* ]]
  [[ "$output" != *"make images"* ]]
  [[ "$output" != *"workload-key"* ]]
  [[ "$output" != *"signalloom-local.sh up"* ]]
  [[ "$output" != *"olly-up.sh"* ]]
  [[ "$output" != *"osramp-up.sh"* ]]
  [[ "$output" != *"demo-lifecycle.sh bao-up"* ]]
}

@test "demo help states that no demos run and lists opt-in commands" {
  run make -n demo-help

  [ "$status" -eq 0 ]
  [[ "$output" == *"No demos are running"* ]]
  [[ "$output" == *"Next: choose one demo to start"* ]]
  [[ "$output" == *"demo-signalloom-up"* ]]
  [[ "$output" == *"demo-osramp-up"* ]]
  [[ "$output" == *"demo-olly-up"* ]]
  [[ "$output" == *"demo-bao-up"* ]]
}

@test "control panel describes make up as foundation-only startup" {
  run jq -e '
    ([.lanes[] | select(.id == "control") | .title | contains("foundation")] | any) and
    ([.lanes[] | select(.id == "control") | .steps[] | select(.id == "lifecycle") |
      (.description | contains("shared foundation")) and
      (.actions[] | select(.id == "up") | .label | contains("foundation"))] | any)
  ' "$root/ui/steps.json"

  [ "$status" -eq 0 ]
}

@test "Signal Loom startup checks foundation health before activation" {
  run make -n demo-signalloom-up

  [ "$status" -eq 0 ]
  health_line=$(printf '%s\n' "$output" | grep -n -F './scripts/healthcheck.sh' | cut -d: -f1)
  up_line=$(printf '%s\n' "$output" | grep -n -F './scripts/signalloom-local.sh up' | cut -d: -f1)
  [ -n "$health_line" ]
  [ -n "$up_line" ]
  [ "$health_line" -lt "$up_line" ]
  [[ "$output" == *"push-local-signalloom"* ]]
  [[ "$output" != *"make up"* ]]
}

# Was "demo ResourceSets default to inactive inputs", asserting `inputs: []` in
# all three files and exactly twice in signalloom.yaml. That encoded the defect
# as the requirement: `inputs: []` is not an inactive ResourceSet. flux-operator
# renders spec.resources with `Option("missingkey=error")` and BuildResourceSet
# treats an empty input list as "render ONCE against a nil map" rather than
# "render nothing", so each of those objects shipped terminally Stalled with
# `map has no entry for key "tenant"` and waited for a script to repair it.
#
# The two demos that really are opt-in now say so with the annotation the
# controller actually honours (obj.IsDisabled(), checked before the build).
# Signal Loom is not opt-in on this branch -- tenants/local/kustomization.yaml
# includes it deliberately -- so it carries declarative inputs and Flux brings
# it up unaided. Completeness of those inputs is swept in
# test/resourceset-inputs-declarative.bats.
@test "opt-in demo ResourceSets ship disabled, not merely input-less" {
  local f
  for f in apps olly; do
    run grep -F 'fluxcd.controlplane.io/reconcile: disabled' \
      "$root/d2-osramp-fleet/tenants/base/$f.yaml"
    [ "$status" -eq 0 ]
  done

  # Signal Loom's two ResourceSets must NOT be input-less: an empty input list
  # there is the cold-start deadlock this branch exists to remove.
  #
  # Asserted structurally rather than with `grep -Fc 'inputs: []'`, which is a
  # guard that matches its own documentation: the header of signalloom.yaml
  # explains at length why `inputs: []` was wrong, so the literal appears in the
  # file for exactly the reason the file is now correct. yq parses YAML and does
  # not see comments.
  command -v yq >/dev/null || skip "yq is required"
  local name
  for name in signalloom-infra signalloom-apps; do
    run yq -e "select(.kind == \"ResourceSet\" and .metadata.name == \"$name\") | (.spec.inputs | length) > 0" \
      "$root/d2-osramp-fleet/tenants/local/signalloom.yaml"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
  done
}

@test "stack purge fails closed while a labelled Bao consumer remains" {
  run env PATH="$bin:$PATH" KUBECTL_LOG="$log" KUBECTL_STATE=consumer "$root/scripts/demo-lifecycle.sh" stack-purge
  [ "$status" -ne 0 ]
  [[ "$output" == *"Bao consumers remain"* ]]
  ! grep -Fq 'delete namespace fe-signalloom' "$log"
  ! grep -Fq 'delete namespace inf-bao' "$log"
}

@test "stack purge fails closed when the authoritative consumer query is unavailable" {
  run env PATH="$bin:$PATH" KUBECTL_LOG="$log" KUBECTL_STATE=unknown "$root/scripts/demo-lifecycle.sh" stack-purge
  [ "$status" -ne 0 ]
  [[ "$output" == *"consumer state is unavailable or unknown"* ]]
  ! grep -Fq 'delete namespace fe-signalloom' "$log"
  ! grep -Fq 'delete namespace inf-bao' "$log"
}

@test "explicit force is the only purge override" {
  run env PATH="$bin:$PATH" KUBECTL_LOG="$log" KUBECTL_STATE=consumer DEMO_BAO_FORCE=1 "$root/scripts/demo-lifecycle.sh" stack-purge
  [ "$status" -eq 0 ]
  grep -Fq 'delete namespace inf-bao' "$log"
}

@test "Bao lifecycle generates a fresh local agent token after server readiness" {
  run env PATH="$bin:$PATH" KUBECTL_LOG="$log" KUBECTL_STATE=empty "$root/scripts/demo-lifecycle.sh" bao-up
  [ "$status" -eq 0 ]
  grep -Fq 'exec deployment/spire-server -- /opt/spire/bin/spire-server token generate' "$log"
  grep -Fq 'create secret generic spire-agent-join-token --from-literal=token=local-demo-token' "$log"
  grep -Fq 'delete pod -l app.kubernetes.io/name=spire-agent --ignore-not-found' "$log"
  grep -Fq 'entry create -spiffeID spiffe://signalloom.demo/ns/fe-signalloom/sa/fe-signalloom' "$log"
  grep -Fq -- '-parentID spiffe://signalloom.demo/agent/kind -selector k8s:ns:fe-signalloom -selector k8s:sa:fe-signalloom' "$log"
	 grep -Fq 'delete job openbao-spire-bootstrap --ignore-not-found --wait=true' "$log"
	 grep -Fq 'wait job/openbao-spire-bootstrap --for=condition=complete' "$log"
	 grep -Fq 'bundle show -format spiffe' "$log"
	 grep -Fq 'exec deployment/openbao -- env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=signalloom-demo-root-token bao write auth/jwt/config jwt_validation_pubkeys=' "$log"
}

@test "Signal Loom startup recreates both proof Jobs after identity registration" {
  run env PATH="$bin:$PATH" KUBECTL_LOG="$log" KUBECTL_STATE=empty \
    "$root/scripts/demo-lifecycle.sh" signalloom-up
  [ "$status" -eq 0 ]
  grep -Fq 'delete job bao-spire-positive-proof bao-spire-negative-proof --ignore-not-found --wait=true' "$log"
}

@test "Bao lifecycle configures every active SPIRE JWT key" {
  run env PATH="$bin:$PATH" KUBECTL_LOG="$log" KUBECTL_STATE=empty KUBECTL_JWT_KEYS=two \
    "$root/scripts/demo-lifecycle.sh" bao-up
  [ "$status" -eq 0 ]
  [ "$(grep -Fo -- '-----BEGIN PUBLIC KEY-----' "$log" | wc -l)" -eq 2 ]
}
