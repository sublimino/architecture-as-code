#!/usr/bin/env bats
#
# @id      final-mission-governor
# @target  scripts/final-governor-certification.sh
# @doc     docs/eap/SLDC-MISSION-CERTIFICATION.md
# @spec    Proposal - Signal Loom Local Dual-Cluster EAP Pilot Validation … SLDC-P5-GOV
#
# Hermetic: the e2e suite, reset, packager and verifier are fakes, so this runs
# with no cluster. The live gate is scripts/final-governor-certification.sh with
# its defaults.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    GATE="${REPO_ROOT}/scripts/final-governor-certification.sh"
    OUT="${BATS_TEST_TMPDIR}/out"
    FAKES="${BATS_TEST_TMPDIR}/fakes"
    mkdir -p "${FAKES}"
    # Fake e2e: 5 green steps, unless FAIL_RUN matches or SKIP_RUN matches.
    cat >"${FAKES}/e2e" <<'EOF'
#!/usr/bin/env bash
echo "${SLDC_RUN_INDEX}" >>"${CALLS}"
echo "1..5"
for s in 1 2 3 4 5; do
  if [ "${SLDC_RUN_INDEX}" = "${FAIL_RUN:-x}" ] && [ "$s" = 4 ]; then echo "not ok $s Step $s"; continue; fi
  if [ "${SLDC_RUN_INDEX}" = "${SKIP_RUN:-x}" ] && [ "$s" = 2 ]; then echo "ok $s Step $s # skip no cluster"; continue; fi
  [ "${SLDC_RUN_INDEX}" = "${SHORT_RUN:-x}" ] && [ "$s" = 5 ] && continue
  echo "ok $s Step $s"
done
[ "${SLDC_RUN_INDEX}" = "${FAIL_RUN:-x}" ] && exit 1 || exit 0
EOF
    cat >"${FAKES}/package" <<'EOF'
#!/usr/bin/env bash
out="${3:?}"; mkdir -p "$out"; [ "${PACKAGE_WRITES:-1}" = 0 ] || echo bundle >"$out/kusari-eap-evidence-test.tar.gz"
EOF
    printf '#!/usr/bin/env bash\nexit "${VERIFY_RC:-0}"\n' >"${FAKES}/verify"
    chmod +x "${FAKES}"/*
    export CALLS="${BATS_TEST_TMPDIR}/calls"
    export SLDC_E2E_CMD="${FAKES}/e2e"
    export SLDC_RESET_CMD="true"
    export SLDC_PACKAGE_CMD="${FAKES}/package"
    export SLDC_VERIFY_CMD="${FAKES}/verify"
    export SLDC_APPROVERS="Alice,Bob"
}

cert() { jq -r "$1" "${OUT}/final-mission-certification.json"; }

make_signoff() {
    # Real ssh-keygen signatures over the certificate digest written by the gate.
    local digest="$1" who
    echo '{"approvers":[]}' >"${BATS_TEST_TMPDIR}/signoff.json"
    for who in Alice Bob; do
        ssh-keygen -q -t ed25519 -N '' -C "$who" -f "${BATS_TEST_TMPDIR}/$who" <<<y >/dev/null
        echo "$who $(cat "${BATS_TEST_TMPDIR}/$who.pub")" >"${BATS_TEST_TMPDIR}/$who.allowed"
        ssh-keygen -q -Y sign -f "${BATS_TEST_TMPDIR}/$who" -n sldc-mission-cert <"$digest" >"${BATS_TEST_TMPDIR}/$who.sig"
        jq --arg w "$who" --arg s "${BATS_TEST_TMPDIR}/$who.sig" --arg a "${BATS_TEST_TMPDIR}/$who.allowed" \
           '.approvers += [{identity:$w, role:"test", signature_file:$s, allowed_signers:$a}]' \
           "${BATS_TEST_TMPDIR}/signoff.json" >"${BATS_TEST_TMPDIR}/s.tmp"
        mv "${BATS_TEST_TMPDIR}/s.tmp" "${BATS_TEST_TMPDIR}/signoff.json"
    done
}

@test "three green runs without sign-off are refused: agents cannot self-approve" {
    run "${GATE}" --out "${OUT}"
    [ "$status" -eq 1 ]
    [ "$(cert .status)" = awaiting-signoff ]
    [ "$(cert .consecutive_green_achieved)" -eq 3 ]
    [[ "$(cert .reason)" == *"human sign-off required"* ]]
    [ -f "${OUT}/kusari-eap-certified-bundle.tar.gz" ]
}

@test "mutation: run 2 fails -> gate halts, run 3 never executes, exit 1" {
    FAIL_RUN=2 run "${GATE}" --out "${OUT}"
    [ "$status" -eq 1 ]
    [ "$(cert .status)" = fail ]
    [ "$(cert .consecutive_green_achieved)" -eq 1 ]
    [ "$(tr '\n' ' ' <"${CALLS}")" = "1 2 " ]
    [ ! -f "${OUT}/kusari-eap-certified-bundle.tar.gz" ]
    grep -q '=== RUN 2 exit=1' "${OUT}/final-e2e-consecutive-runs.log"
}

@test "a skipped step is not green" {
    SKIP_RUN=3 run "${GATE}" --out "${OUT}"
    [ "$status" -eq 1 ]
    [[ "$(cert .reason)" == *"skipped"* ]]
}

@test "bundle that fails verification blocks certification" {
    VERIFY_RC=1 run "${GATE}" --out "${OUT}"
    [ "$status" -eq 1 ]
    [ "$(cert .reason)" = "evidence bundle failed verification" ]
    [ ! -f "${OUT}/kusari-eap-certified-bundle.tar.gz" ]
}

@test "valid ssh signatures from every approver certify the mission" {
    run "${GATE}" --out "${OUT}"
    make_signoff "${OUT}/final-mission-certification.digest"
    : >"${CALLS}"
    run "${GATE}" --out "${OUT}" --signoff "${BATS_TEST_TMPDIR}/signoff.json"
    [ "$status" -eq 0 ]
    [ ! -s "${CALLS}" ]  # finalising never re-runs the suite
    [ "$(cert .status)" = pass ]
    [ "$(cert '[.signoffs[] | select(.verified)] | length')" -eq 2 ]
}

@test "mutation: one approver signs the wrong digest -> refused" {
    run "${GATE}" --out "${OUT}"
    echo tampered >"${BATS_TEST_TMPDIR}/wrong.digest"
    make_signoff "${OUT}/final-mission-certification.digest"
    ssh-keygen -q -Y sign -f "${BATS_TEST_TMPDIR}/Bob" -n sldc-mission-cert <"${BATS_TEST_TMPDIR}/wrong.digest" >"${BATS_TEST_TMPDIR}/Bob.sig"
    run "${GATE}" --out "${OUT}" --signoff "${BATS_TEST_TMPDIR}/signoff.json"
    [ "$status" -eq 1 ]
    [ "$(cert .status)" = awaiting-signoff ]
    [[ "$(cert .reason)" == *"Bob"* ]]
}

@test "a red certificate cannot be signed into a pass" {
    FAIL_RUN=1 run "${GATE}" --out "${OUT}"
    make_signoff "${OUT}/final-mission-certification.digest"
    run "${GATE}" --out "${OUT}" --signoff "${BATS_TEST_TMPDIR}/signoff.json"
    [ "$status" -eq 1 ]
    [ "$(cert .status)" = fail ]
}

@test "mutation: a red certificate relabelled awaiting-signoff cannot be signed into a pass" {
    FAIL_RUN=1 run "${GATE}" --out "${OUT}"
    [ "$status" -eq 1 ]
    c="${OUT}/final-mission-certification.json"
    jq '.status = "awaiting-signoff"' "$c" >"$c.tmp" && mv "$c.tmp" "$c"
    make_signoff "${OUT}/final-mission-certification.digest"
    run "${GATE}" --out "${OUT}" --signoff "${BATS_TEST_TMPDIR}/signoff.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *"certificate records do not support sign-off"* ]]
    [ "$(cert .status)" != pass ]
}

@test "mutation: runs edited into the certificate break the digest and are refused" {
    run "${GATE}" --out "${OUT}"
    c="${OUT}/final-mission-certification.json"
    jq '.runs[0].seconds = 1' "$c" >"$c.tmp" && mv "$c.tmp" "$c"
    make_signoff "${OUT}/final-mission-certification.digest"
    run "${GATE}" --out "${OUT}" --signoff "${BATS_TEST_TMPDIR}/signoff.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *"certificate_digest does not match its recorded runs and bundle"* ]]
}

@test "mutation: a bundle replaced after the gate ran is refused at sign-off" {
    run "${GATE}" --out "${OUT}"
    echo forged >"${OUT}/kusari-eap-certified-bundle.tar.gz"
    make_signoff "${OUT}/final-mission-certification.digest"
    run "${GATE}" --out "${OUT}" --signoff "${BATS_TEST_TMPDIR}/signoff.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *"certified bundle no longer matches bundle_sha256"* ]]
    [ "$(cert .status)" = awaiting-signoff ]
}

@test "mutation: a stale bundle left in staging is never certified when packaging writes nothing" {
    mkdir -p "${OUT}/bundle-staging"
    echo stale >"${OUT}/bundle-staging/kusari-eap-evidence-20200101T000000Z.tar.gz"
    PACKAGE_WRITES=0 run "${GATE}" --out "${OUT}"
    [ "$status" -eq 1 ]
    [ "$(cert .status)" = fail ]
    [ "$(cert .reason)" = "evidence bundle failed verification" ]
    [ ! -f "${OUT}/kusari-eap-certified-bundle.tar.gz" ]
}

@test "mutation: a run that stops short of its TAP plan is not green" {
    SHORT_RUN=2 run "${GATE}" --out "${OUT}"
    [ "$status" -eq 1 ]
    [ "$(cert .status)" = fail ]
    [[ "$(cert .reason)" == *"run 2 reported 4 of 5 planned tests"* ]]
}

@test "--runs must be a positive integer (exit 2)" {
    run "${GATE}" --runs 0 --out "${OUT}"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--runs must be a positive integer"* ]]
}
