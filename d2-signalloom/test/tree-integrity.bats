#!/usr/bin/env bats
# d2-signalloom/test/tree-integrity.bats — a suite that fails to LOAD is silent
#
# Prompted by kagent-real-chart, who lost five tests this way: committed conflict
# markers in test/kagent-demo-harness.bats meant bats could not parse the file at
# all. The five tests did not fail — they ceased to exist. The tally dropped from
# 65 to 60 and the only signal was a parse error in the noise.
#
# That is worse than a failing test in the same way every defect this session has
# been worse than an error: the suite reports a number, the number is smaller,
# and nothing says which coverage went away. A green run over a shrunken suite is
# the shape of every false-confidence bug we have chased.
#
# Two guards, deliberately mechanical:
#   1. no tracked file carries conflict markers — the cause;
#   2. every bats file in this directory parses and declares at least one test —
#      the symptom, which also catches syntax errors, a bad shebang, or a
#      truncated write, none of which announce themselves either.
#
# Guard 2 is the load-bearing one. Guard 1 only catches the cause we have already
# seen; guard 2 catches any cause, including ones nobody has hit yet.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SELF="$(basename "$BATS_TEST_FILENAME")"
  SELF_PATH="${BATS_TEST_FILENAME#"${REPO_ROOT}/"}"
  # Anchored to line start: `=======` under a heading and `>>>>>>>` in prose are
  # common in markdown, and a looser pattern would fire on documentation.
  MARKERS='^(<<<<<<< |=======$|>>>>>>> )'
}

conflict_hits() {
  local root="$1" excluded_path="$2" matches filtered rc
  matches="$(
    cd "$root" && git ls-files -z |
      xargs -0 -r sh -c '
        pattern="$1"
        shift
        grep -lE "$pattern" "$@"
        rc=$?
        [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]
      ' sh "$MARKERS"
  )" || return 1
  [ -n "$matches" ] || return 0

  filtered="$(printf '%s\n' "$matches" | grep -vFx -- "$excluded_path")" || {
    rc=$?
    [ "$rc" -eq 1 ] || return "$rc"
    return 0
  }
  printf '%s\n' "$filtered"
}

@test "tree-integrity: no tracked file carries merge conflict markers" {
  # git ls-files, not the working directory: an untracked scratch file with
  # markers is not a problem, a committed one is.
  hits="$(conflict_hits "$REPO_ROOT" "$SELF_PATH")"
  [ -z "$hits" ] || {
    echo "committed conflict markers in:"
    echo "$hits"
    echo ""
    echo "a .bats file in this state does not FAIL, it fails to LOAD — its tests"
    echo "vanish from the tally and nothing reports which coverage was lost."
    return 1
  }
}

@test "tree-integrity: that marker guard is armed — it fires on a planted file" {
  # Without this, a broken pattern and a clean tree are the same result. The
  # subject is `git ls-files`, so the plant must be in a real index.
  scratch="${BATS_TEST_TMPDIR}/planted"
  mkdir -p "$scratch"
  ( cd "$scratch" && git init -q . && git config user.email t@t && git config user.name t )
  printf '@test "x" {\n<<<<<<< HEAD\n  true\n=======\n  false\n>>>>>>> other\n}\n' >"${scratch}/conflicted.bats"
  ( cd "$scratch" && git add -A )

  hits="$( cd "$scratch" && git ls-files -z | xargs -0 -r grep -lE "$MARKERS" 2>/dev/null || true )"
  [ -n "$hits" ] || {
    echo "the guard did not catch a planted conflict — its pattern is broken,"
    echo "so every green run above meant 'unsearchable', not 'clean'"
    return 1
  }
}

@test "tree-integrity: a similar tracked filename is not self-filtered" {
  scratch="${BATS_TEST_TMPDIR}/similar-name"
  mkdir -p "${scratch}/nested"
  ( cd "$scratch" && git init -q . && git config user.email t@t && git config user.name t )
  printf '<<<<<<< HEAD\n=======\n>>>>>>> other\n' >"${scratch}/nested/${SELF}.fixture"
  ( cd "$scratch" && git add -A )

  hits="$(conflict_hits "$scratch" "nested/${SELF}" || true)"
  [ "${hits}" = "nested/${SELF}.fixture" ] || {
    echo "a similarly named tracked file was incorrectly self-filtered: ${hits}"
    return 1
  }
}

@test "tree-integrity: marker scan fails when the Git inventory is unavailable" {
  scratch="${BATS_TEST_TMPDIR}/not-a-repository"
  mkdir -p "$scratch"

  run conflict_hits "$scratch" "$SELF_PATH"
  [ "$status" -ne 0 ] || {
    echo "marker scan accepted an unavailable Git inventory"
    return 1
  }
}

@test "tree-integrity: every bats suite in this directory parses and declares tests" {
  # The general guard. A file that will not parse reports no tests, and bats
  # exits 0 over the remaining files — so the suite silently shrinks. Catches
  # conflict markers, syntax errors, a mangled shebang, a truncated write.
  #
  # ─── SCOPED TO THIS DIRECTORY DELIBERATELY. DO NOT WIDEN. ──────────────────
  #
  # Widening to the whole tree is the obvious improvement — the appeal of this
  # guard is that it catches ANY cause, so covering more files looks strictly
  # better. It is not. Measured over `git ls-files '*.bats'`, ten files fire,
  # and only one of them is what this guard is for:
  #
  #   d2-osramp-apps/test/_helper.bats                    @test=0   --count=0
  #   .../test_helper/bats-assert/test/assert.bats        @test=2   --count=err
  #   .../test_helper/bats-assert/test/assert_line.bats   @test=31  --count=err
  #   ...and 7 more vendored bats-assert suites
  #
  # Two different things, and the second is the trap:
  #   - `_helper.bats` declares no tests because it IS a helper. Correct to skip.
  #   - the nine vendored suites declare 2-31 REAL tests each and still fail to
  #     load, because their `load test_helper` resolves relative to their own
  #     directory and cannot be invoked from the repo root.
  #
  # A file with real tests reporting zero for an ENVIRONMENTAL reason is, at
  # this guard, indistinguishable from one corrupted by conflict markers. Ten
  # firing at once is precisely the pressure that gets an assertion weakened —
  # someone appends `|| true`, or drops the floor below — and the guard that
  # catches the real defect leaves with it. Found by kagent-real-chart when they
  # ran this logic against their tree; confirmed identical on mine.
  #
  # If you do widen it, the discriminator is `@test` count versus load count:
  #   grep >= 1 and --count 0  ->  "does not load in THIS context"  (suspicious)
  #   both 0                   ->  "not a suite"                    (fine)
  # and even then only inside directories this repo owns, never vendored ones.
  failed=""
  count=0
  for f in "${BATS_TEST_DIRNAME}"/*.bats; do
    [ -f "$f" ] || continue
    n="$(bats "$f" --count 2>/dev/null || true)"
    case "$n" in
      ''|*[!0-9]*) failed="${failed}
  ${f##*/}: does not parse" ;;
      0)           failed="${failed}
  ${f##*/}: parses but declares 0 tests" ;;
      *)           count=$((count + 1)) ;;
    esac
  done
  [ -z "$failed" ] || {
    echo "suite(s) that would silently contribute nothing:${failed}"
    return 1
  }
  # A floor, so deleting every suite cannot satisfy this test vacuously.
  [ "$count" -ge 7 ] || {
    echo "only ${count} loadable suites found; expected at least 7"
    return 1
  }
}
