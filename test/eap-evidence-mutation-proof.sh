#!/usr/bin/env bash
# eap-evidence-mutation-proof.sh: prove the SLDC evidence / governor / P6 suites
# can fail. Each mutation breaks one REAL production line (never a fixture),
# the named test must go red, and the file is restored from the sentinel
# backup (test/helpers/mutation-sentinel.bash), not `git checkout`.
#
# Offline: every suite exercised here is hermetic (stubs, ephemeral keys).
#
# Run: bash test/eap-evidence-mutation-proof.sh
#
# Mutations are single-quoted sed programs so `$` stays literal.
# shellcheck disable=SC2016

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
export KUBECONFIG=/dev/null

V=scripts/verify-eap-evidence.sh
P=scripts/package-eap-evidence.sh
L=scripts/lib/eap-evidence.sh
J=scripts/lib/json-schema-lite.jq
G=scripts/final-governor-certification.sh
R=scripts/run-e2e-dual-cluster-containment.sh
T=scripts/super-test-adversarial.sh
H=scripts/lib/cluster-reset-helpers.sh
PRE=scripts/verify-teardown-prereqs.sh
TD=scripts/cluster-clean-teardown.sh
SU=scripts/cluster-scratch-standup.sh

# shellcheck source=helpers/mutation-sentinel.bash
source "${REPO_ROOT}/test/helpers/mutation-sentinel.bash"
ms_guard_init eap-evidence "$V" "$P" "$L" "$J" "$G" "$R" "$T" "$H" "$PRE" "$TD" "$SU"
trap ms_guard_on_exit EXIT

PASS=0
FAIL=0

# check LABEL SUITE FILTER: the unmutated test matching FILTER was green at
# baseline; under the mutation it must report `not ok`.
check() {
	local label="$1" suite="test/$2.bats" filter="$3" out
	out="$(bats --tap -f "$filter" "$suite" 2>&1 || true)"
	if grep -q '^not ok' <<<"$out"; then
		echo "  RED as expected  [$label]"
		PASS=$((PASS + 1))
	else
		echo "  *** NOT PROVEN [$label]: '$filter' in $suite stayed green" >&2
		FAIL=$((FAIL + 1))
	fi
	ms_guard_restore
}

CHECKS=(
	"eap-evidence-adversarial|duplicate entry"
	"eap-evidence-adversarial|symlinked signature"
	"eap-evidence-adversarial|entry is refused and nothing"
	"eap-evidence-adversarial|symlink entry pointing outside"
	"eap-evidence-adversarial|one flipped byte"
	"eap-evidence-adversarial|garbage signature"
	"eap-evidence-adversarial|extra field"
	"eap-evidence-adversarial|fails self-verification"
	"eap-evidence-adversarial|planted keys"
	"evidence-bundle-integrity|legacy tenant kurasi fails closed"
	"eap-evidence-schema-lite|unsupported keyword is refused"
	"eap-evidence-schema-lite|more than one JSON document"
	"eap-evidence-schema-lite|pattern and minLength"
	"final-mission-governor|relabelled awaiting-signoff"
	"final-mission-governor|stale bundle left in staging"
	"final-mission-governor|stops short of its TAP plan"
	"eap-evidence-runner|a red suite"
	"eap-evidence-supertest|live probe command that fails"
	"p6-teardown-preflight|orphaned_veths lists only"
	"p6-teardown-preflight|tampered Phase 5 bundle"
	"p6-teardown-safety|cluster delete fails"
	"p6-teardown-safety|failing platform target"
)

echo "=== baseline: every guarded test is green before any mutation ==="
for c in "${CHECKS[@]}"; do
	if ! bats -f "${c#*|}" "test/${c%%|*}.bats" >/dev/null 2>&1; then
		echo "HARNESS ERROR: '${c#*|}' in test/${c%%|*}.bats is not green before mutation" >&2
		exit 2
	fi
done
echo "  GREEN (${#CHECKS[@]} tests)"

echo "=== mutations ==="
ms_sed "$V" 's/LC_ALL=C sort | uniq -d)/LC_ALL=C sort | uniq -d | head -0)/'
check "M1 duplicate tar entries accepted" eap-evidence-adversarial "duplicate entry"
ms_sed "$V" 's/^  if \[ -L "\$dir\/\$f" \]; then$/  if false; then/'
check "M2 symlinked signature material followed" eap-evidence-adversarial "symlinked signature"
ms_sed "$V" 's#^      /\* | \*\.\.\*)#      /NEVER)#'
check "M3 parent-path entries accepted" eap-evidence-adversarial "entry is refused and nothing"
ms_sed "$V" 's/\$1 != "-rw-r--r--" && //'
check "M4 non-regular entry types accepted" eap-evidence-adversarial "symlink entry pointing outside"
ms_sed "$V" 's/sha256sum --check --strict "\$EAP_MANIFEST"/true/'
check "M5 manifest digests not checked" eap-evidence-adversarial "one flipped byte"
ms_sed "$V" 's/^  if openssl pkeyutl -verify/  if true || openssl pkeyutl -verify/'
check "M6 signature not verified" eap-evidence-adversarial "garbage signature"
ms_sed "$V" "s/^elif ! errs=\"\\\$(eap_validate_json \"\\\$schema\" \"\\\$header\" '#')\"; then/elif false; then/"
check "M7 header schema not enforced" eap-evidence-adversarial "extra field"
ms_sed "$P" '/^(cd "\$out_dir" && sha256sum "\$bundle_name.tar.gz"/a cp -f "$tarball" "$out_dir/eap-kusari-containment.tar.gz"'
check "M8 alias written before self-verification" eap-evidence-adversarial "fails self-verification"
ms_sed "$P" 's#^cp -- "\${EAP_RAW_ARTIFACTS\[@\]}"#cp -r ./. "$stage/$bundle_name/" \&\& true || cp -- "${EAP_RAW_ARTIFACTS[@]}"#'
check "M9 whole evidence dir packaged (secrets leak)" eap-evidence-adversarial "planted keys"
ms_sed "$L" "s/grep -Eiq 'kurasi|6f82ad81'/grep -Eiq 'NEVERMATCH'/"
check "M10 legacy tenant sweep disabled" evidence-bundle-integrity "legacy tenant kurasi fails closed"
ms_sed "$J" 's/elif (\$s | unsupported_keywords | length) > 0 then/elif false then/'
check "M11 unsupported keywords ignored" eap-evidence-schema-lite "unsupported keyword is refused"
ms_sed "$J" 's/if (\$doc | length) != 1 then/if false then/'
check "M12 only first JSON document validated" eap-evidence-schema-lite "more than one JSON document"
ms_sed "$J" 's/if \$v | test(\$s.pattern) then empty/if true then empty/'
check "M13 pattern not enforced" eap-evidence-schema-lite "pattern and minLength"
ms_sed "$G" '/certificate records do not support sign-off/s/exit 1; }/true; }/'
check "M14 sign-off trusts the status label" final-mission-governor "relabelled awaiting-signoff"
ms_sed "$G" 's/^    rm -rf "\${OUT_DIR}\/bundle-staging"$/    :/'
check "M15 stale staging bundle certified" final-mission-governor "stale bundle left in staging"
ms_sed "$G" 's/if \[ "\${planned:-0}" -ne "\${passed}" \]; then/if false; then/'
check "M16 short TAP run counted green" final-mission-governor "stops short of its TAP plan"
ms_sed "$R" 's/rc="\${PIPESTATUS\[0\]}"/rc=0/'
check "M17 runner masks a red suite" eap-evidence-runner "a red suite"
ms_sed "$T" 's/"\$(\[ "\$rc" -eq 0 \] && echo PASS || echo FAIL)"/PASS/'
check "M18 super-test hardcodes PASS" eap-evidence-supertest "live probe command that fails"
ms_sed "$H" 's#\$0 !~ / master / ##'
check "M19 bridge-attached veths treated as orphans" p6-teardown-preflight "orphaned_veths lists only"
ms_sed "$PRE" 's#^elif ! bash "\$SCRIPT_DIR/verify-eap-evidence.sh" --quiet "\$EAP_TAR" >/dev/null 2>&1; then#elif false; then#'
check "M20 preserved bundle not verified" p6-teardown-preflight "tampered Phase 5 bundle"
ms_sed "$TD" 's/^        FAILURES=\$((FAILURES + 1))$/        :/'
check "M21 failed cluster delete ignored" p6-teardown-safety "cluster delete fails"
ms_sed "$SU" 's/^make -C "\$REPO_ROOT" demo-signalloom-up$/make -C "$REPO_ROOT" demo-signalloom-up || true/'
check "M22 platform failure swallowed" p6-teardown-safety "failing platform target"

echo "=== restored ==="
ms_guard_restore
echo "mutations proven: ${PASS}/$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
