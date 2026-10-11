#!/usr/bin/env bash
# Confirms the behavioural tests still independently catch a WIRE-VISIBLE money
# figure, so the source guard is not load-bearing for that case and does not
# need to duplicate the coverage.
#
# The guard tests are excluded from the run on purpose: the question is what the
# BEHAVIOURAL suite sees.
set -eo pipefail
cd "$(dirname "$0")"
SRC=pkg/compliance/fleet_scan.go
BAK=/tmp/w8-fs-wire.bak

cp "$SRC" "$BAK"
trap 'cp "$BAK" "$SRC"' EXIT

# Inject a carried figure that actually reaches the response.
python3 - "$SRC" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "\tstatus := PricingStatusNoDeclaredLossFrequency\n\treturn FleetFairRiskSummary{"
new = ("\tstatus := PricingStatusNoDeclaredLossFrequency\n"
       "\tw8carried := 847000.0\n"
       "\treturn FleetFairRiskSummary{\n"
       "\t\tCarriedGBP: &w8carried,")
assert s.count(old) == 1, f"anchor count {s.count(old)}"
open(p, "w").write(s.replace(old, new))
PY

if ! go build ./... >/tmp/w8-wire-build.log 2>&1; then
  echo "COMPILE-FAIL (not scored)"; sed -n '1,6p' /tmp/w8-wire-build.log; exit 0
fi
if ! go vet ./pkg/compliance/ >/tmp/w8-wire-vet.log 2>&1; then
  echo "VET-FAIL (not scored)"; sed -n '1,6p' /tmp/w8-wire-vet.log; exit 0
fi

go test ./pkg/compliance/ -count=1 -v >/tmp/w8-wire-test.log 2>&1 || true
RAN=$(grep -c '^=== RUN   Test' /tmp/w8-wire-test.log || true)
echo "named tests run: $RAN"
echo "behavioural tests killed by a wire-visible 847000.0:"
grep '^--- FAIL' /tmp/w8-wire-test.log \
  | grep -vE 'BindsNoMoneyMagnitudeLiterals|MoneyLiteralGuard|MoneyLiteralExemptions' \
  | sed 's/^/  /'
echo "source guard also fired (expected, and NOT the point here):"
grep '^--- FAIL' /tmp/w8-wire-test.log | grep -E 'BindsNoMoneyMagnitudeLiterals' | sed 's/^/  /'

cp "$BAK" "$SRC"
cmp -s "$BAK" "$SRC" && echo "RESTORE: byte-identical" || echo "RESTORE: FAILED"
