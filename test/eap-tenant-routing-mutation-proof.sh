#!/usr/bin/env bash
# eap-tenant-routing-mutation-proof.sh — prove the SLDC-P3 tenant suites can fail.
#
# Breaks the REAL tenant filter Lua, HTTPRoute, Dex config, verify script and
# preflight legacy-gate one defect at a time, confirms the named test goes red,
# restores, and confirms green. Uses test/helpers/mutation-sentinel.bash, so a
# killed run leaves a sentinel and the next run refuses instead of lying.
#
# Run: test/eap-tenant-routing-mutation-proof.sh   (offline; no cluster)

# Mutations are single-quoted sed programs so `$` and quotes stay literal.
# shellcheck disable=SC2016

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
export KUBECONFIG=/dev/null

POLICY="d2-infra/components/ingress/tenant-filter-policy.yaml"
ROUTE="deploy/eap-tenant-httproute.yaml"
DEX="d2-signalloom/infra/dex/dex-config-eap.yaml"
VERIFY="scripts/verify-tenant-routing.sh"
PREFLIGHT="scripts/p3-tenant-preflight.sh"

# shellcheck source=helpers/mutation-sentinel.bash
source "${REPO_ROOT}/test/helpers/mutation-sentinel.bash"
ms_guard_init eap-tenant-routing "$POLICY" "$ROUTE" "$DEX" "$VERIFY" "$PREFLIGHT"
trap ms_guard_on_exit EXIT

PASS=0
FAIL=0
SUITE=""

# Names, not numbers: failing test names survive reordering.
failing_tests() { bats "$SUITE" 2>&1 | sed -n 's/^not ok [0-9]* //p'; }

check() { # label, expected failing test name
  local got
  got="$(failing_tests || true)"
  if [[ "$got" == *"$2"* ]]; then
    echo "  RED as expected — \"$2\"  [$1]"
    PASS=$((PASS + 1))
  else
    echo "  *** NOT PROVEN: expected \"$2\" to fail. Failures were:" >&2
    printf '        %s\n' "${got:-<none>}" >&2
    FAIL=$((FAIL + 1))
  fi
  ms_guard_restore
}

green_or_die() { # phase
  bats "$SUITE" >/dev/null 2>&1 || { echo "HARNESS ERROR: $SUITE not green $1 mutation" >&2; exit 2; }
}

SUITE="test/eap-tenant-routing.bats"
echo "=== $SUITE ==="
green_or_die before

echo "M1  filter admits the retired typo kurasi"
ms_sed "$POLICY" 's/if clean_tenant == "kurasi" or clean_tenant == "6f82ad81" or (clean_tenant ~= "kusari" and/if clean_tenant == "6f82ad81" or (clean_tenant ~= "kurasi" and clean_tenant ~= "kusari" and/'
check M1 "lua: the retired typo kurasi and its hash 6f82ad81 are 403 in any case or padding"

echo "M2  filter inspects only x-tenant-id (conflicting header laundered)"
ms_sed "$POLICY" 's/for _, name in ipairs({ "x-tenant-id", "x-signalloom-tenant" }) do/for _, name in ipairs({ "x-tenant-id" }) do/'
check M2 "lua: conflicting tenant headers are 403 even when x-tenant-id is canonical"

echo "M3  rejected tenant echoed unescaped into the 403 body and audit log"
ms_sed "$POLICY" 's/local tenant = escape(clean_tenant)/local tenant = clean_tenant/'
check M3 "lua: the 403 body stays valid JSON and echoes the tenant exactly for hostile values"

echo "M4  audit log alone loses escaping of the authority"
ms_sed "$POLICY" 's/tenant, escape(authority)))/clean_tenant, authority))/'
check M4 "lua: the security audit log line cannot be split by CR/LF in the tenant value"

echo "M5  whitespace trim removed"
ms_sed "$POLICY" 's/string.lower(raw_tenant:match("^%s\*(.-)%s\*$") or raw_tenant)/string.lower(raw_tenant)/'
check M5 "lua: surrounding whitespace, upper case and one pair of quotes normalise to kusari"

echo "M6  x-signalloom-tenant no longer canonicalised upstream"
ms_sed "$POLICY" '/^          headers:replace("x-signalloom-tenant", "kusari")$/d'
check M6 "lua: no tenant header continues with the canonical tenant injected"

echo "M7  no return after the 403 local reply"
ms_sed "$POLICY" '/reject(handle, clean_tenant, authority)/{n;s/return/-- return/}'
check M7 "lua: mismatched tenants are 403 with the exact JSON body"

echo "M8  whitespace-only header treated as absent"
ms_sed "$POLICY" 's/if raw_tenant and raw_tenant ~= "" then/if raw_tenant and raw_tenant:match("%S") then/'
check M8 "lua: a whitespace-only tenant header is 403, not treated as absent"

echo "M9  HTTPRoute hostname drifts to the retired hash"
ms_sed "$ROUTE" 's/"sl-eap-4b53ab6b.ts.net"/"sl-eap-6f82ad81.ts.net"/'
check M9 "HTTPRoute hostnames and tenant labels are derived from the salted kusari hash"

echo "M10 HTTPRoute backend port drifts"
ms_sed "$ROUTE" 's/port: 3000/port: 3001/'
check M10 "HTTPRoute attaches to signalloom-gateway and sends / to fe-signalloom-service:3000"

echo "M11 SecurityPolicy targets a different route"
ms_sed "$POLICY" '/^kind: SecurityPolicy/,$ s/name: eap-tenant-kusari/name: eap-tenant-other/'
check M11 "both tenant policies target the HTTPRoute in its own namespace"

echo "M12 Dex drops the demo host /callback"
ms_sed "$DEX" '\|"https://sl-eap-4b53ab6b.demo.signalloom.io/callback"|d'
check M12 "Dex registers /auth/callback and /callback for every routed hostname and no other sl-eap host"

echo "M13 Dex gains a redirect on an unrouted sl-eap host"
ms_sed "$DEX" 's|"http://localhost:5173/callback"|"https://sl-eap-6f82ad81.ts.net/callback"|'
check M13 "Dex registers /auth/callback and /callback for every routed hostname and no other sl-eap host"

echo "M14 verify --hermetic answers 200 without running the Lua"
ms_sed "$VERIFY" 's/^  if \[\[ "\$out" == \*"action=respond"\* \]\]; then/  if false; then/'
check M14 "verify --hermetic answers from the policy file: a filter that admits kurasi fails P6 and P9"

echo "M15 verify probe error count trips set -e again"
ms_sed "$VERIFY" 's/ || ERRORS=\$((ERRORS + 1))$/ || ((ERRORS++))/'
check M15 "verify --hermetic routes by the HTTPRoute: an unlisted host is 404, the retired host too"

echo "M16 verify --hermetic no longer requires luajit"
ms_sed "$VERIFY" 's/^  for tool in yq luajit; do/  for tool in yq; do/'
check M16 "verify --hermetic refuses to run without luajit (exit 2), never falls back to a mock"

echo "M17 verify routes any host (no HTTPRoute lookup)"
ms_sed "$VERIFY" 's/^  if ! yq -e ".spec.hostnames\[\] | select(. == \\"\$host\\")" "\$HTTPROUTE_MANIFEST" >\/dev\/null 2>&1; then/  if false; then/'
check M17 "verify --hermetic passes all 11 probes against the shipped config"

green_or_die after

SUITE="test/p3-tenant-preflight.bats"
echo "=== $SUITE ==="
green_or_die before

echo "M18 legacy-gate ignores the allowlist subtraction"
ms_sed "$PREFLIGHT" 's/| unique - \$a\[0\] | \.\[\]/| [] | .[]/'
check M18 "legacy-gate fails with exit 3 and names each unexcused active file, ignoring docs, tests and records"

echo "M19 legacy-gate passes without an allowlist"
ms_sed "$PREFLIGHT" 's/\[\[ -f "\$allow" \]\] || die "legacy-gate: allowlist not found: \$allow"/[[ -f "$allow" ]] || { echo "legacy-gate: 0 unexcused files (0 allowlisted)"; return 0; }/'
check M19 "legacy-gate refuses to run without an allowlist (exit 2), never passes by default"

echo "M20 .evidence/ records counted as active code"
ms_sed "$PREFLIGHT" 's/ | \.evidence\/\* | / | /'
check M20 "legacy-gate fails with exit 3 and names each unexcused active file, ignoring docs, tests and records"

green_or_die after

echo ""
echo "proven: ${PASS}   NOT proven: ${FAIL}"
[[ "$FAIL" -eq 0 ]]
