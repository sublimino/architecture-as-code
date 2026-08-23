#!/usr/bin/env bash
# tailscale-serve-boot-mutation-proof.sh
#   -- prove test/terraform-tailscale-serve-boot.bats can actually fail.
#
# A green suite is evidence of nothing until each guard has been shown to go RED
# for the right reason. This repo has shipped guards that were pure decoration:
# a `! grep` that is dead under `set -e`, a `[ "$status" -ne 0 ]` that reads a
# MISSING FILE as "pattern absent", a mechanism assertion that passed vacuously
# because its own discovery returned empty. Every one of them was green.
#
# The defect this suite guards is entirely SILENT. A lane that comes back from a
# reboot without its serve config is online, correctly named, resolving through
# MagicDNS, and reachable by SSH — every cheap check reports healthy, and only
# fetching the URL says otherwise. A guard against a silent failure that is
# itself silently broken leaves the estate exactly where it started, with the
# added cost that somebody now believes it is covered.
#
# So: introduce each defect into the real file, confirm the EXPECTED test goes
# red, restore, confirm green again.
#
# Restore is from a byte-for-byte backup taken here, NOT `git checkout`.
# `git checkout <dir>` in a proof harness wipes in-progress edits elsewhere in
# the tree, and the resulting "the guard did not fire" reads exactly like a real
# finding.
#
# Run: bash test/tailscale-serve-boot-mutation-proof.sh

# Every mutation below is a sed expression, and sed expressions are
# single-quoted precisely SO THAT `$` stays literal — these patterns match shell
# variables in the source files, they do not expand them.
# shellcheck disable=SC2016

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SUITE="test/terraform-tailscale-serve-boot.bats"
STARTUP="terraform/modules/compute/startup/demo-vm.sh"
DRIVER="scripts/gcp-tf/demo-up.sh"
COMPUTE_TF="terraform/modules/compute/main.tf"

# ── The shared safety rail ──────────────────────────────────────────────────
#
# An EXIT trap was the whole protection here, and it does not survive SIGKILL —
# which is what a tool timeout escalates to. A hard kill leaves these files
# mutated, the &&-chained gate carries on, and the leak reads as content lost in
# a merge. The helper adds the marker that outlives a hard kill, refuses to
# start on top of one, and verifies the restore on content AND mode.
# See test/helpers/mutation-sentinel.bash.
# shellcheck source=helpers/mutation-sentinel.bash
source "${REPO_ROOT}/test/helpers/mutation-sentinel.bash"

ms_guard_init tailscale-serve-boot "$STARTUP" "$DRIVER" "$COMPUTE_TF"
trap ms_guard_on_exit EXIT

restore_all() { ms_guard_restore; }

PASS=0
FAIL=0

# A sed that cannot silently do nothing. A non-matching pattern no-ops while
# returning 0, so the mutation never lands, the suite stays green, and the
# harness reports "guard did not fire" — a false finding that looks exactly like
# a real one, and one that invites somebody to go and "fix" working code.
#
# ms_sed keeps that refusal and adds two things the local version could not: it
# tells a sed SYNTAX ERROR apart from a pattern that no longer matches, and it
# ARMS the sentinel before touching the file, so no call site can forget.
mutate() { ms_sed "$1" "$2"; }

# Names, not `not ok <n>` numbers: inserting two tests in the middle of a suite
# renumbers everything below them, and every expectation here would silently
# start pointing at the wrong test.
#
# A non-zero bats is the EXPECTED outcome, and `set -o pipefail` promotes it to
# the pipeline's status — so without `|| true` at the call site, `set -e` kills
# this harness on its first SUCCESS.
failing_tests() {
  bats "$SUITE" 2>&1 | sed -n 's/^not ok [0-9]* //p'
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
  restore_all
}

echo "=== baseline: the suite must be green before any mutation ==="
if ! bats "$SUITE" >/dev/null 2>&1; then
  echo "HARNESS ERROR: suite is not green before mutation" >&2
  bats "$SUITE" 2>&1 | tail -20 >&2
  exit 2
fi
echo "  GREEN"
echo

echo "=== mutations ==="

# ── The defect that started all of this ──────────────────────────────────────
#
# A perfectly correct installer that nothing calls installs nothing. Every other
# test in the suite invokes the function directly and would stay green.
echo "M1  the installer is never called from the boot path (dead code)"
mutate "$STARTUP" 's/^  install_tailscale_serve_unit$/  : # removed/'
check "M1 installer is reached" "BOOT the serve unit and its helper are both written"

# ── The reason signalloom-app-port exists at all ─────────────────────────────
echo "M2  the proxy port is hardcoded instead of read from metadata"
mutate "$STARTUP" "s|http://127.0.0.1:\${app_port}|http://127.0.0.1:30754|"
check "M2 port comes from metadata" "BOOT the helper proxies to the port that metadata published"

# ── A real TLS listener in front of nothing ──────────────────────────────────
echo "M3  a non-numeric app port is interpolated instead of refused"
mutate "$STARTUP" "s/^    '' | \*\[!0-9\]\*)/    'IMPOSSIBLE-SENTINEL')/"
check "M3 port is validated" "BOOT a NON-NUMERIC app-port is refused rather than interpolated"

# ── enable and start are different bugs ──────────────────────────────────────
echo "M4  the unit is enabled but never started (this boot serves nothing)"
mutate "$STARTUP" 's|^  systemctl start "\$TS_SERVE_UNIT_NAME" .*|  true \&\& {|'
check "M4 started as well as enabled" "BOOT the unit is both enabled AND started"

echo "M5  the unit is started but never enabled (no reboot survives)"
mutate "$STARTUP" 's|^  systemctl enable "\$TS_SERVE_UNIT_NAME" .*|  true \&\& {|'
check "M5 enabled as well as started" "BOOT the unit is both enabled AND started"

# ── The security property ────────────────────────────────────────────────────
#
# The single most expensive mutation in this file: a boot unit that re-asserted
# funnel would republish this estate to the public internet after every reboot.
echo "M6  the boot helper funnels instead of serving (PUBLIC exposure at boot)"
mutate "$STARTUP" 's/^exec tailscale serve --bg/exec tailscale funnel --bg/'
check "M6 boot never funnels" "BOOT the helper serves, and never funnels"

# ── The unit would never run ─────────────────────────────────────────────────
echo "M7  the unit is not linked into multi-user.target"
mutate "$STARTUP" 's/^WantedBy=multi-user.target$/WantedBy=graphical.target/'
check "M7 linked into multi-user" "BOOT the unit runs the helper and is linked into multi-user.target"

# ── The instant-failure case the wait loop exists for ────────────────────────
echo "M8  the helper no longer waits for tailscaled to authenticate"
mutate "$STARTUP" 's/"BackendState": \*"Running"/ALWAYS-TRUE-SENTINEL/'
check "M8 waits for the daemon" "BOOT the helper waits for tailscaled instead of failing instantly"

# ── Terraform stops publishing what bash reads ───────────────────────────────
echo "M9  the port metadata is a literal instead of var.app_port"
mutate "$COMPUTE_TF" 's/^    signalloom-app-port            = tostring(var.app_port)$/    signalloom-app-port            = "30754"/'
check "M9 metadata derives from the variable" "TF signalloom-app-port is published as instance metadata"

echo "M10 the port metadata is not published at all"
mutate "$COMPUTE_TF" 's/^    signalloom-app-port            = tostring(var.app_port)$/    signalloom-unrelated-key       = "x"/'
check "M10 metadata is published" "TF signalloom-app-port is published as instance metadata"

# ── The seam between the two copies ─────────────────────────────────────────
echo "M11 the boot copy installs its helper somewhere the driver does not look"
mutate "$STARTUP" 's|^readonly TS_SERVE_HELPER="/usr/local/sbin/signalloom-tailscale-serve"$|readonly TS_SERVE_HELPER="/opt/signalloom/serve-helper"|'
check "M11 helper paths agree" "SEAM both copies agree on the helper path"

echo "M12 the two copies serve different HTTPS ports"
mutate "$STARTUP" 's/^readonly TS_SERVE_HTTPS_PORT="443"$/readonly TS_SERVE_HTTPS_PORT="8443"/'
check "M12 ports agree" "SEAM both copies serve the same HTTPS port"

echo "M13 the driver stops reading the unit the boot path installs"
mutate "$DRIVER" 's/^ts_serve_unit_state() {$/ts_serve_unit_state_RENAMED() {/'
check "M13 detector reads the installed unit" "SEAM ts-status reads the unit the boot path installs"

# ── The blast radius must stay documented and stay true ─────────────────────
echo "M14 the ForceNew warning is deleted in a tidy-up"
mutate "$STARTUP" 's/ForceNew//g; s/DESTROYS AND RECREATES/updates/; s/REPLACES that instance/updates that instance/'
check "M14 blast radius documented" "BLAST the startup script states that editing it replaces the VM"

echo "M15 the script moves to the metadata map, silently changing replacement semantics"
mutate "$COMPUTE_TF" 's/^  metadata_startup_script = file(local.startup_script_file)$/  metadata_startup_script_RENAMED = file(local.startup_script_file)/'
check "M15 delivery mechanism pinned" "BLAST the script is delivered by metadata_startup_script, not the metadata map"

echo "M16 the port is baked into the script instead of read from metadata"
mutate "$STARTUP" 's/^  app_port="\$(metadata_attr signalloom-app-port)" || app_port=""$/  app_port="30754"/'
check "M16 per-lane values stay in metadata" "BLAST values the script READS are metadata, not baked into the script"

echo
echo "=== restored: the suite must be green again ==="
restore_all
if ! bats "$SUITE" >/dev/null 2>&1; then
  echo "HARNESS ERROR: suite is not green after restore" >&2
  bats "$SUITE" 2>&1 | tail -20 >&2
  exit 2
fi
echo "  GREEN"

echo
echo "=== result ==="
echo "  proven:    ${PASS}"
echo "  unproven:  ${FAIL}"
if [[ "$FAIL" -ne 0 ]]; then
  echo
  echo "A mutation that fails NOTHING is a finding, not a nuisance."
  echo "Fix the assertion before moving on."
  exit 1
fi
