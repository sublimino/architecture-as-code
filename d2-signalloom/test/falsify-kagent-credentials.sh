#!/usr/bin/env bash
# d2-signalloom/test/falsify-kagent-credentials.sh
#
# Mutation harness. A green test suite is not evidence that it asserts anything;
# it is evidence that nothing it looks at is currently broken. This breaks each
# guarded thing in turn and requires the named test to go red.
#
# Two hazards this is built to avoid, both learned the hard way:
#
#   1. A killed harness leaves the repo mutated. EXIT traps do not survive
#      SIGKILL, so restoration cannot rely on the trap alone. Every mutation is
#      restored from a byte-for-byte backup keyed by FULL PATH (basename keys
#      collide across the three main.tf-shaped files in any real tree), the
#      restore is verified by sha256, and the harness refuses to start on a
#      dirty tree so `git checkout -- .` is always available as a last resort.
#
#   2. `set -e` plus a trap rewrites the verdict. errexit is deliberately NOT
#      enabled around the mutate/run/restore cycle: a failing test IS the
#      expected outcome and must not abort the run.
#
# Usage: d2-signalloom/test/falsify-kagent-credentials.sh [test-name-filter]

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/falsify.XXXXXX")"
declare -a MUTATED=()

PASS=0; FAIL=0
declare -a RESULTS=()

restore_all() {
  local f rel
  for rel in "${MUTATED[@]:-}"; do
    [ -n "$rel" ] || continue
    f="${BACKUP_DIR}/${rel}"
    [ -f "$f" ] && cp -p "$f" "${REPO_ROOT}/${rel}"
  done
  MUTATED=()
}
trap 'restore_all; rm -rf "$BACKUP_DIR"' EXIT INT TERM

# Refuse to run against uncommitted work: a mutation harness that crashes on a
# dirty tree destroys work that has no other copy.
if [ -n "$(git status --porcelain)" ]; then
  echo "REFUSING: working tree is dirty. Commit first — this harness edits files in place." >&2
  git status --porcelain >&2
  exit 2
fi

backup() {
  local rel="$1"
  mkdir -p "$(dirname "${BACKUP_DIR}/${rel}")"
  cp -p "${REPO_ROOT}/${rel}" "${BACKUP_DIR}/${rel}"
  MUTATED+=("$rel")
}

# Asserts the edit actually landed. A sed whose pattern does not match is a
# silent no-op, and the test then "fails to fail" for a reason that has nothing
# to do with the test.
mutate_sed() {
  local rel="$1" expr="$2" before after
  before="$(sha256sum "${REPO_ROOT}/${rel}" | cut -d' ' -f1)"
  sed -i "$expr" "${REPO_ROOT}/${rel}"
  after="$(sha256sum "${REPO_ROOT}/${rel}" | cut -d' ' -f1)"
  [ "$before" != "$after" ] || { echo "    MUTATION NO-OP: '$expr' did not match in $rel"; return 1; }
  return 0
}

run_case() {
  local label="$1" suite="$2" test_name="$3"; shift 3
  local out rc restored_ok="yes" rel matched

  printf '\n── %s\n' "$label"

  # A `bats -f` filter that matches no test runs zero tests and exits 0, which
  # this harness would otherwise report as "the test stayed green — it guards
  # nothing". That is a false accusation against a working test, and it happened
  # on the first run: one filter said "placeholder" where the test said
  # "literal". The filter is now a checked precondition, not an assumption.
  matched="$(bats "$suite" -f "$test_name" --count 2>/dev/null || echo 0)"
  if [ "${matched:-0}" -ne 1 ]; then
    printf '   FILTER MATCHED %s TESTS (expected exactly 1) — result would be meaningless\n' "${matched:-0}"
    RESULTS+=("INCONCLUSIVE  ${label}  (filter matched ${matched:-0} tests, not 1)")
    FAIL=$((FAIL + 1)); restore_all; return
  fi

  # The mutation is applied by the caller-supplied function.
  if ! "$@"; then
    RESULTS+=("INCONCLUSIVE  ${label}  (mutation did not apply)")
    FAIL=$((FAIL + 1)); restore_all; return
  fi

  out="$(bats "$suite" -f "$test_name" 2>&1)"; rc=$?

  # Restore, then prove the restore was byte-identical.
  for rel in "${MUTATED[@]:-}"; do
    [ -n "$rel" ] || continue
    local pre post
    pre="$(sha256sum "${BACKUP_DIR}/${rel}" | cut -d' ' -f1)"
    cp -p "${BACKUP_DIR}/${rel}" "${REPO_ROOT}/${rel}"
    post="$(sha256sum "${REPO_ROOT}/${rel}" | cut -d' ' -f1)"
    [ "$pre" = "$post" ] || restored_ok="NO (${rel})"
  done
  MUTATED=()

  if [ "$rc" -ne 0 ]; then
    printf '   test went RED as required   (restore byte-identical: %s)\n' "$restored_ok"
    RESULTS+=("KILLED        ${label}")
    PASS=$((PASS + 1))
  else
    printf '   TEST STAYED GREEN — it does not guard this   (restore: %s)\n' "$restored_ok"
    printf '%s\n' "$out" | tail -5
    RESULTS+=("SURVIVED      ${label}   <-- test asserts nothing here")
    FAIL=$((FAIL + 1))
  fi
}

CRED_SUITE="d2-signalloom/test/kagent-credentials.bats"
INV_SUITE="d2-signalloom/test/kagent-invoke.bats"
HTTP_SUITE="d2-signalloom/test/kagent-invoke-http.bats"
SCRIPT_REL="scripts/kagent-credentials.sh"
INV_REL="scripts/kagent-invoke.sh"
MC_REL="d2-signalloom/infra/agent-swarm/kagent-k8s-reader/modelconfig.yaml"
CTRL_REL="d2-signalloom/infra/kagent/base/controller.yaml"
ENVLIB_REL="scripts/lib/env-file.sh"
ENV_SUITE="d2-signalloom/test/env-file.bats"
SEC_SUITE="d2-signalloom/test/no-tracked-secrets.bats"

# ── 1. The loud-failure contract ─────────────────────────────────────────────
# Deleting any ONE refusal branch does not make seed accept a bad key: the
# branches back each other up (an unset key is also an empty key, an empty key is
# also a short key). That layering is worth having, but it means a single-branch
# mutation proves nothing about the test.
#
# Two earlier attempts at this mutation were themselves wrong, and both reported
# a working test as asserting nothing:
#   - flipping `if [ -z "${ANTHROPIC_API_KEY+set}" ]` to false: the empty and
#     length guards still caught it.
#   - substituting a default into `local key=...`: the `+set` branch tests
#     whether the variable is set AT ALL, so it fired regardless of the value.
#
# The mutation that models the real defect is to remove the validation wholesale
# and substitute a default — which is precisely the behaviour this task exists to
# delete. Injected as an early return, so the entire body below it is dead.
m_silent_fallback() {
  backup "$SCRIPT_REL"
  mutate_sed "$SCRIPT_REL" \
    's|^require_key() {|require_key() { VALIDATED_KEY="${ANTHROPIC_API_KEY:-sk-ant-TEST.silent-fallback-mutant-000000}"; return 0 # MUTANT|'
}
run_case "seed silently falls back to a default when the key is unset" \
  "$CRED_SUITE" "seed with ANTHROPIC_API_KEY unset no-ops loudly and writes nothing" m_silent_fallback

run_case "seed silently falls back to a default when the key is empty" \
  "$CRED_SUITE" "seed with ANTHROPIC_API_KEY empty no-ops and writes nothing" m_silent_fallback

run_case "seed silently falls back rather than refusing whitespace" \
  "$CRED_SUITE" "seed with a whitespace-only key writes nothing" m_silent_fallback

# The placeholder is 33 characters, so the length guard does NOT catch it — this
# branch is genuinely load-bearing on its own, and the test name here is the one
# the suite actually uses. (The first run of this harness said "placeholder"
# where the suite says "literal", matched zero tests, and reported a working
# test as asserting nothing. Hence the filter precondition above.)
m_mock() {
  backup "$SCRIPT_REL"
  mutate_sed "$SCRIPT_REL" 's|if \[ "$key" = "$RETIRED_MOCK" \]; then|if false; then|'
}
run_case "seed no longer refuses the retired placeholder" \
  "$CRED_SUITE" "seed refuses the retired mock literal even if exported" m_mock

m_short() {
  backup "$SCRIPT_REL"
  mutate_sed "$SCRIPT_REL" 's|if \[ "$len" -lt "$MIN_KEY_LEN" \]; then|if false; then|'
}
run_case "seed no longer refuses a truncated key" \
  "$CRED_SUITE" "seed refuses an implausibly short key rather than writing a partial one" m_short

# ── 2. The leak contract ─────────────────────────────────────────────────────
m_argv_leak() {
  backup "$SCRIPT_REL"
  # The single most likely real-world regression: someone "simplifies" the
  # stdin plumbing into a command-line argument.
  mutate_sed "$SCRIPT_REL" \
    's|printf '"'"'%s'"'"' "$VALIDATED_KEY" . "$KUBECTL" exec -i -n "$BAO_NS" "$pod" -- sh -ec "$remote"|"$KUBECTL" exec -i -n "$BAO_NS" "$pod" -- sh -ec "$remote --leak=$VALIDATED_KEY" </dev/null|'
}
run_case "the key is passed in argv instead of on stdin" \
  "$CRED_SUITE" "the key never reaches argv of any executed command" m_argv_leak

m_xtrace_leak() {
  backup "$SCRIPT_REL"
  # Disarm the xtrace shield.
  mutate_sed "$SCRIPT_REL" 's|^    \*x\*) _XTRACE_HELD=1; set +x ;;|    *x*) _XTRACE_HELD=1; : ;;|'
}
run_case "the xtrace shield is disarmed" \
  "$CRED_SUITE" "the key never appears in xtrace output" m_xtrace_leak

m_mock_returns() {
  backup "$CTRL_REL"
  # Someone restores the placeholder Secret.
  #
  # The literal is assembled at runtime rather than written out here. Spelling it
  # in a heredoc would put it on a non-comment line of a tracked file, which is
  # exactly what the guard hunts — so this harness would trip the very test it is
  # trying to falsify, permanently, and the failure would look like a real
  # regression in the tree. Caught on the second run of this harness.
  local placeholder="mock-anthropic-key""-for-local-demo"
  cat >>"${REPO_ROOT}/${CTRL_REL}" <<YAML
---
apiVersion: v1
kind: Secret
metadata:
  name: kagent-anthropic-key
  namespace: kagent
type: Opaque
stringData:
  api-key: "${placeholder}"
YAML
  MUTATED+=("$CTRL_REL"); return 0
}
run_case "the placeholder Secret is restored to a manifest" \
  "$CRED_SUITE" "the retired placeholder survives in no applyable file" m_mock_returns

# ── 3. The ModelConfig contract ──────────────────────────────────────────────
m_nested() {
  backup "$MC_REL"
  mutate_sed "$MC_REL" 's|^  apiKeySecret: kagent-anthropic-key|  anthropic2:\n    apiKeySecret: kagent-anthropic-key|'
}
run_case "apiKeySecret is removed from spec top level" \
  "$CRED_SUITE" "ModelConfig sets apiKeySecret at spec top level, per v1alpha2" m_nested

m_keyname() {
  backup "$MC_REL"
  mutate_sed "$MC_REL" 's|^  apiKeySecretKey: ANTHROPIC_API_KEY|  apiKeySecretKey: api-key|'
}
run_case "apiKeySecretKey reverts to the old api-key name" \
  "$CRED_SUITE" "ModelConfig declares apiKeySecretKey explicitly" m_keyname

# ── 4. SPIFFE scoping ────────────────────────────────────────────────────────
m_flat_path() {
  backup "$SCRIPT_REL"
  # A flat path: every agent shares one location, so any SVID reads any key.
  mutate_sed "$SCRIPT_REL" \
    's|printf '"'"'ns/%s/sa/%s'"'"' "$AGENTS_NS" "$sa"|printf '"'"'shared'"'"'|'
}
run_case "the OpenBao path stops being SPIFFE-scoped" \
  "$CRED_SUITE" "the OpenBao path is scoped by the agent's own SPIFFE path" m_flat_path

m_unbound_role() {
  backup "$SCRIPT_REL"
  mutate_sed "$SCRIPT_REL" 's|  bound_subject=spiffe://\${td}/\${sp} \\\\|  bound_subject="" \\\\|'
}
run_case "the JWT role stops binding to the agent's SPIFFE ID" \
  "$CRED_SUITE" "seed writes a JWT role bound to the agent's exact SPIFFE ID" m_unbound_role

# ── 5. Secret materialisation ────────────────────────────────────────────────
m_one_ns() {
  backup "$SCRIPT_REL"
  mutate_sed "$SCRIPT_REL" 's|SECRET_NAMESPACES="${KAGENT_SECRET_NAMESPACES:-kagent fe-signalloom-agents}"|SECRET_NAMESPACES="${KAGENT_SECRET_NAMESPACES:-kagent}"|'
}
run_case "sync writes the Secret to only one namespace" \
  "$CRED_SUITE" "sync targets both namespaces the ModelConfigs live in" m_one_ns

m_empty_secret() {
  backup "$SCRIPT_REL"
  mutate_sed "$SCRIPT_REL" 's|if \[ "${len:-0}" -lt "$MIN_KEY_LEN" \]; then|if false; then|'
}
run_case "sync creates a Secret from an empty OpenBao read" \
  "$CRED_SUITE" "sync refuses to create a Secret when OpenBao returns nothing" m_empty_secret

m_leftover() {
  backup "$SCRIPT_REL"
  mutate_sed "$SCRIPT_REL" 's|^  rm -f "$staged"$|  : # leaked|'
}
run_case "sync leaves the staged plaintext key on disk" \
  "$CRED_SUITE" "sync leaves no plaintext key on disk after it exits" m_leftover

m_verify_prints() {
  backup "$SCRIPT_REL"
  mutate_sed "$SCRIPT_REL" 's|      printf '"'"'  %-8s %-7s %-14s %s\\n'"'"' "yes" "$len" "$digest" "$path"|      printf '"'"'  %-8s %-7s %-14s %s %s\\n'"'"' "yes" "$len" "$digest" "$path" "$out"|'
}
run_case "verify prints the credential value" \
  "$CRED_SUITE" "verify reports presence and length but never the value" m_verify_prints

# ── 6. Invocation ────────────────────────────────────────────────────────────
m_url() {
  backup "$INV_REL"
  mutate_sed "$INV_REL" 's|AGENT_URL="${BASE}/api/a2a/${AGENTS_NS}/${AGENT}/"|AGENT_URL="${BASE}/api/invoke/${AGENT}"|'
}
run_case "the A2A endpoint URL stops matching upstream" \
  "$INV_SUITE" "posts to the upstream A2A agent endpoint" m_url

m_ignore_state() {
  backup "$INV_REL"
  mutate_sed "$INV_REL" 's|^if \[ "$state" = "failed" \] .. \[ "$state" = "canceled" \] .. \[ "$state" = "rejected" \]; then|if false; then|'
}
run_case "a failed task state is no longer treated as failure" \
  "$INV_SUITE" "exits non-zero when the task state is failed" m_ignore_state

m_ignore_rpc_error() {
  backup "$INV_REL"
  mutate_sed "$INV_REL" 's|^if \[ -n "$rpc_error" \]; then|if false; then|'
}
run_case "a JSON-RPC error object is ignored" \
  "$INV_SUITE" "exits non-zero on a JSON-RPC error object" m_ignore_rpc_error

m_ignore_empty() {
  backup "$INV_REL"
  mutate_sed "$INV_REL" 's|^if \[ -z "$text" \]; then|if false; then|'
}
run_case "an empty completed task is reported as success" \
  "$INV_SUITE" "exits non-zero on valid JSON carrying no response text" m_ignore_empty

m_ignore_nonjson() {
  backup "$INV_REL"
  mutate_sed "$INV_REL" 's|^if ! jq -e . "$RESP" >/dev/null 2>&1; then|if false; then|'
}
run_case "an HTML page served as 200 is accepted as a response" \
  "$INV_SUITE" "exits non-zero on a 200 that is not JSON" m_ignore_nonjson

m_no_card_check() {
  backup "$INV_REL"
  mutate_sed "$INV_REL" 's|^if \[ "$card_code" != "200" \]; then|if false; then|'
}
run_case "the agent-card precondition is skipped" \
  "$INV_SUITE" "exits non-zero when the agent card is not served" m_no_card_check

m_prompt_argv() {
  backup "$INV_REL"
  # Anchored on the unique substring rather than the whole line: the trailing
  # backslash continuation needs three levels of escaping to survive shell ->
  # sed, and getting it wrong produces a silent no-op that reads as a result.
  mutate_sed "$INV_REL" 's|--data-binary "@${REQ}"|--data-binary "$PROMPT"|'
}
run_case "the prompt is passed in curl argv instead of by file" \
  "$INV_SUITE" "the prompt travels by file, not argv" m_prompt_argv

# ── 7. Real HTTP ─────────────────────────────────────────────────────────────
m_http_envelope() {
  backup "$INV_REL"
  mutate_sed "$INV_REL" 's|    method: "message/send",|    method: "invoke",|'
}
run_case "the JSON-RPC method stops being message/send (over real HTTP)" \
  "$HTTP_SUITE" "real HTTP round trip returns the agent's text and exits zero" m_http_envelope

m_http_escape() {
  backup "$INV_REL"
  # Replace jq's escaping with naive string interpolation — the classic bug.
  mutate_sed "$INV_REL" \
    's|  jq -n --arg id "$MSG_ID" --arg text "$PROMPT" .{|  printf '"'"'{"jsonrpc":"2.0","id":"%s","method":"message/send","params":{"message":{"role":"user","messageId":"%s","kind":"message","parts":[{"kind":"text","text":"%s"}]}}}'"'"' "$MSG_ID" "$MSG_ID" "$PROMPT" >"$REQ"; false \&\& jq -n --arg id "$MSG_ID" --arg text "$PROMPT" '"'"'{|'
}
run_case "JSON escaping is hand-rolled instead of delegated to jq (over real HTTP)" \
  "$HTTP_SUITE" "a prompt containing quotes, newlines and backslashes survives the wire" m_http_escape

# ── 8. .env resolution (the worktree bug) ───────────────────────────────────
# .env is gitignored, so it exists only in the main checkout. A $PWD-relative
# read finds nothing from a worktree and reports "no key configured" — a fake
# success, with the operator's key two directories away.
m_env_pwd_relative() {
  backup "$ENVLIB_REL"
  # Must disable the WHOLE git resolution, not just the fast path — the
  # fallback branch resolves correctly on its own, so a shallower mutation
  # leaves the resolver working and falsely acquits the test.
  mutate_sed "$ENVLIB_REL" 's|^  local common="" root=""|  printf "%s/.env" "$PWD"; return 0  # MUTANT|'
}
run_case "the .env resolver goes back to being \$PWD-relative" \
  "$ENV_SUITE" "resolves to the MAIN checkout when run from a linked worktree" m_env_pwd_relative

m_env_no_normalise() {
  backup "$ENVLIB_REL"
  # Emit git's raw answer. From the MAIN worktree root `git rev-parse
  # --git-common-dir` is the RELATIVE ".git", so dirname is "." and the result
  # is "./.env" — which happens to work from that directory and breaks on any cd.
  mutate_sed "$ENVLIB_REL" 's|^  local common="" root=""|  printf "%s/.env" "$(dirname "$(git rev-parse --git-common-dir)")"; return 0  # MUTANT|'
}
run_case "the resolved .env path stops being normalised to absolute" \
  "$ENV_SUITE" "the path returned from the main checkout is absolute" m_env_no_normalise

m_env_clobbers() {
  backup "$ENVLIB_REL"
  # Restore the plain `set -a; . file` behaviour, which clobbers the environment.
  mutate_sed "$ENVLIB_REL" 's|^    if \[ -n "${!name:-}" \]; then _sig_preset\["$name"\]="${!name}"; fi|    :|'
}
run_case "the environment stops winning over the file" \
  "$ENV_SUITE" "an already-set environment variable wins over the file" m_env_clobbers

m_env_trace_leak() {
  backup "$ENVLIB_REL"
  mutate_sed "$ENVLIB_REL" 's|^    \*x\*) held=1; set +x ;;|    *x*) held=1; : ;;|'
}
run_case "the .env sourcing xtrace shield is disarmed" \
  "$ENV_SUITE" "sourcing the file does not leak values into an xtrace" m_env_trace_leak

m_env_override() {
  backup "$ENVLIB_REL"
  mutate_sed "$ENVLIB_REL" 's|^  if \[ -n "${SIGNALLOOM_ENV_FILE:-}" \]; then|  if false; then|'
}
run_case "SIGNALLOOM_ENV_FILE stops overriding" \
  "$ENV_SUITE" "SIGNALLOOM_ENV_FILE overrides everything" m_env_override

# ── 9. The tracked-secret guard ──────────────────────────────────────────────
m_secret_guard_pattern() {
  backup "$SEC_SUITE"
  # A pattern that cannot match anything real. The guard then reports a clean
  # tree forever, which is indistinguishable from actually being clean.
  mutate_sed "$SEC_SUITE" "s|KEY_SHAPE='sk-ant-\[A-Za-z0-9_-\]{40,}'|KEY_SHAPE='zz-never-matches-anything-zz'|"
}
run_case "the tracked-secret guard's pattern is broken" \
  "$SEC_SUITE" "the guard is armed — a planted real-shaped key is caught" m_secret_guard_pattern

m_secret_guard_scans_untracked() {
  backup "$SEC_SUITE"
  # Scan the filesystem instead of the git index. .env then trips the guard on
  # every run — it would be wrong every day, get switched off, and guard nothing.
  mutate_sed "$SEC_SUITE" 's|git ls-files -z 2>/dev/null|find . -type f -not -path "./.git/*" -print0|g'
}
run_case "the guard scans the working directory instead of the git index" \
  "$SEC_SUITE" "an untracked file holding a key is NOT flagged" m_secret_guard_scans_untracked

# ── 10. The invoke credential precondition ───────────────────────────────────
m_invoke_no_cred_check() {
  backup "$INV_REL"
  mutate_sed "$INV_REL" 's|^if \[ "${KAGENT_SKIP_CREDENTIAL_CHECK:-0}" != "1" \]; then|if false; then|'
}
run_case "invoke stops checking that a model credential exists" \
  "$INV_SUITE" "fails loudly when the model credential Secret is absent" m_invoke_no_cred_check

# ── Report ───────────────────────────────────────────────────────────────────
printf '\n════════════════════════════════════════════════════════════════\n'
printf 'FALSIFICATION RESULTS\n'
printf '════════════════════════════════════════════════════════════════\n'
for r in "${RESULTS[@]}"; do printf '  %s\n' "$r"; done
printf '\n  killed: %d    survived/inconclusive: %d\n' "$PASS" "$FAIL"

printf '\n  tree clean after restore: '
if [ -z "$(git status --porcelain)" ]; then printf 'YES\n'; else printf 'NO\n'; git status --porcelain; fi

[ "$FAIL" -eq 0 ]
