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

# ─── The sentinel ───────────────────────────────────────────────────────────
#
# Matched by `*mutation-in-progress` in .gitignore. Its presence means a
# previous run died holding a mutation, so the tree cannot be trusted to be the
# real thing. REFUSE — never auto-repair. A harness that silently restored what
# it found would make the broken state invisible, which is the same defect as a
# guard that repairs what it detects.
#
# Note the limit of this, honestly: an EXIT trap survives SIGTERM and does NOT
# survive SIGKILL. A `kill -9` leaves the tree mutated AND leaves this sentinel,
# which is the case it exists for.
SENTINEL="$REPO_ROOT/.node-doctor-mutation-in-progress"

if [[ -e "$SENTINEL" ]]; then
  cat >&2 <<EOF
HARNESS REFUSING TO START.

  A sentinel from a previous run is present:
    $SENTINEL

  That run died while the node doctor was MUTATED, so the working tree may
  contain deliberately broken code. This harness will not repair it for you: an
  auto-repair would make the broken state invisible and the next green run
  would be measuring code nobody has looked at.

  It records the backups it was restoring from. Inspect, restore by hand, then
  delete the sentinel:

$(sed 's/^/    /' "$SENTINEL" 2>/dev/null || echo "    <sentinel is unreadable>")
EOF
  exit 2
fi

command -v bats >/dev/null 2>&1 || { echo "HARNESS ERROR: bats is not installed" >&2; exit 2; }
for f in "$SUITE" "${TARGETS[@]}"; do
  [[ -f "$f" ]] || { echo "HARNESS ERROR: $f not found" >&2; exit 2; }
done

BACKUP="$(mktemp -d)"
declare -A ORIG_HASH ORIG_MODE
{
  printf 'started: %s\n' "$(date -Is)"
  printf 'backups: %s\n' "$BACKUP"
} >"$SENTINEL"
for f in "${TARGETS[@]}"; do
  cp -p "$f" "$BACKUP/$(basename "$f")"
  ORIG_HASH["$f"]="$(sha256sum "$f" | cut -d' ' -f1)"
  ORIG_MODE["$f"]="$(stat -c '%a' "$f")"
  printf 'file   : %s  sha256=%s  mode=%s\n' "$f" "${ORIG_HASH[$f]}" "${ORIG_MODE[$f]}" >>"$SENTINEL"
done

restore() {
  local f
  for f in "${TARGETS[@]}"; do
    # `cp` onto the existing inode, not `mv` from the tempfile. mv replaces the
    # inode and carries the TEMPFILE's mode across — restoring the bytes exactly
    # while dropping the executable bit.
    cp "$BACKUP/$(basename "$f")" "$f"
    chmod "${ORIG_MODE[$f]}" "$f"
  done
}

cleanup() {
  restore
  rm -f "$SENTINEL"
  rm -rf "$BACKUP"
}
trap cleanup EXIT

PASS=0
FAIL=0

# A sed that cannot silently do nothing. A non-matching pattern no-ops while
# printing success, and in a proof harness that ships as "every mutation was
# caught" against a tree that was never mutated.
mutate() {
  local file="$1" expr="$2" before after
  before="$(sha256sum "$file" | cut -d' ' -f1)"
  sed -i "$expr" "$file"
  after="$(sha256sum "$file" | cut -d' ' -f1)"
  if [[ "$before" == "$after" ]]; then
    echo "HARNESS ERROR: mutation did not change ${file}: ${expr}" >&2
    exit 2
  fi
}

# Appends a line to a file — for the mutations that ADD something forbidden
# rather than break something present. Same no-op refusal as mutate().
append_mutation() {
  local file="$1" line="$2" before after
  before="$(sha256sum "$file" | cut -d' ' -f1)"
  printf '%s\n' "$line" >>"$file"
  after="$(sha256sum "$file" | cut -d' ' -f1)"
  [[ "$before" != "$after" ]] || { echo "HARNESS ERROR: append changed nothing in ${file}" >&2; exit 2; }
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
mutate "$LIB" 's|^  elif \[ "\$ND_UNKNOWN" -gt 0 \]; then verdict=UNKNOWN; rc=3$|  elif false; then verdict=UNKNOWN; rc=3|'
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
