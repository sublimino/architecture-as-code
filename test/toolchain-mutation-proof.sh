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
SUITES=(test/terraform-toolchain-pins.bats test/terraform-env-contract.bats)

BACKUP="$(mktemp -d)"

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
SENTINEL="${REPO_ROOT}/.mutation-in-progress"

if [ -e "$SENTINEL" ]; then
  cat >&2 <<EOF
ERROR: a previous mutation run did not complete.

$(cat "$SENTINEL" 2>/dev/null)

The working tree may still contain a MUTATED file. This is what an interrupted
run looks like, and it is not a merge regression — check with:

    git status --porcelain
    git diff

A line replaced by a bare ':' is a mutation signature, never a merge artefact.

Restore the named file from the backup path above if it still exists, or with
'git checkout -- <file>' if you have no other uncommitted work in that
directory, then delete ${SENTINEL} and re-run.

Refusing to start. This script will not repair the tree for you: silently
restoring would hide that a destructive run was interrupted, and any gate result
read since then was computed against an unknown tree.
EOF
  exit 4
fi

mark_sentinel() { # label file
  printf 'mutation:  %s\nfile:      %s\nbackup:    %s/%s\nstarted:   %s\npid:       %s\n' \
    "$1" "$2" "$BACKUP" "$2" "$(date -Iseconds)" "$$" >"$SENTINEL"
}

clear_sentinel() { rm -f "$SENTINEL"; }

# The sentinel is removed by the EXIT trap on every path this process controls.
# When it survives, that is precisely the SIGKILL case it exists to report.
trap 'restore_all; clear_sentinel; rm -rf "$BACKUP"' EXIT INT TERM

backup_all() {
  local f
  for f in "$CI_TOOLS" "$STARTUP" "$UP" "$PIPE"; do
    mkdir -p "${BACKUP}/$(dirname "$f")"
    cp -p "$f" "${BACKUP}/${f}"
  done
}

restore_all() {
  local f
  for f in "$CI_TOOLS" "$STARTUP" "$UP" "$PIPE"; do
    [ -f "${BACKUP}/${f}" ] && cp -p "${BACKUP}/${f}" "$f"
  done
  return 0
}

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
  out="$(bats "${SUITES[@]}" 2>&1)" || status=$?

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

prove "drop the unlink from install_binary (leaving install -m 0755 alone)" \
  "$CI_TOOLS" "unlinks a destination before installing over it" \
  $'perl -0pi -e \'s{    && \\$\\{SUDO\\} rm -f "\\$\\{dest\\}" \\\\\\n}{}\' '"$CI_TOOLS"

prove "drop the unlink from install_from_tarball" \
  "$CI_TOOLS" "unlinks a destination before installing over it" \
  $'perl -0pi -e \'s{    && \\$\\{SUDO\\} rm -f "\\$\\{BIN\\}/\\$\\{name\\}" \\\\\\n    && \\$\\{SUDO\\} install -m 0755 "\\$\\{tmp\\}/\\$\\{name\\}"}{    && \\$\\{SUDO\\} install -m 0755 "\\$\\{tmp\\}/\\$\\{name\\}"}\' '"$CI_TOOLS"

# SCOPED TO THE FUNCTION BODY. install_from_tarball and install_anchore_tool
# contain byte-identical unlink+install pairs, so an unscoped substitution
# rewrites the FIRST one and proves nothing about the second — the first run of
# this harness reported exactly that, with the failure attributed to the
# install_from_tarball test. The `(?s)` block match pins the edit to the
# function that is actually under test.
prove "drop the unlink from install_anchore_tool" \
  "$CI_TOOLS" "anchore installer also unlinks" \
  $'perl -0pi -e \'s{(install_anchore_tool\\(\\) \\{.*?)    && \\$\\{SUDO\\} rm -f "\\$\\{BIN\\}/\\$\\{name\\}" \\\\\\n}{$1}s\' '"$CI_TOOLS"

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
for f in "$CI_TOOLS" "$STARTUP" "$UP" "$PIPE"; do
  if ! cmp -s "$f" "${BACKUP}/${f}"; then
    echo "ERROR: ${f} was not restored cleanly" >&2
    exit 3
  fi
done
echo "  all four files restored byte-for-byte"

if bats "${SUITES[@]}" >/dev/null 2>&1; then
  echo "  suites green after restore"
else
  echo "ERROR: suites are not green after restore" >&2
  exit 3
fi

[ "$FAIL" -eq 0 ] || exit 1
