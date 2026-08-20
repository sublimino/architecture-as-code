#!/usr/bin/env bats
# KEYS_DIR is absolute almost everywhere. Nothing may concatenate a prefix onto
# it.
#
# 72d0166 made KEYS_DIR resolve through `git rev-parse --git-common-dir` so that
# every worktree of a clone shares one signing key. That was right, but it
# changed the variable from always-relative to almost-always-absolute, and one
# caller had been walking back to the repo root by hand:
#
#   $(MAKE) -C d2-osramp-fleet bootstrap-local COSIGN_PUB=../$(KEYS_DIR)/cosign.pub
#
# which then produced
#
#   ..//home/ci/osramp-demo-ci-2/.keys/cosign.pub not found;
#     run 'make signing-keys' at the repo root
#
# The leading slash is swallowed by the concatenation. Both GCP CI lanes aborted
# on it before stage 1 — not a test failure, no summary.json, so the wrapper had
# nothing to report and both VMs suspended into a state indistinguishable from a
# clean pass.
#
# The error is worse than the outage. It names a file that exists and is valid,
# and it tells you to run `make signing-keys`, which had already succeeded two
# minutes earlier. Anyone following that instruction is sent away from the bug.
#
# This is the SECOND time this exact class shipped. 5d31ff6 swept for it, added
# keys_dir_abs() to scripts/lib/keys.sh and $(abspath …) to AUDIT_ANCHOR_KEYS,
# and wrote test/audit-anchor-keys-path.bats — but scoped all of it to the
# audit-anchor entry points and missed the identical concatenation 500 lines
# earlier. A guard aimed at one site does not cover a class, so this one is
# derived from the Makefile itself and covers every use.

setup() {
  repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  makefile="${repo_root}/Makefile"
}

@test "KEYSPATH no Makefile line concatenates a prefix onto \$(KEYS_DIR)" {
  # The signature of the bug is a path separator immediately before the
  # reference: `../$(KEYS_DIR)`, `foo/$(KEYS_DIR)`. Passing $(KEYS_DIR) bare, or
  # wrapped in $(abspath …), is correct and stays silent here.
  local offenders
  # Comment lines are skipped deliberately: this file and the Makefile both
  # SPELL the anti-pattern out to explain it, and a guard that fires on its own
  # documentation gets muted, which is worse than no guard at all.
  offenders="$(grep -vE '^[[:space:]]*#' "$makefile" | grep -nE '[^ 	="'"'"'(]/\$\(KEYS_DIR\)' || true)"

  if [ -n "$offenders" ]; then
    echo "A prefix is concatenated onto \$(KEYS_DIR). KEYS_DIR is absolute in" >&2
    echo "any tree with a .git, which is every checkout, every worktree, AND the" >&2
    echo "CI VM (vm-pipeline.sh runs git init after extracting the tarball)." >&2
    echo "Use \$(abspath \$(KEYS_DIR)) instead, as AUDIT_ANCHOR_KEYS does:" >&2
    echo "$offenders" >&2
    return 1
  fi
}

@test "KEYSPATH no shell script concatenates a prefix onto \${KEYS_DIR}" {
  # Same class on the shell side. keys_dir_abs() in scripts/lib/keys.sh exists
  # for callers that must change directory; nothing should hand-roll a prefix.
  local offenders
  offenders="$(grep -rnE '[^ 	="'"'"'$]/\$\{?KEYS_DIR\}?' \
    --include='*.sh' "${repo_root}/scripts" | grep -vE ':[[:space:]]*#' || true)"

  if [ -n "$offenders" ]; then
    echo "A prefix is concatenated onto \${KEYS_DIR}; use keys_dir_abs instead:" >&2
    echo "$offenders" >&2
    return 1
  fi
}

# The two above read the source. This one reads what make actually expands, so a
# concatenation written in a form the patterns do not anticipate still fails.
@test "KEYSPATH bootstrap-local expands to a path with no doubled slash" {
  local expanded
  # `make -n` echoes recipe COMMENT lines too, and the recipe explains this very
  # bug, so filter them out before pattern-matching the commands.
  expanded="$(cd "$repo_root" && make -n bootstrap-local 2>/dev/null \
    | grep -vE '^[[:space:]]*#' || true)"
  [ -n "$expanded" ] || skip "make -n bootstrap-local produced nothing"

  # `..//abs/path` is the exact shape that aborted both lanes.
  if printf '%s' "$expanded" | grep -qE '\.\./+/'; then
    echo "bootstrap-local expands a '../' onto an absolute path:" >&2
    printf '%s\n' "$expanded" | grep -E '\.\./+/' >&2
    return 1
  fi

  # Any doubled slash mid-path is the same defect wearing a different prefix.
  if printf '%s' "$expanded" | grep -oE '[A-Za-z0-9_.-]+=[^ ]*//[^ ]*' | grep -q .; then
    echo "bootstrap-local expands an argument containing a doubled slash:" >&2
    printf '%s' "$expanded" | grep -oE '[A-Za-z0-9_.-]+=[^ ]*//[^ ]*' >&2
    return 1
  fi
}

# The three above are order-independent: they read source, and an expansion of
# source. This one was not, and that is why it failed on every freshly-built CI
# VM and passed on every developer machine.
#
# It used to assert that $(COSIGN_PUB) EXISTS. This file runs in the stage
# advertised as "[3/8] Static gates (no cluster required)"; `make signing-keys`
# creates the key at [4/8]. A developer's checkout already has .keys/ from an
# earlier run, so the file was found and the test went green. A VM rebuilt from
# scratch has no earlier run, and a perfectly well-formed path failed:
#
#   not ok 4 … COSIGN_PUB=/home/ci/osramp-demo-ci-2/.keys/cosign.pub does not exist
#
# which is a report about the clock, not about the path. Worse, it is the same
# report a genuinely mis-constructed path produces, so the signal this suite
# exists to carry was buried under a false one that fired every cold run.
#
# EXISTENCE is not this gate's to own, and it is already owned. The assertion
# this test was written to guard —
#
#   d2-osramp-fleet/Makefile:29
#   @test -f $(COSIGN_PUB) || { echo "… run 'make signing-keys'"; exit 1; }
#
# — is a hard abort, it runs on every CI run, and by the time it runs
# signing-keys has completed. What a static gate CAN own at any point in the
# ordering is PATH AGREEMENT: the path handed to the fleet sub-make must name
# the file `make signing-keys` writes. That is the defect this test was written
# for — a mis-constructed path — and it is decidable with no key material
# anywhere on disk.
#
# The obvious hole in an equality assertion is that two paths derived the same
# wrong way agree with each other perfectly. So equality is NOT the only
# assertion here and it is not the load-bearing one. Both ends are also pinned
# to facts that follow from neither expansion's arithmetic:
#
#   * the path must be absolute, with no `..` component and no doubled slash —
#     the sub-make runs -C d2-osramp-fleet, so anything else resolves one
#     directory below the repo root;
#   * cosign.pub is the fixed output name of `cosign generate-key-pair`, and is
#     the literal d2-osramp-fleet/Makefile:29 stats;
#   * the keys directory's own last component must be `.keys`;
#   * the PARENT of the keys directory must ALREADY EXIST on disk.
#
# The last two are what survive both sides being wrong together: rename `.keys`
# in the KEYS_DIR definition, or re-root it under a directory that is not there,
# and both expansions change in lockstep while these two go red. The parent
# check is also the one that would have caught the ORIGINAL bug in this very
# gate, on a fresh VM, with no keys present — ..//home/ci/osramp-demo/.keys
# resolves from d2-osramp-fleet/ to a parent that is not on disk, whereas the
# correct absolute path's parent is the repo root, which exists before anything
# is generated. It is a fact about the filesystem, not about make.
#
# Falsified by test/keys-path-agreement-mutation-proof.sh, which mutates the
# real Makefile — including the two lockstep mutations named above.
@test "KEYSPATH the COSIGN_PUB handed to the fleet sub-make names the file signing-keys writes" {
  local genline keydir keyparent pub pubdir

  # Assert the MECHANISM before asserting anything about it. If signing-keys is
  # restructured so that it no longer runs cosign generate-key-pair, this test
  # must fail by name rather than quietly stop testing.
  genline="$(cd "$repo_root" && make -n signing-keys 2>/dev/null \
    | grep -vE '^[[:space:]]*#' | grep -E 'cosign generate-key-pair' | head -1 || true)"
  if [ -z "$genline" ]; then
    echo "MECHANISM MISSING: make -n signing-keys no longer runs" >&2
    echo "'cosign generate-key-pair'. This test derives the signing key" >&2
    echo "directory from that line; re-point it at whatever writes cosign.pub." >&2
    return 1
  fi

  # generate-key-pair writes cosign.pub into $PWD, so the directory the recipe
  # cds into IS the directory the public key lands in. Derived from a DIFFERENT
  # recipe than the one under test, deliberately.
  keydir="$(printf '%s\n' "$genline" \
    | sed -nE 's@^[[:space:]]*cd[[:space:]]+([^[:space:]]+)[[:space:]]+&&.*@\1@p')"
  if [ -z "$keydir" ]; then
    # Each of these sentences is kept whole on one line on purpose. The
    # mutation harness greps for a fragment of it to prove WHICH assertion
    # fired, and a phrase split across two echoes matches nothing — which
    # reads, wrongly, as a dead guard.
    echo "MECHANISM MISSING: no 'cd' precedes cosign generate-key-pair." >&2
    echo "There is no producer directory for COSIGN_PUB to agree with:" >&2
    echo "$genline" >&2
    return 1
  fi

  pub="$(cd "$repo_root" && make -n bootstrap-local 2>/dev/null \
    | grep -vE '^[[:space:]]*#' \
    | grep -oE 'COSIGN_PUB=[^ ]+' | head -1 | cut -d= -f2- || true)"
  if [ -z "$pub" ]; then
    echo "NO COSIGN_PUB: bootstrap-local hands no COSIGN_PUB to the fleet" >&2
    echo "sub-make, so d2-osramp-fleet/Makefile:29 would stat an empty path." >&2
    return 1
  fi

  # ── shape ──────────────────────────────────────────────────────────────────
  case "$pub" in
    /*) ;;
    *)  echo "NOT ABSOLUTE: COSIGN_PUB=$pub" >&2
        echo "The fleet sub-make runs with -C d2-osramp-fleet, so this resolves" >&2
        echo "one directory BELOW the repo root. Use \$(abspath \$(KEYS_DIR))." >&2
        return 1 ;;
  esac
  case "$pub" in
    *//*) echo "DOUBLED SLASH: COSIGN_PUB=$pub" >&2
          echo "That is the exact shape a prefix concatenated onto an absolute" >&2
          echo "KEYS_DIR produces, and it aborted both GCP CI lanes." >&2
          return 1 ;;
  esac
  case "$pub" in
    ../*|*/../*|*/..)
          echo "DOTDOT COMPONENT: COSIGN_PUB=$pub" >&2
          echo "A walk back up the tree is how this defect keeps arriving." >&2
          echo "\$(abspath …) collapses it; hand-written '..' does not." >&2
          return 1 ;;
  esac

  # ── filename ───────────────────────────────────────────────────────────────
  if [ "${pub##*/}" != "cosign.pub" ]; then
    echo "WRONG FILENAME: COSIGN_PUB=$pub" >&2
    echo "cosign.pub is the fixed output name of 'cosign generate-key-pair'," >&2
    echo "and is the literal d2-osramp-fleet/Makefile:29 stats." >&2
    return 1
  fi

  # ── agreement ──────────────────────────────────────────────────────────────
  pubdir="${pub%/*}"
  if [ "$pubdir" != "$keydir" ]; then
    echo "PATH DISAGREEMENT: bootstrap-local hands the fleet sub-make" >&2
    echo "    $pub" >&2
    echo "but 'make signing-keys' writes cosign.pub into" >&2
    echo "    $keydir" >&2
    echo "One of the two is constructed wrongly. The file's absence at this" >&2
    echo "point is expected and is not what this test is about." >&2
    return 1
  fi

  # ── anchors ────────────────────────────────────────────────────────────────
  # Everything above compares two make expansions against each other, so two
  # paths broken in the same way agree. These two do not consult make's
  # arithmetic at all, and are what catches that case.
  if [ "${keydir##*/}" != ".keys" ]; then
    echo "ANCHOR (name): the signing key directory is" >&2
    echo "    $keydir" >&2
    echo "whose last component is '${keydir##*/}', not '.keys'. Both expansions" >&2
    echo "may agree on this and still be wrong, which is why it is checked" >&2
    echo "against the literal rather than against the other path." >&2
    return 1
  fi

  keyparent="${keydir%/*}"
  [ -n "$keyparent" ] || keyparent="/"
  if [ ! -d "$keyparent" ]; then
    echo "ANCHOR (parent): the signing key directory" >&2
    echo "    $keydir" >&2
    echo "has no parent on disk:" >&2
    echo "    $keyparent" >&2
    echo "The keys directory itself may legitimately be absent — this gate runs" >&2
    echo "BEFORE 'make signing-keys' — but the directory it will be created IN" >&2
    echo "must already exist. ..//home/ci/osramp-demo/.keys is exactly this" >&2
    echo "failure, and it is decidable with no key material anywhere." >&2
    return 1
  fi
}
