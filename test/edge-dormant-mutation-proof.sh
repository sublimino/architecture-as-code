#!/usr/bin/env bash
# edge-dormant-mutation-proof.sh — prove the dormant-edge guards can fail.
#
# A green suite is evidence of nothing until each guard has been shown to go RED
# for the right reason. This repo has shipped guards that were pure decoration:
# a `! grep` that is dead under `set -e`, a `[ "$status" -ne 0 ]` that reads a
# MISSING FILE as "pattern absent", a mechanism assertion that passed vacuously
# because its own discovery returned empty. Every one of them was green.
#
# The guards proven here are the ones that keep "this estate has no web edge"
# true by test rather than by comment:
#
#   test/terraform-edge-dormant.bats               the module graph contains no
#                                                  edge module, and the path
#                                                  back is intact
#   terraform/environments/tests/edge_dormant.tftest.hcl
#                                                  local.edge_environments is
#                                                  empty and the hand-off
#                                                  reports the tunnel
#   terraform/modules/network/tests/network.tftest.hcl
#                                                  the health-check ingress is
#                                                  created only for a lane that
#                                                  really has a load balancer
#
# So: introduce each defect into the real file, confirm the EXPECTED test goes
# red, restore, confirm green again.
#
# Restore is from a byte-for-byte backup taken here, NOT `git checkout`.
# `git checkout <dir>` in a proof harness wipes in-progress edits elsewhere in
# the tree, and the resulting "the guard did not fire" reads exactly like a real
# finding.
#
# Offline: `terraform get` and `terraform test` both run against locally
# installed providers and mocked cloud providers. No network, no credentials.
#
# Run: test/edge-dormant-mutation-proof.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ROOT_MAIN="terraform/environments/main.tf"
NET_MAIN="terraform/modules/network/main.tf"
EDGE_TESTS="terraform/modules/edge/tests"

BATS_SUITE="test/terraform-edge-dormant.bats"
ROOT_TF_DIR="terraform/environments"
NET_TF_DIR="terraform/modules/network"

BACKUP="$(mktemp -d)"
trap 'restore_all; rm -rf "$BACKUP"' EXIT

mkdir -p "$BACKUP/$(dirname "$ROOT_MAIN")" "$BACKUP/$(dirname "$NET_MAIN")"
cp "$ROOT_MAIN" "$BACKUP/$ROOT_MAIN"
cp "$NET_MAIN" "$BACKUP/$NET_MAIN"
cp -R "$EDGE_TESTS" "$BACKUP/edge-tests"

restore_all() {
  cp "$BACKUP/$ROOT_MAIN" "$ROOT_MAIN"
  cp "$BACKUP/$NET_MAIN" "$NET_MAIN"
  rm -rf "$EDGE_TESTS"
  cp -R "$BACKUP/edge-tests" "$EDGE_TESTS"
}

PASS=0
FAIL=0

# A sed that cannot silently do nothing.
#
# A non-matching pattern no-ops while returning 0, so the mutation never lands,
# the suite stays green, and the harness reports "guard did not fire" — a false
# finding that looks exactly like a real one.
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

# Same contract as mutate(), for the one edit sed cannot express: stripping the
# leading "# " from a multi-line block. The perl is the same expression the bats
# suite uses, so the two cannot drift in what "uncommenting the block" means.
uncomment_edge_block() {
  local file="$1" before after
  before="$(md5sum "$file" | cut -d' ' -f1)"
  perl -0pi -e 's/^# module "edge" \{\n(.*?)^# \}$/my $b=$1; $b =~ s{^# ?}{}gm; "module \"edge\" {\n$b}"/sme' "$file"
  after="$(md5sum "$file" | cut -d' ' -f1)"
  if [[ "$before" == "$after" ]]; then
    echo "HARNESS ERROR: the commented module \"edge\" block was not uncommented." >&2
    echo "               Its shape in ${file} has changed; fix this harness AND" >&2
    echo "               the matching helper in ${BATS_SUITE}." >&2
    exit 2
  fi
}

# Runs the bats suite and reports the NAMES of the tests that failed.
#
# Names, not the `not ok <n>` numbers: inserting a test in the middle of a suite
# renumbers everything below it, and a harness that reports "NOT PROVEN" for a
# guard that fired perfectly well is worse than no harness — the natural
# response is to go and "fix" working code.
#
# A non-zero bats is the EXPECTED outcome here, and `set -o pipefail` promotes
# it to the pipeline's status, so `|| true` at the call site is what stops
# `set -e` from killing the harness on its own success.
failing_bats_tests() {
  bats "$BATS_SUITE" 2>&1 | sed -n 's/^not ok [0-9]* //p'
}

# The same idea for `terraform test`, whose failure lines name the run.
failing_tf_runs() {
  local dir="$1"
  terraform -chdir="$dir" test 2>&1 |
    sed 's/\x1b\[[0-9;]*m//g' |
    sed -n 's/^  run "\([^"]*\)"\.\.\. fail$/\1/p'
}

check_bats() {
  local label="$1" want="$2" got
  got="$(failing_bats_tests || true)"
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

check_tf() {
  local label="$1" dir="$2" want="$3" got
  got="$(failing_tf_runs "$dir" || true)"
  if [[ "$got" == *"$want"* ]]; then
    echo "  RED as expected — run \"${want}\"  [${label}]"
    PASS=$((PASS + 1))
  else
    echo "  *** NOT PROVEN: expected run \"${want}\" to fail. Failures were:" >&2
    printf '        %s\n' "${got:-<none>}" >&2
    FAIL=$((FAIL + 1))
  fi
  restore_all
}

echo "=== baseline: everything must be green before any mutation ==="
if ! bats "$BATS_SUITE" >/dev/null 2>&1; then
  echo "HARNESS ERROR: ${BATS_SUITE} is not green before mutation" >&2
  bats "$BATS_SUITE" 2>&1 | tail -20 >&2
  exit 2
fi
if ! terraform -chdir="$ROOT_TF_DIR" test >/dev/null 2>&1; then
  echo "HARNESS ERROR: ${ROOT_TF_DIR} tests are not green before mutation" >&2
  exit 2
fi
if ! terraform -chdir="$NET_TF_DIR" test >/dev/null 2>&1; then
  echo "HARNESS ERROR: ${NET_TF_DIR} tests are not green before mutation" >&2
  exit 2
fi
echo "  GREEN"
echo ""

echo "=== mutations ==="

# ── The property itself: no web edge is instantiated ────────────────────────

echo "M1  the commented module \"edge\" block is uncommented (a live HTTPS LB)"
uncomment_edge_block "$ROOT_MAIN"
check_bats "M1 module graph" "the environments root instantiates no edge module"

# ── The positive control, without which M1 proves nothing ───────────────────
#
# Every absence assertion is vacuously true against a graph that contains
# nothing. This mutation empties the graph of a module that IS live, and the
# control must notice. If this one cannot go red, the guard is capable of
# reporting a clean estate because it read no configuration at all.

echo "M2  the live module \"network\" block is commented out (empties the graph)"
mutate "$ROOT_MAIN" 's|^module "network" {$|# module "network" {|'
mutate "$ROOT_MAIN" 's|^  source   = "\.\./modules/network"$|#  source   = "../modules/network"|'
check_bats "M2 positive control" "the module graph is readable and names the modules this root really instantiates"

# ── The path back must not rot ──────────────────────────────────────────────

echo "M3  one of the six edge test suites is deleted"
rm -f "$EDGE_TESTS/iap_access.tftest.hcl"
check_bats "M3 re-enable path" "the edge module and its six test suites still exist"

# ── The root's derived state ────────────────────────────────────────────────

echo "M4  local.edge_environments claims the demo lanes have an edge"
mutate "$ROOT_MAIN" 's|^  edge_environments = {}$|  edge_environments = { for k, v in local.target_environments : k => v if v.kind == "demo" }|'
check_tf "M4 dormant local" "$ROOT_TF_DIR" "no_lane_has_an_edge"

echo "M5  the hand-off reports the wished-for access mode again"
mutate "$ROOT_MAIN" 's|^  effective_access_mode = contains(keys(local.edge_environments), var.target_env) ? var.access_mode : "iap_tunnel"$|  effective_access_mode = var.access_mode|'
check_tf "M5 effective access mode" "$ROOT_TF_DIR" "the_access_mode_reported_is_the_tunnel_not_the_web_edge"

# ── The firewall conditional ────────────────────────────────────────────────

echo "M6  the health-check ingress is created unconditionally again"
mutate "$NET_MAIN" 's|^  count = var.edge_enabled ? 1 : 0$|  count = 1|'
check_tf "M6 health-check conditional" "$NET_TF_DIR" "no_edge_means_no_health_check_ingress"

echo ""
echo "=== restored: everything must be green again ==="
if ! bats "$BATS_SUITE" >/dev/null 2>&1; then
  echo "HARNESS ERROR: ${BATS_SUITE} did not return to green after restore" >&2
  exit 2
fi
if ! terraform -chdir="$ROOT_TF_DIR" test >/dev/null 2>&1; then
  echo "HARNESS ERROR: ${ROOT_TF_DIR} tests did not return to green after restore" >&2
  exit 2
fi
if ! terraform -chdir="$NET_TF_DIR" test >/dev/null 2>&1; then
  echo "HARNESS ERROR: ${NET_TF_DIR} tests did not return to green after restore" >&2
  exit 2
fi
echo "  GREEN"
echo ""

echo "=== ${PASS} proven, ${FAIL} not proven ==="
[[ "$FAIL" -eq 0 ]]
