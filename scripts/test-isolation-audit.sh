#!/usr/bin/env bash
# Test-isolation audit: find every shared-resource literal that would make two
# concurrent test runs collide.
#
# Two classes of finding, both of which are "this test owns a machine-global
# name":
#   PORT  a fixed TCP port literal — two runs bind the same port, the second
#         fails with EADDRINUSE (or worse, silently talks to the first run's
#         server and asserts on its state)
#   TMP   a fixed path under /tmp — two runs read and write the same file
#
# Scope is the acceptance set, which is what `scripts/parallel-acceptance.sh`
# runs twice over: the SLDC_OFFLINE_BATS list, the Go test files under
# SLDC_GO_DIRS, and the Go test files of the other acceptance commands.
#
# Allowlist: test/fixtures/test-isolation-allowlist.txt. Every entry carries a
# reason. Exit 1 on any finding that is not allowlisted.
#
#   usage: scripts/test-isolation-audit.sh [--json] [--list-allowlisted]
#
# @id      test-isolation-audit
# @doc     docs/signalloom/runbooks/parallel-tests.md
# @tests   test/test-isolation-audit.bats
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

ALLOWLIST="${TEST_ISOLATION_ALLOWLIST:-test/fixtures/test-isolation-allowlist.txt}"
json=0
list_allowlisted=0
for arg in "$@"; do
  case "$arg" in
    --json) json=1 ;;
    --list-allowlisted) list_allowlisted=1 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# --- scope -----------------------------------------------------------------
# Makefile list variables are the single source of truth for what the
# acceptance set runs; re-deriving them here would let the two drift.
makefile_list() {
  python3 - "$1" <<'PY'
import re, sys
name = sys.argv[1]
src = open('Makefile').read()
m = re.search(r'^' + re.escape(name) + r'\s*=\s*((?:.*\\\n)*.*)$', src, re.M)
print('\n'.join(m.group(1).replace('\\\n', ' ').split()) if m else '', end='')
PY
}

mapfile -t bats_files < <(makefile_list SLDC_OFFLINE_BATS)
# `mapfile -t arr < <(cmd)` discards cmd's own exit status -- mapfile succeeds
# having read zero lines from a command that crashed outright, so a
# python3/Makefile failure here would silently drop every SLDC_GO_DIRS entry
# from the audit while still running (the three go_dirs+= below keep the loop
# at line 68 non-empty either way, so it is a real but invisible coverage
# loss, not literally a zero-iteration loop).
#
# Captured into a variable first instead, specifically so a legitimately
# EMPTY SLDC_GO_DIRS (test/test-isolation-audit.bats's own fixtures set
# `SLDC_GO_DIRS =` on purpose) is not confused with makefile_list having
# failed -- `||` below only fires on the command's actual exit status, never
# on empty output.
go_dirs_raw="$(makefile_list SLDC_GO_DIRS)" || {
  echo "ERROR: makefile_list SLDC_GO_DIRS failed — check python3 and the Makefile" >&2
  exit 1
}
go_dirs=()
if [ -n "$go_dirs_raw" ]; then
  mapfile -t go_dirs <<<"$go_dirs_raw"
fi
# The acceptance set also runs these Go module roots directly (policy-engine via
# scripts/slaws-acceptance.sh, obscel and signal-ingest via make targets).
go_dirs+=(
  d2-signalloom/apps/policy-engine
  d2-signalloom/pkg/obscel
  d2-signalloom/apps/signal-ingest
)

go_files=()
# Dedupe: signal-ingest is reached both via SLDC_GO_DIRS and via
# `make test-signal-ingest`, and a doubled file doubles every finding in it.
while IFS= read -r f; do go_files+=("$f"); done < <(
  for d in "${go_dirs[@]}"; do
    [ -d "$d" ] || continue
    find "$d" -name '*_test.go' -type f
  done | sort -u
)

# --- allowlist -------------------------------------------------------------
# Format: <file>:<kind>:<literal>  # reason
# A line without a reason is itself a finding: an allowlist entry whose
# justification was never written down is indistinguishable from an oversight.
declare -A allowed=()
allow_order=()
if [ -f "$ALLOWLIST" ]; then
  while IFS= read -r line; do
    [ -n "${line// }" ] || continue
    case "$line" in \#*) continue ;; esac
    key="${line%%#*}"
    key="${key%"${key##*[![:space:]]}"}"
    reason="${line#*#}"
    [ "$reason" != "$line" ] || { echo "allowlist entry has no reason: $line" >&2; exit 2; }
    reason="${reason#"${reason%%[![:space:]]*}"}"
    allowed["$key"]="$reason"
    allow_order+=("$key")
  done < "$ALLOWLIST"
fi

if [ "$list_allowlisted" = 1 ]; then
  for k in "${allow_order[@]}"; do printf '%s  # %s\n' "$k" "${allowed[$k]}"; done
  exit 0
fi

# --- detection -------------------------------------------------------------
# PORT. Deliberately narrow so the signal stays readable:
#   - host:port forms  127.0.0.1:8080, localhost:8080, 0.0.0.0:8080, :8080"
#   - bare 4-5 digit numbers assigned to a *_PORT / *Port name
# Port 0 is the fix, not a finding. Years (19xx/20xx) and 3-digit HTTP status
# codes are excluded by requiring a host prefix or a PORT-shaped name.
port_hits() {
  local f="$1"
  grep -naoE '(127\.0\.0\.1|localhost|0\.0\.0\.0|\[::1\]):[0-9]{2,5}' "$f" 2>/dev/null |
    sed -E 's/^([0-9]+):.*:([0-9]{2,5})$/\1\t\2/'
  grep -naoE '(^|[^A-Za-z0-9_])(PORT|port|Port)[A-Za-z_]*[=:][[:space:]]*"?[0-9]{4,5}"?' "$f" 2>/dev/null |
    sed -E 's/^([0-9]+):.*[^0-9]([0-9]{4,5})"?$/\1\t\2/'
  grep -naoE '[A-Za-z_]*(PORT|_port|Port)[A-Za-z_]*[=:][[:space:]]*"?[0-9]{4,5}"?' "$f" 2>/dev/null |
    sed -E 's/^([0-9]+):.*[^0-9]([0-9]{4,5})"?$/\1\t\2/'
}

# TMP. A fixed path directly under /tmp. $BATS_TEST_TMPDIR, $TMPDIR, mktemp
# output and anything carrying $$ or a $-expansion are per-run already, so a
# literal that continues into a '$' or a '%' format verb is NOT a finding --
# /tmp/sldc-evidence-abs-$$ and /tmp/test-baoaudit-%d.sock are already unique.
tmp_hits() {
  grep -naoE '/tmp/[A-Za-z0-9_.-]*[$%]?' "$1" 2>/dev/null |
    grep -vE '[$%]$' |
    sed -E 's/^([0-9]+):(.*)$/\1\t\2/'
}

findings=()
record() { # file kind literal line
  local key="$1:$2:$3"
  if [ -n "${allowed[$key]+x}" ]; then return; fi
  findings+=("$1|$2|$3|$4")
}

scan() {
  local f="$1"
  [ -f "$f" ] || return 0
  local line lit
  while IFS=$'\t' read -r line lit; do
    [ -n "${lit:-}" ] || continue
    lit="${lit##*:}"
    [ "$lit" != "0" ] || continue
    record "$f" PORT "$lit" "$line"
  done < <(port_hits "$f" | sort -u -k2,2)
  while IFS=$'\t' read -r line lit; do
    [ -n "${lit:-}" ] || continue
    record "$f" TMP "$lit" "$line"
  done < <(tmp_hits "$f" | sort -u -k2,2)
}

for f in "${bats_files[@]}"; do scan "$f"; done
for f in "${go_files[@]}"; do scan "$f"; done

# --- report ----------------------------------------------------------------
scanned=$(( ${#bats_files[@]} + ${#go_files[@]} ))
if [ "$json" = 1 ]; then
  printf '{"scanned":%d,"allowlisted":%d,"findings":[' "$scanned" "${#allowed[@]}"
  sep=''
  for x in "${findings[@]}"; do
    IFS='|' read -r f k l n <<<"$x"
    printf '%s{"file":"%s","kind":"%s","literal":"%s","line":%s}' "$sep" "$f" "$k" "$l" "$n"
    sep=','
  done
  printf ']}\n'
else
  echo "test-isolation-audit: scanned $scanned test files, ${#allowed[@]} allowlisted"
  for x in "${findings[@]}"; do
    IFS='|' read -r f k l n <<<"$x"
    printf '  FINDING %-4s %s:%s  %s\n' "$k" "$f" "$n" "$l"
  done
fi

if [ "${#findings[@]}" -gt 0 ]; then
  # --json stays machine-parseable: the advisory epilogue would otherwise land in
  # a caller's stdout-plus-stderr capture and break the parse.
  if [ "$json" = 0 ]; then
    echo "test-isolation-audit: ${#findings[@]} finding(s) not on $ALLOWLIST" >&2
    echo "  fix: free_port() (test/lib/freeport.bash) / net.Listen(\"tcp\",\"127.0.0.1:0\") / \$BATS_TEST_TMPDIR / t.TempDir()" >&2
    echo "  or add '<file>:<kind>:<literal>  # <reason>' to $ALLOWLIST" >&2
  fi
  exit 1
fi
[ "$json" = 1 ] || echo "test-isolation-audit: OK"
