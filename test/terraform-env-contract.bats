#!/usr/bin/env bats
#
# The demo-up.sh <-> demo-pipeline.sh environment contract must have both halves.
#
# ─── The failure this exists to prevent ────────────────────────────────────
#
# demo-up.sh exported ten variables named SL_DEMO_*. demo-pipeline.sh reads
# DEMO_*. The two lists were pairwise identical but for the prefix, and NOTHING
# in the repository consumed a single SL_DEMO_ name:
#
#   $ grep -rl 'SL_DEMO_' --include='*.sh' --include='*.bats' .
#   ./scripts/gcp-tf/demo-up.sh
#   ./test/terraform-demo-driver.bats
#
# The sender and the sender's own test. No reader anywhere.
#
# Both halves were GREEN throughout. terraform-demo-driver.bats asserted the
# string appeared in the gcloud command line; gcp-demo-pipeline.bats drove
# DEMO_* directly with its own stubs. Each side verified its own half against
# its own fixtures, so the disagreement BETWEEN them was invisible to both. That
# is the failure shape this suite exists for, and it is why the assertions below
# compare the two files to each other rather than to a list kept here.
#
# ─── What it cost ───────────────────────────────────────────────────────────
#
# All ten fell back to their defaults. Two of those defaults aborted the run:
#
#   DEMO_REPORT_DIR      the pipeline wrote summary.json to ${HOME}/demo-reports
#                        while demo-up.sh collected /opt/signalloom/reports, so
#                        no verdict was ever collected and the classifier read
#                        the absence as ABORTED.
#   DEMO_SOURCE_COMMIT   the pipeline fell back to `git rev-parse HEAD` against
#                        the throwaway repo created for Kustomize and stamped
#                        that into summary.json — the `master@47c5ea5` in the
#                        run log, where the driver had delivered
#                        feat/signal-loop-and-bootstrap-refactor@42d144fb.
#
# The second is the one worth remembering. demo-up.sh's STALE guard compares the
# collected .commit against the commit it delivered, in order to prove that a
# verdict describes the tree under test. Those two values could never be equal,
# so the guard was permanently inert — silently, on every run, unlike the
# ABORTED verdict which at least announced itself.
#
# The contract comment in demo-up.sh predicted this exact failure, in writing,
# while the code beneath it did the opposite:
#
#     "The commit MUST be the SL_DEMO_SOURCE_COMMIT it was handed — the VM's own
#      git SHA is a throwaway snapshot and means nothing, so stamping that
#      instead makes every run look STALE."
#
# A correct comment guarding incorrect code. Comments are not tested; this file
# is the test that comment needed.
#
# Offline: reads files. No network, no cloud, no VM.

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  export UP="${REPO_ROOT}/scripts/gcp-tf/demo-up.sh"
  export PIPE="${REPO_ROOT}/scripts/gcp-tf/demo-pipeline.sh"
}

setup() {
  load helpers/toolchain-contract
  [ -f "${UP}" ]
  [ -f "${PIPE}" ]
}

# ── The extractors must actually extract ────────────────────────────────────
#
# The central assertion is a set comparison, and the empty set is a subset of
# everything. Without these two tests this suite would report a perfect contract
# if either grep stopped matching.

@test "the sender extractor finds the exported names (no vacuous pass)" {
  run contract_sent_names "${UP}"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$(printf '%s\n' "$output" | wc -l)" -ge 8 ]
  # Two anchors that must be present for the contract to mean anything at all.
  printf '%s\n' "$output" | grep -qx 'DEMO_REPORT_DIR'
  printf '%s\n' "$output" | grep -qx 'DEMO_SOURCE_COMMIT'
}

@test "the reader extractor finds the injectable boundaries (no vacuous pass)" {
  run contract_read_names "${PIPE}"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$(printf '%s\n' "$output" | wc -l)" -ge 10 ]
  printf '%s\n' "$output" | grep -qx 'DEMO_REPORT_DIR'
  printf '%s\n' "$output" | grep -qx 'DEMO_SOURCE_COMMIT'
}

@test "the sender extractor reads the export line, not the prose describing it" {
  # demo-up.sh's contract comment names DEMO_REPORT_DIR and DEMO_SOURCE_COMMIT
  # in English, several paragraphs above the export. A whole-file grep would
  # match those and keep passing after the export itself was deleted — a guard
  # satisfied by the comment that explains it.
  #
  # Proven by construction: a file with the prose and NO export must yield
  # nothing.
  local fixture="${BATS_TEST_TMPDIR}/prose-only.sh"
  cat >"${fixture}" <<'FIXTURE'
# The commit MUST be the DEMO_SOURCE_COMMIT it was handed, and the reports go to
# DEMO_REPORT_DIR=%q which the driver supplies.
#   configured by: the DEMO_* environment below, nothing else
run_pipeline() {
  echo "no export here"
}
FIXTURE

  run contract_sent_names "${fixture}"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || {
    echo "the extractor matched prose rather than the export line:" >&2
    echo "$output" >&2
    return 1
  }
}

# ── The contract ────────────────────────────────────────────────────────────

@test "every variable demo-up.sh exports is read by demo-pipeline.sh" {
  # THE test. This is the assertion whose absence let the prefix diverge.
  #
  # Direction matters and only this direction is asserted: a name the pipeline
  # reads but the driver never sends is a legitimate injectable boundary with a
  # default (DEMO_CHROME_BIN, DEMO_PF_STATE_DIR and friends). A name the driver
  # SENDS that nothing reads is always a bug — either a typo, or a feature that
  # was never implemented and is quietly pretending otherwise.
  local sent read_names orphans=""
  sent="$(contract_sent_names "${UP}")"
  read_names="$(contract_read_names "${PIPE}")"

  [ -n "$sent" ] && [ -n "$read_names" ] || {
    echo "one side of the contract extracted empty — refusing a vacuous pass" >&2
    return 1
  }

  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf '%s\n' "$read_names" | grep -qx "$name" || orphans="${orphans} ${name}"
  done <<<"$sent"

  [ -z "$orphans" ] || {
    echo "demo-up.sh exports variables that demo-pipeline.sh never reads:" >&2
    echo "  ${orphans}" >&2
    echo "" >&2
    echo "Every one of these silently falls back to the pipeline's default. That is" >&2
    echo "how SL_DEMO_REPORT_DIR sent the reports to a directory nobody collected" >&2
    echo "and SL_DEMO_SOURCE_COMMIT let the VM stamp its own throwaway git SHA" >&2
    echo "into the verdict. Add a reader in demo-pipeline.sh or stop exporting it." >&2
    return 1
  }
}

@test "the driver exports no name under a prefix the pipeline cannot read" {
  # The specific regression: an SL_DEMO_ prefix on the sending side. Kept as its
  # own test because the set comparison above would also catch it, but this one
  # names the actual mistake in its failure message.
  #
  # COMMENT LINES ARE STRIPPED FIRST. demo-up.sh's contract block deliberately
  # RECOUNTS the SL_DEMO_ history — that narrative is the most valuable part of
  # the fix and must not be deletable by a test. The first draft of this
  # assertion grepped the whole file and failed on the very paragraph explaining
  # why the prefix is gone, which is a guard matching its own source: it reads
  # as a genuine finding and its easiest fix is to erase the documentation.
  local code
  code="$(grep -v '^[[:space:]]*#' "${UP}")"
  [ -n "$code" ] || { echo "stripped every line of ${UP}" >&2; return 1; }

  printf '%s\n' "$code" | grep -q 'SL_DEMO_' && {
    echo "demo-up.sh still references the SL_DEMO_ prefix in CODE:" >&2
    printf '%s\n' "$code" | grep -n 'SL_DEMO_' >&2
    echo "demo-pipeline.sh reads DEMO_*; nothing in this repo reads SL_DEMO_*." >&2
    return 1
  }
  return 0
}

@test "the comment-stripping in the prefix guard does not disarm it" {
  # Mutation control, for the same reason as the stable.txt pair: a guard that
  # strips lines must still be provably able to fire.
  local fixture="${BATS_TEST_TMPDIR}/still-broken.sh"
  cat >"${fixture}" <<'FIXTURE'
# History: we used to send SL_DEMO_REPORT_DIR and nothing read it.
printf -v envs 'SL_DEMO_ENV=%q' "$ENV_KEY"
FIXTURE

  local code
  code="$(grep -v '^[[:space:]]*#' "${fixture}")"
  printf '%s\n' "$code" | grep -q 'SL_DEMO_' || {
    echo "the guard cannot detect a real SL_DEMO_ export — it is disarmed" >&2
    return 1
  }

  # `|| true` on the strip: an all-comments file leaves grep -v with no output
  # and exit 1, which under bats' errexit would kill the test at the assignment
  # instead of at an assertion — and that is precisely the file this case exists
  # to exercise.
  local prose="${BATS_TEST_TMPDIR}/history-only.sh"
  printf '%s\n' '# History: we used to send SL_DEMO_REPORT_DIR and nothing read it.' >"${prose}"
  code="$(grep -v '^[[:space:]]*#' "${prose}" || true)"
  printf '%s\n' "$code" | grep -q 'SL_DEMO_' && {
    echo "the guard fires on a comment" >&2
    return 1
  }
  return 0
}

@test "the pipeline stamps the driver's commit, not the VM's throwaway git SHA" {
  # The STALE guard's whole basis. Asserted on the assignment line so that the
  # paragraph explaining it cannot satisfy the test.
  grep -qE '^SOURCE_COMMIT="\$\{DEMO_SOURCE_COMMIT:-' "${PIPE}" || {
    echo "demo-pipeline.sh does not prefer DEMO_SOURCE_COMMIT for SOURCE_COMMIT" >&2
    grep -n 'SOURCE_COMMIT=' "${PIPE}" >&2
    return 1
  }
  grep -qE '^SOURCE_BRANCH="\$\{DEMO_SOURCE_BRANCH:-' "${PIPE}" || {
    echo "demo-pipeline.sh does not prefer DEMO_SOURCE_BRANCH for SOURCE_BRANCH" >&2
    return 1
  }
}

@test "the aborted summary carries a commit so STALE can still be judged" {
  # write_terminal_summary used to emit no commit field at all, so an aborted
  # run produced a verdict the STALE guard could only read as "unknown" —
  # indistinguishable from a genuine wrong-tree result.
  local body
  body="$(sed -n '/^write_terminal_summary() {/,/^}/p' "${PIPE}")"
  [ -n "$body" ] || {
    echo "write_terminal_summary is not defined" >&2
    return 1
  }
  printf '%s\n' "$body" | grep -q '"commit"' || {
    echo "the aborted summary omits .commit:" >&2
    printf '%s\n' "$body" >&2
    return 1
  }
}

@test "SOURCE_COMMIT is resolved before the EXIT trap is armed" {
  # Ordering assertion, and it guards a real crash rather than a style point:
  # the abort writer now stamps SOURCE_COMMIT, and this script runs under
  # `set -u`. Resolving it after `trap on_pipeline_exit EXIT` means any abort
  # before that line dies on an unbound variable INSIDE the handler that exists
  # to record the abort.
  local trap_line commit_line
  trap_line="$(grep -n '^trap on_pipeline_exit EXIT' "${PIPE}" | head -1 | cut -d: -f1)"
  commit_line="$(grep -nE '^SOURCE_COMMIT="\$\{DEMO_SOURCE_COMMIT:-' "${PIPE}" | head -1 | cut -d: -f1)"

  [ -n "$trap_line" ] || { echo "no EXIT trap found" >&2; return 1; }
  [ -n "$commit_line" ] || { echo "no SOURCE_COMMIT assignment found" >&2; return 1; }

  [ "$commit_line" -lt "$trap_line" ] || {
    echo "SOURCE_COMMIT (line ${commit_line}) is resolved AFTER the EXIT trap is" >&2
    echo "armed (line ${trap_line}). Under set -u an early abort would fail inside" >&2
    echo "write_terminal_summary on an unbound variable." >&2
    return 1
  }
}

@test "the source-commit fallback names the tree explicitly, not the cwd" {
  # Because the resolution moved above `cd "$WORK_DIR"`, a bare `git rev-parse`
  # would describe whatever directory the caller was standing in.
  grep -qE 'DEMO_SOURCE_COMMIT:-\$\(git -C "\$WORK_DIR" rev-parse' "${PIPE}" || {
    echo "the SOURCE_COMMIT fallback does not scope git to WORK_DIR" >&2
    grep -n 'SOURCE_COMMIT=' "${PIPE}" >&2
    return 1
  }
}

# ── Defect 4: the log path the abort message names must be the one written ──

@test "the log path demo-up.sh advertises is the one it tells the pipeline to use" {
  # The abort message printed "VM log: /opt/signalloom/demo-pipeline.log" while
  # the pipeline logged to ${HOME}/demo-pipeline.log, because SL_DEMO_LOG had no
  # reader. On the VM: `tail: cannot open '/opt/signalloom/demo-pipeline.log':
  # No such file or directory`. Sending an operator to a nonexistent file during
  # an incident is a real cost.
  #
  # Asserted structurally: whatever REMOTE_LOG is, it must be what gets exported
  # as DEMO_PIPELINE_LOG, and DEMO_PIPELINE_LOG must be what the pipeline reads.
  grep -qE 'DEMO_PIPELINE_LOG=%q' "${UP}" || {
    echo "demo-up.sh does not export DEMO_PIPELINE_LOG" >&2
    return 1
  }
  grep -qE '^PIPELINE_LOG="\$\{DEMO_PIPELINE_LOG:-' "${PIPE}" || {
    echo "demo-pipeline.sh does not read DEMO_PIPELINE_LOG" >&2
    return 1
  }
  # And the value handed over is REMOTE_LOG, the same variable the abort message
  # and the ABORTED diagnosis both print.
  grep -q '"\$REMOTE_LOG"' "${UP}" || {
    echo "demo-up.sh does not pass REMOTE_LOG into the pipeline environment" >&2
    return 1
  }
}

# ── Defect 3: report collection must not build a malformed sudo ─────────────

@test "report collection never emits sudo with an empty user" {
  # REMOTE_USER is empty by default. `sudo -u ''` is rejected by sudo's own
  # argument parser before any user lookup, so it prints the full usage block
  # and exits 1 — reproduced verbatim:
  #
  #   $ sudo -n -u '' tar -C /tmp -czf /tmp/x.tar.gz .
  #   usage: sudo -h | -K | -k | -V
  #   usage: sudo -v [-ABkNnS] [-g group] [-h host] [-p prompt] [-u user]
  #
  # Every other sudo site in demo-up.sh guards on [ -n "$REMOTE_USER" ]; this
  # one did not. Asserted on the function body so the comment explaining the bug
  # cannot satisfy the test.
  local body
  body="$(sed -n '/^collect_reports() {/,/^}/p' "${UP}")"
  [ -n "$body" ] || {
    echo "collect_reports is not defined in ${UP}" >&2
    return 1
  }

  # No unguarded interpolation of REMOTE_USER straight after `sudo -u`.
  if printf '%s\n' "$body" | grep -qE 'sudo -u \$\(printf'; then
    echo "collect_reports interpolates REMOTE_USER into 'sudo -u' without a guard:" >&2
    printf '%s\n' "$body" | grep -nE 'sudo -u \$\(printf' >&2
    return 1
  fi

  # And it must branch on emptiness, like every other sudo site in the file.
  printf '%s\n' "$body" | grep -qE '\[ -n "\$REMOTE_USER" \]' || {
    echo "collect_reports does not guard on a non-empty REMOTE_USER" >&2
    printf '%s\n' "$body" >&2
    return 1
  }
}

@test "sudo really does reject an empty -u argument with a usage error" {
  # The premise of the test above, verified against the real sudo on this
  # machine rather than assumed. If a future sudo accepted `-u ''` this would
  # fail and tell us the guard's rationale had changed — which is better than a
  # guard whose reason nobody can reconstruct.
  #
  # -n is non-interactive: it can never prompt, and it never runs tar because
  # argument parsing fails first.
  run sudo -n -u '' true
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: sudo"* ]] || {
    echo "expected a sudo usage error, got: ${output}" >&2
    return 1
  }
}

# ── The stage refusal ───────────────────────────────────────────────────────

@test "demo-pipeline.sh refuses a stage it cannot honour" {
  # It has no stage system: the "STAGE:" banners label steps in one fixed
  # sequence and select nothing. Now that the driver's environment actually
  # arrives, accepting DEMO_STAGE=test would silently perform a FULL bring-up —
  # including a cluster rebuild — for a caller that asked to re-run tests
  # against a standing cluster. Refusing is one line and is honest.
  local body
  body="$(sed -n '/^STAGE="\${DEMO_STAGE:-full}"/,/^esac/p' "${PIPE}")"
  [ -n "$body" ] || {
    echo "no DEMO_STAGE handling found in ${PIPE}" >&2
    return 1
  }
  printf '%s\n' "$body" | grep -q 'exit 2' || {
    echo "the stage guard does not refuse:" >&2
    printf '%s\n' "$body" >&2
    return 1
  }
}

@test "the stage refusal actually fires, and full actually passes" {
  # Executes the real guard rather than reading it. The script is run with bash
  # -n disabled and a WORK_DIR that does not exist, so it would fail at the
  # checkout phase anyway — but the stage guard sits ABOVE that, so an
  # unsupported stage must produce exit 2 and the stage message, while a
  # supported one must get past the guard and fail differently.
  run env DEMO_STAGE=test DEMO_WORK_DIR=/nonexistent-tree-for-test \
    DEMO_REPORT_DIR="${BATS_TEST_TMPDIR}/r" \
    DEMO_PIPELINE_LOG="${BATS_TEST_TMPDIR}/p.log" \
    bash "${PIPE}"
  [ "$status" -eq 2 ] || {
    echo "expected exit 2 for an unsupported stage, got ${status}" >&2
    echo "$output" >&2
    return 1
  }
  [[ "$output" == *"cannot honour it"* ]] || {
    echo "the refusal did not name the problem: ${output}" >&2
    return 1
  }

  # The mutation control: DEMO_STAGE=full must NOT be refused. Without this, a
  # guard that rejected everything would pass the test above.
  run env DEMO_STAGE=full DEMO_WORK_DIR=/nonexistent-tree-for-test \
    DEMO_REPORT_DIR="${BATS_TEST_TMPDIR}/r2" \
    DEMO_PIPELINE_LOG="${BATS_TEST_TMPDIR}/p2.log" \
    bash "${PIPE}"
  [[ "$output" != *"cannot honour it"* ]] || {
    echo "DEMO_STAGE=full was refused, which it must not be" >&2
    echo "$output" >&2
    return 1
  }
}

# ── Every remote path the pipeline is told to write to must be provisioned ──
#
# The first genuinely-addressed bring-up failed here:
#
#   tee: /opt/signalloom/demo-pipeline.log: Permission denied
#   mkdir: cannot create directory '/opt/signalloom/reports': Permission denied
#
# /opt/signalloom is root-owned 0755 and only `repo` was ever created and
# chowned. Unreachable until the prefix mismatch was fixed: while the variables
# never arrived the pipeline fell back to ${HOME}/… — writable, so the
# permission assumption never fired, it just wrote where nobody collected.
#
# DERIVED, never pinned. The assertions below do not know that today's answer is
# /opt/signalloom; they pair the exported names to the shell variables that
# supply them and require each path-valued one to be provisioned.

@test "the name-to-variable pairing extractor works (no vacuous pass)" {
  run contract_remote_path_vars "${UP}"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # The three that must be present for the contract to mean anything.
  printf '%s\n' "$output" | grep -qx 'DEMO_WORK_DIR REMOTE_WORK_DIR'
  printf '%s\n' "$output" | grep -qx 'DEMO_REPORT_DIR REMOTE_REPORT_DIR'
  printf '%s\n' "$output" | grep -qx 'DEMO_PIPELINE_LOG REMOTE_LOG'
}

@test "every REMOTE_* path exported to the pipeline is created and chowned on the VM" {
  # THE assertion. A path the driver tells the pipeline to write to, that the
  # driver never provisions, is a forty-minute run that ends in "no verdict".
  #
  # Scoped to the two functions that touch the VM's filesystem, so the long
  # comment explaining the failure cannot satisfy it.
  # Scoped to the lines that actually TOUCH THE FILESYSTEM — mkdir, chown,
  # touch, tar — not to the whole function.
  #
  # Two things can otherwise satisfy this without any path being created, and
  # both were observed. Comments are the obvious one: the rationale above
  # provision_remote_paths names every variable in prose. The second is subtler
  # and is what the mutation harness caught — the `die` message interpolates
  # ${REMOTE_REPORT_DIR} to tell the operator which path failed, so replacing
  # the real mkdir argument with a wrong path left the assertion green on the
  # strength of the ERROR STRING. A diagnostic that names a thing is not
  # evidence that the thing happens.
  # PRESENCE PER SOURCE, checked independently before they are concatenated.
  #
  # An earlier version extracted `deliver()` — the function is `deliver_code()`
  # — so that half silently produced NOTHING, and the combined non-empty check
  # passed on the strength of the other half alone. The test then asserted over
  # one of the two functions it claimed to cover, and stayed green. A single
  # presence check across several sources cannot tell "all present" from "at
  # least one present", which is the whole failure mode it is meant to prevent.
  local deliver_body provision_body provisioning
  deliver_body="$(sed -n '/^deliver_code() {/,/^}/p' "${UP}")"
  provision_body="$(sed -n '/^provision_remote_paths() {/,/^}/p' "${UP}")"

  [ -n "$deliver_body" ] || {
    echo "deliver_code() not found in ${UP} — did it get renamed?" >&2
    return 1
  }
  [ -n "$provision_body" ] || {
    echo "provision_remote_paths() not found in ${UP} — did it get renamed?" >&2
    return 1
  }
  provisioning="${deliver_body}"$'\n'"${provision_body}"
  provisioning="$(
    printf '%s\n' "$provisioning" \
      | grep -v '^[[:space:]]*#' \
      | grep -E 'mkdir|chown|touch|tar -xzf'
  )"
  [ -n "$provisioning" ] || {
    echo "no mkdir/chown/touch lines found in the delivery path at all" >&2
    return 1
  }

  local pairs remote_var unprovisioned=""
  pairs="$(contract_remote_path_vars "${UP}")"
  [ -n "$pairs" ] || { echo "no exported name/variable pairs found" >&2; return 1; }

  while read -r _ remote_var; do
    # Only the ones naming a remote filesystem path.
    case "$remote_var" in
      REMOTE_*) ;;
      *) continue ;;
    esac
    printf '%s\n' "$provisioning" | grep -q "\$$remote_var\|\${$remote_var}" \
      || unprovisioned="${unprovisioned} ${remote_var}"
  done <<<"$pairs"

  [ -z "$unprovisioned" ] || {
    echo "exported to the pipeline but never created on the VM:${unprovisioned}" >&2
    echo "" >&2
    echo "The pipeline is told to write there and cannot. /opt/signalloom is" >&2
    echo "root-owned 0755, so a path under it must be mkdir'd AND chowned by the" >&2
    echo "delivery step, which is the only thing here that holds sudo." >&2
    return 1
  }
}

@test "the log FILE is created and handed over, not merely its parent directory" {
  # A writable DIRECTORY does not imply a writable FILE — the same lesson as the
  # curl/EACCES defect in install-ci-tools.sh, in a different tool. `tee` opens
  # an existing log for writing and is refused when another principal owns it,
  # however writable the parent is. Creating only the parent works on the first
  # run and fails after any run under a different service account.
  local body
  body="$(sed -n '/^provision_remote_paths()/,/^}/p' "${UP}" | grep -v '^[[:space:]]*#')"
  [ -n "$body" ] || { echo "provision_remote_paths is not defined" >&2; return 1; }

  printf '%s\n' "$body" | grep -qE 'touch .*REMOTE_LOG' || {
    echo "the log file itself is never created:" >&2
    printf '%s\n' "$body" >&2
    return 1
  }
  # `.*`, NOT `[^\n]*`. Inside a POSIX ERE bracket expression `\n` is the two
  # literal characters backslash and n, so `[^\n]*` means "not a backslash and
  # not the letter n" — it cannot cross the `n` in `${owner}`, and this
  # assertion failed against code that was correct. grep is line-oriented; `.`
  # already excludes newlines.
  printf '%s\n' "$body" | grep -qE 'chown .*REMOTE_LOG' || {
    echo "the log file is created but never chowned to the pipeline user" >&2
    return 1
  }
}

@test "provisioning failure is fatal, not a warning" {
  # A driver that carries on after failing to create the report directory
  # produces "no verdict was produced" forty minutes later, with the real cause
  # scrolled off the top. The same argument the STALE and missing-summary paths
  # already make: a verdict derived from absent evidence is not a verdict.
  local body
  body="$(sed -n '/^provision_remote_paths()/,/^}/p' "${UP}" | grep -v '^[[:space:]]*#')"
  printf '%s\n' "$body" | grep -q 'die ' || {
    echo "provision_remote_paths does not abort on failure:" >&2
    printf '%s\n' "$body" >&2
    return 1
  }
}

@test "provisioning runs as part of delivery, before the pipeline is invoked" {
  # Ordering, asserted by line number: the paths must exist before run_pipeline
  # tells the pipeline to write to them.
  local call_line run_line
  call_line="$(grep -n '^  provision_remote_paths ' "${UP}" | head -1 | cut -d: -f1)"
  run_line="$(grep -n '^run_pipeline() {' "${UP}" | head -1 | cut -d: -f1)"
  [ -n "$call_line" ] || {
    echo "provision_remote_paths is defined but never called" >&2
    return 1
  }
  [ -n "$run_line" ] || { echo "run_pipeline not found" >&2; return 1; }
  [ "$call_line" -lt "$run_line" ] || {
    echo "provision_remote_paths (line ${call_line}) is called after run_pipeline" >&2
    echo "is defined (line ${run_line}); check it runs during delivery" >&2
    return 1
  }
}

# ── The first-session docker group ──────────────────────────────────────────

@test "the pipeline re-execs under sg docker when the group is not yet active" {
  # Without this the FIRST bring-up after any VM replacement always fails:
  # OS Login provisions the account at first login, demo-vm.sh's profile.d
  # snippet runs `usermod -aG docker` in that same session, and usermod cannot
  # change the credentials of a session already running.
  local block
  block="$(sed -n '/^if \[\[ -z "\${DEMO_SG_REEXEC:-}" \]\]/,/^fi$/p' "${PIPE}")"
  [ -n "$block" ] || {
    echo "no sg docker re-exec guard found in ${PIPE}" >&2
    return 1
  }

  # Each condition, because each one prevents a distinct failure.
  printf '%s\n' "$block" | grep -q 'DEMO_SG_REEXEC' || {
    echo "no loop guard — a failing sg would re-exec forever" >&2; return 1; }
  printf '%s\n' "$block" | grep -q 'getent group docker' || {
    echo "membership is not checked against /etc/group; sg prompts for a group" >&2
    echo "password when the caller is not a member, and a non-interactive SSH" >&2
    echo "session has no tty for that prompt — it would hang to the fence." >&2
    return 1; }
  printf '%s\n' "$block" | grep -q 'docker version' || {
    echo "the socket is never probed; this would re-exec on a healthy session" >&2
    return 1; }
  printf '%s\n' "$block" | grep -q 'exec sg docker -c' || {
    echo "the guard does not actually re-exec under sg" >&2; return 1; }
  printf '%s\n' "$block" | grep -q 'export DEMO_SG_REEXEC=1' || {
    echo "the loop guard is not exported, so it cannot survive the exec" >&2
    return 1; }
}

@test "the sg re-exec sits before the first docker consumer" {
  # install-ci-tools.sh is where the failure surfaces, as "Docker daemon is not
  # running" — a message that is wrong about the cause. The re-exec is worthless
  # after it.
  local guard_line consumer_line
  guard_line="$(grep -n '^if \[\[ -z "\${DEMO_SG_REEXEC:-}" \]\]' "${PIPE}" | head -1 | cut -d: -f1)"
  # The comment filter is anchored `^[0-9]+:[[:space:]]*#`, because `grep -n`
  # emits `238:# ...` — the line number comes FIRST. An earlier version looked
  # for `:[0-9]*:#`, which never matches that shape, so the filter did nothing
  # and the first "consumer" found was the comment explaining the guard. Third
  # time tonight a comment has satisfied one of my own assertions.
  consumer_line="$(grep -n 'install-ci-tools.sh' "${PIPE}" | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)"
  [ -n "$guard_line" ] || { echo "no sg guard found" >&2; return 1; }
  [ -n "$consumer_line" ] || { echo "install-ci-tools.sh is no longer invoked" >&2; return 1; }
  [ "$guard_line" -lt "$consumer_line" ] || {
    echo "the sg re-exec (line ${guard_line}) runs after install-ci-tools.sh" >&2
    echo "(line ${consumer_line}), which is where the docker check fails" >&2
    return 1
  }
}

@test "the sg guard does not fire on a healthy session" {
  # Executed, not read. This box has a working docker socket and the invoking
  # user is already an effective member, so the guard must decline — proving it
  # cannot re-exec a session that does not need it.
  command -v docker >/dev/null 2>&1 || skip "no docker on this machine"
  docker version >/dev/null 2>&1 || skip "docker socket unreachable here"

  run env DEMO_STAGE=full DEMO_WORK_DIR=/nonexistent-tree-for-test \
    DEMO_REPORT_DIR="${BATS_TEST_TMPDIR}/r" \
    DEMO_PIPELINE_LOG="${BATS_TEST_TMPDIR}/p.log" \
    bash "${PIPE}"
  [[ "$output" != *"re-executing under 'sg docker'"* ]] || {
    echo "the guard re-executed a session whose socket already works" >&2
    echo "$output" >&2
    return 1
  }
}

@test "both scripts are syntactically valid" {
  run bash -n "${UP}"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  run bash -n "${PIPE}"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}
