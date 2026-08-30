#!/usr/bin/env bats
# d2-signalloom/test/kagent-credentials.bats — Real model credential via OpenBao
#
# Guards the path that replaces the hardcoded `mock-anthropic-key-for-local-demo`
# Secret with a real Anthropic key, sourced from the operator's environment,
# stored in OpenBao under a SPIFFE-scoped path, and materialised into the one
# Kubernetes Secret the kagent chart is contractually required to read.
#
# The failure mode this file exists to prevent is NOT "the key is wrong". It is
# "the key is fake and nothing said so". A demo whose whole claim is OpenBao
# credential mediation, quietly running on a 33-byte literal, is worse than one
# that refuses to start.
#
# Tier 1 throughout: every test here runs with no cluster, no OpenBao, and no
# real credential. The kubectl boundary is injected via $KUBECTL so the stub can
# record exactly what the script would have executed. Tier 2 (live OpenBao) is
# scripts/kagent-credentials.sh verify, run against the cluster.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/kagent-credentials.sh"

  # A key-shaped value that is unmistakable in any output we grep. Not a real
  # credential and never was.
  FAKE_KEY="sk-ant-api03-BATSCANARY0000000000000000000000000000000000000000"

  STUB_DIR="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_DIR"
  ARGV_LOG="${BATS_TEST_TMPDIR}/kubectl.argv"
  STDIN_LOG="${BATS_TEST_TMPDIR}/kubectl.stdin"

  # Records argv and stdin, then answers the handful of reads the script makes.
  # Deliberately dumb: its job is to be a witness, not a simulator.
  cat >"${STUB_DIR}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_ARGV_LOG"
case " $* " in
  *" -i "*|*" --stdin "*) cat >>"$KUBECTL_STDIN_LOG" ;;
esac
case " $* " in
  *"get pod"*)     echo "pod/openbao-stub-000" ;;
  *"-field=value"*) printf '%s' "${KUBECTL_STUB_BAO_VALUE:-}" ;;
  *)               : ;;
esac
exit "${KUBECTL_STUB_RC:-0}"
STUB
  chmod +x "${STUB_DIR}/kubectl"

  export KUBECTL="${STUB_DIR}/kubectl"
  export KUBECTL_ARGV_LOG="$ARGV_LOG"
  export KUBECTL_STDIN_LOG="$STDIN_LOG"

  # Redirects the script's staging file into the test's own tmpdir, so the
  # "no plaintext left on disk" assertion has something real to look at. Without
  # this it would search a directory the script never writes to and pass for the
  # wrong reason.
  export TMPDIR="$BATS_TEST_TMPDIR"
}

# ─── The loud-failure contract ────────────────────────────────────────────────
#
# Andy's instruction was explicit: unset means stop, with the variable named.
# The alternative — falling back to a mock — is the exact defect being removed,
# and it is invisible until an agent silently fails a model call in a demo.

@test "kagent-credentials: script exists and is executable" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
}

@test "kagent-credentials: seed with ANTHROPIC_API_KEY unset fails and names the variable" {
  unset ANTHROPIC_API_KEY
  run "$SCRIPT" seed
  [ "$status" -ne 0 ]
  [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
}

@test "kagent-credentials: seed with ANTHROPIC_API_KEY empty fails, it is not treated as set" {
  export ANTHROPIC_API_KEY=""
  run "$SCRIPT" seed
  [ "$status" -ne 0 ]
  [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
}

@test "kagent-credentials: seed with a whitespace-only key fails rather than writing it" {
  export ANTHROPIC_API_KEY="   "
  run "$SCRIPT" seed
  [ "$status" -ne 0 ]
  # Nothing may have been written. An empty credential in OpenBao is worse than
  # no credential: it satisfies every presence check downstream.
  writes=""
  if [ -f "$KUBECTL_ARGV_LOG" ]; then
    writes="$(grep -c 'kv put' "$KUBECTL_ARGV_LOG" 2>/dev/null || true)"
  fi
  [ "${writes:-0}" = "0" ] || [ -z "$writes" ]
}

@test "kagent-credentials: seed refuses the retired mock literal even if exported" {
  export ANTHROPIC_API_KEY="mock-anthropic-key-for-local-demo"
  run "$SCRIPT" seed
  [ "$status" -ne 0 ]
  [[ "$output" == *"mock"* ]] || [[ "$output" == *"placeholder"* ]]
}

@test "kagent-credentials: seed refuses an implausibly short key rather than writing a partial one" {
  export ANTHROPIC_API_KEY="sk-ant-x"
  run "$SCRIPT" seed
  [ "$status" -ne 0 ]
}

# ─── The leak contract ────────────────────────────────────────────────────────
#
# Three independent channels, because they fail independently: argv (world
# readable in /proc and in shell history), xtrace (the standard way a debugging
# session leaks a credential into a terminal scrollback and then a bug report),
# and the repo itself.

@test "kagent-credentials: the key never reaches argv of any executed command" {
  export ANTHROPIC_API_KEY="$FAKE_KEY"
  run "$SCRIPT" seed
  [ -f "$KUBECTL_ARGV_LOG" ]
  leaked="$(grep -F "$FAKE_KEY" "$KUBECTL_ARGV_LOG" || true)"
  [ -z "$leaked" ]
}

@test "kagent-credentials: the key does reach the child on stdin, so the argv test is not vacuous" {
  # Without this, the argv assertion above would pass just as happily if the
  # script never transmitted the key at all. It asserts the transport exists.
  export ANTHROPIC_API_KEY="$FAKE_KEY"
  run "$SCRIPT" seed
  [ -f "$KUBECTL_STDIN_LOG" ]
  carried="$(grep -F "$FAKE_KEY" "$KUBECTL_STDIN_LOG" || true)"
  [ -n "$carried" ]
}

@test "kagent-credentials: the key never appears in xtrace output" {
  export ANTHROPIC_API_KEY="$FAKE_KEY"
  run bash -x "$SCRIPT" seed
  leaked="$(printf '%s' "$output" | grep -F "$FAKE_KEY" || true)"
  [ -z "$leaked" ]
}

@test "kagent-credentials: the retired mock placeholder survives nowhere as a value" {
  # The mock Secret is not merely superseded, it is deleted. Leaving it in a
  # manifest means the next `kubectl apply -k` silently overwrites a real key
  # with a fake one and every presence check still passes.
  #
  # Scoped to non-comment lines. Prose naming the retired value — the comment in
  # controller.yaml explaining why the Secret is absent, the header of this file
  # — cannot be applied to a cluster and is worth keeping. A YAML `key: "value"`
  # or a shell assignment can be, and is what this catches. Comment lines are
  # identified the same way in YAML and shell: # after optional whitespace.
  #
  # This file excludes itself: it necessarily contains the string it hunts.
  hits="$(grep -rIF 'mock-anthropic-key-for-local-demo' \
            --exclude-dir=.git \
            --exclude="$(basename "$BATS_TEST_FILENAME")" \
            "$REPO_ROOT" \
          | grep -vE '^[^:]+:[[:space:]]*#' || true)"
  [ -z "$hits" ]
}

@test "kagent-credentials: that guard is armed — it fires on a planted value" {
  # A grep-based negative assertion passes identically whether the tree is clean
  # or the pattern is wrong. This plants the literal on a non-comment line in a
  # scratch tree and requires the same expression to catch it, so a green result
  # above means "absent", not "unsearchable".
  planted="${BATS_TEST_TMPDIR}/planted"
  mkdir -p "$planted"
  printf 'stringData:\n  api-key: "mock-anthropic-key-for-local-demo"\n' >"${planted}/decoy.yaml"
  printf '# api-key: "mock-anthropic-key-for-local-demo"\n' >"${planted}/prose.yaml"

  hits="$(grep -rIF 'mock-anthropic-key-for-local-demo' "$planted" \
          | grep -vE '^[^:]+:[[:space:]]*#' || true)"
  [ -n "$hits" ]
  [[ "$hits" == *"decoy.yaml"* ]]
  # ...and does not fire on the commented one, or the exemption is a hole big
  # enough to hide a real credential in.
  [[ "$hits" != *"prose.yaml"* ]]
}

# ─── The ModelConfig contract ─────────────────────────────────────────────────
#
# Verified against the upstream v0.9.9 CRD, not against the stub CRDs currently
# installed in the kind cluster. Those stubs use x-kubernetes-preserve-unknown-
# fields, so they validate nothing and have been accepting a misplaced field
# without complaint.

@test "kagent-credentials: ModelConfig sets apiKeySecret at spec top level, per v1alpha2" {
  mc="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/kagent-k8s-reader/modelconfig.yaml"
  [ -f "$mc" ]
  name="$(yq -r '.spec.apiKeySecret' "$mc")"
  [ "$name" = "kagent-anthropic-key" ]
}

@test "kagent-credentials: ModelConfig does not nest apiKeySecret under spec.anthropic" {
  # spec.anthropic in v1alpha2 accepts only baseUrl/maxTokens/temperature/topK/
  # topP. A nested apiKeySecret is pruned by the structural schema: the field is
  # accepted, dropped, and the agent then fails its model call for a reason that
  # points nowhere near this file.
  mc="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/kagent-k8s-reader/modelconfig.yaml"
  nested="$(yq -r '.spec.anthropic.apiKeySecret // ""' "$mc")"
  [ -z "$nested" ] || [ "$nested" = "null" ]
}

@test "kagent-credentials: ModelConfig declares apiKeySecretKey explicitly" {
  # The chart default is ANTHROPIC_API_KEY. Relying on the default couples this
  # manifest to a values.yaml it does not own.
  mc="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/kagent-k8s-reader/modelconfig.yaml"
  key="$(yq -r '.spec.apiKeySecretKey' "$mc")"
  [ "$key" = "ANTHROPIC_API_KEY" ]
}

# ─── The SPIFFE-scoped path contract ──────────────────────────────────────────

@test "kagent-credentials: the OpenBao path is scoped by the agent's own SPIFFE path" {
  export ANTHROPIC_API_KEY="$FAKE_KEY"
  run "$SCRIPT" seed
  [ -f "$KUBECTL_ARGV_LOG" ]
  # ns/<namespace>/sa/<serviceaccount> is the SPIFFE ID's path component. A flat
  # path would let any agent's token read any other agent's credential.
  scoped="$(grep -F 'secret/agents/ns/fe-signalloom-agents/sa/kagent-k8s-reader/anthropic/api-key' \
              "$KUBECTL_ARGV_LOG" || true)"
  [ -n "$scoped" ]
}

@test "kagent-credentials: seed writes a JWT role bound to the agent's exact SPIFFE ID" {
  export ANTHROPIC_API_KEY="$FAKE_KEY"
  run "$SCRIPT" seed
  bound="$(grep -F 'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kagent-k8s-reader' \
             "$KUBECTL_ARGV_LOG" || true)"
  [ -n "$bound" ]
}

@test "kagent-credentials: every kagent agent declaring anthropic/api-key gets seeded" {
  export ANTHROPIC_API_KEY="$FAKE_KEY"
  run "$SCRIPT" seed
  [ "$status" -eq 0 ]
  for agent in kagent-k8s-reader kagent-commit-summariser kagent-security-analyst \
               kagent-network-auditor kagent-incident-responder \
               kagent-compliance-checker kagent-finops-optimizer kagent-chaos-prober; do
    hit="$(grep -F "sa/${agent}/anthropic/api-key" "$KUBECTL_ARGV_LOG" || true)"
    [ -n "$hit" ] || {
      echo "agent $agent was never seeded — it will fail its model call at run time"
      return 1
    }
  done
}

# ─── The Secret materialisation contract ──────────────────────────────────────

@test "kagent-credentials: sync targets both namespaces the ModelConfigs live in" {
  # apiKeySecret resolves in the ModelConfig's OWN namespace (upstream CRD:
  # "Must be a reference to the name of a secret in the same namespace as the
  # referencing ModelConfig"). The swarm's ModelConfigs are in
  # fe-signalloom-agents; the chart's defaults are in kagent. One Secret in one
  # namespace satisfies exactly one of them.
  export KUBECTL_STUB_BAO_VALUE="$FAKE_KEY"
  run "$SCRIPT" sync
  [ "$status" -eq 0 ]
  for ns in kagent fe-signalloom-agents; do
    hit="$(grep -E "create secret .*(-n|--namespace) ${ns}( |$)" "$KUBECTL_ARGV_LOG" || true)"
    [ -n "$hit" ] || {
      echo "no Secret created in namespace ${ns}"
      return 1
    }
  done
}

@test "kagent-credentials: sync does not put the key in argv" {
  export KUBECTL_STUB_BAO_VALUE="$FAKE_KEY"
  run "$SCRIPT" sync
  leaked="$(grep -F "$FAKE_KEY" "$KUBECTL_ARGV_LOG" || true)"
  [ -z "$leaked" ]
}

@test "kagent-credentials: sync refuses to create a Secret when OpenBao returns nothing" {
  # The dangerous case. An empty read that still creates a Secret produces a
  # zero-length credential that every `kubectl get secret` presence check
  # reports as healthy.
  export KUBECTL_STUB_BAO_VALUE=""
  run "$SCRIPT" sync
  [ "$status" -ne 0 ]
  created="$(grep -c 'create secret' "$KUBECTL_ARGV_LOG" 2>/dev/null || true)"
  [ "${created:-0}" = "0" ]
}

@test "kagent-credentials: sync keeps the Secret name and key the chart consumes" {
  export KUBECTL_STUB_BAO_VALUE="$FAKE_KEY"
  run "$SCRIPT" sync
  named="$(grep -F 'create secret generic kagent-anthropic-key' "$KUBECTL_ARGV_LOG" || true)"
  [ -n "$named" ]
  keyed="$(grep -F 'ANTHROPIC_API_KEY=' "$KUBECTL_ARGV_LOG" || true)"
  [ -n "$keyed" ]
}

@test "kagent-credentials: sync leaves no plaintext key on disk after it exits" {
  export KUBECTL_STUB_BAO_VALUE="$FAKE_KEY"
  run "$SCRIPT" sync
  # The staging file is how the key avoids argv; it must not outlive the run.
  residue="$(grep -rlF "$FAKE_KEY" "${BATS_TEST_TMPDIR}" 2>/dev/null \
               | grep -v 'kubectl.stdin' || true)"
  [ -z "$residue" ]
}

# ─── Evidence without disclosure ──────────────────────────────────────────────

@test "kagent-credentials: verify reports presence and length but never the value" {
  export KUBECTL_STUB_BAO_VALUE="$FAKE_KEY"
  run "$SCRIPT" verify
  leaked="$(printf '%s' "$output" | grep -F "$FAKE_KEY" || true)"
  [ -z "$leaked" ]
  [[ "$output" == *"secret/agents/ns/fe-signalloom-agents/sa/kagent-k8s-reader"* ]]
  [[ "$output" == *"${#FAKE_KEY}"* ]]
}

@test "kagent-credentials: an unknown subcommand fails rather than defaulting to seed" {
  export ANTHROPIC_API_KEY="$FAKE_KEY"
  run "$SCRIPT" wibble
  [ "$status" -ne 0 ]
  writes="$(grep -c 'kv put' "$KUBECTL_ARGV_LOG" 2>/dev/null || true)"
  [ "${writes:-0}" = "0" ]
}
