#!/usr/bin/env bash
# node-doctor-mutation-proof.sh — prove test/node-doctor.bats can actually fail.
#
# ─── What is being proved, and why it needed proving ────────────────────────
#
# node-doctor.bats went 55/55 green on its first complete run. For a suite whose
# entire job is to catch checks that pass when they should not, green on the
# first run is the suspicious state, not the reassuring one — it is exactly what
# a suite of assertions that can never fail looks like.
#
# Worse, this suite's subject matter makes it unusually prone to that. Most of
# its tests assert that an adjudicator returns UNKNOWN or FAIL. Those are the
# shape that goes green for the wrong reason: `[ "$(f x)" = "UNKNOWN" ]` passes
# against a correct function, and it passes just as happily against a function
# that has been broken into returning UNKNOWN for everything. Only mutating the
# real implementation and requiring the suite to go RED at a NAMED test
# separates "the suite is watching the logic" from "the suite is watching a
# string it would get anyway".
#
# ─── IT MUTATES THE REAL TREE. NOTHING ELSE MAY TOUCH THE CHECKOUT ──────────
#
# This harness edits scripts/node-doctor/*.sh and scripts/node-doctor.sh in
# place and restores them between mutations. Any concurrent edit or `make` in
# the same checkout lands inside a mutation window and shows up as tests failing
# for reasons that have nothing to do with the mutation under test — a false NOT
# PROVEN that reads precisely like a real finding, which is the expensive part.
#
# Run it alone. In a shared worktree, run it alone and say so.
#
# Run: test/node-doctor-mutation-proof.sh
# Exit 0 = every mutation was caught. Exit 1 = at least one was not.

set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

SUITE="test/node-doctor.bats"
LIB="scripts/node-doctor/lib.sh"
PROBE="scripts/node-doctor/probe.sh"
DEMO="scripts/node-doctor/demo.sh"
CI="scripts/node-doctor/ci.sh"
ENTRY="scripts/node-doctor.sh"
# The SUITE is a mutation target too, for M15 alone. Mutating the tests is
# normally the wrong move — a harness that breaks the test to prove the test
# works has proved nothing — but the refutation HELPER is different: it is
# implementation that every negative assertion depends on, it lives in the test
# file for want of anywhere better, and switching it off silently disables a
# dozen guards at once while they all still read as green assertions.
TARGETS=("$LIB" "$PROBE" "$DEMO" "$CI" "$ENTRY" "$SUITE")

command -v bats >/dev/null 2>&1 || { echo "HARNESS ERROR: bats is not installed" >&2; exit 2; }
for f in "$SUITE" "${TARGETS[@]}"; do
  [[ -f "$f" ]] || { echo "HARNESS ERROR: $f not found" >&2; exit 2; }
done

# ─── The sentinel, now the shared one ───────────────────────────────────────
#
# Matched by `*mutation-in-progress` in .gitignore. Its presence means a
# previous run died holding a mutation, so the tree cannot be trusted to be the
# real thing. REFUSE — never auto-repair. A harness that silently restored what
# it found would make the broken state invisible, which is the same defect as a
# guard that repairs what it detects.
#
# The limit, stated honestly: an EXIT trap survives SIGTERM and does NOT survive
# SIGKILL. A `kill -9` leaves the tree mutated AND leaves the sentinel, which is
# the case it exists for. What the shared rail adds over the hand-rolled version
# it replaces is that a LIVE second run is told apart from a dead one, and that
# a FAILED restore KEEPS the sentinel — the old `cleanup` deleted it
# unconditionally, so a restore that did not work left a mutated tree with
# nothing recording it. See test/helpers/mutation-sentinel.bash.
# shellcheck source=helpers/mutation-sentinel.bash
source "${REPO_ROOT}/test/helpers/mutation-sentinel.bash"

# Still read by the end-of-run content check below.
#
# The matching ORIG_MODE map is gone with the hand-rolled restore that was its
# only consumer: the rail records each file's mode at init and VERIFIES it on
# restore, so a second copy here would be a duplicate that nothing compares.
declare -A ORIG_HASH
for f in "${TARGETS[@]}"; do
  ORIG_HASH["$f"]="$(sha256sum "$f" | cut -d' ' -f1)"
done

ms_guard_init node-doctor "${TARGETS[@]}"
trap ms_guard_on_exit EXIT

# The rail restores content and mode and then VERIFIES both. The old loop did
# the `cp` + `chmod` half and reported nothing.
restore() { ms_guard_restore; }

PASS=0
FAIL=0

# A sed that cannot silently do nothing. A non-matching pattern no-ops while
# printing success, and in a proof harness that ships as "every mutation was
# caught" against a tree that was never mutated.
#
# ms_sed keeps that refusal and adds two things: it tells a sed SYNTAX ERROR
# apart from a pattern that no longer matches, and it ARMS the sentinel before
# touching the file so no call site can forget.
mutate() { ms_sed "$1" "$2"; }

# Appends a line to a file — for the mutations that ADD something forbidden
# rather than break something present. Same no-op refusal as mutate().
#
# An append is not ms_sed, so the sentinel is armed BY HAND and BEFORE the
# write: a kill landing between the append and the assert would otherwise leave
# the file broken with nothing recording it.
append_mutation() {
  local file="$1" line="$2"
  ms_guard_arm "append to ${file}: ${line}"
  printf '%s\n' "$line" >>"$file"
  ms_assert_mutated "$file" ||
    { echo "HARNESS ERROR: append changed nothing in ${file}" >&2; exit 2; }
}

# Reports the NAMES of failing tests, never `not ok <n>` numbers. Inserting a
# test renumbers everything below it, and a harness reporting NOT PROVEN for a
# guard that fired perfectly well is worse than no harness — the natural
# response is to go and "fix" working code.
#
# `|| true` is load-bearing and the omission is a classic: under pipefail a bats
# run that FAILS — which is the outcome every check here wants — makes the
# pipeline non-zero, and the harness dies on its own success.
failing_tests() {
  bats "$SUITE" 2>&1 | sed -n 's/^not ok [0-9]* //p' || true
}

check() {
  local label="$1" want="$2" got
  got="$(failing_tests)"
  if [[ "$got" == *"$want"* ]]; then
    echo "  RED as expected — \"${want}\"  [${label}]"
    PASS=$((PASS + 1))
  else
    echo "  *** NOT PROVEN: expected \"${want}\" to fail. Failures were:" >&2
    printf '        %s\n' "${got:-<none>}" >&2
    FAIL=$((FAIL + 1))
  fi
  restore
}

echo "=== baseline: the suite must be green before any mutation ==="
if ! bats "$SUITE" >/dev/null 2>&1; then
  echo "HARNESS ERROR: suite is not green before mutation" >&2
  bats "$SUITE" 2>&1 | sed -n 's/^not ok [0-9]* //p' | head -20 >&2
  exit 2
fi
echo "  green."
echo

# ─── M1: the zot log check stops looking at the byte count ──────────────────
#
# THE vacuous pass, and the one this whole file is organised around. An
# unreadable log and a healthy log both grep to zero hits; dropping the byte
# count makes the first report as the second, and a registry nobody can see into
# is announced as clean. Every other zot line in the report stays green.
echo "M1  the zot log verdict ignores the byte count (unreadable reads as clean)"
mutate "$LIB" 's|^  if \[ "\$bytes" -eq 0 \]; then printf .UNKNOWN.; return; fi$|  : # MUTATED|'
check "M1 zot log bytes" "ZOT an UNREADABLE log is UNKNOWN, never a clean bill of health"

# ─── M2: the inode agreement always passes ──────────────────────────────────
#
# The unlinked blob store then becomes invisible to the one detector that needs
# no writes and works while the pod is mid-crash.
echo "M2  the zot blob-store inode check can never disagree"
mutate "$LIB" 's|^  if \[ "\$host" = "\$node" \]; then printf .PASS.; else printf .FAIL.; fi$|  printf "PASS"|'
check "M2 zot inode" "ZOT an unlinked blob store is caught by inode disagreement"

# ─── M3: zero clusters becomes acceptable ───────────────────────────────────
#
# The exact regression the CronJob's */30 schedule produces: /afm/health answers
# 200, the platform holds nothing, and the doctor agrees that everything is fine.
echo "M3  zero imported clusters is treated as healthy"
mutate "$LIB" "s|^    0)                   printf 'FAIL' ;;\$|    0)                   printf 'PASS' ;;|"
check "M3 zero clusters" "AFM zero clusters is a FAIL even when the health endpoint answers 200"

# ─── M4: the MagicDNS check degrades to a prefix match ──────────────────────
#
# The likely shape of a well-meaning future edit, and it re-admits sl-demo-1-1 —
# a node that resolves, serves and answers 200 while being the wrong node.
echo "M4  the MagicDNS name check accepts a prefix instead of requiring equality"
mutate "$LIB" 's|^  if \[ "\$first_label" = "\$expect_host" \]; then printf .PASS.; else printf .FAIL.; fi$|  case "$first_label" in "${expect_host}"*) printf "PASS" ;; *) printf "FAIL" ;; esac|'
check "M4 magicdns prefix" "TSNAME a suffixed name is REJECTED, not accepted as a prefix match"

# ─── M5: SUSPENDED passes on both kinds ─────────────────────────────────────
#
# The lane-kind distinction collapsed. A demo VM that something switched off
# mid-presentation is reported as healthy, because a CI VM in the same state
# would be.
echo "M5  SUSPENDED is a pass regardless of the lane kind"
mutate "$LIB" 's|^      if \[ "\$kind" = "ci" \]; then printf .PASS.; else printf .FAIL.; fi ;;$|      printf "PASS" ;;|'
check "M5 suspended kind" "LANE a demo lane found SUSPENDED is a FAIL, because nothing should suspend it"

# ─── M6: UNKNOWN is laundered into a pass ───────────────────────────────────
#
# The single most damaging mutation available here, because it does not break a
# check — it breaks the REPORTING of every check that could not run. A lane
# nobody measured exits 0 and prints HEALTHY.
echo "M6  a run with UNKNOWNs and no failures exits 0 and calls itself healthy"
mutate "$LIB" 's|^  elif \[ "\$ND_UNKNOWN" -gt 0 \][[:space:]]*; *then verdict=UNKNOWN;[[:space:]]*rc=3$|  elif false; then verdict=UNKNOWN; rc=3|'
check "M6 unknown laundered" "SUMMARY an UNKNOWN with no failures exits 3, and is NOT reported as a pass"

# ─── M7: the push check drops the read-back ─────────────────────────────────
#
# "Accepted" substituted for "stored". A store that 201s and holds nothing is
# the defect's whole character, so this is the mutation that keeps the check
# looking present while removing the only part that can see it.
echo "M7  a blob PUT is accepted without confirming the blob can be read back"
mutate "$LIB" 's|^  if \[ "\$put_code" = "201" \] && \[ "\$head_code" = "200" \]; then printf .PASS.; else printf .FAIL.; fi$|  if [ "$put_code" = "201" ]; then printf "PASS"; else printf "FAIL"; fi|'
check "M7 push readback" "ZOT a 201 the registry cannot then serve back is NOT a successful push"

# ─── M8: zero nodes counts as all nodes ready ───────────────────────────────
#
# `ready == total` is the obvious implementation and 0 == 0 satisfies it. This
# is what an API server that answers while owning nothing looks like.
echo "M8  zero nodes satisfies 'all nodes Ready'"
mutate "$LIB" 's|^  if \[ "\$total" -eq 0 \]; then printf .FAIL.$|  if false; then printf "FAIL"|'
check "M8 zero nodes" "COUNTS zero nodes is a FAIL, not 'all nodes ready'"

# ─── M9: the demo doctor grows an invented difference ───────────────────────
#
# The OPPOSITE failure to every mutation above, and the one the repo's own
# history warns about: modules/ci-runner and modules/compute diverged until CI
# was green against a machine that was not the demo. A demo doctor that starts
# demanding the reaper label fails every correctly-configured demo lane.
echo "M9  the demo doctor starts demanding the CI lane's reaper label"
append_mutation "$DEMO" 'nd_mutated() { nd_verdict_ci_lane_label "$1" "$2"; }'
check "M9 invented difference" "LANE the two doctors differ on EXACTLY the two properties that differ"

# ─── M10: the probe loses its completion marker ─────────────────────────────
#
# The integrity signal for the whole report. Without it a truncated SSH transfer
# and a healthy quiet lane are the same evidence, and every TRUNCATION test
# above would keep passing against its own fixtures while the real thing lost
# the property they exist to protect.
echo "M10 the probe no longer emits its completion marker last"
mutate "$PROBE" 's|^emit probe.complete 1$|# MUTATED: marker removed|'
check "M10 completion marker" "PROBE the completion marker is the last thing emitted"

# ─── M11: the documented gcloud stdin trap is reintroduced ──────────────────
#
# `gcloud compute ssh --command 'bash -s' < file` exits 0 having run ZERO bytes.
# For a doctor that is a report with no keys and no error anywhere — the worst
# available failure shape, because nothing goes red.
echo "M11 the probe is fed to gcloud ssh on stdin instead of via --command"
mutate "$ENTRY" 's|        --command="\$script" 2>&1 </dev/null)" \|\| rc=\$?$|        --command="bash -s" 2>\&1 <<<"$script")" \|\| rc=$?|'
check "M11 gcloud stdin" "PROBE the entry point never redirects a file into gcloud ssh's stdin"

# ─── M12: a new gcloud call site forgets SSH_AUTH_SOCK ──────────────────────
#
# The failure that misreports a healthy lane as unreachable — the exact thing a
# node doctor exists to prevent. It is added rather than removed because that is
# how it actually happens: someone adds a call site, not someone deletes an
# `env` prefix.
echo "M12 a new gcloud call site is added without emptying SSH_AUTH_SOCK"
append_mutation "$ENTRY" 'nd_mutated_call() { gcloud compute instances list; }'
check "M12 unguarded gcloud" "PROBE every gcloud call empties SSH_AUTH_SOCK"

# ─── M13: the mirror of M9, on the CI side ──────────────────────────────────
#
# M9 and M13 are separate for the same reason M2 is separate from M1 in
# test/lane-parallel-port-mutation-proof.sh: one call site being guarded says
# nothing about the other, and a single-side fix is the likely shape of a
# careless future edit. M9 was NOT PROVEN on this harness's first run — the
# assertion covering it was a bare `! grep`, which bash exempts from errexit, so
# it was dead code in every position but last. Both sides are now checked
# through refute_match(), and both mutations are here to keep them checked.
echo "M13 the ci doctor starts demanding the ABSENCE of the label it requires"
append_mutation "$CI" 'nd_mutated() { nd_verdict_demo_no_ci_label "$1"; }'
check "M13 invented difference (ci side)" "LANE the two doctors differ on EXACTLY the two properties that differ"

# ─── M14: the pattern-kill hazard is reintroduced ───────────────────────────
#
# Proves the refutation is live rather than merely written. `pkill -f` in a
# script this repo drives through `bash -c` matches the wrapping shell and kills
# the caller — silently, and reading as a hung probe.
echo "M14 the probe reintroduces a pattern kill"
append_mutation "$PROBE" 'pkill -f zot-port-forward'
check "M14 pattern kill" "PROBE the port-forward is killed by PID, never by pattern"

# ─── M15: the refutation mechanism itself is disabled ───────────────────────
#
# The mutation that would silently switch off EVERY negative assertion in the
# suite at once, while leaving all of them looking like green assertions in the
# source. This is the shape the original `! grep` bug had, and it is why the
# suite carries a meta positive control for its own guard helper.
echo "M15 refute_match can no longer fail"
mutate "$SUITE" 's|^    return 1$|    return 0 # MUTATED|'
check "M15 dead refutation" "GUARD refute_match can actually fail, and refuses to judge an empty file"

# ─── M16: the publish check stops caring whether anything is listening ──────
#
# THE zombie. kubectl port-forward does not exit when the pod it forwards to is
# rolled: the process survives, systemd reports `active`, and the socket is
# gone. Consulting the unit state alone is the natural "simplification" and it
# reports a dead public origin as a healthy forward — which is exactly how a
# dashboard rollout took the URL down with every in-VM check passing.
echo "M16 the publish verdict trusts systemd and ignores the listening socket"
mutate "$LIB" 's|^  if \[ "\$active" = "active" \] && \[ "\$listeners" -ge 1 \]; then printf .PASS.; return; fi$|  if [ "$active" = "active" ]; then printf "PASS"; return; fi|'
check "M16 zombie forward" "PUBLISH the ZOMBIE forward — systemd active, NOTHING listening — is a FAIL"

# ─── M17: the four publish states collapse to two ───────────────────────────
#
# The verdict survives; only the DIAGNOSIS is lost. A zombie and a healthy
# forward then print the same sentence, and the operator restarts nothing
# because nothing told them which of the four states they are in.
echo "M17 the zombie state is reported as a healthy serving forward"
mutate "$LIB" 's|^    if \[ "\$listeners" -ge 1 \]; then printf .SERVING.; else printf .ZOMBIE.; fi$|    printf "SERVING"|'
check "M17 zombie diagnosis" "PUBLISH the entry point reports the zombie with its own diagnosis"

# ─── M18: the JWT comparison goes vacuous ───────────────────────────────────
#
# The defect found in assert_openbao_accepts_spire_jwt_keys on 2026-08-23,
# reintroduced here deliberately: with the emptiness guard gone, a failed read
# leaves one side empty and the function answers confidently having compared
# NOTHING. In the one check that exists to catch silent identity-plane failure.
echo "M18 an unreadable OpenBao is compared instead of refused"
mutate "$LIB" 's|^  case "\$bao_keys".*esac$|  : # MUTATED|'
check "M18 vacuous jwt compare" "JWT an UNREADABLE side is UNKNOWN — the vacuous pass this refuses"

# ─── M19: only the ACTIVE key is checked ────────────────────────────────────
#
# The plausible edit — "logins work, so the lane is fine" — and it removes the
# entire predictive value. The prepared authority's absence becomes invisible,
# and the lane breaks unattended hours later with nobody watching. This is the
# state sl-demo-1 was measured in on 2026-08-24.
echo "M19 the JWT check ignores every key except the one in use right now"
mutate "$LIB" 's|^      \*) printf .WILL_BREAK.; return ;;$|      *) : ;;|'
check "M19 prepared key ignored" "JWT the PREPARED authority missing is WILL_BREAK — the live sl-demo-1 state"

# ─── M20: the positional key lookup drops its parallelism guard ─────────────
#
# Returns a DIFFERENT key's bytes with no error anywhere — a wrong answer that
# looks exactly like a right one, in a comparison whose whole job is to decide
# whether the estate is about to stop authenticating.
echo "M20 the kid lookup answers from lists that are not parallel"
mutate "$LIB" 's|^  \[ "\$(nd_csv_count "\$kids")".*$|  : # MUTATED|'
check "M20 desynced key lookup" "JWT nd_der_for_kid refuses to answer from lists that are not parallel"

# ─── M21: script_available stops being consulted ────────────────────────────
#
# The Signal Fusion outage becomes invisible. The surface answered 200 and
# reported itself INCAPABLE; accepting `false` alongside `true` reduces this
# check to the reachability test that already could not see it.
echo "M21 a demo that reports itself incapable is accepted as ready"
mutate "$LIB" 's|^    true) : ;;$|    true\|false) : ;;|'
check "M21 incapable demo" "DEMO a 200 that reports script_available=false FAILS"

# ─── M22: the Dex rejection flag stops outranking the status code ───────────
#
# Dex can return 200 on a page whose body carries the rejection. Dropping the
# flag makes the verdict depend on a status code that is not the answer, which
# is the same trap the first draft of the probe fell into.
echo "M22 the Dex check believes the status code over the rejection in the body"
mutate "$LIB" 's|^    yes) printf .FAIL.; return ;;$|    yes) : ;;|'
check "M22 dex rejection ignored" "DEX a 302 with no rejection passes — the first hop is not the answer"

# ─── M23: the listener count is grepped instead of counted ──────────────────
#
# Added rather than removed, because that is how it happens: someone adds a
# convenience line. Under pipefail a `grep -q` that matches early can surface
# 141 and invert the answer — in a verdict input.
echo "M23 the probe grows an ss | grep -q listener check"
append_mutation "$PROBE" 'ND_MUTANT="$(ss -ltn | grep -q :30754 && echo 1)"'
check "M23 grep -q listener" "PROBE the listener count is counted, never piped into grep -q"

# ─── M24: a second, looser jwt-svid selector appears ────────────────────────
#
# The exact desync nd_der_for_kid's positional lookup depends on not happening:
# a kid list filtered more loosely than the key list, after which position i
# means different keys on the two sides.
echo "M24 the probe grows a second jwt-svid selector alongside the pinned one"
append_mutation "$PROBE" "ND_MUTANT=\$(jq -r '.keys[]|select(.use==\"jwt-svid\")|.kid')"
check "M24 second jwt selector" "PROBE both SPIRE key lists are built from ONE pinned jq selector"

echo
echo "=== restored; verifying every file is byte-identical to where we started ==="
for f in "${TARGETS[@]}"; do
  now="$(sha256sum "$f" | cut -d' ' -f1)"
  if [[ "$now" != "${ORIG_HASH[$f]}" ]]; then
    echo "HARNESS ERROR: ${f} was not restored (${now} != ${ORIG_HASH[$f]})" >&2
    exit 2
  fi
done
echo "  restored."

echo
echo "=== ${PASS} proven, ${FAIL} not proven ==="
[[ "$FAIL" -eq 0 ]]
