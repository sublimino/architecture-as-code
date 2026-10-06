#!/usr/bin/env bash
# docs-tests-alignment.sh — check that what the documentation CLAIMS about the
# test suite is true. scripts/docs-lint.sh checks links, paths, make targets and
# style. test/docs-index-sync.bats checks the records index. Neither reads a
# claim about a test. A page can name a Go test that was renamed, a bats file
# that moved, or a flag a script never took, and every existing gate stays green.
#
# Usage:
#   scripts/docs-tests-alignment.sh            # living docs, by the docs-lint tier
#   scripts/docs-tests-alignment.sh FILE...    # the given markdown files only
#
# Checks (each finding is one line: FILE:LINE: CHECK: detail):
#   gotest       a Test... name is defined by no *_test.go and no Python test class
#   artefact     a named test/*.bats, *.spec.ts or scripts/*.sh does not exist
#   make         a `make TARGET` reference names no target in any tracked Makefile
#   command      a shell block runs an executable that is no repo file, no make
#                target, no shell builtin and nothing on PATH
#   flag         a flag passed to a repo script appears nowhere in that script
#   walkthrough  a numbered step of the walkthrough has no row in the map, a row
#                names a heading or a spec that does not exist, or a row's spec
#                string is absent from the spec it names
#
# Tiers follow scripts/docs-lint.sh: decision records are exempt, because they
# keep the state of their date. OPTIN_RECORDS below names the records that are
# checked anyway. test/docs-tests-alignment.bats pins that list.
#
# Offline. Needs only bash, awk, git, and rg. Exit 0 when clean, 1 on findings,
# 2 on a usage error.

set -o errexit -o pipefail

ROOT="${DOCS_ALIGN_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)}"
cd "$ROOT"

# Records that carry test claims worth checking even though they are records.
# The SLAWS proposal errata cite test names as evidence, so a renamed test
# silently turns the evidence into a fiction.
OPTIN_RECORDS=(
  "docs/Proposal — Signal Loom AWS Telemetry Ingest & Multilayer Policy Engine Beta (2026-Q3).md"
)

# The pages whose fenced shell blocks are checked: the Kusari pilot walkthroughs
# and the Signal Loom runbooks. These are the pages a reader types from.
SHELL_SCOPE="${ALIGN_SHELL_SCOPE:-^docs/(EAP|signalloom/runbooks)/[^/]+\.md$}"

WALKTHROUGH_DOC="${ALIGN_WALKTHROUGH_DOC:-docs/EAP/onboarding.md}"
WALKTHROUGH_MAP="${ALIGN_WALKTHROUGH_MAP:-test/fixtures/walkthrough-map.tsv}"
ALIGNMENT_GAPS="${ALIGN_GAPS_DOC:-docs/signalloom/alignment-gaps.md}"

# Tokens that match Test[A-Z]... but name no test: library and helper types.
NOT_A_TEST='^(TestClient|TestServer|TestCase|TestSuite|TestConnection|TestData|TestDouble|TestEnv|TestKube|TestContainers|TestFixture|TestHarness|TestID|TestIDs|TestOnly|TestRunner)$'

# Shell builtins and keywords that a block may start a command with.
BUILTINS=' cd export set unset source . eval exec echo printf read true false test [ let local declare readonly shift exit return wait trap times umask type command builtin : while for if then else fi do done case esac function time '

# ---------------------------------------------------------------------------
# File selection and tiering
# ---------------------------------------------------------------------------
declare -A INSCOPE=()
if [[ $# -gt 0 ]]; then
  for f in "$@"; do
    [[ -f "$f" ]] || { echo "docs-tests-alignment: no such file: $f" >&2; exit 2; }
    INSCOPE[$f]=1
  done
else
  LINT="scripts/docs-lint.sh"
  [[ -f "$LINT" ]] || { echo "docs-tests-alignment: no $LINT to read the tiers from" >&2; exit 2; }
  RECORDS="$(sed -n "s/^RECORDS='\(.*\)'$/\1/p" "$LINT")"
  IGNORED="$(sed -n "s/^IGNORED='\(.*\)'$/\1/p" "$LINT")"
  [[ -n "$RECORDS" && -n "$IGNORED" ]] || {
    echo "docs-tests-alignment: could not read RECORDS and IGNORED from $LINT" >&2
    exit 2
  }
  while IFS= read -r -d '' f; do
    [[ "$f" =~ $IGNORED ]] && continue
    [[ "$f" =~ $RECORDS ]] && continue
    INSCOPE[$f]=1
  done < <(git ls-files -z '*.md')
  for f in "${OPTIN_RECORDS[@]}"; do
    [[ -f "$f" ]] || { echo "docs-tests-alignment: opt-in record is missing: $f" >&2; exit 2; }
    INSCOPE[$f]=1
  done
fi

findings=0
report() { printf '%s:%s: %s: %s\n' "$1" "$2" "$3" "$4"; findings=$((findings + 1)); }

# ---------------------------------------------------------------------------
# Indexes, each built once
# ---------------------------------------------------------------------------

# Every defined test name: Go `func TestX`, and Python `class TestX` (the
# pytest suites group their cases in classes the docs cite by name).
declare -A TESTNAMES=()
while IFS= read -r n; do [[ -n "$n" ]] && TESTNAMES[$n]=1; done < <(
  { rg --no-filename -o '^func Test[A-Za-z0-9_]+' -g '*_test.go' . 2>/dev/null || true
    rg --no-filename -o '^class Test[A-Za-z0-9_]+' -g '*_test.py' -g 'test_*.py' . 2>/dev/null || true
  } | awk '{ print $2 }' | sort -u
)

# Every tracked Makefile target. Patterns keep a regular expression.
declare -A MAKETARGETS=()
MAKEPATTERNS=""
while IFS= read -r t; do
  [[ -z "$t" ]] && continue
  if [[ "$t" == *%* ]]; then MAKEPATTERNS+="^${t//%/.+}\$ "; else MAKETARGETS[$t]=1; fi
done < <(
  git ls-files -z 'Makefile' '*/Makefile' '*.mk' |
    xargs -0 -r awk -F: '/^[^\t#=][^=]*:([^=]|$)/ && $1 !~ /^\./ {
      n = split($1, a, /[ \t]+/); for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
    }' | sort -u
)

# Every tracked file, by base name and by top-level directory.
declare -A BASENAMES=() TOPDIRS=()
while IFS= read -r b; do [[ -n "$b" ]] && BASENAMES[$b]=1; done < <(git ls-files | awk -F/ '{ print $NF }' | sort -u)
while IFS= read -r d; do [[ -n "$d" ]] && TOPDIRS[$d]=1; done < <(git ls-files | awk -F/ 'NF > 1 { print $1 }' | sort -u)

has_make_target() {
  local name="$1" re
  [[ -v "MAKETARGETS[$name]" ]] && return 0
  for re in $MAKEPATTERNS; do [[ "$name" =~ $re ]] && return 0; done
  return 1
}

has_testname() {
  local name="$1" k
  [[ -v "TESTNAMES[$name]" ]] && return 0
  # A `-run 'TestFoo.*'` reference is a prefix. Accept any defined name under it.
  if [[ "$2" == prefix ]]; then
    for k in "${!TESTNAMES[@]}"; do [[ "$k" == "$name"* ]] && return 0; done
  fi
  return 1
}

# ---------------------------------------------------------------------------
# extract FILE SHELL — tab-separated records for one markdown file:
#   T <line> <name>[\t prefix]  a Test... candidate
#   R <line> <path>             a named bats, Playwright spec, or repo script
#   K <line> <make target>      a `make TARGET` reference
#   S <line> <command line>     one logical line of a fenced shell block
# SHELL is 1 when the shell blocks of this file are in scope.
# A region between <!-- docs-lint: off --> and <!-- docs-lint: on --> is skipped,
# the same escape hatch scripts/docs-lint.sh honours.
# ---------------------------------------------------------------------------
extract() {
  LC_ALL=C awk -v OFS='\t' -v want_shell="$2" '
    # A name on a line that also carries -run is a prefix: `go test -run NAME`
    # takes an unanchored regular expression, so NAME selects every test under it.
    function emit_names(text, ln,   t, prevc, name, rest, kind, runline) {
      t = text
      runline = (text ~ /-run/)
      while (match(t, /Test[A-Z][A-Za-z0-9_]*/)) {
        prevc = (RSTART > 1) ? substr(t, RSTART - 1, 1) : ""
        name = substr(t, RSTART, RLENGTH)
        rest = substr(t, RSTART + RLENGTH)
        t = rest
        # A match inside a longer identifier (fxTestVectors) or after a colon
        # (the AWS event s3:TestEvent) is not a reference to a test.
        if (prevc ~ /[A-Za-z0-9_:]/) continue
        kind = (rest ~ /^(\.\*|\*)/ || runline) ? "prefix" : "exact"
        # A subtest reference keeps only the parent name.
        sub(/\/.*$/, "", name)
        print "T", ln, name, kind
      }
    }
    # The three named test artefacts: a bats suite, a Playwright spec, and a
    # shell script under a scripts/ directory. A bare *.sh name is not in scope:
    # a page may name a script that lives outside this repository.
    function emit_paths(text, ln,   t, p, prevc, nextc) {
      t = text
      while (match(t, /[A-Za-z0-9_][A-Za-z0-9_.\/-]*(\.bats|\.spec\.ts)|[A-Za-z0-9_][A-Za-z0-9_.\/-]*scripts\/[A-Za-z0-9_.-]+\.sh/)) {
        prevc = (RSTART > 1) ? substr(t, RSTART - 1, 1) : ""
        p = substr(t, RSTART, RLENGTH)
        nextc = substr(t, RSTART + RLENGTH, 1)
        t = substr(t, RSTART + RLENGTH)
        # A suffix that does not end the token is a different name:
        # audit-signature.sha256 is not audit-signature.sh.
        if (nextc ~ /[A-Za-z0-9_]/) continue
        # A match preceded by / or . is the tail of a longer path or of a URL
        # (../../test/x.bats, https://nono.sh). The prefix decides what it names,
        # and scripts/docs-lint.sh already checks every link target.
        if (prevc == "/" || prevc == ".") continue
        print "R", ln, p
      }
    }
    function emit_makes(text, ln,   t, a) {
      t = text
      while (match(t, /(^|[^A-Za-z0-9_-])make[ \t]+[^`|;&)#]*/)) {
        a = substr(t, RSTART, RLENGTH)
        sub(/^[^m]*make[ \t]+/, "", a)
        print "K", ln, a
        t = substr(t, RSTART + RLENGTH)
      }
    }
    function flush_shell(   i) {
      if (pending == "") return
      print "S", pstart, pending
      pending = ""
    }
    /<!-- *docs-lint: *off *-->/ { off = 1; next }
    /<!-- *docs-lint: *on *-->/  { off = 0; next }
    off { next }
    /^[ \t]*(```|~~~)/ {
      if (fence) { flush_shell(); fence = 0; shell = 0; next }
      fence = 1
      shell = ($0 ~ /^[ \t]*(```|~~~)[ \t]*(bash|sh|shell|console|zsh)[ \t]*$/) ? 1 : 0
      next
    }
    fence {
      emit_names($0, NR)
      if (shell && want_shell == "1") {
        line = $0
        sub(/^[ \t]*/, "", line)
        sub(/^\$ +/, "", line)
        if (line ~ /^#/ || line ~ /^[ \t]*$/) { flush_shell(); next }
        if (pending == "") pstart = NR
        if (line ~ /\\$/) { sub(/\\$/, " ", line); pending = pending line; next }
        pending = pending line
        flush_shell()
      }
      next
    }
    /<!--/ { incomment = 1 }
    incomment { if ($0 ~ /-->/) incomment = 0; next }
    {
      emit_names($0, NR)
      emit_paths($0, NR)
      # make references come from inline code and shell blocks only, never from
      # prose: "make targets" and "make sure" are English, not invocations.
      c = $0
      while (match(c, /`[^`]*`/)) {
        code = substr(c, RSTART + 1, RLENGTH - 2)
        c = substr(c, RSTART + RLENGTH)
        if (code ~ /^make[ \t]/) emit_makes(code, NR)
      }
    }
    END { flush_shell() }
  ' "$1"
}

# ---------------------------------------------------------------------------
# Per-record checks
# ---------------------------------------------------------------------------

check_testname() {
  local file="$1" ln="$2" name="$3" kind="$4"
  [[ "$name" =~ $NOT_A_TEST ]] && return 0
  # A bare `Test` plus one capital is prose ("TestA"); require a real name.
  [[ ${#name} -ge 8 ]] || return 0
  has_testname "$name" "$kind" && return 0
  report "$file" "$ln" gotest "no test named '$name' in any *_test.go or Python test class"
}

check_artefact() {
  local file="$1" ln="$2" p="$3" top
  [[ "$p" == /* ]] && return 0
  if [[ "$p" != */* ]]; then
    # A bare name is a reference to the suite wherever it lives in the tree.
    [[ -v "BASENAMES[$p]" ]] && return 0
    report "$file" "$ln" artefact "no file named $p anywhere in the tree"
    return 0
  fi
  top="${p%%/*}"
  # A path that does not start at a tracked top-level directory belongs to a
  # container, a VM, or another repository, so this tree cannot judge it.
  [[ -v "TOPDIRS[$top]" ]] || return 0
  [[ -e "$p" ]] && return 0
  [[ -e "$(dirname "$file")/$p" ]] && return 0
  git check-ignore -q "$p" 2>/dev/null && return 0
  report "$file" "$ln" artefact "no such test artefact in the tree: $p"
}

check_make() {
  local file="$1" ln="$2" args="$3" name
  # shellcheck disable=SC2086 # splitting the make argument list is intended
  set -- $args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -C) shift; [[ $# -gt 0 ]] && shift ;;
      -C* | -*) shift ;;
      *=*) shift ;;
      *) break ;;
    esac
  done
  name="${1:-}"
  [[ -z "$name" || "$name" == *'<'* || "$name" == *'$'* || "$name" == *'*'* ]] && return 0
  [[ "$name" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || return 0
  case "$name" in sure | it | a | an | the | this | that | them | your | changes | comprehensive | sense) return 0 ;; esac
  has_make_target "$name" && return 0
  report "$file" "$ln" make "no target '$name' in any tracked Makefile"
}

# repo_script TOKEN — print the repository path of TOKEN when it is a repo file.
repo_script() {
  local tok="$1"
  tok="${tok#./}"
  [[ -f "$tok" ]] && { printf '%s' "$tok"; return 0; }
  return 1
}

# split_command — read one shell line on stdin, print one command segment per
# line with the words separated by tabs. Quote aware: a pipe or a semicolon
# inside quotes is data (a `grep -E 'a|b'` pattern), not a separator.
split_command() {
  LC_ALL=C awk '
    function flushseg(   j, s) {
      if (nw == 0) return
      s = out[1]
      for (j = 2; j <= nw; j++) s = s "\t" out[j]
      print s
      for (j = 1; j <= nw; j++) delete out[j]
      nw = 0
    }
    {
      q = ""; word = ""; nw = 0; n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (q != "") { if (c == q) q = ""; else word = word c; continue }
        if (c == "\047" || c == "\042") { q = c; quoted = 1; continue }
        if (c == "\\") { i++; word = word substr($0, i, 1); continue }
        if (c == " " || c == "\t") { if (word != "") { out[++nw] = word; word = "" }; continue }
        if (c == "|" || c == ";" || c == "&") {
          if (substr($0, i + 1, 1) == c) i++
          if (word != "") { out[++nw] = word; word = "" }
          flushseg(); continue
        }
        word = word c
      }
      if (word != "") out[++nw] = word
      flushseg()
    }
  '
}

check_command() {
  local file="$1" ln="$2" cmd="$3" exe tok script flag
  local -a words=()
  while IFS=$'\t' read -r -a words; do
    ((${#words[@]})) || continue
    set -- "${words[@]}"
    exe=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        *'$('* | *'`'*) exe=""; break ;;   # a command substitution, not a name
        *=*) shift ;;                      # a leading VAR=value assignment
        *) exe="$1"; break ;;
      esac
    done
    [[ -z "$exe" ]] && continue
    # Shell syntax, substitutions, and redirections are not executables.
    case "$exe" in
      '$'* | '('* | '{'* | '<'* | '>'* | '-'* | '#'*) continue ;;
      *'$'* | *'('* | *'*'*) continue ;;
      http://* | https://*) continue ;;
    esac
    [[ "$BUILTINS" == *" $exe "* ]] && continue
    if [[ "$exe" == make ]]; then
      shift
      check_make "$file" "$ln" "$*"
      continue
    fi
    if script="$(repo_script "$exe")"; then
      # Every flag a repo script is given must appear in that script: in its
      # usage text, its case arms, or its argument parsing.
      for tok in "$@"; do
        case "$tok" in
          --) break ;;
          --*) flag="${tok%%=*}" ;;
          -[A-Za-z]) flag="$tok" ;;
          *) continue ;;
        esac
        grep -qF -- "$flag" "$script" && continue
        report "$file" "$ln" flag "$script takes no $flag"
      done
      continue
    fi
    command -v -- "$exe" >/dev/null 2>&1 && continue
    report "$file" "$ln" command "not a repo file, a make target, a builtin, or on PATH: $exe"
  done < <(printf '%s\n' "$cmd" | split_command)
}

# ---------------------------------------------------------------------------
# Walkthrough and spec correspondence
# ---------------------------------------------------------------------------
WALK_ROWS=0
check_walkthrough() {
  local doc="$WALKTHROUGH_DOC" map="$WALKTHROUGH_MAP" gaps="$ALIGNMENT_GAPS"
  [[ -f "$doc" && -f "$map" ]] || return 0
  local -A mapped=()
  local ln=0 heading spec needle

  while IFS=$'\t' read -r heading spec needle || [[ -n "$heading" ]]; do
    ln=$((ln + 1))
    [[ -z "$heading" || "$heading" == '#'* ]] && continue
    WALK_ROWS=$((WALK_ROWS + 1))
    if [[ -z "$spec" || -z "$needle" ]]; then
      report "$map" "$ln" walkthrough "row needs three tab-separated fields: heading, spec file, spec string"
      continue
    fi
    if ! grep -qxF -- "## $heading" "$doc"; then
      report "$map" "$ln" walkthrough "no heading '## $heading' in $doc"
      continue
    fi
    mapped[$heading]=1
    if [[ "$spec" == "-" ]]; then
      # A step no spec covers must be a recorded gap, never a silent omission.
      if [[ ! -f "$gaps" ]] || ! grep -qF -- "$needle" "$gaps"; then
        report "$map" "$ln" walkthrough "uncovered step cites '$needle', which is not recorded in $gaps"
      fi
      continue
    fi
    if [[ ! -f "$spec" ]]; then
      report "$map" "$ln" walkthrough "no such spec: $spec"
      continue
    fi
    grep -qF -- "$needle" "$spec" ||
      report "$map" "$ln" walkthrough "$spec asserts no '$needle'"
  done <"$map"

  # Every numbered step of the walkthrough needs a row. A missing row is the
  # drift this check exists for: a step added to the page and to no spec.
  while IFS=$'\t' read -r ln heading; do
    [[ -v "mapped[$heading]" ]] && continue
    report "$doc" "$ln" walkthrough "numbered step '$heading' has no row in $map"
  done < <(awk -v OFS='\t' '
    /^[ \t]*(```|~~~)/ { fence = !fence; next }
    !fence && /^## [0-9]+\. / { s = $0; sub(/^## /, "", s); print NR, s }
  ' "$doc")
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
# A check that examines nothing reports the same clean line as a check that
# examined everything, so the counts are part of the output and the suite pins
# their floor.
declare -A SEEN=([T]=0 [R]=0 [K]=0 [S]=0)

for file in "${!INSCOPE[@]}"; do
  shell=0
  [[ "$file" =~ $SHELL_SCOPE ]] && shell=1
  while IFS=$'\t' read -r kind ln rest extra; do
    case "$kind" in
      T) check_testname "$file" "$ln" "$rest" "$extra" ;;
      R) check_artefact "$file" "$ln" "$rest" ;;
      K) check_make "$file" "$ln" "$rest" ;;
      S) check_command "$file" "$ln" "$rest" ;;
      *) continue ;;
    esac
    SEEN[$kind]=$((SEEN[$kind] + 1))
  done < <(extract "$file" "$shell")
done

check_walkthrough

if ((findings > 0)); then
  echo "docs-tests-alignment: $findings finding(s)." >&2
  exit 1
fi
printf 'docs-tests-alignment: %d file(s) clean (tests=%d artefacts=%d make=%d commands=%d walkthrough-rows=%d; indexed %d test names, %d make targets)\n' \
  "${#INSCOPE[@]}" "${SEEN[T]}" "${SEEN[R]}" "${SEEN[K]}" "${SEEN[S]}" "$WALK_ROWS" \
  "${#TESTNAMES[@]}" "${#MAKETARGETS[@]}"
