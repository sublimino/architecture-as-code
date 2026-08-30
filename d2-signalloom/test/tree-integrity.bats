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
  # Anchored to line start: `=======` under a heading and `>>>>>>>` in prose are
  # common in markdown, and a looser pattern would fire on documentation.
  MARKERS='^(<<<<<<< |=======$|>>>>>>> )'
}

@test "tree-integrity: no tracked file carries merge conflict markers" {
  # git ls-files, not the working directory: an untracked scratch file with
  # markers is not a problem, a committed one is.
  hits="$( cd "$REPO_ROOT" && git ls-files -z 2>/dev/null \
             | xargs -0 -r grep -lE "$MARKERS" 2>/dev/null \
             | grep -vF "$SELF" || true )"
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

@test "tree-integrity: every bats suite in this directory parses and declares tests" {
  # The general guard. A file that will not parse reports no tests, and bats
  # exits 0 over the remaining files — so the suite silently shrinks. Catches
  # conflict markers, syntax errors, a mangled shebang, a truncated write.
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
