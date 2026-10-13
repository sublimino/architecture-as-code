#!/usr/bin/env bats
#
# The applicability chaos suites, and the three things about them that CANNOT
# BE EYEBALLED.
#
# Same reasoning as test/jev-loop.bats, applied to an API surface instead of a
# browser one: every interesting failure mode of a chaos suite is SILENT. A run
# over four date inputs reports PASS exactly like a run over sixty-six. A table
# that lost half its rows to a bad rebase is still green. A chaos test whose
# assertions all happen to be tautologies is the greenest thing in the repo.
#
# So the three properties pinned here are the three a human reading `ok
# policy-engine 0.09s` cannot check:
#
#   1. the date corpus on disk was WALKED IN FULL — every row it declares was
#      reported as exercised, and every row reported was declared, as SETS and
#      not merely as counts
#   2. a deliberately trimmed corpus FAILS, rather than passing against its own
#      narrower definition of "everything"
#   3. every chaos test is PAIRED WITH A MUTATION that breaks the guard it
#      names, and the whole mutation table comes back with zero VOID rows. A
#      chaos test added without a mutation is a test nobody has shown can fail,
#      and this suite goes red for it.
#
# Property 3 is the load-bearing one. The mutation harness itself gates on the
# tree still COMPILING after each mutation, because `go test` exits non-zero for
# a build failure exactly as it does for a failed assertion — three of this
# card's own twenty-one mutations were scored as proven before that gate was
# added, and all three had merely broken the build. Nothing had run.
#
# No network, no Docker, no dev server: the engine suites are pure Go and the
# packs under test are synthesised into t.TempDir().

setup() {
  root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  engine="$root/d2-signalloom/apps/policy-engine"
  corpus="$engine/frameworks/testdata/chaos-date-corpus.tsv"
  mutations="$root/scripts/applicability-chaos-mutations.sh"
  date_suite="$engine/frameworks/applicability_chaos_date_test.go"
  scan_suite="$engine/applicability_chaos_scan_test.go"
  local gopath="${GOPATH:-}"
  if [ "$gopath" = "/usr/local/src/gocode" ] || [ -z "$gopath" ]; then gopath=/tmp/gopath; fi
  export GOPATH="$gopath"
  export GOCACHE="${GOCACHE:-/tmp/gocache}"
  export GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}"
  export GONOSUMDB="*"
  export CGO_ENABLED=0
}

# Column 1 of every non-comment row, in file order.
corpus_inputs() {
  grep -v '^[[:space:]]*#' "$corpus" | grep -v '^[[:space:]]*$' | cut -f1
}

@test "APPCHAOS the suites, the corpus and the mutation harness are all present and parse" {
  [ -f "$date_suite" ]
  [ -f "$scan_suite" ]
  [ -f "$corpus" ]
  [ -x "$mutations" ]
  run bash -n "$mutations"
  [ "$status" -eq 0 ]
  run gofmt -l "$date_suite" "$scan_suite"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── 1. the corpus was walked in full ───────────────────────────────────────

@test "APPCHAOS every corpus row is reported as exercised, and nothing is reported that the corpus does not declare" {
  run bash -c "cd '$engine' && go test ./frameworks -run '^TestChaosDate_ParsesToTheDeclaredDayOrNotAtAll\$' -count=1 -v 2>&1"
  [ "$status" -eq 0 ]

  printf '%s\n' "$output" | grep '^CHAOS-DATE ' | sed 's/^CHAOS-DATE //' | sort > "$BATS_TEST_TMPDIR/reported"
  corpus_inputs | sort > "$BATS_TEST_TMPDIR/declared"

  # SETS, not counts. A count match with a swapped row is the exact failure a
  # count-only assertion cannot see.
  run diff -u "$BATS_TEST_TMPDIR/declared" "$BATS_TEST_TMPDIR/reported"
  [ "$status" -eq 0 ]

  # And the corpus is not trivially small.
  declared="$(wc -l < "$BATS_TEST_TMPDIR/declared")"
  [ "$declared" -ge 60 ]
}

@test "APPCHAOS the corpus declares a wrong-day expectation for nothing: every row is reject or a canonical day" {
  run bash -c "
    grep -v '^[[:space:]]*#' '$corpus' | grep -v '^[[:space:]]*\$' | while IFS=\$'\t' read -r input want; do
      case \"\$want\" in
        reject) ;;
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
        *) echo \"BAD EXPECTATION for \$input: \$want\"; exit 1 ;;
      esac
    done
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── 2. a trimmed corpus must FAIL ──────────────────────────────────────────

@test "APPCHAOS a trimmed corpus fails the suite instead of passing against its own narrower definition of everything" {
  backup="$BATS_TEST_TMPDIR/corpus.bak"
  cp "$corpus" "$backup"
  # Restored from the explicit copy, never from git: a `git checkout --` here
  # would also discard unrelated uncommitted work in this tree.
  restore() { cp "$backup" "$corpus"; }

  # Keep the comment header and four rows. A suite that measures its own
  # coverage against the list it was handed reports 100% of four.
  { grep '^[[:space:]]*#' "$backup" | head -20
    corpus_inputs | head -4 | while read -r i; do printf '%s\treject\n' "$i"; done
  } > "$corpus"

  run bash -c "cd '$engine' && go test ./frameworks -run '^TestChaosDate_ParsesToTheDeclaredDayOrNotAtAll\$' -count=1 2>&1"
  restore

  [ "$status" -ne 0 ]
  [[ "$output" == *"rows have been lost"* ]]

  # And the restore worked, so no later test in this file runs against a
  # trimmed corpus.
  run cmp -s "$corpus" "$backup"
  [ "$status" -eq 0 ]
}

@test "APPCHAOS a duplicated corpus row fails rather than inflating the count" {
  backup="$BATS_TEST_TMPDIR/corpus.dup.bak"
  cp "$corpus" "$backup"
  first="$(corpus_inputs | head -1)"
  printf '%s\treject\n' "$first" >> "$corpus"

  run bash -c "cd '$engine' && go test ./frameworks -run '^TestChaosDate_ParsesToTheDeclaredDayOrNotAtAll\$' -count=1 2>&1"
  cp "$backup" "$corpus"

  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicates line"* ]]
  run cmp -s "$corpus" "$backup"
  [ "$status" -eq 0 ]
}

# ── 3. every chaos test is paired with a mutation ───────────────────────────

@test "APPCHAOS every chaos test in both suites is paired with a mutation in the harness" {
  grep -ho '^func \(TestChaos[A-Za-z_]*\)' "$date_suite" "$scan_suite" \
    | sed 's/^func //' | sort -u > "$BATS_TEST_TMPDIR/tests"
  [ -s "$BATS_TEST_TMPDIR/tests" ]

  missing=""
  while read -r t; do
    grep -q "|${t}|" "$mutations" || missing="$missing $t"
  done < "$BATS_TEST_TMPDIR/tests"

  # A chaos test with no paired mutation is a test nobody has shown can fail.
  # The one documented exception states its own reason in the suite: the
  # round-trip guard is unreachable because the stdlib range-checks days.
  if [ -n "$missing" ]; then
    for t in $missing; do
      [ "$t" = "TestChaosDate_TheRoundTripGuardsJustificationIsStaleButHarmless" ] || {
        echo "no mutation pairs with $t"
        false
      }
    done
  fi
}

@test "APPCHAOS the mutation harness reports every mutation proven and zero void" {
  run bash -c "'$mutations' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONTROL: pristine tree green"* ]]
  [[ "$output" != *"MUTATION VOID"* ]]
  [[ "$output" == *"mutations proven"* ]]
  [[ "$output" == *"mutated files byte-identical to the pre-mutation copies"* ]]

  # The table must be non-trivial: 20+ guards, each paired.
  rows="$(printf '%s\n' "$output" | grep -c 'MUTATION PROVEN')"
  [ "$rows" -ge 20 ]

  # And the two inverted rows — the characterisation tests whose mutation is
  # the actual FIX — must both be present, or the two reported defects have
  # silently stopped being tracked.
  [[ "$output" == *"FIX-reject-dateless-window"* ]]
  [[ "$output" == *"FIX-require-jurisdiction-for-directives"* ]]
}

@test "APPCHAOS the mutation harness leaves the tree exactly as it found it" {
  for f in "$engine/frameworks/applicability.go" "$engine/compliance.go" "$engine/bindings.go" "$corpus"; do
    cp "$f" "$BATS_TEST_TMPDIR/$(basename "$f").before"
  done
  run bash -c "'$mutations' >/dev/null 2>&1"
  [ "$status" -eq 0 ]
  for f in "$engine/frameworks/applicability.go" "$engine/compliance.go" "$engine/bindings.go" "$corpus"; do
    run cmp -s "$f" "$BATS_TEST_TMPDIR/$(basename "$f").before"
    [ "$status" -eq 0 ]
  done
}

# ── and the suites themselves, green ───────────────────────────────────────

@test "APPCHAOS both chaos suites pass and report at least twenty tests between them" {
  run bash -c "cd '$engine' && go test . ./frameworks -run '^TestChaos' -count=1 -v 2>&1"
  [ "$status" -eq 0 ]
  passed="$(printf '%s\n' "$output" | grep -c '^--- PASS: TestChaos')"
  [ "$passed" -ge 20 ]
  # Zero skips. A `skip` on a missing dependency turns a build failure into a
  # silent pass, which is how 81 tests went green against a binary that would
  # not compile elsewhere in this estate.
  [[ "$output" != *"--- SKIP"* ]]
}
