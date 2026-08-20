#!/usr/bin/env bats
#
# terraform-vm-state-contract.bats — offline proof that the VM state gate works.
#
# ── Why this suite is named terraform-* ─────────────────────────────────────
#
# Two reasons, and the first one is the load-bearing one.
#
# `GCP_TF_BATS = $(sort $(wildcard test/terraform-*.bats))` is the ONLY
# auto-discovering bats runner in this repo. Every other suite is named by hand
# in a Makefile recipe, which is how 33 suites once shipped that no runner
# executed — all passing, all measuring nothing. A suite named anything else is
# claimed by nobody and is silently skipped with exit 0, which for a suite whose
# entire job is to prove a guard can fail would be the worst possible outcome:
# evidence that the guard was falsified, produced by never running it.
#
# The second reason is that the name is honest. The facts this gate asserts are
# the POST-CONDITIONS of terraform/modules/compute — demo-vm.sh installs docker,
# kind and kubectl at boot, and this suite derives facts 1 and 2 straight out of
# that file's pins. The VM state contract is the compute module's contract,
# observed from the far side.
#
# ── What is actually being tested ───────────────────────────────────────────
#
# Not the gate's source. The gate's whole reason for existing is that source is
# the wrong surface — test/ci-installer-privileges.bats guards this same bug
# class by grepping the installers, it is well argued and green, and the bug
# recurred anyway because whether /usr/local/bin is writable is a property of
# the machine, not of the script.
#
# So every test below RUNS the real gate against a sandbox filesystem whose
# state it controls, and asserts on the verdict. That is only possible because
# every boundary in the gate is an injectable environment variable.
#
# Offline: no network, no cloud credentials, no VM, no privileges. Well under
# 30 seconds.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  VMSC_GATE="${REPO_ROOT}/scripts/vm-state/vm-state-contract.sh"
  HELPER="${REPO_ROOT}/test/helpers/vm-state-contract.bash"

  # Presence before behaviour. Without this, every assertion below is a claim
  # about a file that may not exist: `bash /nonexistent` exits 127, and a test
  # asserting only "the gate failed" would pass forever having run nothing.
  [ -f "${VMSC_GATE}" ]
  [ -f "${HELPER}" ]

  # shellcheck source=test/helpers/vm-state-contract.bash
  . "${HELPER}"

  VMSC_SANDBOX="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/vmsc.XXXXXX")"
  export VMSC_SANDBOX
  vmsc_sandbox "${VMSC_SANDBOX}"
}

teardown() {
  # chmod back before rm, or a deliberately-unwritable directory survives the
  # cleanup and the next run inherits it.
  [ -n "${VMSC_SANDBOX}" ] && chmod -R u+w "${VMSC_SANDBOX}" 2>/dev/null
  [ -n "${VMSC_SANDBOX}" ] && rm -rf "${VMSC_SANDBOX}"
  return 0
}

# ---------------------------------------------------------------------------
# The mechanism is present, and the baseline is green
# ---------------------------------------------------------------------------

@test "the gate exists, is executable, and is not under the frozen scripts/ci tree" {
  [ -x "${VMSC_GATE}" ]
  # scripts/ci/** is frozen and owned elsewhere. A gate that drifted into it
  # would be un-editable by the person who has to maintain it.
  case "${VMSC_GATE}" in
    */scripts/ci/*) echo "the gate has moved into the frozen scripts/ci tree"; return 1 ;;
  esac
}

@test "a healthy sandbox passes every fact and exits 0" {
  # The anchor for everything below. If this is not green then a FAIL in any
  # mutation test proves nothing — it could be the sandbox, not the mutation.
  vmsc_run_gate
  [ "$status" -eq 0 ]
  vmsc_fact_is F1-kind-pinned PASS
  vmsc_fact_is F2-kubectl-pinned PASS
  vmsc_fact_is F3-node-runnable PASS
  vmsc_fact_is F4-bun-runnable PASS
  vmsc_fact_is F5-uv-runnable PASS
  vmsc_fact_is F6-bin-placeable PASS
  vmsc_fact_is F7a-work-root-writable PASS
  vmsc_fact_is F7b-reports-writable PASS
  vmsc_fact_is F8-docker-usable PASS
  [[ "$output" == *"9/9 facts hold"* ]]
}

@test "all nine facts are evaluated, so the count cannot silently shrink" {
  # A fact that stops being emitted stops being checked, and every "PASS: N/N"
  # line is happy to report a smaller N. Count the status lines.
  vmsc_run_gate
  n="$(printf '%s\n' "$output" | grep -cE '^ +\[(PASS|FAIL)\] +F[0-9]')"
  [ "$n" -eq 9 ]
}

# ---------------------------------------------------------------------------
# Facts 1 and 2 — the pinned tools
# ---------------------------------------------------------------------------

@test "F1 goes red when kind is present at the wrong version" {
  # The live defect: kind was v0.24.0 while the pipeline required 0.29.0.
  vmsc_stub kind "kind version 0.24.0"
  vmsc_run_gate
  [ "$status" -eq 1 ]
  vmsc_fact_is F1-kind-pinned FAIL
  [[ "$output" == *"pinned 0.29.0"* ]]
  [[ "$output" == *"0.24.0"* ]]
}

@test "F1 names the early-return-on-presence trap, because that is the actual fix" {
  # install_kind() in demo-vm.sh returns early if `command -v kind` succeeds,
  # regardless of version. So a warm VM keeps a stale kind forever and the pin
  # in the source is a lie about that machine. An operator told only "wrong
  # version" re-runs the installer and watches it skip.
  vmsc_stub kind "kind version 0.24.0"
  vmsc_run_gate
  [[ "$output" == *"early-return"* ]] || [[ "$output" == *"PRESENCE"* ]]
}

@test "F1 goes red when kind is absent entirely" {
  vmsc_remove_tool kind
  vmsc_run_gate
  [ "$status" -eq 1 ]
  vmsc_fact_is F1-kind-pinned FAIL
  [[ "$output" == *"ABSENT"* ]]
}

@test "F2 goes red when kubectl is at the wrong version" {
  # The live defect: kubectl was not pinned at all, resolving
  # dl.k8s.io/release/stable.txt at boot, so this is whatever shipped that day.
  vmsc_stub kubectl "Client Version: v1.31.0"
  vmsc_run_gate
  [ "$status" -eq 1 ]
  vmsc_fact_is F2-kubectl-pinned FAIL
}

@test "a pinned version is not satisfied by a longer number that contains it" {
  # 1.33.2 must NOT be satisfied by a reported 1.33.20. A bare substring match
  # passes here, which is the trap: the gate would certify a version nobody
  # pinned, and it would do it silently on the one machine that had drifted.
  vmsc_stub kubectl "Client Version: v1.33.20"
  vmsc_run_gate
  [ "$status" -eq 1 ]
  vmsc_fact_is F2-kubectl-pinned FAIL
}

@test "pins are read from declarations only, never from prose that mentions a version" {
  # The sandbox's pin file carries `v0.24.0` and `KUBECTL_VERSION="v9.9.9"`
  # inside a COMMENT, exactly as the real demo-vm.sh:53 does while explaining
  # the old defect. An unanchored extractor reads that comment and asserts the
  # version the gate exists to reject — a guard satisfied by the paragraph
  # describing the bug. Both correct tools must still pass.
  vmsc_run_gate
  [ "$status" -eq 0 ]
  vmsc_fact_is F1-kind-pinned PASS
  vmsc_fact_is F2-kubectl-pinned PASS
  [[ "$output" == *"kind: 0.29.0"* ]]
  [[ "$output" == *"kubectl: 1.33.2"* ]]
}

# ---------------------------------------------------------------------------
# Facts 3, 4, 5 — node, bun, uv. Absent on sl-demo-1-vm at the time of writing.
# ---------------------------------------------------------------------------

@test "F3 goes red when node is absent" {
  vmsc_remove_tool node
  vmsc_run_gate
  [ "$status" -eq 1 ]
  vmsc_fact_is F3-node-runnable FAIL
}

@test "F4 goes red when bun is absent, and names the best-effort installer" {
  # install-ci-tools.sh logs "ERROR: bun failed verification or install" and
  # CARRIES ON — it is best-effort by construction. Nothing converts that line
  # into a stop, which is why the pipeline reached stage 2 before anyone knew.
  vmsc_remove_tool bun
  vmsc_run_gate
  [ "$status" -eq 1 ]
  vmsc_fact_is F4-bun-runnable FAIL
  [[ "$output" == *"install-ci-tools.sh"* ]]
}

@test "F5 goes red when uv is present but cannot run" {
  # Present-and-broken is a real state: a truncated download or a wrong-arch
  # binary is on PATH, is executable, and exits non-zero. `[ -x ]` calls that
  # healthy. Running it is the only honest question.
  vmsc_stub_broken uv "uv: cannot execute binary file" 126
  vmsc_run_gate
  [ "$status" -eq 1 ]
  vmsc_fact_is F5-uv-runnable FAIL
  [[ "$output" == *"exited 126"* ]]
}

# ---------------------------------------------------------------------------
# Fact 6 — /usr/local/bin. The check where the obvious answer is wrong.
# ---------------------------------------------------------------------------

@test "F6 PASSES when the bin dir is unwritable but sudo is available" {
  # THE MOST IMPORTANT TEST IN THIS FILE.
  #
  # Measured on sl-demo-1-vm 2026-08-20: /usr/local/bin is drwxr-xr-x root:root,
  # `touch` returns Permission denied, and `sudo -n true` returns 0. That VM is
  # HEALTHY — install-ci-tools.sh:27 does `[ -w "${BIN}" ] || SUDO="sudo"` and
  # escalates.
  #
  # So a gate asserting "writable by the invoking user", which is what fact 6
  # was briefed as, FAILS ON A CORRECTLY-PROVISIONED MACHINE. A false alarm on
  # the healthy case is not a small defect: it is how a check earns a reputation
  # for lying and gets deleted, taking the true positives with it.
  VMSC_BIN_DIR="${VMSC_SANDBOX}/nonexistent-bin"
  export VMSC_BIN_DIR
  export VMSC_SUDO_PROBE="true"
  vmsc_run_gate
  vmsc_fact_is F6-bin-placeable PASS
  [[ "$output" == *"escalation available"* ]]
}

@test "F6 goes red only when BOTH the direct write and the escalation are gone" {
  # An unwritable directory AND no passwordless sudo is the state that produces
  # "install: cannot create regular file '/usr/local/bin/bun': Permission
  # denied". Nothing else is.
  #
  # A NON-EXISTENT directory rather than a chmod'd one, deliberately: chmod a-w
  # does not stop root, and this suite runs as root in the container privilege
  # shape. touch returns ENOENT for root too, so the probe's verdict is the same
  # and the test is not quietly vacuous on one of the three shapes.
  VMSC_BIN_DIR="${VMSC_SANDBOX}/nonexistent-bin"
  export VMSC_BIN_DIR
  export VMSC_SUDO_PROBE="false"
  vmsc_run_gate
  [ "$status" -eq 1 ]
  vmsc_fact_is F6-bin-placeable FAIL
  [[ "$output" == *"Permission denied"* ]]
}

@test "F6 reports which SUDO branch the installers will take" {
  # The disagreement between "writable" and "sudo available" is not trivia: it
  # selects whether install-ci-tools.sh runs its writes bare or elevated, and
  # therefore which of two code paths the next twenty minutes exercises.
  vmsc_run_gate
  [[ "$output" == *"SUDO will be empty"* ]]
}

# ---------------------------------------------------------------------------
# Fact 7 — /opt/signalloom. Currently violated on sl-demo-1-vm.
# ---------------------------------------------------------------------------

@test "F7b goes red when the report directory does not exist" {
  # Measured on sl-demo-1-vm 2026-08-20: /opt/signalloom/reports does not exist,
  # and /opt/signalloom itself is root:root and unwritable by the login user —
  # so demo-up.sh:111's REMOTE_LOG=/opt/signalloom/demo-pipeline.log cannot be
  # created either. This fact is live-failing today.
  rmdir "${VMSC_SANDBOX}/work/reports"
  vmsc_run_gate
  [ "$status" -eq 1 ]
  vmsc_fact_is F7b-reports-writable FAIL
  [[ "$output" == *"DOES NOT EXIST"* ]]
}

@test "F7 distinguishes 'missing' from 'present but unwritable'" {
  # Different failures, different fixes: mkdir versus chown. A gate that
  # reported both as "not usable" would send the operator to the wrong command.
  if [ "$(id -u)" -eq 0 ]; then
    skip "runs as root; chmod cannot make a directory unwritable to uid 0"
  fi
  chmod a-w "${VMSC_SANDBOX}/work/reports"
  vmsc_run_gate
  [ "$status" -eq 1 ]
  vmsc_fact_is F7b-reports-writable FAIL
  [[ "$output" == *"NOT writable"* ]]
  [[ "$output" != *"reports: DOES NOT EXIST"* ]]
}

@test "F7a and F7b are independent, so one cannot vouch for the other" {
  # The work root is writable while the report dir is not. A gate that probed
  # only the parent would call this healthy — and /opt/signalloom is exactly
  # that shape on the live VM: parent root-owned, repo/ writable, reports/ absent.
  rmdir "${VMSC_SANDBOX}/work/reports"
  vmsc_run_gate
  vmsc_fact_is F7a-work-root-writable PASS
  vmsc_fact_is F7b-reports-writable FAIL
}

# ---------------------------------------------------------------------------
# Fact 8 — docker. The other check where the obvious answer is wrong.
# ---------------------------------------------------------------------------

@test "F8 goes red when docker is present but cannot reach the daemon" {
  # The state getent cannot see. Group membership is granted on FIRST OS Login,
  # so /etc/group lists the user immediately while the RUNNING session's
  # credentials, fixed at login, do not carry the group. `getent group docker`
  # passes; docker fails.
  vmsc_stub_broken docker "permission denied while trying to connect to the Docker daemon socket" 1
  vmsc_run_gate
  [ "$status" -eq 1 ]
  vmsc_fact_is F8-docker-usable FAIL
  [[ "$output" == *"permission denied"* ]]
}

@test "F8 tells the operator to reconnect rather than re-run usermod" {
  # The remedy matters as much as the detection. usermod has already run and
  # succeeded; running it again changes nothing, because the group cannot be
  # added to a process that has already started. A new session is the fix.
  vmsc_stub_broken docker "permission denied" 1
  vmsc_run_gate
  [[ "$output" == *"reconnect"* ]]
}

@test "F8 does not consult group membership, which passes while docker fails" {
  # An anti-criterion, and it has to be asserted against the SOURCE because it
  # is a statement about a mechanism NOT being used — the one class a black-box
  # run cannot see.
  #
  # It matches an INVOCATION, not a mention, and the distinction is the whole
  # test. The first version counted `getent` anywhere outside a comment and
  # failed on the gate's own remedy text, which tells the operator to compare
  # `getent group docker` against `id -nG` — advice that is correct, useful, and
  # not a probe. A guard that cannot tell a command from a word about a command
  # gets satisfied by prose in one direction and deleted in the other.
  #
  # So: getent at a command position — line start, or after a separator, or in
  # a substitution. Quoted inside a message string it is preceded by a quote and
  # does not match.
  offenders="$(grep -vE '^[[:space:]]*#' "${VMSC_GATE}" \
    | grep -cE '(^|[;&|]|\$\()[[:space:]]*getent[[:space:]]' || true)"
  [ "${offenders}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Reporting contract
# ---------------------------------------------------------------------------

@test "every failure is reported, not just the first" {
  # The stated problem is a pipeline that dies at stage 2 of 8 after twenty
  # minutes. A gate that stops at its own first failure reproduces that shape
  # exactly, one fix per forty-minute run.
  vmsc_remove_tool node
  vmsc_remove_tool bun
  vmsc_remove_tool uv
  vmsc_run_gate
  [ "$status" -eq 1 ]
  vmsc_fact_is F3-node-runnable FAIL
  vmsc_fact_is F4-bun-runnable FAIL
  vmsc_fact_is F5-uv-runnable FAIL
  [[ "$output" == *"3 of 9 facts"* ]]
}

@test "every failure carries a remedy naming what to do" {
  vmsc_remove_tool bun
  vmsc_run_gate
  [[ "$output" == *"-> "* ]]
}

@test "json output is emitted and carries the failure count" {
  vmsc_remove_tool bun
  vmsc_run_gate --format json
  [ "$status" -eq 1 ]
  [[ "$output" == *'"failed":1'* ]]
  [[ "$output" == *'"total":9'* ]]
  [[ "$output" == *'"id":"F4-bun-runnable","status":"FAIL"'* ]]
}

@test "json output parses" {
  vmsc_run_gate --format json
  printf '%s' "$output" | python3 -c 'import json,sys; json.load(sys.stdin)'
}

@test "a missing pin source is a harness error, not eight facts silently becoming seven" {
  # Facts 1 and 2 derive their versions from demo-vm.sh. If that file moves, a
  # gate that degraded them to "skipped" would report PASS on a machine it had
  # not checked — the vacuous pass this repo keeps rediscovering. Exit 2 is a
  # distinct status from 1 so a caller can tell "the VM is wrong" from "the gate
  # could not run".
  export VMSC_PIN_FILE="${VMSC_SANDBOX}/no-such-file.sh"
  vmsc_run_gate
  [ "$status" -eq 2 ]
  [[ "$output" == *"HARNESS ERROR"* ]]
}

@test "an unknown --format is refused rather than silently treated as text" {
  vmsc_run_gate --format yaml
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Discrimination — the property that separates a gate from a decoration
# ---------------------------------------------------------------------------

@test "the gate returns DIFFERENT verdicts on two differently-configured machines" {
  # A gate that returns the same answer on every box is measuring nothing, and
  # this repo has shipped that shape repeatedly — 33 unclaimed bats suites, a
  # doctor whose "7 missing images" read identically on pass and fail, a
  # staleness guard that said VERIFIED FRESH beside a 25-hour-stale workload.
  # Green on a good machine proves nothing on its own; the pair does.
  #
  # This encodes the live measurement of 2026-08-20. sl-demo-1-vm reported 5
  # failures and sl-demo-2-vm reported 2, and the three facts that differ are
  # exactly the three ways demo-2 differs from demo-1. Two sandboxes are built
  # here with that same delta and the verdicts are diffed against each other
  # rather than against a hardcoded list, so the test states a RELATIONSHIP
  # between two runs and cannot be satisfied by one lucky run.

  # The demo-2 shape: everything present.
  vmsc_run_gate
  good="$(vmsc_status_map)"

  # The demo-1 shape: node never installed, and /opt/signalloom root-owned so
  # neither the work root nor the report dir is usable. Non-existent paths
  # rather than chmod, so the test is not vacuous when run as root.
  vmsc_remove_tool node
  export VMSC_WORK_ROOT="${VMSC_SANDBOX}/no-such-work-root"
  export VMSC_REPORT_DIR="${VMSC_SANDBOX}/no-such-work-root/reports"
  vmsc_run_gate
  bad="$(vmsc_status_map)"

  [ "$good" != "$bad" ]

  # The differing facts, named. `comm -3` on two sorted maps yields exactly the
  # lines that changed.
  differing="$(comm -3 <(printf '%s\n' "$good") <(printf '%s\n' "$bad") \
    | awk '{print $1}' | sort -u | tr '\n' ' ')"
  [ "$differing" = "F3-node-runnable F7a-work-root-writable F7b-reports-writable " ]

  # And nothing else moved. bun and uv failed on BOTH live VMs — they are the
  # defect that is still open — so they must be identical across the pair, or
  # the delta above is being reported for the wrong reason.
  printf '%s\n' "$good" | grep -q '^F4-bun-runnable PASS$'
  printf '%s\n' "$bad"  | grep -q '^F4-bun-runnable PASS$'
}

@test "docker is the one fact that cannot be observed after the fact" {
  # Fact 8's hazard is real and TIME-BOUNDED, and that is worth writing down
  # because it makes the fact look redundant when it is not.
  #
  # The docker group is granted on FIRST OS Login. Only the session that spans
  # that grant sees /etc/group carrying the user while its own credentials do
  # not. Every LATER session picks the group up at login and passes. So on both
  # live VMs today F8 reads PASS — not because the hazard is absent, but
  # because the window has closed and cannot be reopened by observation.
  #
  # The consequence for placement: this fact is only worth anything if the gate
  # runs EARLY in the first session after provisioning. Run late it is a
  # tautology. The suite can still prove the probe discriminates, which is what
  # this asserts, but no live run can confirm it on a warm box.
  vmsc_run_gate
  vmsc_fact_is F8-docker-usable PASS
  vmsc_stub_broken docker "permission denied while trying to connect" 1
  vmsc_run_gate
  vmsc_fact_is F8-docker-usable FAIL
}

@test "the gate reads exit status from the probe itself, never from a pipeline tail" {
  # An anti-criterion with a live provenance: diagnosing this very bug,
  # `touch /x 2>&1 | head -1 && echo WRITABLE` printed WRITABLE against a failed
  # touch, because $? belonged to head. Any `touch ... |` in this gate is that
  # defect. Comments are stripped first — this file and the gate both discuss
  # the trap in prose, and prose is not a pipeline.
  offenders="$(grep -vE '^[[:space:]]*#' "${VMSC_GATE}" | grep -cE 'touch [^|]*\|' || true)"
  [ "${offenders}" -eq 0 ]
}
