#!/usr/bin/env bash
#
# surfaces-report.sh — the state of EVERY lane, on both surfaces, in one table.
#
#   surfaces-report.sh [--lanes "demo-1 demo-2 ci-1 ci-2"] [--commit <sha>] [--json]
#
# ─── Why this exists ────────────────────────────────────────────────────────
#
# Each lane files a receipt per surface at demo-surfaces/<env>.<surface>.json,
# and `make gcp-tf-test-surfaces ENV=<key>` asserts that one lane's two receipts
# both passed. Nothing read all of them. After a four-lane rebuild the question
# an operator actually has is "which lanes are good?", and answering it meant
# four invocations and holding the answers in your head.
#
# ─── The two ways a report like this lies, and what stops each ──────────────
#
# 1. A MISSING receipt read as a pass. This is the cardinal sin in this
#    repository — an absent summary.json was read as a pass twice in one day on
#    2026-08-13 (see the note at the head of demo-up.sh). So a lane with no
#    receipt is reported MISSING and counts as a failure, never as silence.
#
# 2. A STALE receipt read as current. A receipt is a record of a run, not of the
#    estate: it keeps saying PASS long after the lane it describes was destroyed
#    and rebuilt. That is not hypothetical here — demo-1 was rebuilt three times
#    on 2026-08-20 and its receipt outlived two of those. So every receipt is
#    checked against the commit under test (--commit, defaulting to HEAD) and
#    its age is always printed. A receipt from another commit is STALE and
#    counts as a failure, because "it passed on a tree that is not this one" is
#    not evidence about this one.
#
# Exit codes:
#   0  every requested lane has both surfaces present, current and passing
#   1  at least one lane is failing, missing or stale
#   2  usage error
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SURFACES_DIR="${GCP_TF_SURFACES_DIR:-${REPO_ROOT}/demo-surfaces}"
LANES="${GCP_TF_LANES:-demo-1 demo-2 ci-1 ci-2}"
SURFACES="on-vm tailnet"
WANT_COMMIT=""
AS_JSON=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --lanes)  LANES="${2:-}"; shift 2 ;;
    --commit) WANT_COMMIT="${2:-}"; shift 2 ;;
    --json)   AS_JSON=1; shift ;;
    -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'surfaces-report: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# Default to the tree we are standing in. Explicitly resolved rather than left
# empty, because an empty expected-commit would make every staleness check pass.
if [ -z "$WANT_COMMIT" ]; then
  WANT_COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "")"
fi

now="$(date +%s)"
rows=""
json_rows=""
fail=0

for lane in $LANES; do
  for surface in $SURFACES; do
    f="${SURFACES_DIR}/${lane}.${surface}.json"
    if [ ! -f "$f" ]; then
      rows+="${lane}|${surface}|MISSING|—|—|no receipt at $(basename "$f")\n"
      json_rows+="{\"env\":\"${lane}\",\"surface\":\"${surface}\",\"state\":\"MISSING\"},"
      fail=1
      continue
    fi

    outcome="$(jq -r '.outcome // "UNPARSEABLE"' "$f" 2>/dev/null || echo UNPARSEABLE)"
    commit="$(jq -r '.commit // ""' "$f" 2>/dev/null || echo "")"
    epoch="$(jq -r '.written_epoch // 0' "$f" 2>/dev/null || echo 0)"
    failed="$(jq -r '.checks_failed // 0' "$f" 2>/dev/null || echo 0)"
    total="$(jq -r '.checks_total // 0' "$f" 2>/dev/null || echo 0)"

    age="?"
    case "$epoch" in
      ''|*[!0-9]*) ;;
      *) age="$(( (now - epoch) / 60 ))m" ;;
    esac

    # Staleness outranks outcome. A PASS from another tree is not a pass here,
    # and reporting it as one is precisely the lie this file exists to prevent.
    state="$outcome"
    detail="${total:-0} checks, ${failed:-0} failed"
    if [ -n "$WANT_COMMIT" ] && [ -n "$commit" ] && [ "$commit" != "$WANT_COMMIT" ]; then
      state="STALE"
      detail="receipt is from ${commit}, tree is ${WANT_COMMIT}"
    fi

    [ "$state" = "PASS" ] || fail=1
    rows+="${lane}|${surface}|${state}|${age}|${commit:-—}|${detail}\n"
    json_rows+="{\"env\":\"${lane}\",\"surface\":\"${surface}\",\"state\":\"${state}\",\"commit\":\"${commit}\",\"age_minutes\":\"${age}\"},"
  done
done

if [ -n "$AS_JSON" ]; then
  printf '{"schema":"signalloom.surfaces.report/v1","expected_commit":"%s","lanes":[%s]}\n' \
    "$WANT_COMMIT" "${json_rows%,}"
  exit "$fail"
fi

printf '\n  Lane surfaces — expected commit %s\n\n' "${WANT_COMMIT:-<none>}"
printf '  %-8s %-8s %-8s %-6s %-9s %s\n' LANE SURFACE STATE AGE COMMIT DETAIL
printf '  %-8s %-8s %-8s %-6s %-9s %s\n' -------- -------- -------- ------ --------- ------
printf "$rows" | while IFS='|' read -r lane surface state age commit detail; do
  [ -n "$lane" ] || continue
  printf '  %-8s %-8s %-8s %-6s %-9s %s\n' "$lane" "$surface" "$state" "$age" "$commit" "$detail"
done
printf '\n'

# The two banners must not be substrings of one another.
#
# The failure text used to begin "NOT ALL LANES PASS", which CONTAINS the
# success phrase "ALL LANES PASS". Exit codes were right, but anything matching
# on the text — a human skimming, a log scraper, a grep in a wrapper script —
# would find the success string in a failing run. This suite's own test caught
# it. Keep the two phrases lexically disjoint.
if [ "$fail" -eq 0 ]; then
  printf '  ALL LANES PASS on both surfaces at %s\n\n' "$WANT_COMMIT"
else
  printf '  SWEEP FAILED. MISSING is not silence and STALE is not a pass:\n'
  printf '    MISSING  the surface never ran for that lane — run it\n'
  printf '    STALE    it passed on a DIFFERENT tree; rerun against %s\n\n' "$WANT_COMMIT"
fi
exit "$fail"
