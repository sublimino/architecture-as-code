#!/usr/bin/env bats
#
# terraform-four-lane-loop.bats — the loop harness that destroys and rebuilds
# four estates N times, and the guards that stop it reporting a green run it did
# not have.
#
# WHAT THIS SUITE IS ABOUT
#
# scripts/gcp-tf/four-lane-loop.sh drives sixty state transitions per run. Nobody
# watches sixty transitions, so every claim it makes has to be derived from a
# recorded artefact rather than from what the operator remembers. This suite is
# about the derivation, not about the cloud: the four things that can turn a real
# failure into a reported success are a lane whose exit code was never recorded,
# a pipe that swallows a status, a verdict taken from the driver instead of from
# the report, and a create launched into an estate that is still standing.
#
# NOTHING HERE TOUCHES GCP. Every test drives the script's functions against
# fixture trees with `gcloud` and `make` stubbed on PATH. The driver itself is
# never run — it destroys live infrastructure — which is why the driver sits
# behind a `BASH_SOURCE[0] == $0` guard and every function it calls is reachable
# by sourcing the REAL file. Testing a sed-extracted copy of these functions
# would be testing a second implementation, which proves nothing about the one
# that runs.
#
# The name matters: the gate discovers suites with `wildcard test/terraform-*.bats`
# (GCP_TF_BATS in the Makefile), so `terraform-` is what makes this run at all.

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  export MAKEFILE="${REPO_ROOT}/Makefile"
  export SCRIPT="${REPO_ROOT}/scripts/gcp-tf/four-lane-loop.sh"
  export DELEGATE="${REPO_ROOT}/scripts/gcp-tf/worktree-bootstrap.sh"
}

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

# Run a snippet with the REAL script sourced. Safe by construction: the driver
# is behind the executed-not-sourced guard, so sourcing defines the functions and
# runs none of them. Extra `VAR=value` arguments are placed in the environment.
drive() {
  local body="$1"; shift
  run env FOUR_LANE_OUT="${BATS_TEST_TMPDIR}/out" "$@" bash -c "
    source '${SCRIPT}' || { echo 'SOURCE FAILED'; exit 90; }
    ${body}
  "
}

# A fixture repo tree carrying the untracked operational state, as an operator's
# checkout carries it. Values are obviously fake — a real project id in a test
# fixture is how one ends up in a tracked file.
make_tree() {
  local d="${BATS_TEST_TMPDIR}/tree${1:-}"
  mkdir -p "${d}/deploy/gcp" "${d}/.keys" "${d}/afm"
  printf 'deployer@acme-real-project-42.iam.gserviceaccount.com\n' >"${d}/deploy/gcp/deploy-sa"
  printf 'project_id = "acme-real-project-42"\n' >"${d}/deploy/gcp/bootstrap.tfvars"
  printf 'project_id = "acme-real-project-42"\n' >"${d}/deploy/gcp/sl-port-over-sandbox.tfvars"
  printf 'not-a-real-key\n' >"${d}/.keys/cosign.key"
  printf '%s' "$d"
}

# A PATH directory for stubs. Returned so a test can add more.
make_bin() {
  local b="${BATS_TEST_TMPDIR}/bin${1:-}"
  mkdir -p "$b"
  printf '%s' "$b"
}

# ---------------------------------------------------------------------------
# The reconciliation: one implementation of "is the untracked state present"
# ---------------------------------------------------------------------------

@test "the preflight delegates to worktree-bootstrap.sh rather than checking for itself" {
  # scripts/gcp-tf/worktree-bootstrap.sh already owns this invariant, with its own
  # suite and mutation proof. A second copy in the loop harness is the drift this
  # repo punishes, and the copy that was here had already diverged — it checked
  # `.keys/cosign.key` where the manifest checks `.keys`.
  run grep -c 'worktree-bootstrap.sh' "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "the loop harness carries no second copy of the manifest's paths" {
  # The negative half. Stated with a positive control immediately below it,
  # because a grep that finds nothing and a grep pointed at the wrong file are
  # the same observation.
  run grep -c 'deploy/gcp/deploy-sa' "${SCRIPT}"
  [ "$output" -eq 0 ]
  run grep -c 'deploy/gcp/bootstrap.tfvars' "${SCRIPT}"
  [ "$output" -eq 0 ]

  # POSITIVE CONTROL: those exact strings are findable by this grep — they live
  # in the delegate. Without this, the two assertions above would also pass
  # against a file that does not exist.
  run grep -c 'deploy/gcp/deploy-sa' "${DELEGATE}"
  [ "$output" -ge 1 ]
  run grep -c 'deploy/gcp/bootstrap.tfvars' "${DELEGATE}"
  [ "$output" -ge 1 ]
}

@test "the preflight calls check, not gate — gate is a no-op outside a worktree" {
  # `gate` returns 0 unconditionally when it is not in a linked worktree, and
  # this loop is normally driven FROM the main checkout, where a missing
  # deploy-sa still costs a full apply. A preflight wired to `gate` would pass
  # here and the test could not tell the difference any other way: the fixture
  # tree is not a git worktree at all.
  local t; t="$(make_tree A)"
  rm -f "${t}/deploy/gcp/deploy-sa"
  drive "REPO_ROOT='${t}' KUBESEC_AFM_ROOT='${t}/afm' preflight"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"deploy-sa"* ]]
}

# ---------------------------------------------------------------------------
# The preflight refuses a tree missing each required file, and NAMES it
# ---------------------------------------------------------------------------

@test "preflight passes on a complete tree" {
  # The control for every refusal below. Without it, a preflight that refused
  # unconditionally would satisfy all of them.
  local t; t="$(make_tree B)"
  drive "REPO_ROOT='${t}' KUBESEC_AFM_ROOT='${t}/afm' preflight"
  [ "$status" -eq 0 ]
}

@test "preflight refuses a tree missing deploy/gcp/deploy-sa and names it" {
  # The expensive one: its absence lets gcp-tf-up complete a full successful
  # apply and then fail in gcp-tf-handoff blaming terraform outputs.
  local t; t="$(make_tree C)"
  rm -f "${t}/deploy/gcp/deploy-sa"
  drive "REPO_ROOT='${t}' KUBESEC_AFM_ROOT='${t}/afm' preflight"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"MISSING"* ]]
  [[ "${output}" == *"deploy/gcp/deploy-sa"* ]]
}

@test "preflight refuses a tree missing deploy/gcp/bootstrap.tfvars and names it" {
  local t; t="$(make_tree D)"
  rm -f "${t}/deploy/gcp/bootstrap.tfvars"
  drive "REPO_ROOT='${t}' KUBESEC_AFM_ROOT='${t}/afm' preflight"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"deploy/gcp/bootstrap.tfvars"* ]]
}

@test "preflight refuses a tree missing the lane tfvars it exports as GCP_TF_VAR_FILE" {
  # The manifest marks this optional on purpose — gcp-tf-up in a main checkout
  # without it is supported. This loop passes it as GCP_TF_VAR_FILE, so for THIS
  # caller it is mandatory. That difference is a parameter, not a second guard.
  local t; t="$(make_tree E)"
  rm -f "${t}/deploy/gcp/sl-port-over-sandbox.tfvars"
  drive "REPO_ROOT='${t}' KUBESEC_AFM_ROOT='${t}/afm' preflight"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"sl-port-over-sandbox.tfvars"* ]]
}

@test "the lane-tfvars requirement FOLLOWS GCP_TF_VAR_FILE rather than repeating it" {
  # Two hardcoded spellings of one filename is how they stop agreeing. Point
  # GCP_TF_VAR_FILE somewhere else and the preflight must demand THAT file.
  local t; t="$(make_tree F)"
  drive "REPO_ROOT='${t}' KUBESEC_AFM_ROOT='${t}/afm' preflight" \
    GCP_TF_VAR_FILE=../../deploy/gcp/some-other-lane.tfvars
  [ "$status" -ne 0 ]
  [[ "${output}" == *"some-other-lane.tfvars"* ]]
  # And it is no longer demanding the default, which the tree does carry.
  [[ "${output}" != *"MISSING  deploy/gcp/sl-port-over-sandbox.tfvars"* ]]
}

@test "preflight refuses a tree missing .keys/cosign.key and names it" {
  local t; t="$(make_tree G)"
  rm -f "${t}/.keys/cosign.key"
  drive "REPO_ROOT='${t}' KUBESEC_AFM_ROOT='${t}/afm' preflight"
  [ "$status" -ne 0 ]
  [[ "${output}" == *".keys/cosign.key"* ]]
}

@test "preflight refuses an unresolvable KUBESEC_AFM_ROOT and names the path" {
  # A set-but-nonexistent KUBESEC_AFM_ROOT is the case the delegate deliberately
  # does not warn about on its own ("a set KUBESEC_AFM_ROOT is not second-guessed"),
  # because for gcp-tf-up it does not gate terraform. For this loop it does gate
  # the estate stage, and the abort lands LATE — after a multi-hundred-MB archive
  # has been built. So this caller declares it required.
  local t; t="$(make_tree H)"
  drive "REPO_ROOT='${t}' KUBESEC_AFM_ROOT='${t}/no-such-afm' preflight"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"no-such-afm"* ]]
}

@test "preflight names every missing file at once, not just the first" {
  # Discovering these one refusal at a time is four round trips through a
  # preflight that exists to save round trips.
  local t; t="$(make_tree I)"
  rm -f "${t}/deploy/gcp/deploy-sa" "${t}/.keys/cosign.key"
  drive "REPO_ROOT='${t}' KUBESEC_AFM_ROOT='${t}/afm' preflight"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"deploy/gcp/deploy-sa"* ]]
  [[ "${output}" == *".keys/cosign.key"* ]]
}

@test "preflight states the consequence of each missing file" {
  # A guard that says only "file absent" invites "so what?" and gets bypassed.
  local t; t="$(make_tree J)"
  rm -f "${t}/deploy/gcp/deploy-sa"
  drive "REPO_ROOT='${t}' KUBESEC_AFM_ROOT='${t}/afm' preflight"
  [[ "${output}" == *"Consequence:"* ]]
}

@test "preflight REFUSES when the delegate is missing, rather than skipping it" {
  # Observed for real in this repo on the worktree-bootstrap guard: an earlier
  # draft skipped itself when its script was absent, and a fresh worktree sailed
  # straight past into terraform. A guard whose absence is indistinguishable
  # from its success is not a guard. The tree here is COMPLETE, so the only
  # possible cause of a refusal is the missing delegate.
  local t; t="$(make_tree K)"
  drive "REPO_ROOT='${t}' KUBESEC_AFM_ROOT='${t}/afm' WORKTREE_SCRIPT=/nonexistent/worktree-bootstrap.sh preflight"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"Refusing rather than skipping"* ]]
  [[ "${output}" == *"/nonexistent/worktree-bootstrap.sh"* ]]
}

# ---------------------------------------------------------------------------
# fan_out — a lane whose exit code was never recorded is the dangerous lane
# ---------------------------------------------------------------------------

@test "fan_out records a per-lane exit code for EVERY lane, including the failures" {
  local out="${BATS_TEST_TMPDIR}/out"
  drive "
    LANES=(a b c d)
    lane() { case \"\$1\" in b) return 4;; d) return 9;; *) return 0;; esac; }
    fan_out probe 1 lane
    echo \"fan_out=\$?\"
    echo '--rc--'; sort '${out}/c1-probe.rc'
  "
  [[ "${output}" == *"a=0"* ]]
  [[ "${output}" == *"b=4"* ]]
  [[ "${output}" == *"c=0"* ]]
  [[ "${output}" == *"d=9"* ]]
}

@test "a non-zero lane exit is not lost: fan_out reports failure" {
  drive "
    LANES=(a b)
    lane() { [ \"\$1\" = b ] && return 4; return 0; }
    fan_out probe 1 lane
    echo \"fan_out=\$?\"
  "
  [[ "${output}" == *"fan_out=1"* ]]
}

@test "fan_out reports success when every lane succeeded" {
  # The positive control for the test above. Without it, a fan_out that returned
  # non-zero unconditionally would satisfy it.
  drive "
    LANES=(a b)
    lane() { return 0; }
    fan_out probe 1 lane
    echo \"fan_out=\$?\"
  "
  [[ "${output}" == *"fan_out=0"* ]]
}

@test "a lane that records NOTHING is refused, not read as success" {
  # The failure mode that matters most and is easiest to ship: a results file
  # short of one lane. `kill -9 $BASHPID` inside the lane subshell reproduces it
  # exactly — the command dies before fan_out's `echo "$e=$?"` ever runs, which
  # is what a lane killed by the OOM killer or a hard timeout looks like.
  drive "
    LANES=(a ghost c)
    lane() { [ \"\$1\" = ghost ] && kill -9 \$BASHPID; return 0; }
    fan_out probe 1 lane
    echo \"fan_out=\$?\"
  " 2>/dev/null
  [[ "${output}" == *"REFUSING"* ]]
  [[ "${output}" == *"2 of 3 lanes recorded"* ]]
  [[ "${output}" == *"fan_out=1"* ]]
}

@test "an empty results file does not read as success either" {
  # The degenerate case of the same defect. The previous implementation computed
  # `grep -cv '=0$' file || echo 0`, which on an empty file yields the TWO-line
  # string "0\n0" — grep -c both prints 0 and exits 1, so the `||` fires as well
  # — and `$(( "0\n0" > 0 ))` is a bash syntax error. Measured, not assumed.
  # Here the results file is pre-created read-only so no lane can write to it.
  local out="${BATS_TEST_TMPDIR}/out"
  mkdir -p "$out"
  : >"${out}/c1-probe.rc"
  chmod 0444 "${out}/c1-probe.rc"
  drive "
    LANES=(a b)
    lane() { return 0; }
    fan_out probe 1 lane
    echo \"fan_out=\$?\"
  " 2>/dev/null
  [[ "${output}" == *"fan_out=1"* ]]
  [[ "${output}" != *"syntax error"* ]]
}

@test "fan_out captures each lane's output in its own log" {
  local out="${BATS_TEST_TMPDIR}/out"
  drive "
    LANES=(a b)
    lane() { echo \"output-from-\$1\"; return 0; }
    fan_out probe 7 lane >/dev/null
    cat '${out}/c7-probe-a.log' '${out}/c7-probe-b.log'
  "
  [[ "${output}" == *"output-from-a"* ]]
  [[ "${output}" == *"output-from-b"* ]]
}

@test "each phase gets its own results file, so one phase cannot vouch for another" {
  local out="${BATS_TEST_TMPDIR}/out"
  drive "
    LANES=(a)
    good() { return 0; }
    bad()  { return 5; }
    fan_out up 1 good; echo \"up=\$?\"
    fan_out estate 1 bad; echo \"estate=\$?\"
    echo \"up-rc=\$(cat '${out}/c1-up.rc')\"
    echo \"estate-rc=\$(cat '${out}/c1-estate.rc')\"
  "
  [[ "${output}" == *"up=0"* ]]
  [[ "${output}" == *"estate=1"* ]]
  [[ "${output}" == *"up-rc=a=0"* ]]
  [[ "${output}" == *"estate-rc=a=5"* ]]
}

# ---------------------------------------------------------------------------
# The destroy pipeline — `yes yes`, and the PIPESTATUS index
# ---------------------------------------------------------------------------

@test "the destroy answers \"yes\", not \"y\"" {
  # `yes` emits "y". terraform requires exactly "yes" and answers
  # "Destroy cancelled" to anything else — a destroy that appears to run, does
  # nothing, and leaves the estate standing for the next create to deadlock on.
  # Observed directly: the stub records what actually arrived on its stdin.
  local t; t="$(make_tree L)"; local b; b="$(make_bin L)"
  cat >"${b}/make" <<EOF
#!/usr/bin/env bash
read -r line
printf '%s\n' "\$line" >'${BATS_TEST_TMPDIR}/answer.txt'
exit 0
EOF
  chmod +x "${b}/make"
  drive "REPO_ROOT='${t}'; do_destroy demo-1; echo \"rc=\$?\"" PATH="${b}:${PATH}"
  [ -f "${BATS_TEST_TMPDIR}/answer.txt" ]
  run cat "${BATS_TEST_TMPDIR}/answer.txt"
  [ "$output" = "yes" ]
}

@test "a successful destroy is not reported as a failure by SIGPIPE" {
  # This is what ${PIPESTATUS[1]} buys. The script sets `set -o pipefail`, and
  # terraform stops reading stdin long before `yes` stops writing, so `yes` dies
  # of SIGPIPE with 141. Under pipefail the PIPELINE therefore reports 141 even
  # when make exited 0. Measured: `yes yes | make` with make exiting 0 returns
  # 141. Taking the status from element [1] — make — is what makes a successful
  # destroy report success.
  local t; t="$(make_tree M)"; local b; b="$(make_bin M)"
  cat >"${b}/make" <<'EOF'
#!/usr/bin/env bash
# Exits immediately without draining stdin, exactly as terraform does once it
# has read the confirmation.
exit 0
EOF
  chmod +x "${b}/make"
  drive "REPO_ROOT='${t}'; do_destroy demo-1; echo \"rc=\$?\"" PATH="${b}:${PATH}"
  [[ "${output}" == *"rc=0"* ]]
}

@test "the PIPESTATUS index selects make, not \`yes\`" {
  # The header comment on this script used to say [0]. [0] is `yes`. A future
  # maintainer "correcting" the index to match that comment turns every
  # successful destroy into a 141. Proven by making the two elements
  # distinguishable: `yes` exits 42, make exits 0.
  local t; t="$(make_tree N)"; local b; b="$(make_bin N)"
  cat >"${b}/yes" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${1:-y}"
exit 42
EOF
  cat >"${b}/make" <<'EOF'
#!/usr/bin/env bash
# Reads the confirmation and stops. NEVER `cat >/dev/null` in a stub on the
# receiving end of `yes` — `yes` is an infinite generator and the pair spins
# forever, which presents as a hung test suite rather than a failing one.
read -r _ || true
exit 0
EOF
  chmod +x "${b}/yes" "${b}/make"
  drive "REPO_ROOT='${t}'; do_destroy demo-1; echo \"rc=\$?\"" PATH="${b}:${PATH}"
  [[ "${output}" == *"rc=0"* ]]
  [[ "${output}" != *"rc=42"* ]]
}

@test "a failing destroy IS reported as a failure" {
  # The positive control for both tests above: neither proves anything if
  # do_destroy returns 0 no matter what make did.
  local t; t="$(make_tree O)"; local b; b="$(make_bin O)"
  cat >"${b}/make" <<'EOF'
#!/usr/bin/env bash
read -r _ || true
exit 7
EOF
  chmod +x "${b}/make"
  drive "REPO_ROOT='${t}'; do_destroy demo-1; echo \"rc=\$?\"" PATH="${b}:${PATH}"
  [[ "${output}" == *"rc=7"* ]]
}

@test "the destroy pipeline is written with \`yes yes\`, not a bare \`yes\`" {
  # The structural half. Kept alongside the behavioural test above because the
  # behavioural one pins the ANSWER and this one pins the SPELLING that produces
  # it, and a reader editing this line sees the assertion.
  run grep -c 'yes yes | make gcp-tf-destroy' "${SCRIPT}"
  [ "$output" -eq 1 ]
  run grep -c 'PIPESTATUS\[1\]' "${SCRIPT}"
  [ "$output" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Capacity — four lanes at the 8-vCPU floor need exactly 32 of a 32-CPU quota
# ---------------------------------------------------------------------------

@test "capacity is free when the estate is genuinely empty" {
  local b; b="$(make_bin P)"
  cat >"${b}/gcloud" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${b}/gcloud"
  drive "wait_for_capacity; echo \"rc=\$?\"" PATH="${b}:${PATH}" CAPACITY_TRIES=1 CAPACITY_SLEEP=0
  [[ "${output}" == *"capacity free (0 instances)"* ]]
  [[ "${output}" == *"rc=0"* ]]
}

@test "capacity is NOT free while instances are still standing" {
  local b; b="$(make_bin Q)"
  cat >"${b}/gcloud" <<'EOF'
#!/usr/bin/env bash
printf 'demo-1-node\ndemo-2-node\n'
exit 0
EOF
  chmod +x "${b}/gcloud"
  drive "wait_for_capacity; echo \"rc=\$?\"" PATH="${b}:${PATH}" CAPACITY_TRIES=2 CAPACITY_SLEEP=0
  [[ "${output}" == *"2 instance(s) still present"* ]]
  [[ "${output}" == *"rc=1"* ]]
}

@test "a FAILING gcloud is not read as an empty estate" {
  # The defect this guard was carrying: `gcloud ... 2>/dev/null | wc -l` reports
  # 0 for an expired credential exactly as it does for an empty project, so
  # "capacity free (0 instances)" gets announced on the strength of an error and
  # four applies are launched into an estate that is still standing. Measured:
  # a non-existent gcloud through that pipeline yields n=0.
  local b; b="$(make_bin R)"
  cat >"${b}/gcloud" <<'EOF'
#!/usr/bin/env bash
echo 'ERROR: (gcloud.compute.instances.list) reauthentication required' >&2
exit 1
EOF
  chmod +x "${b}/gcloud"
  drive "wait_for_capacity; echo \"rc=\$?\"" PATH="${b}:${PATH}" CAPACITY_TRIES=1 CAPACITY_SLEEP=0
  [[ "${output}" != *"capacity free"* ]]
  [[ "${output}" == *"capacity UNKNOWN"* ]]
  [[ "${output}" == *"rc=1"* ]]
}

@test "capacity is verified free BEFORE any create — no create happens otherwise" {
  # End to end through the real driver, with make and gcloud stubbed. The stub
  # make records every target it was asked for, so "gcp-tf-up did not run" is an
  # observation rather than an inference.
  local t; t="$(make_tree S)"; local b; b="$(make_bin S)"
  local calls="${BATS_TEST_TMPDIR}/calls-S.txt"
  cat >"${b}/make" <<EOF
#!/usr/bin/env bash
read -r _ >/dev/null 2>&1 || true
printf '%s\n' "\$*" >>'${calls}'
exit 0
EOF
  cat >"${b}/gcloud" <<'EOF'
#!/usr/bin/env bash
printf 'demo-1-node\n'
exit 0
EOF
  chmod +x "${b}/make" "${b}/gcloud"
  cat >"${b}/wt-stub.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${b}/wt-stub.sh"

  run env FOUR_LANE_OUT="${BATS_TEST_TMPDIR}/outS" PATH="${b}:${PATH}" \
    CAPACITY_TRIES=1 CAPACITY_SLEEP=0 WORKTREE_SCRIPT="${b}/wt-stub.sh" \
    bash -c "source '${SCRIPT}' 1 demo-1; REPO_ROOT='${t}'; four_lane_main"

  [[ "${output}" == *"ABORTED: capacity not confirmed free"* ]]
  grep -q 'result=CAPACITY_NOT_FREE' "${BATS_TEST_TMPDIR}/outS/summary.txt"

  # POSITIVE CONTROL: the recording mechanism works and make really ran — the
  # destroy is in the log. Without this, "gcp-tf-up is absent" would also be
  # satisfied by a log that was never written.
  grep -q 'gcp-tf-destroy' "${calls}"
  run grep -c 'gcp-tf-up' "${calls}"
  [ "$output" -eq 0 ]
}

@test "the create DOES happen once capacity is confirmed free" {
  # The positive control for the test above: it proves nothing if the driver
  # never reaches gcp-tf-up under any conditions.
  local t; t="$(make_tree T)"; local b; b="$(make_bin T)"
  local calls="${BATS_TEST_TMPDIR}/calls-T.txt"
  cat >"${b}/make" <<EOF
#!/usr/bin/env bash
read -r _ >/dev/null 2>&1 || true
printf '%s\n' "\$*" >>'${calls}'
exit 0
EOF
  cat >"${b}/gcloud" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${b}/make" "${b}/gcloud"
  cat >"${b}/wt-stub.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${b}/wt-stub.sh"

  run env FOUR_LANE_OUT="${BATS_TEST_TMPDIR}/outT" PATH="${b}:${PATH}" \
    CAPACITY_TRIES=1 CAPACITY_SLEEP=0 WORKTREE_SCRIPT="${b}/wt-stub.sh" \
    bash -c "source '${SCRIPT}' 1 demo-1; REPO_ROOT='${t}'; four_lane_main"

  grep -q 'gcp-tf-up' "${calls}"
  run grep -c 'result=CAPACITY_NOT_FREE' "${BATS_TEST_TMPDIR}/outT/summary.txt"
  [ "$output" -eq 0 ]
}

# ---------------------------------------------------------------------------
# The verdict is derived from summary.json, not from the driver's exit code
# ---------------------------------------------------------------------------

@test "the cycle verdict comes from summary.json, not from the driver exit code" {
  # An ABORTED run and a run whose tests failed both exit non-zero and mean very
  # different things. Here the lane's own report says `fail`, and that is what
  # must be recorded — the estate and doctor phases swallow their status with
  # `|| true`, so the driver's own view of this cycle is "fine".
  local t; t="$(make_tree U)"
  mkdir -p "${t}/demo-reports/demo-1"
  printf '{"outcome":"fail","phase":"tests","passed":21,"total_stages":29}\n' \
    >"${t}/demo-reports/demo-1/summary.json"
  local out="${BATS_TEST_TMPDIR}/outU"
  run env FOUR_LANE_OUT="${out}" bash -c "
    source '${SCRIPT}'
    REPO_ROOT='${t}'; LANES=(demo-1)
    record_verdicts 3
    cat '${out}/summary.txt'
  "
  [[ "${output}" == *"cycle=3 lane=demo-1 fail phase=tests 21/29"* ]]
}

@test "a passing report is recorded as passing" {
  # Positive control: the test above is satisfied by a recorder that writes
  # "fail" unconditionally.
  local t; t="$(make_tree V)"
  mkdir -p "${t}/demo-reports/demo-1"
  printf '{"outcome":"pass","phase":"complete","passed":29,"total_stages":29}\n' \
    >"${t}/demo-reports/demo-1/summary.json"
  local out="${BATS_TEST_TMPDIR}/outV"
  run env FOUR_LANE_OUT="${out}" bash -c "
    source '${SCRIPT}'
    REPO_ROOT='${t}'; LANES=(demo-1)
    record_verdicts 1
    cat '${out}/summary.txt'
  "
  [[ "${output}" == *"pass phase=complete 29/29"* ]]
}

@test "a lane with no report is recorded as NO-VERDICT, not omitted" {
  # A lane that produced no report is the one most likely to have died early.
  # Dropping its line makes the summary shorter and quieter, which is exactly
  # backwards.
  local t; t="$(make_tree W)"
  local out="${BATS_TEST_TMPDIR}/outW"
  run env FOUR_LANE_OUT="${out}" bash -c "
    source '${SCRIPT}'
    REPO_ROOT='${t}'; LANES=(demo-1 demo-2)
    record_verdicts 2
    cat '${out}/summary.txt'
  "
  [[ "${output}" == *"cycle=2 lane=demo-1 NO-VERDICT"* ]]
  [[ "${output}" == *"cycle=2 lane=demo-2 NO-VERDICT"* ]]
}

@test "an unparseable report is recorded as UNREADABLE-VERDICT, not as a blank" {
  # jq failing leaves the verdict empty, and an empty verdict renders as a line
  # with nothing after the lane name — which reads as "nothing to report".
  local t; t="$(make_tree X)"
  mkdir -p "${t}/demo-reports/demo-1"
  printf 'this is not json at all\n' >"${t}/demo-reports/demo-1/summary.json"
  local out="${BATS_TEST_TMPDIR}/outX"
  run env FOUR_LANE_OUT="${out}" bash -c "
    source '${SCRIPT}'
    REPO_ROOT='${t}'; LANES=(demo-1)
    record_verdicts 1
    cat '${out}/summary.txt'
  "
  [[ "${output}" == *"UNREADABLE-VERDICT"* ]]
  [[ "${output}" != *"cycle=1 lane=demo-1 "$'\n'* ]]
}

@test "record_verdicts writes exactly one line per lane" {
  local t; t="$(make_tree Y)"
  local out="${BATS_TEST_TMPDIR}/outY"
  run env FOUR_LANE_OUT="${out}" bash -c "
    source '${SCRIPT}'
    REPO_ROOT='${t}'; LANES=(a b c d)
    record_verdicts 1
    grep -c . '${out}/summary.txt'
  "
  [[ "${output}" == *"4"* ]]
}

# ---------------------------------------------------------------------------
# The harness is testable at all — and is registered
# ---------------------------------------------------------------------------

@test "the driver is behind an executed-not-sourced guard" {
  # Everything in this suite depends on it. Without the guard, sourcing the
  # script to reach its functions would destroy four live estates, so the suite
  # would have to test a sed-extracted copy instead — a second implementation,
  # whose greenness says nothing about the one that runs.
  run grep -c 'BASH_SOURCE\[0\]}" == "${0}' "${SCRIPT}"
  [ "$output" -eq 1 ]
}

@test "sourcing the script runs no phase at all" {
  # The behavioural half of the assertion above. If any make or gcloud ran on
  # source, the stub would record it.
  local b; b="$(make_bin Z)"
  local calls="${BATS_TEST_TMPDIR}/calls-Z.txt"
  : >"${calls}"
  for c in make gcloud terraform; do
    cat >"${b}/${c}" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "${c}" "\$*" >>'${calls}'
exit 0
EOF
    chmod +x "${b}/${c}"
  done
  run env FOUR_LANE_OUT="${BATS_TEST_TMPDIR}/outZ" PATH="${b}:${PATH}" \
    bash -c "source '${SCRIPT}'; echo sourced-ok"
  [[ "${output}" == *"sourced-ok"* ]]
  run grep -c . "${calls}"
  [ "$output" -eq 0 ]
}

@test "the script is executable, or nothing can run it" {
  [ -x "${SCRIPT}" ]
}

@test "this suite is discovered by the Makefile's glob, not by a hand list" {
  # The registration trap this repo has hit repeatedly: a suite matching no glob
  # and named in no pipeline list runs NOWHERE, green by hand forever.
  run grep -c 'GCP_TF_BATS = \$(sort \$(wildcard test/terraform-\*.bats))' "${MAKEFILE}"
  [ "$output" -eq 1 ]
  case "$(basename "${BATS_TEST_FILENAME}")" in
    terraform-*.bats) ;;
    *) echo "this suite's name is not matched by the gate's glob" >&2; return 1 ;;
  esac
}

@test "the mutation proof for this suite is discovered by the proof glob" {
  run grep -c 'GCP_TF_PROOFS = \$(wildcard test/\*-mutation-proof.sh)' "${MAKEFILE}"
  [ "$output" -eq 1 ]
  [ -f "${REPO_ROOT}/test/four-lane-loop-mutation-proof.sh" ]
  case "four-lane-loop-mutation-proof.sh" in
    *-mutation-proof.sh) ;;
    *) return 1 ;;
  esac
}
