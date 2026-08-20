#!/usr/bin/env bash
# ts-stable-node-name-mutation-proof.sh
#   -- prove test/terraform-ts-stable-node-name.bats can actually fail.
#
# A green suite is evidence of nothing until each guard has been shown to go RED
# for the right reason. This repo has shipped guards that were pure decoration:
# a `! grep` that is dead under `set -e`, a `[ "$status" -ne 0 ]` that reads a
# MISSING FILE as "pattern absent", a mechanism assertion that passed vacuously
# because its own discovery returned empty. Every one of them was green.
#
# The suite this file falsifies is about a defect whose entire signature is
# SILENCE — a node that joined under the wrong name, and every status command
# reporting healthy. A guard against a silent failure that is itself silently
# broken leaves the estate in exactly the state it was in before the guard
# existed, with the added cost that somebody now believes it is covered.
#
# So: introduce each defect into the real file, confirm the EXPECTED test goes
# red, restore, confirm green again.
#
# Restore is from a byte-for-byte backup taken here, NOT `git checkout`.
# `git checkout <dir>` in a proof harness wipes in-progress edits elsewhere in
# the tree, and the resulting "the guard did not fire" reads exactly like a real
# finding.
#
# Run: bash test/ts-stable-node-name-mutation-proof.sh

# Every mutation below is a sed expression, and sed expressions are
# single-quoted precisely SO THAT `$` stays literal — these patterns match shell
# variables in the source files, they do not expand them. Double-quoting as
# SC2016 suggests would expand them against this harness's own environment,
# produce a pattern that matches nothing, and `mutate` would abort the run.
# File-scoped because a directive placed lower down binds only to the next
# command.
# shellcheck disable=SC2016

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

STARTUP="terraform/modules/compute/startup/demo-vm.sh"
DRIVER="scripts/gcp-tf/demo-up.sh"
MAKEFILE="Makefile"
SUITE="test/terraform-ts-stable-node-name.bats"

BACKUP="$(mktemp -d)"
trap 'restore_all; rm -rf "$BACKUP"' EXIT

mkdir -p "$BACKUP/$(dirname "$STARTUP")" "$BACKUP/$(dirname "$DRIVER")"
cp "$STARTUP" "$BACKUP/$STARTUP"
cp "$DRIVER" "$BACKUP/$DRIVER"
cp "$MAKEFILE" "$BACKUP/$MAKEFILE"

restore_all() {
  cp "$BACKUP/$STARTUP" "$STARTUP"
  cp "$BACKUP/$DRIVER" "$DRIVER"
  cp "$BACKUP/$MAKEFILE" "$MAKEFILE"
}

PASS=0
FAIL=0

# A sed that cannot silently do nothing.
#
# A non-matching pattern no-ops while returning 0, so the mutation never lands,
# the suite stays green, and the harness reports "guard did not fire" — a false
# finding that looks exactly like a real one, and one that invites somebody to
# go and "fix" working code.
mutate() {
  local file="$1" expr="$2" before after
  before="$(md5sum "$file" | cut -d' ' -f1)"
  sed -i "$expr" "$file"
  after="$(md5sum "$file" | cut -d' ' -f1)"
  if [[ "$before" == "$after" ]]; then
    echo "HARNESS ERROR: mutation did not change ${file}: ${expr}" >&2
    exit 2
  fi
}

# Runs the suite and reports the NAMES of the tests that failed.
#
# Names, not the `not ok <n>` numbers: inserting two tests in the middle of a
# suite renumbers everything below them, and every expectation in this file
# would silently start pointing at the wrong test. A harness that reports
# "NOT PROVEN" for a guard that fired perfectly well is worse than no harness.
#
# A non-zero bats is the EXPECTED outcome here, and `set -o pipefail` at the top
# of this file promotes it to the pipeline's status — so without the `|| true`
# at the call site, `set -e` kills the harness on its first SUCCESS.
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
echo ""

echo "=== the name comparison itself ==="

echo "M1  comparison inverted: a correct name is reported as a mismatch"
mutate "$STARTUP" 's|^  if \[\[ "$label" == "$want" \]\]; then|  if [[ "$label" != "$want" ]]; then|'
check "M1 inverted comparison" "a node granted the name it asked for passes and writes no marker"

echo "M2  comparison always true: the drifted name is accepted"
mutate "$STARTUP" 's|^  if \[\[ "$label" == "$want" \]\]; then|  if true; then|'
check "M2 always-true comparison" "a drifted name FAILS, logs at ERROR, and writes the marker"

# M3 is the mutation that taught this harness something. It was first pointed at
# "the comparison is trailing-dot safe", which stayed GREEN — because
# `${got%%.*}` takes the first label and is dot-safe without the strip. The
# strip's real job is normalising the name REPORTED to humans, so that is what
# the expectation names now. The original test was passing for a reason other
# than the one it claimed, which is the whole point of running this file.
echo "M3  trailing dot no longer stripped from the reported name"
mutate "$STARTUP" 's|^  got="${got%.}"|  got="${got}"|'
check "M3 reported name normalised" "the FQDN this node reports is normalised, with no trailing dot"

echo "M4  whole FQDN compared instead of the first label"
mutate "$STARTUP" 's|^  label="${got%%.\*}"|  label="${got}"|'
check "M4 first-label comparison" "only the first label is compared, so the tailnet suffix is never hardcoded"

echo "M5  mismatch returns success, so the caller carries on"
mutate "$STARTUP" '/log "ERROR:   https:\/\/login.tailscale.com\/admin\/machines"/{n;n;s/  return 1/  return 0/}'
check "M5 mismatch is a failure" "a drifted name FAILS, logs at ERROR, and writes the marker"

echo "M6  an unreadable status document is treated as a pass"
mutate "$STARTUP" 's|^    write_ts_name_marker "$want" "(unreadable)"\n    return 1|    return 0|; /write_ts_name_marker "$want" "(unreadable)"/{n;s/    return 1/    return 0/}'
check "M6 unreadable is not a pass" "a status document that cannot be read FAILS rather than assuming success"

echo "M7  peers no longer suppressed, so a peer's DNSName can be read as ours"
mutate "$STARTUP" 's|tailscale status --json --peers=false|tailscale status --json|'
check "M7 peers suppressed" "the status query suppresses peers, so a peer's name cannot be read as ours"

echo "=== the durable signal ==="

echo "M8  marker no longer written on a mismatch"
mutate "$STARTUP" 's|^  write_ts_name_marker "$want" "$got"|  :|'
check "M8 marker is written" "a drifted name FAILS, logs at ERROR, and writes the marker"

echo "M9  a stale marker is left behind after a good boot"
mutate "$STARTUP" 's|^    rm -f "$TS_NAME_MARKER"|    :|'
check "M9 stale marker cleared" "a marker from an earlier boot is cleared when the name is correct"

echo "M10 the drift is downgraded to a WARNING"
mutate "$STARTUP" 's|log "ERROR: tailscale assigned a different name than the one requested"|log "WARNING: tailscale assigned a different name than the one requested"|'
check "M10 logged at ERROR" "the drift is logged at ERROR and never as a WARNING"

echo "M11 the marker stops naming what was actually observed"
mutate "$STARTUP" 's|^observed:  ${got}|observed:  (redacted)|'
check "M11 marker names both" "the marker records both names and a timestamp"

echo "=== secret hygiene ==="

echo "M12 the auth key is echoed into a log line"
mutate "$STARTUP" 's|^  log "tailscale is up as ${node_name} (${tag})"|  log "tailscale is up as ${node_name} (${tag}) key=${authkey}"|'
check "M12 key never logged" "the auth key's value is referenced in exactly two places, and both are named"

echo "M13 set -x is enabled, which prints the key on the tailscale up line"
mutate "$STARTUP" 's|^set -euo pipefail|set -euo pipefail\nset -x|'
check "M13 set -x is absent" "the key is never echoed, and set -x is never enabled"

echo "=== the shutdown backstop ==="

echo "M14 ExecStop failure is no longer tolerated"
mutate "$STARTUP" 's|^ExecStop=-/usr/bin/tailscale logout|ExecStop=/usr/bin/tailscale logout|'
check "M14 ExecStop tolerates failure" "the unit logs out on stop, and tolerates every way that can fail"

echo "M15 DefaultDependencies disabled, so systemd never stops the unit"
mutate "$STARTUP" 's|^After=network-online.target tailscaled.service|DefaultDependencies=no\nAfter=network-online.target tailscaled.service|'
check "M15 DefaultDependencies kept" "the unit does NOT disable DefaultDependencies"

# `|` cannot be the delimiter here: the line being matched contains `||`, and
# sed reads the first of those as the end of the pattern. The observed failure
# was `sed: unknown option to 's'`, which reads as a broken expression rather
# than as a delimiter collision.
echo "M16 unit enabled but never started, so ExecStop never runs"
mutate "$STARTUP" 's@^  systemctl start "$TS_LOGOUT_UNIT_NAME"@  : start-removed-by-mutation@'
check "M16 unit is started" "the unit is STARTED, not merely enabled"

echo "M17 the unit is never installed at all"
mutate "$STARTUP" 's|^  install_tailscale_logout_unit$|  :|'
check "M17 unit is installed" "the startup script installs a shutdown logout unit"

echo "=== logout before destroy ==="

echo "M18 the logout is moved AFTER the destroy"
mutate "$MAKEFILE" '/^\t-@\$(GCP_TF_DEMO_ENVIRONMENT) .\$(GCP_TF_DEMO_SCRIPT). ts-logout$/d'
check "M18 logout precedes destroy" "gcp-tf-destroy releases the tailnet name BEFORE terraform destroy"

echo "M19 the logout can fail the destroy (error tolerance removed)"
mutate "$MAKEFILE" 's|^\t-@\$(GCP_TF_DEMO_ENVIRONMENT) .\$(GCP_TF_DEMO_SCRIPT). ts-logout$|\t@$(GCP_TF_DEMO_ENVIRONMENT) '"'"'$(GCP_TF_DEMO_SCRIPT)'"'"' ts-logout|'
check "M19 logout cannot fail destroy" "the logout step cannot fail the destroy"

# M20's first form mutated `return 0` to `return "$rc"` and expected the
# failing-logout test to go red. It did not, and the harness was right to say
# so: when the remote logout fails, the if/else INSIDE the subshell handles it
# and the subshell still exits 0, so `$rc` is 0 and the two forms are identical.
# That mutation is M21 — the outer `return 0` only matters on the `die` path —
# and pointing two mutations at one line proves one thing twice.
#
# The failing-logout test guards a SECOND property that nothing else covers:
# that the operator is told the name may still be held. A silent best-effort
# step is indistinguishable from one that worked.
echo "M20 a failed logout becomes silent (the remediation is dropped)"
mutate "$DRIVER" 's@https://login.tailscale.com/admin/machines@the admin console@'
check "M20 a failed logout is reported" "ts-logout exits 0 when the logout itself fails"

echo "M21 a missing hand-off takes the destroy down with it (die escapes)"
mutate "$DRIVER" 's|^  ) \|\| rc=\$?|  )|'
check "M21 prepare is contained" "ts-logout exits 0 when the hand-off file is missing"

echo "M22 ts-logout stops actually logging out"
mutate "$DRIVER" 's|^    if remote_run '"'"'sudo tailscale logout'"'"'; then|    if true; then|'
check "M22 logout really runs" "ts-logout logs the node out when the VM is running"

echo "=== surfacing ==="

echo "M23 the marker is read but no longer fails the status command"
mutate "$DRIVER" 's|^  printf '"'"'ts name:   MISMATCH — this node does not own the name the demo URL uses\\n'"'"'\n  printf|  printf|; /ts name:   MISMATCH/{n;n;s/^  return 1$/  return 0/}'
check "M23 mismatch fails status" "status FAILS when the VM recorded a name mismatch"

echo "M24 status stops reading the marker at all"
mutate "$DRIVER" 's|^  marker="$(ts_name_marker)"|  marker=""|'
check "M24 status reads the marker" "status FAILS when the VM recorded a name mismatch"

echo "M25 the writer and reader marker paths drift apart"
mutate "$DRIVER" 's|/var/lib/signalloom/tailscale-name-mismatch|/var/lib/signalloom/ts-name-mismatch|'
check "M25 marker path is one contract" "the marker path is the same string in the writer and the reader"

echo "=== documentation ==="

echo "M26 the false reclaim claim is put back"
mutate "$STARTUP" 's|^  # Deterministic, derived from the environment key by Terraform. Requested, not|  # Deterministic. The rebuilt VM reclaims sl-demo-1 rather than accumulating|'
check "M26 false claim stays gone" "the false reclaim claim is gone from the startup script"

echo ""
echo "=== restored: the suite must be green again ==="
restore_all
if ! bats "$SUITE" >/dev/null 2>&1; then
  echo "HARNESS ERROR: suite is not green after restore" >&2
  bats "$SUITE" 2>&1 | tail -20 >&2
  exit 2
fi
echo "  GREEN"
echo ""
echo "proven: ${PASS}   NOT proven: ${FAIL}"
[[ "$FAIL" -eq 0 ]]
