#!/usr/bin/env bats

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  bin="$BATS_TEST_TMPDIR/bin"
  log="$BATS_TEST_TMPDIR/kubectl.log"
  inputs_file="$BATS_TEST_TMPDIR/saved-inputs.json"
  mkdir -p "$bin"

  cat >"$bin/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_LOG"
if [[ "$*" == "get resourceset apps -n flux-system -o jsonpath={.spec.inputs}" ]]; then
  printf '%s' "$CURRENT_INPUTS"
fi
exit 0
SCRIPT
  chmod +x "$bin/kubectl"
}

run_up() {
  run env PATH="$bin:$PATH" KUBECTL_LOG="$log" \
    CURRENT_INPUTS="$1" OSRAMP_INPUTS_FILE="$inputs_file" \
    "$root/scripts/osramp-up.sh"
}

@test "existing namespaces do not bypass disabled ResourceSet activation" {
  run_up '[]'

  [ "$status" -eq 0 ]
  grep -Fq 'annotate resourceset apps -n flux-system fluxcd.controlplane.io/reconcile-' "$log"
  grep -Fq 'patch resourceset apps -n flux-system --type merge' "$log"
  grep -Fq 'annotate resourceset apps -n flux-system reconcile.fluxcd.io/requestedAt=' "$log"
  grep -Fq -- '-n flux-system wait resourceset/apps --for=condition=ready' "$log"
  grep -Fq -- '-n frontend wait kustomization/apps --for=condition=ready' "$log"
  grep -Fq -- '-n backend wait kustomization/apps --for=condition=ready' "$log"
}

@test "healthy repeat activation preserves current ResourceSet inputs" {
  local current='[{"tenant":"custom","environment":"local","tag":"candidate","artifactSubjectWorkflow":"local","artifactSubjectGitRef":"local"}]'
  run_up "$current"

  [ "$status" -eq 0 ]
  grep -Fq 'annotate resourceset apps -n flux-system fluxcd.controlplane.io/reconcile-' "$log"
  run grep -Fq 'patch resourceset apps' "$log"
  [ "$status" -ne 0 ]
  run grep -Eq 'delete|down|replace|finalize' "$log"
  [ "$status" -ne 0 ]
  grep -Fq -- '-n frontend wait kustomization/apps --for=condition=ready' "$log"
  grep -Fq -- '-n backend wait kustomization/apps --for=condition=ready' "$log"
}

@test "absent inputs restore a valid saved configuration" {
  local saved='[{"tenant":"restored","environment":"local","tag":"saved","artifactSubjectWorkflow":"local","artifactSubjectGitRef":"local"}]'
  printf '%s' "$saved" >"$inputs_file"

  run_up '[]'

  [ "$status" -eq 0 ]
  grep -Fq -- "--type merge -p {\"spec\":{\"inputs\":$saved}}" "$log"
}

@test "invalid saved inputs fail before patching or evaluation" {
  local marker="$BATS_TEST_TMPDIR/evaluated"
  printf '%s' "\$(touch '$marker')" >"$inputs_file"

  run_up '[]'

  [ "$status" -ne 0 ]
  [[ "$output" == *"valid non-empty JSON input array"* ]]
  run grep -Fq 'patch resourceset apps' "$log"
  [ "$status" -ne 0 ]
  [ ! -e "$marker" ]
}
