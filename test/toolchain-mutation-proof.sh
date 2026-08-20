#!/usr/bin/env bash
# Mutation proof for the demo-up toolchain and environment-contract fixes.
#
# Every mutation below is applied to the REAL FILE, never to a fixture. A
# fixture mutation proves only that the fixture is wired up; it says nothing
# about whether the assertion is scoped to the thing that actually broke. This
# repo has been bitten by that three times in one day — an assertion matched
# `Restart=always` inside a script's own comment carried to the VM in a
# heredoc, and another matched the comment explaining the flag it was testing.
# Both were green and both were measuring nothing.
#
# Each mutation must make a NAMED test fail. A mutation that leaves the suite
# green is reported as UNPROVEN and is a defect in the test, not in the code.
#
# Restores from a byte-for-byte backup rather than `git checkout`, because a
# checkout of a directory silently reverts in-progress work elsewhere in the
# tree — a hazard this repo has already paid for once.

set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CI_TOOLS="scripts/ci/install-ci-tools.sh"
STARTUP="terraform/modules/compute/startup/demo-vm.sh"
UP="scripts/gcp-tf/demo-up.sh"
PIPE="scripts/gcp-tf/demo-pipeline.sh"
STUB="test/fixtures/gcp-tf-demo/stub-gcloud"
SUITES=(test/terraform-toolchain-pins.bats test/terraform-env-contract.bats)

# The driver suite is not in the default set because it is slower and most
# mutations here do not touch it. Mutations that DO — anything involving the
# gcloud stub or the driver's remote calls — pass it as a fifth argument to
# prove, so the proof runs the suite that can actually see the change.
DRIVER_SUITE=(test/terraform-demo-driver.bats)

# ── The sentinel, and why a correct trap is not enough ──────────────────────
#
# This harness restores from an out-of-repo copy on EXIT, INT and TERM, per
# terraform/CONTRACT.md §7b. That is correct and it is still not sufficient.
#
# A bash EXIT trap DOES survive SIGTERM — tested directly rather than assumed,
# because the opposite is widely believed and is false. What it cannot survive
# is SIGKILL, for either a direct kill or a process-group kill of a `make`-style
# parent. A tool timeout that escalates to SIGKILL therefore defeats an
# otherwise-correct harness and leaves a mutated file in the working tree.
#
# That leak is expensive out of all proportion to its size, because of what it
# looks like afterwards. The next gate reports a test failing in a file nobody
# edited, on a branch that was green, from a merge with no conflicts — an
# extremely convincing merge regression. It cost a teammate half an hour tonight.
# The tell is that a functional line has become `:`, a bash null command, which
# is a mutation signature and never a merge artefact.
#
# So the sentinel records what is currently mutated. On a clean finish it is
# removed. On startup, if one is found, this script REFUSES.
#
# REFUSES — it does not restore. Auto-repair here would be the same defect this
# whole task has been removing: a mitigation that silences its own alarm. A
# harness that quietly repaired the tree would make an interrupted destructive
# run invisible, and the operator would never learn that a gate result they had
# already read was computed against a mutated file. The file is named, the
# backup path is printed, and a human decides.
# ── The name was the bug ────────────────────────────────────────────────────
#
# This harness used `.mutation-in-progress` — GENERIC, with no proof name in it,
# while seven other proofs share the same working tree. A shared name is worse
# than no name at all: this harness's restore deletes the marker belonging to
# whichever proof was killed earlier, that proof then starts against a clean-
# LOOKING repo, reads its OWN leaked mutation as a genuine failure, and the
# refusal that exists to prevent exactly that never fires.
#
# It is now `.toolchain-mutation-in-progress`, minted by the shared rail, which
# additionally gives this harness the restore-mode check and the live-pid-versus-
# leaked distinction it did not have. See test/helpers/mutation-sentinel.bash.
# shellcheck source=helpers/mutation-sentinel.bash
source "${REPO_ROOT}/test/helpers/mutation-sentinel.bash"

ms_guard_init toolchain "$CI_TOOLS" "$STARTUP" "$UP" "$PIPE" "$STUB"

# EXIT alone, where this was `EXIT INT TERM`. bash runs the EXIT trap after an
# INT or TERM handler returns, so naming all three ran the restore twice; and
# INT/TERM are not otherwise trapped here, so EXIT covers them.
trap ms_guard_on_exit EXIT

mark_sentinel() { ms_guard_arm "$1 — $2"; }
clear_sentinel() { ms_guard_disarm; }
backup_all() { :; } # ms_guard_init already took the out-of-repo backup
restore_all() { ms_guard_restore; }

PASS=0
FAIL=0

# Applies one mutation, runs the suites, and requires a NAMED test to fail.
#
# `expect_test` is matched against the "not ok ... <name>" lines, so this proves
# the mutation was caught by the assertion that claims to cover it — not merely
# that something somewhere went red. A mutation caught only by an unrelated test
# is not proof of coverage.
prove() {
  local label="$1" file="$2" expect_test="$3" mutate="$4"
  # Optional 5th argument: a suite list, space separated. Defaults to SUITES.
  local -a suites=("${SUITES[@]}")
  if [ -n "${5:-}" ]; then read -r -a suites <<<"$5"; fi

  restore_all
  # The mutation must actually change the file. A sed whose pattern no longer
  # matches is a no-op that prints nothing and exits 0, and the "test did not
  # fail" that follows reads exactly like a dead assertion. Asserting the write
  # happened is what tells those two apart.
  local before after
  before="$(sha256sum "$file" | cut -d' ' -f1)"
  # Written BEFORE the edit, not after: the window this guards is the one where
  # the process dies between the write and the restore, and a sentinel created
  # after the mutation would miss a kill landing inside it.
  mark_sentinel "$label" "$file"
  eval "$mutate"
  after="$(sha256sum "$file" | cut -d' ' -f1)"

  if [ "$before" = "$after" ]; then
    printf '  [BROKEN MUTATION] %s\n' "$label"
    printf '      the edit did not change %s — the pattern no longer matches.\n' "$file"
    printf '      This is NOT evidence about the test; it is a broken proof.\n'
    FAIL=$((FAIL + 1))
    restore_all
    clear_sentinel
    return 0
  fi

  local out status=0
  out="$(bats "${suites[@]}" 2>&1)" || status=$?

  if printf '%s\n' "$out" | grep -qE "^not ok [0-9]+ .*${expect_test}"; then
    printf '  [CAUGHT]   %s\n' "$label"
    printf '      by: %s\n' "$(printf '%s\n' "$out" | grep -E "^not ok [0-9]+ .*${expect_test}" | head -1 | sed 's/^not ok [0-9]* //')"
    PASS=$((PASS + 1))
  else
    printf '  [UNPROVEN] %s\n' "$label"
    printf '      expected a failure matching: %s\n' "$expect_test"
    printf '      suite exit status: %s\n' "$status"
    printf '%s\n' "$out" | grep -E '^not ok' | sed 's/^/      saw: /' || printf '      saw: (no failures at all)\n'
    FAIL=$((FAIL + 1))
  fi
  # Restore first, THEN clear. The sentinel must outlive the window it guards.
  restore_all
  clear_sentinel
}

backup_all

echo "════════════════════════════════════════════════════════════════"
echo "  Mutation proof — real files, not fixtures"
echo "════════════════════════════════════════════════════════════════"
echo
echo "── Defect 1: SUDO heuristic tests the directory, curl writes the file ──"

prove "restore the raw 'curl -o \${BIN}/kind' that took EACCES on demo-2" \
  "$CI_TOOLS" "never curls directly onto a path under BIN" \
  $'perl -0pi -e \'s{  install_binary "https://github.com/kubernetes-sigs/kind[^\\n]*\\n}{  \\$\\{SUDO\\} curl -fsSL -o "\\$\\{BIN\\}/kind" "https://github.com/kubernetes-sigs/kind/releases/download/v\\$\\{KIND_VERSION\\}/kind-\\$\\{OS\\}-\\$\\{ARCH\\}"\\n}\' '"$CI_TOOLS"

# The unlink now lives in ONE place, so it is mutated in one place. The three
# mutations that used to target an inline `${SUDO} rm -f` in each installer were
# reported BROKEN MUTATION once it moved — the harness refusing to score a
# no-op edit, which is exactly what that check is for. A sed whose pattern has
# gone stale would otherwise run against correct code and be recorded as "the
# test did not fire".
prove "drop the unlink from bin_place" \
  "$CI_TOOLS" "unlinks a destination before installing over it" \
  $'perl -0pi -e \'s{^  \\$\\{SUDO\\} rm -f "\\$dest".*\\n}{}m\' '"$CI_TOOLS"

prove "make install_binary bypass bin_place" \
  "$CI_TOOLS" "unlinks a destination before installing over it" \
  $'perl -0pi -e \'s{    && bin_place "\\$\\{tmp\\}/payload" "\\$\\{dest\\}"}{    && install -m 0755 "\\$\\{tmp\\}/payload" "\\$\\{dest\\}"}\' '"$CI_TOOLS"

# sed with a LINE RANGE rather than perl across the whole file. The perl form
# needed escaped braces on both sides and produced "Unmatched right curly
# bracket" — a mutation that fails to compile reads, in a hurry, exactly like a
# guard that did not fire. A range scoped to the function is unambiguous and
# needs no escaping.
prove "make install_from_tarball bypass bin_place" \
  "$CI_TOOLS" "unlinks a destination before installing over it" \
  "sed -i '/^install_from_tarball() {/,/^}/ s|&& bin_place |\\&\\& install -m 0755 |' ${CI_TOOLS}"

prove "make install_anchore_tool bypass bin_place" \
  "$CI_TOOLS" "anchore installer also unlinks" \
  "sed -i '/^install_anchore_tool() {/,/^}/ s|&& bin_place |\\&\\& install -m 0755 |' ${CI_TOOLS}"

echo
echo "── Defect 2: two hardcoded versions of the same tool ──"

prove "revert kind in demo-vm.sh to v0.24.0" \
  "$STARTUP" "pins kind, and pins it to the version" \
  'sed -i '"'"'s/^readonly KIND_VERSION="v0.29.0"/readonly KIND_VERSION="v0.24.0"/'"'"' '"$STARTUP"

prove "remove the kubectl pin from demo-vm.sh" \
  "$STARTUP" "pins kubectl rather than resolving it at boot" \
  'sed -i '"'"'/^readonly KUBECTL_VERSION=/d'"'"' '"$STARTUP"

prove "restore the boot-time stable.txt lookup in install_kubectl" \
  "$STARTUP" "never resolves a tool version over the network at boot" \
  $'perl -0pi -e \'s{    "https://dl.k8s.io/release/\\$\\{KUBECTL_VERSION\\}/bin/linux/amd64/kubectl"}{    "https://dl.k8s.io/release/\\$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"}\' '"$STARTUP"

prove "diverge a tool pinned in BOTH setup.sh and install-ci-tools.sh (cosign)" \
  "$CI_TOOLS" "setup.sh and install-ci-tools.sh agrees" \
  'sed -i '"'"'s/^COSIGN_VERSION="3.0.6"/COSIGN_VERSION="3.0.5"/'"'"' '"$CI_TOOLS"

echo
echo "── Defect 6: node / bun / uv absent from every v2 VM ──"

prove "remove the node pin (v2's original state)" \
  "$CI_TOOLS" "every tool the demo pipeline invokes is installed" \
  'sed -i '"'"'/^NODE_VERSION=/d'"'"' '"$CI_TOOLS"

prove "remove the bun pin" \
  "$CI_TOOLS" "every tool the demo pipeline invokes is installed" \
  'sed -i '"'"'/^BUN_VERSION=/d'"'"' '"$CI_TOOLS"

prove "remove the uv pin (the gap that only a contract comment revealed)" \
  "$CI_TOOLS" "every tool the demo pipeline invokes is installed" \
  'sed -i '"'"'/^UV_VERSION=/d'"'"' '"$CI_TOOLS"

prove "install bun v1's way — pipe an unpinned installer into a shell" \
  "$CI_TOOLS" "never piped into a shell" \
  $'perl -0pi -e \'s{^  bun_tmp="\\$\\(mktemp -d\\)"$}{  curl -fsSL https://bun.sh/install | bash\\n  bun_tmp="\\$(mktemp -d)"}m\' '"$CI_TOOLS"

prove "skip the checksum verification for uv" \
  "$CI_TOOLS" "checksum-verified before it is unpacked" \
  $'perl -0pi -e \'s{    && verify_against_sidecar "\\$\\{uv_tmp\\}/\\$\\{uv_base\\}\\.tar\\.gz" "\\$\\{uv_url\\}\\.sha256" \\\\\\n}{}\' '"$CI_TOOLS"

prove "make verify_against_sidecar accept a mismatched digest" \
  "$CI_TOOLS" "actually rejects a bad digest" \
  $'perl -0pi -e \'s{(  if \\[ "\\$expected" != "\\$actual" \\]; then\\n    log "ERROR: checksum mismatch[^\\n]*\\n)    return 1\\n}{$1    return 0\\n}\' '"$CI_TOOLS"

prove "drop node/bun/uv from the operator-facing summary loop" \
  "$CI_TOOLS" "summary loop reports the tools" \
  'sed -i '"'"'s/^for t in \(.*\) node bun uv \(.*\); do$/for t in \1 \2; do/'"'"' '"$CI_TOOLS"

# The comment defect, made detectable.
#
# The first version of this mutation restored the false "node arrives with the
# Playwright setup" sentence and was reported UNPROVEN — correctly, because no
# test could see it. A prose claim is invisible to every assertion in the suite,
# which is exactly the property that let it survive long enough to cost three
# runs. The answer was not to drop the mutation but to make the comment carry a
# testable POSITIVE claim (it must name the file that really installs them), so
# rewriting it back to the Playwright story now fails.
prove "rewrite the prerequisite list back to a wrong provider" \
  "$STARTUP" "names the real provider for node, bun and uv" \
  $'perl -0pi -e \'s{#   node/bun/uv   scripts/ci/install-ci-tools\\.sh, pinned \\+ checksum-verified\\.}{#   node/bun/uv   arrive with the Playwright setup.}\' '"$STARTUP"

echo
echo "── Defect 9: bun/uv unplaceable when the cached SUDO probe is wrong ──"

prove "bypass bin_place and install with the cached \${SUDO} directly" \
  "$CI_TOOLS" "except through bin_place" \
  $'perl -0pi -e \'s{    && bin_place "\\$\\{uv_tmp\\}/\\$\\{uv_base\\}/uv" "\\$\\{BIN\\}/uv"}{    && \\$\\{SUDO\\} install -m 0755 "\\$\\{uv_tmp\\}/\\$\\{uv_base\\}/uv" "\\$\\{BIN\\}/uv"}\' '"$CI_TOOLS"

prove "remove bin_place's escalation, so a wrong probe is fatal again" \
  "$CI_TOOLS" "escalates when the cached probe was wrong" \
  $'perl -0pi -e \'s{  elif sudo -n install -m "\\$mode" "\\$src" "\\$dest" 2>/dev/null; then\\n[^\\n]*\\n[^\\n]*\\n}{  elif false; then\\n}\' '"$CI_TOOLS"

# Reverting the NOTE to name-only reproduces the live "owned by UNKNOWN".
prove "print only the owner NAME, losing the uid on an unmapped principal" \
  "$CI_TOOLS" "renders a real owner and mode" \
  "sed -i \"s|stat -c '%U (uid %u), mode %a'|stat -c '%U'|\" ${CI_TOOLS}"

prove "escalate SILENTLY — repair with no alarm" \
  "$CI_TOOLS" "escalates when the cached probe was wrong" \
  $'perl -0pi -e \'s{    log "NOTE:[^\\n]*\\n}{}g\' '"$CI_TOOLS"

prove "drop bin_place's post-install verification" \
  "$CI_TOOLS" "escalates when the cached probe was wrong" \
  $'perl -0pi -e \'s{  if \\[ ! -x "\\$dest" \\]; then\\n[^\\n]*\\n[^\\n]*\\n  fi\\n}{}\' '"$CI_TOOLS"

prove "log an ERROR and carry on instead of aborting when a tool fails" \
  "$CI_TOOLS" "stops the run at the point of failure" \
  $'perl -0pi -e \'s{    die_tool uv "\\$\\{UV_VERSION\\}"}{    log "ERROR: uv failed"}\' '"$CI_TOOLS"

echo
echo "── Defect 7: remote paths exported but never provisioned ──"

# Removing the CALL is caught by the ordering test, not by the set-comparison
# test — and that split is correct rather than a gap. The set test asks "does
# the provisioning cover every exported path", the ordering test asks "does it
# run at all". An earlier expectation named the wrong one of the pair, which is
# how this ran UNPROVEN: the function body still existed and still mentioned
# every variable, so the set test was quite right to stay green.
prove "stop provisioning the report dir and the log (the state that failed live)" \
  "$UP" "provisioning runs as part of delivery" \
  $'perl -0pi -e \'s{^  provision_remote_paths "\\$owner"\\n}{}m\' '"$UP"

# And a mutation that DOES exercise the set comparison: keep the call, drop one
# path from it. This is the shape a future edit would actually take — adding a
# path to the pipeline's environment and forgetting to provision it.
prove "provision the log but not the report directory" \
  "$UP" "created and chowned on the VM" \
  $'perl -0pi -e \'s{\\$\\(printf \\x27%q\\x27 "\\$REMOTE_REPORT_DIR"\\)}{/tmp/unprovisioned}g\' '"$UP"

# Renaming a function the test extracts by name must FAIL, not silently reduce
# what the test covers. This is the mutation that would have caught the
# `deliver()` / `deliver_code()` slip, where one of two extractions returned
# nothing and the combined presence check passed on the other half.
prove "rename deliver_code, so a by-name extraction silently covers nothing" \
  "$UP" "created and chowned on the VM" \
  'sed -i '"'"'s/^deliver_code() {/deliver_code_renamed() {/'"'"' '"$UP"

prove "provision only the log's PARENT, not the log file itself" \
  "$UP" "log FILE is created and handed over" \
  $'perl -0pi -e \'s{    && sudo touch \\$\\(printf \\x27%q\\x27 "\\$REMOTE_LOG"\\) \\\\\\n    && sudo chown \\$\\{owner\\} \\$\\(printf \\x27%q\\x27 "\\$REMOTE_LOG"\\)}{    && true}\' '"$UP"

prove "warn instead of aborting when provisioning fails" \
  "$UP" "failure is fatal, not a warning" \
  $'perl -0pi -e \'s{    \\|\\| die "could not provision[^\\n]*\\n}{    || warn "could not provision"\\n}\' '"$UP"

# The stub matcher, which is a test-infrastructure defect rather than a product
# one — and it produced a red gate on a correct fix, which is the expensive kind.
#
# Reverting the pipeline arm to the bare substring makes it swallow the
# provisioning mkdir, because REMOTE_LOG is /opt/signalloom/demo-pipeline.LOG.
# Exactly the shape as `DEMO_ENV` matching inside `SL_DEMO_ENV`: a token that is
# a substring of a longer, different token.
# Removing the dedicated arm is the mutation that reproduces the live failure.
#
# An earlier version only reverted the pattern to the bare substring and was
# reported UNPROVEN — correctly. The `mkdir -p` arm is ordered BEFORE the
# pipeline arm, so it catches the provisioning call first and the bare pattern
# never gets the chance to swallow it. The ORDERED ARM is the load-bearing fix;
# the `.sh` specificity is belt and braces. Mutating the belt while the braces
# hold proves nothing, which is exactly what the harness said.
prove "delete the dedicated provisioning arm from the stub" \
  "$STUB" "fail INDEPENDENTLY" \
  $'perl -0pi -e \'s{      \\*"mkdir -p"\\*\\).*?\\n        ;;\\n}{}s\' '"$STUB" \
  "${DRIVER_SUITE[*]}"

prove "delete the arm AND revert to the bare substring (the original defect)" \
  "$STUB" "fail INDEPENDENTLY" \
  $'perl -0pi -e \'s{      \\*"mkdir -p"\\*\\).*?\\n        ;;\\n}{}s; s{\\*"demo-pipeline\\.sh"\\*\\)}{*"demo-pipeline"*)}\' '"$STUB" \
  "${DRIVER_SUITE[*]}"

prove "collapse STUB_PROVISION_RC onto STUB_PIPELINE_RC (one knob, two calls)" \
  "$STUB" "fail INDEPENDENTLY" \
  $'perl -0pi -e \'s{exit "\\$\\{STUB_PROVISION_RC:-0\\}"}{exit "\\$\\{STUB_PIPELINE_RC:-0\\}"}\' '"$STUB" \
  "${DRIVER_SUITE[*]}"

echo
echo "── Defect 8: first session after a VM rebuild has no docker group ──"

# `sm`, not `s`. With /s alone the `^` anchors to the START OF THE STRING only,
# so this matched nothing and reported BROKEN MUTATION — which is the harness
# working: a no-op edit is called out rather than being silently scored as
# "the test did not fire".
prove "remove the sg docker re-exec entirely" \
  "$PIPE" "re-execs under sg docker" \
  $'perl -0pi -e \'s{^if \\[\\[ -z "\\$\\{DEMO_SG_REEXEC:-\\}" \\]\\].*?\\nfi\\n}{}sm\' '"$PIPE"

prove "drop the /etc/group membership check (sg would prompt and hang to the fence)" \
  "$PIPE" "re-execs under sg docker" \
  $'perl -0pi -e \'s{  && getent group docker[^\\n]*\\n}{}\' '"$PIPE"

prove "drop the loop guard export (a failing sg would re-exec forever)" \
  "$PIPE" "re-execs under sg docker" \
  $'perl -0pi -e \'s{^  export DEMO_SG_REEXEC=1\\n}{}m\' '"$PIPE"

prove "move the sg re-exec after install-ci-tools.sh, where it is useless" \
  "$PIPE" "sits before the first docker consumer" \
  $'perl -0pi -e \'s{^if \\[\\[ -z "\\$\\{DEMO_SG_REEXEC:-\\}" \\]\\]}{if [[ -n "\\$\\{NEVER_SET:-\\}" ]] \\&\\& [[ -z "\\$\\{DEMO_SG_REEXEC:-\\}" ]]}m\' '"$PIPE"

echo
echo "── Defect 3: report collection runs a malformed sudo ──"

prove "restore the unguarded 'sudo -u \$(printf %q \$REMOTE_USER)' in collect_reports" \
  "$UP" "never emits sudo with an empty user" \
  $'perl -0pi -e \'s{  local pack\\n  if \\[ -n "\\$REMOTE_USER" \\]; then\\n    printf -v pack \\x27sudo -u %q tar -C %q -czf %q \\.\\x27 \\\\\\n      "\\$REMOTE_USER" "\\$REMOTE_REPORT_DIR" "\\$archive"\\n  else\\n    printf -v pack \\x27sudo tar -C %q -czf %q \\.\\x27 "\\$REMOTE_REPORT_DIR" "\\$archive"\\n  fi\\n  if vm_ssh "\\$pack" &&}{  if vm_ssh "sudo -u \\$(printf \\x27%q\\x27 "\\$REMOTE_USER") tar -C \\$(printf \\x27%q\\x27 "\\$REMOTE_REPORT_DIR") -czf \\$(printf \\x27%q\\x27 "\\$archive") ." &&}\' '"$UP"

echo
echo "── Defects 4 & 5: the SL_DEMO_ / DEMO_ contract mismatch ──"

# Reverts EVERY name on the export line, which is what the defect actually was.
#
# An earlier version renamed only the first two and was reported UNPROVEN: the
# remaining eight still had readers, so the set-comparison test passed. Partial
# reversion models a typo; the shipped bug was a wholesale prefix mismatch, and
# a proof should mutate the thing that actually happened.
#
# This mutation is also what exposed the substring defect in
# contract_sent_names: `grep -o 'DEMO_[A-Z_]*=%q'` matched the tail of
# SL_DEMO_ENV=%q, so the extractor reported the names as correct while the file
# carried the original bug.
prove "revert the exported prefix to SL_DEMO_ (the original defect)" \
  "$UP" "extractor finds the exported names" \
  'sed -i '"'"'/printf -v envs /s/\bDEMO_/SL_DEMO_/g'"'"' '"$UP"

prove "stop exporting DEMO_PIPELINE_LOG (defect 4: abort names a missing log)" \
  "$UP" "log path demo-up.sh advertises is the one" \
  'sed -i '"'"'s/ DEMO_PIPELINE_LOG=%q//'"'"' '"$UP"

prove "make the pipeline ignore DEMO_SOURCE_COMMIT (defect 5: VM stamps its own SHA)" \
  "$PIPE" "stamps the driver.s commit" \
  $'perl -0pi -e \'s{^SOURCE_COMMIT="\\$\\{DEMO_SOURCE_COMMIT:-}{SOURCE_COMMIT="\\$\\{IGNORED_SOURCE_COMMIT:-}m\' '"$PIPE"

prove "drop .commit from the aborted summary" \
  "$PIPE" "aborted summary carries a commit" \
  $'perl -0pi -e \'s{    printf \\x27  "commit": %s,\\\\n\\x27 "\\$\\(json_str "\\$SOURCE_COMMIT"\\)"\\n}{}\' '"$PIPE"

prove "move SOURCE_COMMIT back below the EXIT trap (set -u crash in the abort writer)" \
  "$PIPE" "resolved before the EXIT trap is armed" \
  $'perl -0pi -e \'s{^(SOURCE_COMMIT="\\$\\{DEMO_SOURCE_COMMIT:-[^\\n]*\\n)}{}m; s{^(trap on_pipeline_exit EXIT\\n)}{\\$1SOURCE_COMMIT="\\$\\{DEMO_SOURCE_COMMIT:-\\$(git -C "\\$WORK_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)\\}"\\n}m\' '"$PIPE"

prove "unscope the source-commit fallback from WORK_DIR back to the cwd" \
  "$PIPE" "fallback names the tree explicitly" \
  $'perl -0pi -e \'s{git -C "\\$WORK_DIR" rev-parse --short HEAD}{git rev-parse --short HEAD}\' '"$PIPE"

# Removes the WHOLE refusal branch, not just its `exit 2`.
#
# The first version of this mutation deleted only the `exit 2` and was reported
# UNPROVEN — correctly. With the echoes left in place the script still PRINTED
# "cannot honour it" and still exited 2, because the following checkout phase
# rejects the nonexistent WORK_DIR with the same status. Both of the executing
# test's assertions were therefore still satisfied by a pipeline that no longer
# refused anything. Deleting the branch is the mutation that actually models
# "accepts any stage".
prove "accept any DEMO_STAGE instead of refusing (silent full run)" \
  "$PIPE" "stage refusal actually fires" \
  $'perl -0pi -e \'s{  \\*\\)\\n    echo "ERROR: DEMO_STAGE=.*?\\n    ;;\\n}{}s\' '"$PIPE"

echo
echo "════════════════════════════════════════════════════════════════"
printf '  CAUGHT: %d    UNPROVEN/BROKEN: %d\n' "$PASS" "$FAIL"
echo "════════════════════════════════════════════════════════════════"

restore_all

# Final guard: the tree must be byte-identical to where it started, and the
# suites must be green again. A proof harness that leaves a mutation behind is
# worse than no proof at all.
#
# `cmp` against the backup only ever compared CONTENT. The rail checks the MODE
# too, which `cmp` is blind to: `cp` onto an existing file keeps the destination
# mode, so a mutation applied via a tempfile and `mv` restores byte-identical
# with the executable bit gone. Four of the five files here are scripts.
if ! ms_guard_verify; then
  echo "ERROR: the tree was not restored cleanly" >&2
  exit 3
fi
echo "  all five files restored byte-for-byte, modes included"
ms_guard_report

if bats "${SUITES[@]}" >/dev/null 2>&1; then
  echo "  suites green after restore"
else
  echo "ERROR: suites are not green after restore" >&2
  exit 3
fi

[ "$FAIL" -eq 0 ] || exit 1
