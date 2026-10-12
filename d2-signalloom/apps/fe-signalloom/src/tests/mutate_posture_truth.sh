#!/usr/bin/env bash
# Mutation harness for tests/test_posture_truth.py.
#
# Each mutant reintroduces one half of the posture defect and must turn the
# suite red. A mutant that stays green means the test does not actually
# constrain the code it claims to.
#
# Deliberately NOT `set -e`: a mutant is expected to fail and the restore must
# run regardless. The file is restored from an explicit cp backup and the
# restore is verified with `cmp -s` -- never `git checkout --`, which would
# also discard unstaged work and silently does nothing for untracked files.
cd "$(dirname "$0")/.." || exit 1
TARGET=api_compat.py
BAK=/tmp/w12-mutate-api_compat.bak
LOG=/tmp/w12-mutants.log
: > "$LOG"
cp "$TARGET" "$BAK" || exit 1

run_tests() {
    local out="$1"
    UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache timeout 580 \
        uv run --python 3.12 --with pytest --with pytest-asyncio --with respx \
        --with-requirements requirements.txt \
        python -m pytest tests/test_posture_truth.py -o addopts="" -q \
        --disable-warnings -p no:cacheprovider > "$out" 2>&1
    echo "$?"
}

mutate() {  # mutate <id> <description> <python-literal-old> <python-literal-new>
    local id="$1" desc="$2" old="$3" new="$4"
    python3 - "$TARGET" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
n = src.count(old)
if n != 1:
    sys.exit(f"anchor appears {n} times, expected 1")
open(path, "w").write(src.replace(old, new))
PY
    if [ $? -ne 0 ]; then
        echo "MUTANT $id SKIPPED (anchor not unique) -- $desc" >> "$LOG"
        cp "$BAK" "$TARGET"
        return
    fi
    local out="/tmp/w12-mutant-$id.log"
    local rc
    rc="$(run_tests "$out")"
    # Assert the tests RAN. `-run`/`-k` style no-ops exit 0 with zero tests
    # collected, which reads exactly like a pass.
    local collected
    collected="$(grep -cE '^[0-9]+ (passed|failed)|passed|failed' "$out")"
    local summary
    summary="$(grep -E '[0-9]+ (passed|failed)' "$out" | tail -1)"
    if [ "$rc" -eq 0 ]; then
        echo "MUTANT $id SURVIVED (rc=0) -- $desc -- $summary" >> "$LOG"
    elif [ -z "$summary" ]; then
        echo "MUTANT $id INCONCLUSIVE (rc=$rc, no test summary: collection error?) -- $desc" >> "$LOG"
    else
        echo "MUTANT $id KILLED (rc=$rc) -- $desc -- $summary" >> "$LOG"
        grep -E '^FAILED' "$out" | sed 's/^/    /' >> "$LOG"
    fi
    cp "$BAK" "$TARGET"
    if ! cmp -s "$BAK" "$TARGET"; then
        echo "RESTORE FAILED for mutant $id -- STOP" >> "$LOG"
        exit 1
    fi
}

# Baseline: unmutated tree must be green, or every "killed" below is noise.
BASE_RC="$(run_tests /tmp/w12-mutant-base.log)"
echo "BASELINE rc=$BASE_RC -- $(grep -E '[0-9]+ (passed|failed)' /tmp/w12-mutant-base.log | tail -1)" >> "$LOG"

mutate M1 "re-claim resets compliance_posture to 83 (F2, DO UPDATE half)" \
    '                    -- compliance_posture is deliberately NOT in this SET list.' \
    '                    compliance_posture = 83,'

mutate M2 "INSERT persists the literal 83 (F2, INSERT half)" \
    "                    'Signal Loom Built', NULL, NULL, \$6," \
    "                    'Signal Loom Built', 83, NULL, \$6,"

mutate M3 "reader re-synthesises 6 controls and defaults absence to 100 (F3)" \
    '    failing = int(row.get("findings_count", 0) or 0)' \
    '    fc = int(row.get("findings_count", 0) or 0)
    return ComplianceSummaryInline(total_controls=6, passing=max(6 - fc, 0), failing=fc, pending=0, posture_score=float(row.get("compliance_posture", 100)) / 100.0)
    failing = fc'

mutate M4 "zero assessed controls reported as measured instead of refused" \
    '    if total == 0:' \
    '    if False:'

mutate M5 "refusal swallows a real reading (negative control)" \
    '    if total == 0:' \
    '    if True:'

cp "$BAK" "$TARGET"
cmp -s "$BAK" "$TARGET" && echo "RESTORED CLEAN" >> "$LOG"
cat "$LOG"
