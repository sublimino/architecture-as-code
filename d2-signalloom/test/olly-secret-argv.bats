#!/usr/bin/env bats
# d2-signalloom/test/olly-secret-argv.bats — credentials must not reach argv
#
# scripts/olly-llm-secret.sh and scripts/olly-pdi-secret.sh created their
# Secrets with `--from-literal=LLM_API_KEY="$LLM_API_KEY"` and
# `--from-literal=SERVICENOW_PASSWORD="$SERVICENOW_PASSWORD"`.
#
# Every argument of a running process is world-readable at /proc/<pid>/cmdline.
# For as long as kubectl runs, any local process — including any container that
# shares the host PID namespace — can read the credential, and typing the
# command puts it in shell history. It is a real exposure, and it predated the
# secret-hygiene constraint that prompted fixing it.
#
# These scripts had no test coverage at all. The exposure is exactly the kind
# that never announces itself: the Secret is created correctly, the demo works,
# and nothing anywhere indicates the key was briefly public.
#
# The scripts call `kubectl` directly rather than through a $KUBECTL seam. Rather
# than add an injection point purely for testability — a refactor of code this
# change is meant to touch surgically — the double goes first on PATH.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$BIN"
  cp "${BATS_TEST_DIRNAME}/fixtures/kubectl-argv-recorder.sh" "${BIN}/kubectl"
  chmod +x "${BIN}/kubectl"
  export PATH="${BIN}:${PATH}"
  export KUBECTL_ARGV_LOG="${BATS_TEST_TMPDIR}/kubectl.argv"

  # Staging files land here, so "nothing left on disk" has something to inspect.
  export TMPDIR="$BATS_TEST_TMPDIR"

  # Unmistakable in any output, and not shaped like a real key — the tracked-tree
  # secret guard must not fire on this file.
  LLM_CANARY="llm.canary.NOT-A-REAL-KEY.000000000000"
  PDI_CANARY="pdi.canary.NOT-A-REAL-PASSWORD.00000000"

  ENVF="${BATS_TEST_TMPDIR}/fixture.env"
  cat >"$ENVF" <<EOF
LLM_PROVIDER=anthropic
LLM_MODEL=claude-3-5-haiku-latest
LLM_API_KEY=${LLM_CANARY}
LLM_URL=
SERVICENOW_URL=https://dev000000.service-now.com
SERVICENOW_USER=admin
SERVICENOW_PASSWORD=${PDI_CANARY}
EOF
  export SIGNALLOOM_ENV_FILE="$ENVF"
}

# ─── olly-llm-secret ──────────────────────────────────────────────────────────

@test "olly-secret-argv: the LLM API key never reaches a command line" {
  run "${REPO_ROOT}/scripts/olly-llm-secret.sh"
  [ -f "$KUBECTL_ARGV_LOG" ]
  leaked="$(grep -F "$LLM_CANARY" "$KUBECTL_ARGV_LOG" || true)"
  [ -z "$leaked" ] || {
    echo "the key appeared in argv, readable at /proc/<pid>/cmdline:"
    echo "$leaked"
    return 1
  }
}

@test "olly-secret-argv: the key is still delivered, by file — the argv test is not vacuous" {
  # Without this, the assertion above would pass just as happily if the script
  # had stopped transmitting the key at all, or never ran.
  run "${REPO_ROOT}/scripts/olly-llm-secret.sh"
  delivered="$(grep -F -- '--from-file=LLM_API_KEY=' "$KUBECTL_ARGV_LOG" || true)"
  [ -n "$delivered" ] || {
    echo "no --from-file=LLM_API_KEY= in argv; the secret is not being delivered"
    cat "$KUBECTL_ARGV_LOG"
    return 1
  }
}

@test "olly-secret-argv: no --from-literal carries the key" {
  # Named explicitly, because the regression is a one-word edit back.
  run "${REPO_ROOT}/scripts/olly-llm-secret.sh"
  literal="$(grep -F -- '--from-literal=LLM_API_KEY' "$KUBECTL_ARGV_LOG" || true)"
  [ -z "$literal" ]
}

@test "olly-secret-argv: non-secret LLM configuration may stay literal" {
  # Documents the intended scope. Provider/model/URL are configuration, not
  # credentials; moving them to files would be churn without benefit, and a
  # future reader should be able to tell that was a decision rather than a miss.
  run "${REPO_ROOT}/scripts/olly-llm-secret.sh"
  provider="$(grep -F -- '--from-literal=LLM_PROVIDER=' "$KUBECTL_ARGV_LOG" || true)"
  [ -n "$provider" ]
}

@test "olly-secret-argv: the staged LLM key does not outlive the run" {
  run "${REPO_ROOT}/scripts/olly-llm-secret.sh"
  residue="$(grep -rlF "$LLM_CANARY" "$BATS_TEST_TMPDIR" 2>/dev/null \
               | grep -v 'fixture.env' || true)"
  [ -z "$residue" ] || {
    echo "plaintext key left on disk after exit: $residue"
    return 1
  }
}

# ─── olly-pdi-secret ──────────────────────────────────────────────────────────

@test "olly-secret-argv: the ServiceNow password never reaches a command line" {
  run "${REPO_ROOT}/scripts/olly-pdi-secret.sh"
  leaked="$(grep -F "$PDI_CANARY" "$KUBECTL_ARGV_LOG" || true)"
  [ -z "$leaked" ] || {
    echo "the password appeared in argv:"
    echo "$leaked"
    return 1
  }
}

@test "olly-secret-argv: the password is still delivered, by file" {
  run "${REPO_ROOT}/scripts/olly-pdi-secret.sh"
  delivered="$(grep -F -- '--from-file=SERVICENOW_PASSWORD=' "$KUBECTL_ARGV_LOG" || true)"
  [ -n "$delivered" ]
}

@test "olly-secret-argv: the ServiceNow username may stay literal, the password may not" {
  run "${REPO_ROOT}/scripts/olly-pdi-secret.sh"
  user="$(grep -F -- '--from-literal=SERVICENOW_USER=' "$KUBECTL_ARGV_LOG" || true)"
  pw="$(grep -F -- '--from-literal=SERVICENOW_PASSWORD' "$KUBECTL_ARGV_LOG" || true)"
  [ -n "$user" ]
  [ -z "$pw" ]
}

@test "olly-secret-argv: the staged password does not outlive the run" {
  run "${REPO_ROOT}/scripts/olly-pdi-secret.sh"
  residue="$(grep -rlF "$PDI_CANARY" "$BATS_TEST_TMPDIR" 2>/dev/null \
               | grep -v 'fixture.env' || true)"
  [ -z "$residue" ]
}

# ─── The double itself ────────────────────────────────────────────────────────

@test "olly-secret-argv: the recorder actually records, so absence means absence" {
  # If the double silently failed to log, every "not in argv" assertion above
  # would pass against an empty file. This is the arming check for all of them.
  kubectl get ns olly-replica >/dev/null 2>&1
  logged="$(grep -F 'get ns olly-replica' "$KUBECTL_ARGV_LOG" || true)"
  [ -n "$logged" ]
}

@test "olly-secret-argv: the recorder would catch a literal, so the guard can fire" {
  # Proves the grep pattern and the log format agree, by putting the canary on a
  # command line deliberately. Without this, a broken assertion and a clean run
  # are the same result.
  kubectl create secret generic probe --from-literal=X="$LLM_CANARY" >/dev/null 2>&1
  caught="$(grep -F "$LLM_CANARY" "$KUBECTL_ARGV_LOG" || true)"
  [ -n "$caught" ]
}
