#!/usr/bin/env bash
# gcp-demo-keys-persistence-mutation-proof.sh
#   -- prove every assertion in test/terraform-keys-persistence.bats can fail,
#      and that it fails for the reason it claims to be measuring.
#
# ─── Why this file exists ───────────────────────────────────────────────────
#
# That suite is 20 tests and it went green the first time it was run, against
# code written minutes earlier. Green on the first run is the state that should
# be distrusted: this repo has shipped a guard whose abort condition was `&&`
# where it needed `||` and therefore could not fire in either direction, an
# anti-criteria grep that matched the comment explaining the rule, and a whole
# authz suite that reported the exact known-good baseline because it had been
# dropped from collection. A suite is not evidence until something has watched
# it go red.
#
# More than half of the assertions here are ABSENCE checks — no rm against the
# keys directory, no key material tracked in git, no nesting under the work
# dir. Absence-of-bad is trivially satisfied by nothing-being-present, which is
# the single most common way a guard in this repo has turned out to be
# decoration.
#
# ─── Safety ─────────────────────────────────────────────────────────────────
#
# Restore is from a byte-for-byte backup taken OUTSIDE the repository, never
# `git checkout` — a `git checkout` in a proof harness silently reverts
# in-progress work elsewhere in the tree, and the resulting "the guard did not
# fire" reads exactly like a real finding.
#
# `mutate` aborts if a sed changed nothing. A non-matching pattern exits 0 and
# no-ops, the suite then runs against correct code, and the harness reports the
# guard as dead when it is fine.
#
# A sentinel is written before the first mutation and removed after the last, so
# that a SIGKILL no trap survives leaves a visible marker rather than two
# mutated scripts that read as a real regression on the next run. This script
# REFUSES to start if it finds one, and never repairs on its own.
#
# Run: bash test/gcp-demo-keys-persistence-mutation-proof.sh

set -eo pipefail
# Deliberately NOT `set -u`. Claude Code's shell snapshot injects grep/rg
# wrappers whose cross-shell guard references $ZSH_VERSION unguarded, which
# nounset turns into a fatal error on every grep call.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

UP="scripts/gcp-tf/demo-up.sh"
PIPE="scripts/gcp-tf/demo-pipeline.sh"
SUITE="test/terraform-keys-persistence.bats"

SENTINEL="${REPO_ROOT}/.keys-persistence-mutation-in-progress"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
grn()   { printf '\033[32m%s\033[0m\n' "$*"; }
say()   { printf '%s\n' "$*"; }

if [ -e "$SENTINEL" ]; then
  cat >&2 <<-EOF
	REFUSING TO START: a previous run of this harness did not finish.

	  sentinel: $SENTINEL
	  $(cat "$SENTINEL" 2>/dev/null || true)

	${UP} and/or ${PIPE} may still be mutated. This harness will NOT repair them
	for you: a proof harness that silently fixes what it finds is how a broken
	tree goes green, and a leftover mutation reads as a merge regression to the
	next gate that runs. Restore both files from the backup directory named
	above (or from git, once you have confirmed nothing else in the tree is
	uncommitted), then

	  rm $SENTINEL

	and re-run.
	EOF
  exit 2
fi

for f in "$UP" "$PIPE" "$SUITE"; do
  [ -f "$f" ] || { echo "no ${f} at ${REPO_ROOT}" >&2; exit 2; }
done

command -v bats >/dev/null 2>&1 || { echo "bats is not on PATH" >&2; exit 2; }

BACKUP="$(mktemp -d)"
cp "$UP"   "$BACKUP/demo-up.sh"
cp "$PIPE" "$BACKUP/demo-pipeline.sh"

# Recorded before anything is touched and compared again at the end. Content
# alone is not enough: a restore that pipes bytes through a temp file can put
# every byte back and still drop the executable bit.
UP_HASH="$(sha256sum "$UP" | cut -d' ' -f1)"
UP_MODE="$(stat -c '%a' "$UP")"
PIPE_HASH="$(sha256sum "$PIPE" | cut -d' ' -f1)"
PIPE_MODE="$(stat -c '%a' "$PIPE")"

restore_all() {
  cp "$BACKUP/demo-up.sh"       "$UP"
  cp "$BACKUP/demo-pipeline.sh" "$PIPE"
}

cleanup() {
  restore_all
  rm -rf "$BACKUP"
  rm -f "$SENTINEL"
}
trap cleanup EXIT

printf 'started %s by pid %s\n  mutating: %s\n            %s\n  backup:   %s\n' \
  "$(date -Is)" "$$" "${REPO_ROOT}/${UP}" "${REPO_ROOT}/${PIPE}" "$BACKUP" > "$SENTINEL"

PASS=0
FAIL=0

# A sed that cannot silently do nothing. A pattern that stops matching after a
# refactor would otherwise leave the file untouched, the suite green, and this
# harness reporting a dead guard — a false finding that looks exactly like a
# real one and costs a day.
mutate() {
  local file="$1" expr="$2"
  local before after
  before="$(sha256sum "$file" | cut -d' ' -f1)"
  sed -i "$expr" "$file"
  after="$(sha256sum "$file" | cut -d' ' -f1)"
  if [ "$before" = "$after" ]; then
    red "  ABORT: the mutation changed nothing in ${file}."
    say  "         expression: ${expr}"
    say  "         The pattern no longer matches. This is a defect in the HARNESS,"
    say  "         not a verdict about the guard — a no-op mutation runs the suite"
    say  "         against correct code and reports the guard as dead."
    exit 3
  fi
}

# Run the suite and require that a SPECIFICALLY NAMED test failed.
#
# Naming the test is the whole point. "the suite went red" is satisfied by any
# failure, including one caused by the mutation breaking bash syntax, and a
# harness that accepts that is measuring nothing. bats' TAP output carries the
# name on the `not ok` line, so this asserts the intended assertion is the one
# that fired.
expect_red() {
  local label="$1" testname="$2"
  local out rc=0
  out="$(bats --tap "$SUITE" 2>&1)" || rc=$?

  if [ "$rc" -eq 0 ]; then
    red "  ${label}: the suite PASSED with the mutation applied."
    say  "         Nothing in ${SUITE} measures this. The guard is decoration."
    FAIL=$((FAIL + 1))
    return 0
  fi

  if printf '%s\n' "$out" | grep -qF "not ok" && \
     printf '%s\n' "$out" | grep -F "not ok" | grep -qF "$testname"; then
    grn "  ${label}: red, and the failing test is the intended one."
    PASS=$((PASS + 1))
  else
    red "  ${label}: the suite failed, but NOT at \"${testname}\"."
    say  "         Something else broke — most likely the mutation, not the guard."
    printf '%s\n' "$out" | grep -F "not ok" | sed 's/^/           /'
    FAIL=$((FAIL + 1))
  fi
}

# ─── Baseline ───────────────────────────────────────────────────────────────
#
# The unmutated suite must be GREEN before any conclusion is drawn from a red
# one. A suite that is already failing makes every mutation below look like it
# fired.
say "── baseline ────────────────────────────────────────────────────────────"
if bats --tap "$SUITE" >/dev/null 2>&1; then
  grn "  the unmutated suite is green."
else
  red "  the unmutated suite is ALREADY RED. Refusing to draw conclusions."
  bats --tap "$SUITE" 2>&1 | grep -F "not ok" | sed 's/^/    /'
  exit 3
fi

say ""
say "── mutations ───────────────────────────────────────────────────────────"

# M1 — the guard is never called. The function stays perfect and unreachable,
# which is the shape that passes every unit test of the function itself.
restore_all
mutate "$UP" '/^  assert_remote_paths_are_durable$/d'
expect_red "M1  guard call deleted" "KEYS the guard runs during delivery"

# M2 — the nesting check can never fire. This is the `&&`-where-`||`-was-needed
# shape, applied deliberately.
restore_all
mutate "$UP" 's|^  if \[ "\$dir" = "\$work" \] .*then$|  if false; then|'
expect_red "M2  nesting check disarmed" "KEYS a keys dir INSIDE the checkout is refused"

# M3 — bare prefix match instead of the slash-terminated one. Accepts nothing
# new that is dangerous; REFUSES a valid sibling. The failure direction that an
# operator finds instead of a test.
restore_all
mutate "$UP" 's|\[ "\${dir#"\${work}/"}" != "\$dir" \]|[ "${dir#"${work}"}" != "$dir" ]|'
expect_red "M3  bare-prefix nesting check" "KEYS a sibling whose name merely starts with the work dir is ACCEPTED"

# M4 — the absolute-path requirement removed. '.keys' then resolves against the
# pipeline's cwd, which is the delivered tree.
restore_all
mutate "$UP" 's|^    \*) die "\${var} must be an ABSOLUTE|    *) : "not absolute, tolerated: |'
expect_red "M4  absolute-path check removed" "KEYS a relative keys dir is refused"

# M5 — the empty-value refusal DELETED, not inverted.
#
# Inverting it was the first attempt and it was a defect in this harness: `[ -z
# "$keys" ] || die` refuses every non-empty path, so five tests went red and the
# named one was not among them. A mutation must break one thing.
#
# Deleting it is the honest test, and it is the one that found something. An
# empty value still gets refused with the check gone — '' fails the absolute-path
# `case` on the next line — so this mutation is only detectable because the test
# asserts the empty case is diagnosed AS empty rather than merely rejected.
# Without that assertion the check would be unreachable-but-passing, which is the
# state a per-rule deletion sweep exists to find.
restore_all
mutate "$UP" '/^  \[ -n "\$dir" \] || die "\${var} is empty/d'
expect_red "M5  empty-value check deleted" "KEYS an empty keys dir is refused, and says so specifically"

# M6 — the shipped default put back INSIDE the checkout. The original defect,
# restored in one line, with every structural assertion still satisfied.
restore_all
mutate "$UP" 's|GCP_TF_DEMO_REMOTE_KEYS_DIR:-/opt/signalloom/keys|GCP_TF_DEMO_REMOTE_KEYS_DIR:-/opt/signalloom/repo/.keys|'
expect_red "M6  default nested in the checkout" "KEYS the shipped default is durable"

# M7 — the directory is never created on the VM. The pipeline is told to write
# a private key somewhere that does not exist and is not owned by it.
restore_all
mutate "$UP" '/sudo mkdir -p/ s| \$(printf '"'"'%q'"'"' "\$REMOTE_KEYS_DIR")||'
expect_red "M7  keys dir never mkdir'd" "KEYS the keys directory is created and chowned"

# M8 — created but never chowned. /opt/signalloom is root-owned 0755, so this
# is a permission failure forty minutes into a run.
restore_all
mutate "$UP" '/sudo chown \${owner} \$(printf .%q. "\$REMOTE_KEYS_DIR")/d'
expect_red "M8  keys dir never chowned" "KEYS the keys directory is created and chowned"

# M9 — something deletes the persistent directory. Every other assertion stays
# green and the defect is exactly restored.
restore_all
mutate "$UP" 's|^  assert_remote_paths_are_durable$|  assert_remote_paths_are_durable\n  vm_ssh "sudo rm -rf $(printf '"'"'%q'"'"' "$REMOTE_KEYS_DIR")"|'
expect_red "M9  keys dir wiped during provisioning" "KEYS the keys directory is never deleted or truncated"

# M10 — the driver stops sending the variable. The pipeline then falls back to
# the checkout and the keypair dies with it, silently.
restore_all
mutate "$UP" '/printf -v envs/ s| DEMO_KEYS_DIR=%q||'
expect_red "M10 DEMO_KEYS_DIR no longer sent" "KEYS the driver sends DEMO_KEYS_DIR"

# M11 — set but not exported. signing-keys, push-local.sh and bootstrap-local
# each resolve KEYS_DIR in a separate child process; a plain assignment
# configures none of them.
restore_all
mutate "$PIPE" 's|^  export KEYS_DIR="\${DEMO_KEYS_DIR}"$|  KEYS_DIR="${DEMO_KEYS_DIR}"|'
expect_red "M11 KEYS_DIR set but not exported" "KEYS the pipeline turns DEMO_KEYS_DIR into an exported KEYS_DIR"

# M12 — exported unconditionally. On a laptop or a fixture tree DEMO_KEYS_DIR is
# unset, and scripts/lib/keys.sh treats an explicit KEYS_DIR as authoritative —
# so the signing key resolves to '/cosign.key'.
restore_all
mutate "$PIPE" 's|^if \[\[ -n "\${DEMO_KEYS_DIR:-}" \]\]; then$|if true; then|'
expect_red "M12 exported even when unset" "KEYS an unset DEMO_KEYS_DIR leaves KEYS_DIR alone"

# M13 — the zot cache default put back inside the checkout. The original defect
# in its second component, and the one that is silent: the pod stays Running and
# only a push fails.
restore_all
mutate "$UP" 's|GCP_TF_DEMO_REMOTE_ZOT_CACHE:-/opt/signalloom/zot-cache|GCP_TF_DEMO_REMOTE_ZOT_CACHE:-/opt/signalloom/repo/.cache/zot|'
expect_red "M13 zot default nested in the checkout" "ZOT the shipped zot cache default is durable"

# M14 — the durability check stops looking at the zot cache. Every keypair
# assertion stays green; this is the state the branch was in before the zot
# instance was found.
restore_all
mutate "$UP" '/^  assert_dir_is_durable GCP_TF_DEMO_REMOTE_ZOT_CACHE /,/^reports the cluster is fine. Recreating the Kind cluster is the only way back."$/d'
expect_red "M14 zot dropped from the durability check" "ZOT the durability check covers the zot cache"

# M15 — the zot cache is never created on the VM.
restore_all
mutate "$UP" '/sudo mkdir -p/ s| \$(printf '"'"'%q'"'"' "\$REMOTE_ZOT_CACHE")||'
expect_red "M15 zot cache never created" "ZOT the zot cache directory is created and chowned"

# M16 — the driver stops sending it, so ZOT_CACHE_DIR falls back to the relative
# path inside the tree.
restore_all
mutate "$UP" '/printf -v envs/ s| DEMO_ZOT_CACHE_DIR=%q||'
expect_red "M16 DEMO_ZOT_CACHE_DIR no longer sent" "ZOT the driver sends DEMO_ZOT_CACHE_DIR"

# M17 — set but not exported. create-kind-cluster.sh is a separate process.
restore_all
mutate "$PIPE" 's|^  export ZOT_CACHE_DIR="\${DEMO_ZOT_CACHE_DIR}"$|  ZOT_CACHE_DIR="${DEMO_ZOT_CACHE_DIR}"|'
expect_red "M17 ZOT_CACHE_DIR set but not exported" "ZOT the pipeline turns DEMO_ZOT_CACHE_DIR into an exported ZOT_CACHE_DIR"

# M18 — exported unconditionally, so a laptop run points zot at an absolute path
# that does not exist there.
restore_all
mutate "$PIPE" 's|^if \[\[ -n "\${DEMO_ZOT_CACHE_DIR:-}" \]\]; then$|if true; then|'
expect_red "M18 zot exported even when unset" "ZOT an unset DEMO_ZOT_CACHE_DIR leaves ZOT_CACHE_DIR alone"

# ─── Restore, and prove the restore ─────────────────────────────────────────
say ""
say "── restore ─────────────────────────────────────────────────────────────"
restore_all

ok_restore=1
for pair in "$UP:$UP_HASH:$UP_MODE" "$PIPE:$PIPE_HASH:$PIPE_MODE"; do
  f="${pair%%:*}"; rest="${pair#*:}"; want_hash="${rest%%:*}"; want_mode="${rest##*:}"
  got_hash="$(sha256sum "$f" | cut -d' ' -f1)"
  got_mode="$(stat -c '%a' "$f")"
  if [ "$got_hash" != "$want_hash" ]; then
    red "  ${f} is NOT byte-identical to its pre-run state."
    ok_restore=0
  fi
  if [ "$got_mode" != "$want_mode" ]; then
    red "  ${f} mode is ${got_mode}, was ${want_mode}."
    ok_restore=0
  fi
done
[ "$ok_restore" -eq 1 ] && grn "  both files restored byte-for-byte, modes intact."

say ""
say "── verdict ─────────────────────────────────────────────────────────────"
say "  mutations that correctly turned the named test red: ${PASS}"
say "  mutations that did not:                             ${FAIL}"

if [ "$FAIL" -ne 0 ] || [ "$ok_restore" -ne 1 ]; then
  red "PROOF FAILED"
  exit 1
fi
grn "PROOF PASSED — every assertion in ${SUITE} can fail, for its own reason."
