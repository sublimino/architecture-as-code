#!/usr/bin/env bats
# Safety-invariant tests for scripts/revocation-demo.sh.
#
# The invariant under test: the script must never terminate leaving an unsigned
# or unverifiable artifact in the shared Zot registry. `apps/frontend:latest` is
# consumed by the OSRAMP slice, so a poisoned tag outlives the demo and makes the
# next `make demo-osramp-up` fail verification with no obvious cause.
#
# Every failure path AFTER the revoking push is exercised here with fake
# kubectl/flux/cosign/curl binaries, in the same style as test/zot-cache.bats.
# They cannot be exercised against a real cluster without deliberately pushing a
# revoked artifact at a shared registry, which is the very thing being prevented.
#
# The fakes log every invocation; assertions are made against that log, so
# "did the restore actually run" is answered by evidence rather than by exit code.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
  CMD_LOG="${BATS_TEST_TMPDIR}/cmd.log"
  mkdir -p "${FAKE_BIN}"
  : >"${CMD_LOG}"

  # Signing material the preflight insists on before it will revoke anything.
  mkdir -p "${BATS_TEST_TMPDIR}/keys"
  touch "${BATS_TEST_TMPDIR}/keys/cosign.key" \
        "${BATS_TEST_TMPDIR}/keys/cosign.pub" \
        "${BATS_TEST_TMPDIR}/keys/signing-config.json"

  # --- fake kubectl -------------------------------------------------------
  # SLICE_PRESENT toggles whether ocirepository/apps exists.
  #
  # Ready mirrors real Flux behaviour rather than a fixed value: False while the
  # tag holds the unsigned artifact, True once a signed one has been pushed. That
  # is what makes the happy path and the "unexpectedly accepted" path differ by
  # one variable. READY_STATUS forces the answer, for the failure-mode tests.
  cat >"${FAKE_BIN}/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$CMD_LOG"
case "$*" in
  # exec so the PID the script captures IS this sleep. Backgrounding a child
  # instead leaves an orphan that survives cleanup's kill and holds bats' pipe
  # open until the harness times out -- and would mask a real leak of the
  # port-forward, which is exactly what cleanup is supposed to prevent.
  *"port-forward"*) exec sleep 300 ;;
  *"get ocirepository apps"*)
    [ "${SLICE_PRESENT:-1}" = "1" ] || exit 1
    if [ -n "${READY_STATUS:-}" ]; then printf '%s' "${READY_STATUS}"; exit 0; fi
    if grep -qE 'cosign sign' "$CMD_LOG" 2>/dev/null; then printf 'True'; else printf 'False'; fi
    exit 0 ;;
  *annotate*) exit 0 ;;
esac
exit 0
SCRIPT

  # --- fake flux ----------------------------------------------------------
  # PUSH_FAILS_AFTER makes the Nth push (1-indexed) fail, so the restore push
  # can be broken independently of the revoking push.
  cat >"${FAKE_BIN}/flux" <<'SCRIPT'
#!/usr/bin/env bash
printf 'flux %s\n' "$*" >>"$CMD_LOG"
COUNT_FILE="${CMD_LOG}.pushcount"
n=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$COUNT_FILE"
if [ -n "${PUSH_FAILS_AFTER:-}" ] && [ "$n" -ge "${PUSH_FAILS_AFTER}" ]; then
  echo "simulated push failure" >&2; exit 1
fi
case "$*" in
  *--output\ json*) printf '{"digest":"sha256:%064d"}' "$n" ;;
esac
exit 0
SCRIPT

  # --- fake cosign --------------------------------------------------------
  # SIGN_FAILS breaks signing; VERIFY_FAILS breaks post-sign verification.
  cat >"${FAKE_BIN}/cosign" <<'SCRIPT'
#!/usr/bin/env bash
printf 'cosign %s\n' "$*" >>"$CMD_LOG"
case "$1" in
  sign)   [ -z "${SIGN_FAILS:-}" ]   || { echo "simulated sign failure" >&2; exit 1; } ;;
  verify) [ -z "${VERIFY_FAILS:-}" ] || { echo "simulated verify failure" >&2; exit 1; } ;;
esac
exit 0
SCRIPT

  cat >"${FAKE_BIN}/curl" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT

  chmod +x "${FAKE_BIN}"/*
}

run_demo() {
  cd "${REPO_ROOT}"
  run env PATH="${FAKE_BIN}:${PATH}" \
    CMD_LOG="${CMD_LOG}" \
    RECONCILE_SETTLE_SECONDS=0 \
    COSIGN_KEY="${BATS_TEST_TMPDIR}/keys/cosign.key" \
    SIGNING_CONFIG="${BATS_TEST_TMPDIR}/keys/signing-config.json" \
    "$@" \
    ./scripts/revocation-demo.sh
}

# Count how many times the artifact was pushed WITHOUT a following sign.
revoking_pushes() { grep -c 'flux push artifact.*revoked@' "${CMD_LOG}" || true; }
restore_pushes()  { grep -cE 'flux push artifact.*(restored|restore-on-exit)@' "${CMD_LOG}" || true; }

# ---------------------------------------------------------------------------

@test "refuses to revoke when the frontend slice is absent" {
  run_demo SLICE_PRESENT=0
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to push a revoked artifact"* ]]
}

@test "no artifact is pushed at all when preflight refuses" {
  run_demo SLICE_PRESENT=0
  # The regression that motivated this suite: the old script pushed the
  # unsigned artifact BEFORE discovering the slice was missing.
  [ "$(revoking_pushes)" -eq 0 ]
}

@test "refuses to revoke when the signing key is missing" {
  rm -f "${BATS_TEST_TMPDIR}/keys/cosign.key"
  run_demo
  [ "$status" -ne 0 ]
  [[ "$output" == *"cosign key missing"* ]]
  # Never revoke what we could not restore.
  [ "$(revoking_pushes)" -eq 0 ]
}

@test "happy path signs and verifies the restored artifact" {
  run_demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"RESTORED"* ]]
  grep -q 'cosign sign' "${CMD_LOG}"
  grep -q 'cosign verify' "${CMD_LOG}"
}

@test "restores when the unsigned artifact is unexpectedly accepted" {
  # Ready=True after the revoking push means verification is NOT failing closed.
  # The old script exited here, stranding the unsigned artifact.
  run_demo READY_STATUS=True
  [ "$status" -ne 0 ]
  [[ "$output" == *"restoring trust before exit"* ]]
  [ "$(restore_pushes)" -ge 1 ]
}

@test "reports FATAL and non-zero when restoration itself fails" {
  # Push 1 = revoke (succeeds), push 2 = restore (fails).
  run_demo READY_STATUS=True PUSH_FAILS_AFTER=2
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not restore"* ]]
  [[ "$output" == *"make push-local"* ]]
}

@test "a signing failure during restore is surfaced, not swallowed" {
  run_demo READY_STATUS=True SIGN_FAILS=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not restore"* ]]
}

@test "restore is not considered done unless the signature verifies" {
  # A signature that does not verify is indistinguishable from no signature as
  # far as Flux is concerned, so it must not count as a successful restore.
  run_demo READY_STATUS=True VERIFY_FAILS=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not restore"* ]]
}

@test "the restore push signs the exact digest it just pushed" {
  # This replaces an assertion that the push passed --registry-referrers-mode=legacy,
  # "the legacy referrers mode Flux reads". That was measured false on 2026-08-13:
  # under the pinned cosign v3.0.6, legacy, oci-1-1 and omitting the flag all store
  # a key-based signature identically -- one sigstore-bundle OCI referrer, never a
  # sha256-<digest>.sig tag -- and Flux source-controller v1.9.4 verifies that form
  # without complaint. The flag was inert, so asserting it proved nothing about
  # whether Flux would accept the restore, while reading as though it did. It sent
  # a later investigation of a genuine Ready=False after the storage format when
  # the real fault was a signing key the cluster did not trust.
  #
  # What actually matters here is the property the flag was standing in for: the
  # signature must land on the digest this push produced. Signing anything else --
  # a tag that a concurrent push can move -- is what strands `latest` on an
  # artifact Flux refuses. See test/cosign-signing-consistency.bats.
  run_demo READY_STATUS=True
  grep -q 'cosign sign .*@sha256:' "${CMD_LOG}"
}
