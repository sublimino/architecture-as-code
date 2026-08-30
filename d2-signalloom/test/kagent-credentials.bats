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
  FAKE_KEY="sk-ant-TEST.not-a-real-key.BATSCANARY00000000000000000000"

  STUB_DIR="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_DIR"
  ARGV_LOG="${BATS_TEST_TMPDIR}/kubectl.argv"
  STDIN_LOG="${BATS_TEST_TMPDIR}/kubectl.stdin"

  # A real fixture file, not an inline heredoc: the JSON and jsonpath responses
  # need quoting that does not survive being generated into a quoted heredoc.
  # See the fixture's header — that mangling made the stub return empty for
  # everything, and empty is indistinguishable from "absent".
  cp "${BATS_TEST_DIRNAME}/fixtures/kubectl-stub.sh" "${STUB_DIR}/kubectl"
  chmod +x "${STUB_DIR}/kubectl"

  export KUBECTL="${STUB_DIR}/kubectl"
  export KUBECTL_ARGV_LOG="$ARGV_LOG"
  export KUBECTL_STDIN_LOG="$STDIN_LOG"

  # Redirects the script's staging file into the test's own tmpdir, so the
  # "no plaintext left on disk" assertion has something real to look at. Without
  # this it would search a directory the script never writes to and pass for the
  # wrong reason.
  export TMPDIR="$BATS_TEST_TMPDIR"

  # Point the .env resolver at a path that does not exist. Without this, the
  # resolver correctly finds the MAIN checkout's .env — which now holds Andy's
  # REAL 108-character key — and every test below would run against it.
  export SIGNALLOOM_ENV_FILE="${BATS_TEST_TMPDIR}/absent.env"
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

@test "kagent-credentials: seed with ANTHROPIC_API_KEY unset no-ops loudly and writes nothing" {
  # Decided contract, matching scripts/olly-llm-secret.sh: a missing OPTIONAL
  # credential must not break `make up`. The no-op is loud — it names the file
  # and the variable — and it must write nothing at all. The loud FAILURE lives
  # in kagent-invoke.sh, where the key is genuinely required.
  unset ANTHROPIC_API_KEY
  run "$SCRIPT" seed
  [ "$status" -eq 0 ]
  [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
  [[ "$output" == *".env"* ]]
  writes="$(grep -c 'kv put' "$KUBECTL_ARGV_LOG" 2>/dev/null || true)"
  [ "${writes:-0}" = "0" ]
}

@test "kagent-credentials: seed with ANTHROPIC_API_KEY empty no-ops and writes nothing" {
  export ANTHROPIC_API_KEY=""
  run "$SCRIPT" seed
  [ "$status" -eq 0 ]
  [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
  writes="$(grep -c 'kv put' "$KUBECTL_ARGV_LOG" 2>/dev/null || true)"
  [ "${writes:-0}" = "0" ]
}

@test "kagent-credentials: seed with a whitespace-only key writes nothing" {
  export ANTHROPIC_API_KEY="   "
  run "$SCRIPT" seed
  [ "$status" -eq 0 ]
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

# The hazard is not the string, it is a file that can be APPLIED or EXECUTED
# carrying the string as a value. `kubectl apply -k` on a manifest that still
# declares the placeholder silently overwrites a real operator-supplied key with
# a fake one, and every presence check downstream still reports healthy.
#
# So the guard is scoped by what a file can do, not by an exemption list that
# grows a hole every time prose mentions the value. Markdown explaining the
# history is not a hazard; a YAML `key: value` or a shell assignment is. Within
# the scanned types, comment lines are exempt — identified identically in YAML,
# shell and Make: # after optional whitespace.
_placeholder_hits() {
  local root="$1"
  grep -rIF 'mock-anthropic-key-for-local-demo' \
    --include='*.yaml' --include='*.yml' --include='*.json' \
    --include='*.sh' --include='*.bats' --include='Makefile' \
    --exclude-dir=.git \
    --exclude="$(basename "$BATS_TEST_FILENAME")" \
    "$root" 2>/dev/null | grep -vE '^[^:]+:[[:space:]]*#' || true
}

@test "kagent-credentials: the retired placeholder survives in no applyable file" {
  # This file excludes itself: it necessarily contains the string it hunts.
  hits="$(_placeholder_hits "$REPO_ROOT")"
  [ -z "$hits" ]
}

@test "kagent-credentials: that guard is armed — it fires on a planted manifest" {
  # A grep-based negative assertion passes identically whether the tree is clean
  # or the pattern is broken, and both of the traps below have already bitten
  # this suite once: the exclusion list silently swallowed a real hit, and the
  # detector matched its own source. Planting decoys makes a green result above
  # mean "absent" rather than "unsearchable".
  planted="${BATS_TEST_TMPDIR}/planted"
  mkdir -p "$planted"
  printf 'stringData:\n  api-key: "mock-anthropic-key-for-local-demo"\n' >"${planted}/decoy.yaml"
  printf 'K="mock-anthropic-key-for-local-demo"\n'                        >"${planted}/decoy.sh"
  printf '# api-key: "mock-anthropic-key-for-local-demo"\n'               >"${planted}/commented.yaml"
  printf 'the old value was `mock-anthropic-key-for-local-demo` in prose\n' >"${planted}/notes.md"

  hits="$(_placeholder_hits "$planted")"
  [[ "$hits" == *"decoy.yaml"* ]] || { echo "guard misses a YAML value"; return 1; }
  [[ "$hits" == *"decoy.sh"* ]]   || { echo "guard misses a shell assignment"; return 1; }
  # ...and the two exemptions are exemptions, not holes wide enough to hide a
  # real credential in.
  [[ "$hits" != *"commented.yaml"* ]] || { echo "comment exemption not applied"; return 1; }
  [[ "$hits" != *"notes.md"* ]]       || { echo "prose exemption not applied"; return 1; }
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

# ─── The two-key Secret ───────────────────────────────────────────────────────
#
# Found in the live cluster by a sibling agent: kagent-anthropic-key carried BOTH
# ANTHROPIC_API_KEY (real) and api-key (the 33-byte placeholder). Reproduced
# deterministically — `kubectl apply` MERGES, so a Secret of that name created
# earlier by a different actor keeps its old key when a new object is applied
# over it. Keys afterwards: ['ANTHROPIC_API_KEY', 'api-key'].
#
# It is the worst available state: the Secret exists, is non-empty and holds a
# real credential, so every presence check passes, while any consumer naming the
# other key silently reads the placeholder. It also defeats a test that samples
# ONE entry — jq sorts keys, ANTHROPIC_API_KEY sorts first, so `to_entries[0]`
# reports healthy while the credential in use is the mock. That is exactly how
# it went unnoticed.

@test "kagent-credentials: sync replaces the Secret outright rather than merging into it" {
  # `apply` is the merge that produced the two-key state. `replace --force`
  # deletes and recreates, so the object holds exactly the keys named here.
  export KUBECTL_STUB_BAO_VALUE="$FAKE_KEY"
  run "$SCRIPT" sync
  [ "$status" -eq 0 ]
  merged="$(grep -E 'apply -f -' "$KUBECTL_ARGV_LOG" || true)"
  [ -z "$merged" ] || {
    echo "sync still uses 'apply', which merges and preserves a stale key:"
    echo "$merged"
    return 1
  }
  replaced="$(grep -F 'replace --force' "$KUBECTL_ARGV_LOG" || true)"
  [ -n "$replaced" ]
}

@test "kagent-credentials: sync creates exactly one key, the one the ModelConfig asks for" {
  export KUBECTL_STUB_BAO_VALUE="$FAKE_KEY"
  run "$SCRIPT" sync
  # One --from-file per namespace, and every one of them names SECRET_KEY.
  froms="$(grep -oE '\-\-from-file=[A-Za-z0-9_-]+=' "$KUBECTL_ARGV_LOG" | sort -u || true)"
  [ "$(printf '%s\n' "$froms" | grep -c .)" = "1" ] || {
    echo "sync writes more than one key name: $froms"
    return 1
  }
  [[ "$froms" == *"--from-file=ANTHROPIC_API_KEY="* ]]
}

@test "kagent-credentials: the ModelConfig asks for exactly the key sync provides" {
  # The two halves of the contract, compared rather than each tested against its
  # own assumption. Either half can be changed alone and stay internally
  # consistent while the pair stops working.
  mc="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/kagent-k8s-reader/modelconfig.yaml"
  requested="$(yq -r '.spec.apiKeySecretKey' "$mc")"
  provided="$(grep -oE 'SECRET_KEY="\$\{KAGENT_SECRET_KEY:-[A-Za-z0-9_-]+\}"' "$SCRIPT" \
                | sed 's/.*:-//; s/}"//')"
  [ -n "$requested" ] && [ -n "$provided" ]
  [ "$requested" = "$provided" ] || {
    echo "ModelConfig requests '${requested}' but sync provides '${provided}'"
    return 1
  }
}

@test "kagent-credentials: no Secret key name other than the contract one is written" {
  # Catches the reverse of the above: sync growing a second --from-file, which
  # is how a Secret ends up with two keys in the first place.
  writes="$(grep -oE '\-\-from-file=[^ ]+' "$SCRIPT" || true)"
  count="$(printf '%s\n' "$writes" | grep -c . || true)"
  [ "${count:-0}" = "1" ] || {
    echo "kagent-credentials.sh has ${count} --from-file sites; expected exactly 1"
    printf '%s\n' "$writes"
    return 1
  }
}

@test "kagent-credentials: verify flags ANY key holding the placeholder, not just the expected one" {
  # The live falsification of this ran against the cluster; this is the version
  # that runs in CI. b64 of the placeholder and of a plausible key.
  mock_b64="$(printf 'mock-anthropic-key%s' '-for-local-demo' | base64 -w0)"
  real_b64="$(printf '%s' "$FAKE_KEY" | base64 -w0)"
  export KUBECTL_STUB_SECRET_JSON="{\"data\":{\"ANTHROPIC_API_KEY\":\"${real_b64}\",\"api-key\":\"${mock_b64}\"}}"
  export KUBECTL_STUB_BAO_VALUE="$FAKE_KEY"
  export KAGENT_SECRET_NAMESPACES="testns"

  run "$SCRIPT" verify
  [ "$status" -ne 0 ] || {
    echo "verify passed a Secret containing the placeholder under a second key"
    return 1
  }
  [[ "$output" == *"PLACEHOLDER"* ]]
  # And it must still not print the value of either key.
  leaked="$(printf '%s' "$output" | grep -F "$FAKE_KEY" || true)"
  [ -z "$leaked" ]
}

@test "kagent-credentials: verify passes a Secret with only the contract key" {
  # The other half — without it, the test above is satisfied by a verify that
  # fails unconditionally.
  real_b64="$(printf '%s' "$FAKE_KEY" | base64 -w0)"
  export KUBECTL_STUB_SECRET_JSON="{\"data\":{\"ANTHROPIC_API_KEY\":\"${real_b64}\"}}"
  export KUBECTL_STUB_BAO_VALUE="$FAKE_KEY"
  export KAGENT_SECRET_NAMESPACES="testns"

  run "$SCRIPT" verify
  [ "$status" -eq 0 ]
  [[ "$output" != *"PLACEHOLDER"* ]]
}
