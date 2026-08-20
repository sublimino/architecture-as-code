#!/usr/bin/env bash
# keys-path-agreement-mutation-proof.sh
#   -- prove test/keys-dir-path-safety.bats test 4 can actually fail, and prove
#      it fails for path reasons rather than for clock reasons.
#
# ─── What this file is answering ────────────────────────────────────────────
#
# Test 4 used to assert that $(COSIGN_PUB) EXISTS. That assertion was true, and
# it was true of the wrong thing: it passed on a developer machine because an
# earlier run had left .keys/ lying around, and failed on every freshly-built CI
# VM because the gate runs at stage [3/8] and `make signing-keys` runs at [4/8].
# A well-formed path and a mis-constructed one produced the same red line.
#
# It now asserts PATH AGREEMENT — that the path handed to the fleet sub-make
# names the file `make signing-keys` writes — which is decidable with no key
# material on disk. Existence stays where it was already owned, at
# d2-osramp-fleet/Makefile:29, which aborts hard and runs after signing-keys.
#
# The obvious objection to an equality assertion is that two paths derived the
# same wrong way agree with each other. M10 and M11 below exist for exactly that
# objection: each one breaks the shared KEYS_DIR definition so that BOTH
# expansions change in lockstep and the equality still holds, and each must
# still go red. If either of those ever stops firing, the equality assertion has
# become the only thing left and the guard is worth less than it reads.
#
# ─── How every mutation is run ──────────────────────────────────────────────
#
# Twice: once against the tree as it stands, and once with KEYS_DIR pointed at a
# directory that does not exist — the fresh-VM condition, reproduced without
# going near the shared .keys/ that a live demo is using. A guard that only
# fires when the key happens to be present is the defect this whole change is
# removing.
#
# M10 and M11 mutate the KEYS_DIR definition itself, and a KEYS_DIR in the
# environment overrides the Makefile's `?=`, which would mask them. Those two
# therefore run once, and say so, rather than running a pass that proves nothing.
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
# that a SIGKILL that no trap survives leaves a visible marker rather than a
# mutated Makefile that reads as a real regression on the next run. This script
# REFUSES to start if it finds one, and never repairs on its own.
#
# Run: bash test/keys-path-agreement-mutation-proof.sh

# Every mutation is a single-quoted sed expression, precisely so that `$` stays
# literal: these patterns match make variables in the Makefile, they do not
# expand against this harness's environment. SC2016 would have us double-quote
# them, which would produce patterns matching nothing and abort every mutation.
# shellcheck disable=SC2016

set -euo pipefail

# ─── Why this unset is load-bearing ─────────────────────────────────────────
#
# Makefile:43 is `export KEYS_DIR`. Make exports it to every recipe child, so
# when this harness runs under `make gcp-tf-validate` it inherits a KEYS_DIR in
# its ENVIRONMENT — and an environment variable beats `?=`, which is how
# KEYS_DIR is defined at Makefile:42. Every `make` this harness then invokes
# reads the inherited value and the definition line is dead.
#
# M10 and M11 mutate that definition line. Under the gate they changed the file
# (the hash moved, so `mutate` was satisfied) and changed NOTHING that make
# expanded, so the suite stayed green and the harness reported "the named test
# did not fail at all" — a false finding, pointing at a guard that is fine, and
# indistinguishable from a real one. Measured: 21/0 standalone, 19/2 under the
# gate, and reproduced exactly by exporting KEYS_DIR to a standalone run.
#
# So the harness takes its own environment out of the question. The proof's
# verdict must not depend on which process launched it.
unset KEYS_DIR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MAKEFILE="Makefile"
SUITE="test/keys-dir-path-safety.bats"
TESTNAME="KEYSPATH the COSIGN_PUB handed to the fleet sub-make names the file signing-keys writes"

SENTINEL="${REPO_ROOT}/.keys-path-agreement-mutation-in-progress"

if [ -e "$SENTINEL" ]; then
  cat >&2 <<-EOF
	REFUSING TO START: a previous run of this harness did not finish.

	  sentinel: $SENTINEL
	  $(cat "$SENTINEL" 2>/dev/null || true)

	${MAKEFILE} may still be mutated. This harness will not repair it for you:
	a proof harness that silently fixes what it finds is how a broken tree goes
	green. Restore ${MAKEFILE} from the backup directory named above (or from
	git, once you have confirmed nothing else in the tree is uncommitted), then

	  rm $SENTINEL

	and re-run.
	EOF
  exit 2
fi

[ -f "$MAKEFILE" ] || { echo "no ${MAKEFILE} at ${REPO_ROOT}" >&2; exit 2; }
[ -f "$SUITE" ] || { echo "no ${SUITE} at ${REPO_ROOT}" >&2; exit 2; }

BACKUP="$(mktemp -d)"
cp "$MAKEFILE" "$BACKUP/Makefile"

# Recorded before anything is touched, and compared again at the end. Content
# alone is not enough: a restore that pipes bytes through a temp file can put
# every byte back and still drop the executable bit.
ORIG_HASH="$(sha256sum "$MAKEFILE" | cut -d' ' -f1)"
ORIG_MODE="$(stat -c '%a' "$MAKEFILE")"

# A directory that exists, containing a .keys that does not. This is the fresh
# VM: no signing-keys has run yet. Nothing here touches the real .keys/.
NOKEYS_ROOT="$(mktemp -d)"
NOKEYS_DIR="${NOKEYS_ROOT}/.keys"

restore_all() {
  cp "$BACKUP/Makefile" "$MAKEFILE"
}

cleanup() {
  restore_all
  rm -rf "$BACKUP" "$NOKEYS_ROOT"
  rm -f "$SENTINEL"
}
trap cleanup EXIT

printf 'started %s by pid %s\n  mutating: %s\n  backup:   %s/Makefile\n' \
  "$(date -Is)" "$$" "${REPO_ROOT}/${MAKEFILE}" "$BACKUP" > "$SENTINEL"

PASS=0
FAIL=0

# What make actually expands. Both recipes, because a mutation to either end
# must be visible somewhere in here or it is not a mutation of anything.
expansions() {
  make -n bootstrap-local 2>/dev/null | grep -oE 'COSIGN_PUB=[^ ]+' | head -1 || true
  make -n signing-keys 2>/dev/null | grep -E 'cosign generate-key-pair' | head -1 || true
}

PRISTINE_EXPANSIONS="$(expansions)"

# A sed that cannot silently do nothing — at EITHER level.
#
# The hash check is §7b's: a pattern that no longer matches exits 0 and changes
# nothing, the suite then runs against correct code, and a passing suite is
# reported as a dead guard.
#
# The expansion check is the level below it, and it is the one that caught a
# real false finding in this file. A mutation can change the bytes on disk and
# still reach nothing: mutating the `KEYS_DIR ?=` definition is inert whenever
# KEYS_DIR arrives from the environment, because `?=` yields to it. The file
# changed, the hash moved, `mutate` was satisfied — and the thing under test
# never saw it. So the mutation must also move something make expands, or this
# is a HARNESS ERROR rather than a verdict about the guard.
mutate() {
  local expr="$1" before after now
  before="$(sha256sum "$MAKEFILE" | cut -d' ' -f1)"
  sed -i "$expr" "$MAKEFILE"
  after="$(sha256sum "$MAKEFILE" | cut -d' ' -f1)"
  if [ "$before" = "$after" ]; then
    echo "HARNESS ERROR: mutation matched nothing, ${MAKEFILE} unchanged:" >&2
    echo "  $expr" >&2
    exit 2
  fi
  now="$(expansions)"
  if [ "$now" = "$PRISTINE_EXPANSIONS" ]; then
    echo "HARNESS ERROR: ${MAKEFILE} changed but make's expansion did not." >&2
    echo "  $expr" >&2
    echo "The mutation is MASKED — most likely by a variable in the environment" >&2
    echo "overriding a '?=' definition (Makefile:43 exports KEYS_DIR)." >&2
    echo "Any verdict from this mutation would be false, so there is none." >&2
    exit 2
  fi
}

# Names, never `not ok <n>` numbers. Inserting a test renumbers everything below
# it and every expectation here would silently start pointing elsewhere.
#
# Two conditions, both required. RED alone is not proof: this repo has shipped
# guards that went red for a reason unrelated to the one claimed, and the
# harness happily counted them. The message fragment says WHICH assertion fired.
run_case() {
  local label="$1" want_msg="$2" keys="$3" out red=0 said=0
  if [ -n "$keys" ]; then
    out="$(KEYS_DIR="$keys" bats "$SUITE" 2>&1 || true)"
  else
    out="$(bats "$SUITE" 2>&1 || true)"
  fi

  if printf '%s\n' "$out" | sed -n 's/^not ok [0-9]* //p' | grep -qxF "$TESTNAME"; then
    red=1
  fi
  if printf '%s\n' "$out" | grep -qF "$want_msg"; then
    said=1
  fi

  if [ "$red" = 1 ] && [ "$said" = 1 ]; then
    echo "    RED, and for the stated reason — \"${want_msg}\"  [${label}]"
    PASS=$((PASS + 1))
  else
    echo "    *** NOT PROVEN [${label}]" >&2
    [ "$red" = 1 ] || echo "        the named test did not fail at all" >&2
    [ "$said" = 1 ] || echo "        expected message absent: ${want_msg}" >&2
    echo "        failures were:" >&2
    printf '%s\n' "$out" | sed -n 's/^not ok [0-9]* /          /p' >&2
    FAIL=$((FAIL + 1))
  fi
}

# The default: every mutation must fire in BOTH conditions.
check() {
  local label="$1" want_msg="$2"
  run_case "${label} / keys present" "$want_msg" ""
  run_case "${label} / keys ABSENT (fresh VM)" "$want_msg" "$NOKEYS_DIR"
  restore_all
}

# For mutations to the KEYS_DIR definition, which a KEYS_DIR in the environment
# would override and mask.
check_defn_only() {
  local label="$1" want_msg="$2"
  run_case "${label} / keys present (definition mutated, env override would mask)" \
    "$want_msg" ""
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

echo "=== O1: the ordering dependency is gone ==="
echo "    unmutated tree, KEYS_DIR pointed at a directory that does not exist"
O1_PUB="$(KEYS_DIR="$NOKEYS_DIR" make -n bootstrap-local 2>/dev/null \
  | grep -vE '^[[:space:]]*#' | grep -oE 'COSIGN_PUB=[^ ]+' | head -1 | cut -d= -f2- || true)"
if [ -z "$O1_PUB" ]; then
  echo "HARNESS ERROR: could not expand COSIGN_PUB for the ordering control" >&2
  exit 2
fi
if [ -e "$O1_PUB" ]; then
  echo "HARNESS ERROR: ${O1_PUB} exists, so this is not the fresh-VM condition" >&2
  exit 2
fi
echo "    COSIGN_PUB expands to ${O1_PUB}"
echo "    that file does not exist, so the OLD assertion (\`[ -f \$pub ]\`) is RED here"
if KEYS_DIR="$NOKEYS_DIR" bats "$SUITE" >/dev/null 2>&1; then
  echo "    GREEN — the rewritten test decides the question without the key"
  PASS=$((PASS + 1))
else
  echo "    *** NOT PROVEN: the suite still depends on the key existing" >&2
  KEYS_DIR="$NOKEYS_DIR" bats "$SUITE" 2>&1 | tail -20 >&2
  FAIL=$((FAIL + 1))
fi
echo ""

echo "=== the shape of the path handed to the fleet sub-make ==="

echo "M1  the original defect, verbatim: ../\$(KEYS_DIR) instead of \$(abspath …)"
mutate 's@COSIGN_PUB=$(abspath $(KEYS_DIR))/cosign.pub@COSIGN_PUB=../$(KEYS_DIR)/cosign.pub@'
check "M1 original defect" "NOT ABSOLUTE"

echo "M2  a doubled slash survives into the argument"
mutate 's@COSIGN_PUB=$(abspath $(KEYS_DIR))/cosign.pub@COSIGN_PUB=$(abspath $(KEYS_DIR))//cosign.pub@'
check "M2 doubled slash" "DOUBLED SLASH"

echo "M3  a hand-written '..' component that abspath never collapses"
mutate 's@COSIGN_PUB=$(abspath $(KEYS_DIR))/cosign.pub@COSIGN_PUB=$(abspath $(KEYS_DIR))/../.keys/cosign.pub@'
check "M3 dotdot component" "DOTDOT COMPONENT"

echo "M4  the filename drifts from the one generate-key-pair writes"
mutate 's@COSIGN_PUB=$(abspath $(KEYS_DIR))/cosign.pub@COSIGN_PUB=$(abspath $(KEYS_DIR))/cosign.pubkey@'
check "M4 wrong filename" "WRONG FILENAME"

echo "=== the two ends disagreeing ==="

echo "M5  the CONSUMER moves: bootstrap-local looks one directory deeper"
mutate 's@COSIGN_PUB=$(abspath $(KEYS_DIR))/cosign.pub@COSIGN_PUB=$(abspath $(KEYS_DIR)/sub)/cosign.pub@'
check "M5 consumer moved" "PATH DISAGREEMENT"

# M6 is the half a one-sided guard would miss. M5 could be caught by comparing
# the consumer against a hardcoded expectation; only a comparison against the
# PRODUCER catches the producer moving.
echo "M6  the PRODUCER moves: signing-keys generates into a subdirectory"
mutate 's@cd $(KEYS_DIR) && COSIGN_PASSWORD@cd $(KEYS_DIR)/sub \&\& COSIGN_PASSWORD@'
check "M6 producer moved" "PATH DISAGREEMENT"

echo "=== the mechanism this test reads ==="

echo "M7  signing-keys stops cd-ing before generating, so there is no producer path"
mutate 's@cd $(KEYS_DIR) && COSIGN_PASSWORD=""@COSIGN_PASSWORD=""@'
check "M7 no cd" "MECHANISM MISSING: no 'cd' precedes cosign generate-key-pair"

echo "M8  signing-keys stops running generate-key-pair at all"
mutate 's@cosign generate-key-pair@cosign version@'
check "M8 mechanism gone" "MECHANISM MISSING: make -n signing-keys no longer runs"

echo "M9  bootstrap-local stops passing COSIGN_PUB, so Makefile:29 stats nothing"
mutate 's@ COSIGN_PUB=$(abspath $(KEYS_DIR))/cosign.pub@@'
check "M9 no COSIGN_PUB" "NO COSIGN_PUB"

echo "=== both paths wrong TOGETHER — the equality assertion's blind spot ==="
echo "    Each of these breaks the shared KEYS_DIR definition, so the two"
echo "    expansions still agree with each other exactly. Equality passes."
echo "    Only the anchors, which consult no expansion, can see them."

echo "M10 the keys directory is renamed at its single definition"
mutate 's@/.keys,.keys)@/.signing,.signing)@'
check_defn_only "M10 lockstep rename" "ANCHOR (name)"

echo "M11 the keys directory is re-rooted under a parent that is not on disk"
mutate 's@$(abspath $(GIT_COMMON_DIR)/..)/.keys@$(abspath $(GIT_COMMON_DIR)/../nope-abff)/.keys@'
check_defn_only "M11 lockstep re-root" "ANCHOR (parent)"

echo ""
echo "=== restored: the suite must be green again ==="
restore_all
if ! bats "$SUITE" >/dev/null 2>&1; then
  echo "HARNESS ERROR: suite is not green after restore" >&2
  bats "$SUITE" 2>&1 | tail -20 >&2
  exit 2
fi
echo "  GREEN"

FINAL_HASH="$(sha256sum "$MAKEFILE" | cut -d' ' -f1)"
FINAL_MODE="$(stat -c '%a' "$MAKEFILE")"
echo ""
echo "=== restoration verified: content AND mode ==="
echo "  before  sha256 ${ORIG_HASH}  mode ${ORIG_MODE}  ${MAKEFILE}"
echo "  after   sha256 ${FINAL_HASH}  mode ${FINAL_MODE}  ${MAKEFILE}"
if [ "$ORIG_HASH" != "$FINAL_HASH" ]; then
  echo "  *** ${MAKEFILE} was NOT restored byte-for-byte" >&2
  exit 2
fi
if [ "$ORIG_MODE" != "$FINAL_MODE" ]; then
  echo "  *** ${MAKEFILE} came back with a different mode" >&2
  exit 2
fi
echo "  identical"

echo ""
echo "proven: ${PASS}   NOT proven: ${FAIL}"
[ "$FAIL" -eq 0 ]
