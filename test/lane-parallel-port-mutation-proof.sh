#!/usr/bin/env bash
#
# lane-parallel-port-mutation-proof.sh — prove test/terraform-demo-driver.bats
# § PARALLEL can actually fail.
#
# ─── What is being proved, and why it needed proving ────────────────────────
#
# Andy runs demo-1, demo-2, ci-1 and ci-2 concurrently. Nearly every axis of
# that is per-lane by construction and was verified so: the Terraform data dir
# (TF_DATA_DIR=.terraform-$ENV), the GCS state prefix and therefore the state
# lock, the saved plan file, the handoff file, and the Dex origin — which lives
# in each lane's own cluster and is reached over that lane's own SSH.
#
# The operator's own machine is the exception. `app_port` is ONE value in the
# shared tfvars — 30754 for all four lanes — and local_tunnel_port() defaults
# the LOCAL end of the IAP tunnel to it. Four lanes, one localhost port.
#
# That was not a nuisance, it was a wrong-lane bug, and the reason is that the
# driver's post-launch wait loop asks a question that cannot distinguish the
# two cases it must:
#
#     if "$PORT_PROBE" "$local_port"; then bound=1; break; fi
#
# The probe answers "something is listening on 127.0.0.1:<port>". It does not
# and cannot answer "MY tunnel is listening". So with lane A's tunnel already
# bound, `connect` for lane B launches gcloud, waits, probes during gcloud's
# several-second startup, is answered by LANE A, sets bound=1 and prints
# "tunnel is UP". The operator then works lane B's ticket against lane A's
# cluster with nothing in the output to say so.
#
# ─── Why a proof rather than trust in the suite ─────────────────────────────
#
# The § PARALLEL tests assert that the driver REFUSES. A test that asserts a
# refusal is exactly the shape that goes green for the wrong reason: if the
# driver were to start failing for some unrelated reason — a missing stub, a
# handoff that will not parse, a typo in a path — every one of them would still
# see a non-zero exit and still pass, while measuring nothing about the guard.
#
# This harness removes the guard from the REAL driver and requires the REAL
# suite to go RED by test NAME. That is the only thing that distinguishes "the
# suite is watching the guard" from "the suite is watching the exit code".
#
# It also runs the opposite check: with the guard present and the port FREE,
# the connect path must stay green. A guard that refuses valid input is a guard
# somebody deletes, and deleting this one restores a silent wrong-lane bug.
#
# ─── IT MUTATES THE REAL TREE. NOTHING ELSE MAY TOUCH THE CHECKOUT ──────────
#
# This harness edits scripts/gcp-tf/demo-up.sh in place and restores it between
# mutations, and the suite it runs reads the Makefile and the driver off disk.
# So any concurrent edit or `make` in the same checkout lands inside a mutation
# window and shows up as tests failing for reasons that have nothing to do with
# the mutation under test.
#
# That is not hypothetical. On the first run of this harness, M4 reported NOT
# PROVEN and named two unrelated origin tests as the failures — because the
# author was editing the Makefile and running `make gcp-tf-plan` in the same
# worktree while it ran. Re-run cleanly, M4 reports exactly the one test it is
# supposed to. The false NOT PROVEN reads precisely like a real finding, which
# is the expensive part.
#
# Run it alone. In a shared worktree, run it alone and say so.
#
# Run: test/lane-parallel-port-mutation-proof.sh
# Exit 0 = every mutation was caught. Exit 1 = at least one was not.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DRIVER="scripts/gcp-tf/demo-up.sh"
SUITE="test/terraform-demo-driver.bats"

# ─── The sentinel ───────────────────────────────────────────────────────────
#
# Matched by `*mutation-in-progress` in .gitignore. Its presence means a
# previous run died holding a mutation, so the tree cannot be trusted to be the
# real thing. REFUSE — never auto-repair. A harness that silently restored what
# it found would make the broken state invisible, which is the same defect as a
# guard that repairs what it detects.
SENTINEL="$REPO_ROOT/.lane-parallel-port-mutation-in-progress"

if [[ -e "$SENTINEL" ]]; then
  cat >&2 <<EOF
HARNESS REFUSING TO START.

  A sentinel from a previous run is present:
    $SENTINEL

  That run died while ${DRIVER} was MUTATED, so the working tree may contain a
  deliberately broken driver. This harness will not repair it for you: an
  auto-repair would make the broken state invisible and the next green run
  would be measuring code nobody has looked at.

  It records the backup it was restoring from. Inspect, restore by hand, then
  delete the sentinel:

$(sed 's/^/    /' "$SENTINEL" 2>/dev/null || echo "    <sentinel is unreadable>")
EOF
  exit 2
fi

[[ -f "$DRIVER" ]] || { echo "HARNESS ERROR: $DRIVER not found" >&2; exit 2; }
[[ -f "$SUITE" ]] || { echo "HARNESS ERROR: $SUITE not found" >&2; exit 2; }

BACKUP="$(mktemp -d)"
cp -p "$DRIVER" "$BACKUP/demo-up.sh"

ORIG_HASH="$(sha256sum "$DRIVER" | cut -d' ' -f1)"
ORIG_MODE="$(stat -c '%a' "$DRIVER")"

{
  printf 'driver : %s\n' "$REPO_ROOT/$DRIVER"
  printf 'backup : %s\n' "$BACKUP/demo-up.sh"
  printf 'sha256 : %s\n' "$ORIG_HASH"
  printf 'mode   : %s\n' "$ORIG_MODE"
  printf 'started: %s\n' "$(date -Is)"
} >"$SENTINEL"

restore() {
  # `cp` onto the existing inode, not `mv` from the tempfile. mv replaces the
  # inode and carries the TEMPFILE's mode across — restoring the bytes exactly
  # while dropping the executable bit.
  cp "$BACKUP/demo-up.sh" "$DRIVER"
  chmod "$ORIG_MODE" "$DRIVER"
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
  local expr="$1" before after
  before="$(sha256sum "$DRIVER" | cut -d' ' -f1)"
  sed -i "$expr" "$DRIVER"
  after="$(sha256sum "$DRIVER" | cut -d' ' -f1)"
  if [[ "$before" == "$after" ]]; then
    echo "HARNESS ERROR: mutation did not change ${DRIVER}: ${expr}" >&2
    exit 2
  fi
}

# Reports the NAMES of failing tests, never `not ok <n>` numbers. Inserting a
# test renumbers everything below it, and a harness that reports NOT PROVEN for
# a guard that fired perfectly well is worse than no harness — the natural
# response is to go and "fix" working code.
#
# ─── Why --filter, and what it costs ────────────────────────────────────────
#
# The full suite is ~80 tests and takes around four minutes. Six mutations plus
# the baseline is seven runs, so an unfiltered harness adds ~25 minutes to
# `make gcp-tf-validate` — a gate the Makefile already describes as ~13
# minutes, and this file is picked up by its `test/*-mutation-proof.sh` glob
# automatically. Nearly tripling that gate to re-run 74 tests that no mutation
# here can touch is not a trade worth making.
#
# Every expectation in this harness names a § PARALLEL test, so the filter
# cannot skip the thing being measured. The BASELINE below is deliberately NOT
# filtered: that one full run is what establishes the whole suite is green
# before anything is mutated, which is the property the filter would otherwise
# stop checking.
#
# What is given up: collateral damage from a mutation is no longer visible. That
# is acceptable because these mutations are deliberate breakages — a mutation
# also breaking a neighbouring test is expected, not a finding.
FILTER="${LANE_PARALLEL_PROOF_FILTER:-PARALLEL|OWNERSHIP}"
failing_tests() {
  bats --filter "$FILTER" "$SUITE" 2>&1 | sed -n 's/^not ok [0-9]* //p'
}

check() {
  local label="$1" want="$2" got
  got="$(failing_tests || true)"
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

# ─── M1: the connect guard call is deleted ──────────────────────────────────
#
# THE regression. This is the exact state the driver was in before this change:
# the collision is invisible and `connect` reports a live tunnel that belongs to
# another lane.
echo "M1  connect's local-port preflight call is deleted"
mutate 's|^  require_local_port_free "\$local_port" "gcp-tf-connect"$|  : # MUTATED|'
check "M1 connect guard" "PARALLEL connect refuses when another lane already holds the local port"

# ─── M2: the public guard call is deleted ───────────────────────────────────
#
# `public` is the more dangerous of the two, because it also publishes. Covered
# separately: one call site being guarded says nothing about the other, and a
# single-call-site fix is the likely shape of a careless future edit.
echo "M2  public's local-port preflight call is deleted"
mutate 's|^  require_local_port_free "\$local_port" "gcp-tf-public"$|  : # MUTATED|'
check "M2 public guard" "PARALLEL public refuses on a held local port, before the cloud and before Dex"

# ─── M3: the guard survives but stops refusing ──────────────────────────────
#
# Deleting a call is the obvious mutation and it is not the interesting one. A
# guard that is still CALLED, still present to any grep, and simply never fires
# is what a real regression looks like — an inverted test, a probe that was
# "fixed" to return the other polarity. Every presence assertion in the suite
# still passes here; only the behavioural ones can catch it.
echo "M3  the guard is still called but can never fire (inverted probe test)"
# `#` as the delimiter, not `|`: the line being matched contains `||`, which
# ends the expression early and yields sed's opaque "unknown option to `s'".
mutate 's#^  "\$PREFLIGHT_PORT_PROBE" "\$want" \|\| return 0$#  "$PREFLIGHT_PORT_PROBE" "$want" \&\& return 0#'
check "M3 inverted probe" "PARALLEL connect refuses when another lane already holds the local port"

# ─── M4: the guard fires, but too late to matter ────────────────────────────
#
# Ordering is the substance of the fix. Moved below the Dex claim, the guard
# still refuses — the suite's "refuses" assertions all still pass — but this
# lane's issuer has already been repointed at an origin another lane is
# serving, so the refused run has broken this lane's login on its way out.
#
# Implemented by neutering the connect call and re-inserting it after the
# origin claim, so the guard genuinely runs in the wrong place rather than not
# running at all.
echo "M4  the guard runs AFTER Dex has already been repointed"
mutate 's|^  require_local_port_free "\$local_port" "gcp-tf-connect"$|  : # MUTATED moved|'
# Re-inserted against a comment that appears ONLY in cmd_connect. The obvious
# anchor — the `print_connect_instructions "$origin"` call on the next line —
# occurs in cmd_public too, so it would silently mutate both call sites and this
# would stop being a test about connect's ordering.
mutate 's|^  # Printed BEFORE the tunnel, because the tunnel occupies the foreground and$|  require_local_port_free "$local_port" "gcp-tf-connect"\n  # Printed BEFORE the tunnel, because the tunnel occupies the foreground and|'
check "M4 ordering" "PARALLEL connect refuses BEFORE it touches the cloud or mutates Dex"

# ─── M5: the escape hatch is dropped from the refusal ───────────────────────
#
# Andy's requirement is four lanes at once, not four lanes one at a time. A
# refusal that does not carry the variable which gives a lane its own port
# converts the silent bug into a dead end, and the operator's next move is to
# delete the guard.
echo "M5  the refusal no longer names GCP_TF_DEMO_LOCAL_PORT"
mutate 's|GCP_TF_DEMO_LOCAL_PORT=\$((want + 1)) make \${who} ENV=\${ENV_KEY}|<pick another port> make ${who} ENV=${ENV_KEY}|'
check "M5 escape hatch" "PARALLEL the refusal hands over the per-lane escape hatch"

# ─── M6: the two probes are collapsed onto one variable ─────────────────────
#
# The failure mode a future "simplification" produces. PORT_PROBE answers the
# post-launch question ("is it bound yet?") and the suites' probe-ok stub
# answers it unconditionally — correctly. Reuse it for the preflight and the
# guard refuses every single run, including every valid single-lane one.
echo "M6  the preflight probe is collapsed onto the post-launch probe"
mutate 's|^PREFLIGHT_PORT_PROBE="\${GCP_TF_DEMO_PREFLIGHT_PORT_PROBE:-default_port_probe}"$|PREFLIGHT_PORT_PROBE="$PORT_PROBE"|'
check "M6 collapsed probes" "PARALLEL a free port leaves connect completely unchanged"

# ─── M7: connect's ownership check deleted ──────────────────────────────────
#
# The port guard and the ownership check answer different questions, and this
# is what proves the second is not decoration once the first exists. With a
# per-lane port the collision never happens, the port guard stays silent — and
# a socket hijacked inside gcloud's authentication window still gets handed
# over as a healthy tunnel.
echo "M7  connect's tunnel-ownership check is deleted"
mutate 's|^  if ! assert_tunnel_is_ours "\$local_port" "\$tunnel_pid" "gcp-tf-connect"; then$|  if false; then # MUTATED|'
check "M7 connect ownership" "OWNERSHIP connect refuses a socket held by ANOTHER lane's tunnel"

# ─── M8: public's ownership check deleted ───────────────────────────────────
#
# Separate from M7 for the same reason M2 is separate from M1, and with more at
# stake: public's health probe would collect its 200 from the other lane's
# dashboard and print "verified before you clicked".
echo "M8  public's tunnel-ownership check is deleted"
mutate 's|^  if ! assert_tunnel_is_ours "\$local_port" "\$tunnel_pid" "gcp-tf-public"; then$|  if false; then # MUTATED|'
check "M8 public ownership" "OWNERSHIP public refuses a hijacked socket BEFORE its health probe"

# ─── M9: unattributable sockets treated as ours ─────────────────────────────
#
# The fail-OPEN rewrite, and the most likely one to be introduced in good faith.
# `ss` is missing on some machines, the check starts refusing, and the obvious
# "fix" is to let an empty owner list pass. That silently disables the entire
# mechanism on exactly the hosts where it cannot verify anything — while every
# presence assertion in the suite still passes.
echo "M9  an unattributable socket is treated as ours (fail-open)"
# `#` delimiter: the matched line contains `||`, which with `|` as the delimiter
# ends the expression early and yields sed's opaque "unknown option to `s'".
# Same trap as M3 — it bit twice in this file, which is why both now say so.
mutate 's#^  owners="\$("\$LISTENER_OWNER_PROBE" "\$want" 2>/dev/null \|\| true)"$#  owners="$("$LISTENER_OWNER_PROBE" "$want" 2>/dev/null || true)"; [ -n "$owners" ] || return 0#'
check "M9 fail-open owners" "OWNERSHIP an unattributable socket is refused, not assumed to be ours"

# ─── M10: the descendant walk collapsed to an equality test ─────────────────
#
# Subtle, correct-looking, and it breaks the HAPPY path rather than the failure
# path — so no refusal test can catch it. `$!` is the pid of the backgrounded
# `env`; against a real gcloud (a wrapper that runs Python) the socket is held
# by a descendant, so comparing the two numbers directly rejects every
# legitimate tunnel. A guard that refuses valid input is a guard somebody
# deletes, and deleting this one restores the hijack.
#
# The expectation is the DESCENDANT test, not the plain accept test, and the
# distinction is the whole point. `owner-ours` returns a pid EQUAL to
# tunnel_pid — the stub is exec'd by `env` so it keeps the pid — which means
# the direct comparison succeeds and the walk is never entered. This mutation
# was NOT PROVEN against that test, correctly: the suite could not see it. The
# stub now also records a genuine child pid, and only the walk resolves that.
echo "M10 the ancestry walk is collapsed to a direct pid comparison"
mutate 's|^    \[ "\$pid" = "\$want" \] \&\& return 0$|    [ "$pid" = "$want" ] \&\& return 0; return 1|'
check "M10 descendant walk" "OWNERSHIP connect accepts a socket held by a DESCENDANT of its tunnel"

echo
echo "=== restored; verifying the tree is byte-identical to where we started ==="
NOW_HASH="$(sha256sum "$DRIVER" | cut -d' ' -f1)"
if [[ "$NOW_HASH" != "$ORIG_HASH" ]]; then
  echo "HARNESS ERROR: ${DRIVER} was not restored (${NOW_HASH} != ${ORIG_HASH})" >&2
  exit 2
fi
echo "  restored."

echo
echo "=== ${PASS} proven, ${FAIL} not proven ==="
[[ "$FAIL" -eq 0 ]]
