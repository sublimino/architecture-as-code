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

@test "both scripts are syntactically valid" {
  run bash -n "${UP}"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  run bash -n "${PIPE}"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}
