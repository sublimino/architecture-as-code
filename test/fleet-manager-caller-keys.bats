#!/usr/bin/env bats
#
# @id      fleet-manager-caller-keys
# @target  scripts/fleet-manager-caller-keys.sh
# @doc     d2-signalloom/apps/fleet-manager/callerauth.go
#
# The caller-key bootstrap against a fake kubectl that records argv and the
# applied manifest. No cluster.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/fleet-manager-caller-keys.sh"
  STATE="${BATS_TEST_TMPDIR}/state"
  mkdir -p "${STATE}" "${BATS_TEST_TMPDIR}/bin"
  cat >"${BATS_TEST_TMPDIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_STATE}/argv"
case "$*" in
  *" apply -f -"*)
    cat >"${FAKE_STATE}/applied"
    cp "${FAKE_STATE}/applied" "${FAKE_STATE}/stored" ;;
  *"get secret fleet-manager-caller-keys"*)
    [ -f "${FAKE_STATE}/stored" ] || exit 1
    k="$(sed -n 's/.*{\.data\.\([a-z-]*\)}.*/\1/p' <<<"$*")"
    awk -v k="  ${k}:" 'index($0,k)==1 {print $2; exit}' "${FAKE_STATE}/stored" | tr -d '\n' ;;
esac
EOF
  chmod +x "${BATS_TEST_TMPDIR}/bin/kubectl"
  export SLDC_KUBECTL="${BATS_TEST_TMPDIR}/bin/kubectl" FAKE_STATE="${STATE}" KUBECONFIG=/dev/null
}

# value <secret-key>: a data value from the last applied manifest.
value() { awk -v k="  $1:" 'index($0,k)==1 {print $2; exit}' "${STATE}/applied"; }

@test "caller-keys: --context is required, exit 2, nothing applied" {
  run bash "${SCRIPT}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--context is required"* ]]
  [ ! -e "${STATE}/applied" ]
}

@test "caller-keys: writes six distinct keys and mirrors sentinel and warden to agents namespace" {
  run bash "${SCRIPT}" --context kind-osramp
  [ "$status" -eq 0 ]
  local s w r f d o
  s="$(value stun-sentinel)"; w="$(value signalloom-warden)"; r="$(value warden)"
  f="$(value fe-signalloom)"; d="$(value dashboard)"; o="$(value operator)"
  [ -n "$s" ] && [ -n "$w" ] && [ -n "$r" ] && [ -n "$f" ] && [ -n "$d" ] && [ -n "$o" ]
  [ "$(printf '%s\n' "$s" "$w" "$r" "$f" "$d" "$o" | sort -u | wc -l)" -eq 6 ]
  grep -q 'namespace: fe-signalloom-agents' "${STATE}/applied"
  grep -q 'name: signalloom-warden-fleet-key' "${STATE}/applied"
  # 32 random bytes: base64 of the 44-char key decodes to >= 32 bytes.
  [ "$(printf '%s' "$w" | base64 -d | base64 -d | wc -c)" -ge 32 ]
}

@test "caller-keys: the remote warden key is its OWN key, never the local warden's" {
  # The whole point of the sixth caller. `signalloom-warden` carries scope stun
  # and `warden` carries scope report, so one value for both would hand a
  # remote cluster the right to freeze the hub's own agents.
  run bash "${SCRIPT}" --context kind-osramp
  [ "$status" -eq 0 ]
  [ "$(value warden)" != "$(value signalloom-warden)" ]
  [ "$(value warden)" != "$(value stun-sentinel)" ]
  [ "$(value warden)" != "$(value operator)" ]
}

# --- --emit-remote-secrets ----------------------------------------------------
#
# The fake kubectl above answers only for fleet-manager-caller-keys. These
# tests extend it to serve the signal-ingest issuer Secret too, because that is
# what the emitter READS rather than mints.

# with_ingest_issuer <b64-or-empty>: a fake kubectl that also answers
# `get secret signal-ingest-key-signalloom-warden -o jsonpath={.data.token}`.
with_ingest_issuer() {
  export FAKE_INGEST_TOKEN="$1"
  cat >"${BATS_TEST_TMPDIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_STATE}/argv"
case "$*" in
  *" apply -f -"*)
    cat >"${FAKE_STATE}/applied"
    cp "${FAKE_STATE}/applied" "${FAKE_STATE}/stored" ;;
  *"get secret signal-ingest-key-signalloom-warden"*)
    printf '%s' "${FAKE_INGEST_TOKEN}" ;;
  *"get secret fleet-manager-caller-keys"*)
    [ -f "${FAKE_STATE}/stored" ] || exit 1
    k="$(sed -n 's/.*{\.data\.\([a-z-]*\)}.*/\1/p' <<<"$*")"
    awk -v k="  ${k}:" 'index($0,k)==1 {print $2; exit}' "${FAKE_STATE}/stored" | tr -d '\n' ;;
esac
EOF
  chmod +x "${BATS_TEST_TMPDIR}/bin/kubectl"
}

@test "caller-keys: --emit-remote-secrets needs a directory (exit 2)" {
  run bash "${SCRIPT}" --context kind-osramp --emit-remote-secrets
  [ "$status" -eq 2 ]
  [ ! -e "${STATE}/applied" ]
}

@test "caller-keys: --emit-remote-secrets writes the two Secrets the overlay reads" {
  with_ingest_issuer "aW5nZXN0LWtleS12YWx1ZQ=="
  local dir="${BATS_TEST_TMPDIR}/transfer"
  run bash "${SCRIPT}" --context kind-osramp --emit-remote-secrets "${dir}"
  [ "$status" -eq 0 ]

  # The two file names, and the two Secret names the remote-tenant DaemonSet
  # resolves its SIGNAL_INGEST_TOKEN and FLEET_MANAGER_STUN_KEY from.
  [ -f "${dir}/signalloom-warden-fleet-key.yaml" ]
  [ -f "${dir}/signalloom-warden-ingest-token.yaml" ]
  grep -q '^  name: signalloom-warden-fleet-key$' "${dir}/signalloom-warden-fleet-key.yaml"
  grep -q '^  name: signalloom-warden-ingest-token$' "${dir}/signalloom-warden-ingest-token.yaml"
  # Both in the namespace the overlay puts the DaemonSet in, both under `token`.
  grep -cq '^  namespace: fe-signalloom-agents$' "${dir}/signalloom-warden-fleet-key.yaml"
  grep -q '^  token: ' "${dir}/signalloom-warden-fleet-key.yaml"
  grep -q '^  token: aW5nZXN0LWtleS12YWx1ZQ==$' "${dir}/signalloom-warden-ingest-token.yaml"
}

@test "caller-keys: the emitted fleet Secret carries the warden key, not the local one" {
  with_ingest_issuer "aW5nZXN0LWtleS12YWx1ZQ=="
  local dir="${BATS_TEST_TMPDIR}/transfer"
  run bash "${SCRIPT}" --context kind-osramp --emit-remote-secrets "${dir}"
  [ "$status" -eq 0 ]
  local emitted
  emitted="$(awk '$1 == "token:" {print $2; exit}' "${dir}/signalloom-warden-fleet-key.yaml")"
  [ -n "${emitted}" ]
  [ "${emitted}" = "$(value warden)" ]
  [ "${emitted}" != "$(value signalloom-warden)" ]
}

@test "caller-keys: emitted files are 0600 in a 0700 directory" {
  with_ingest_issuer "aW5nZXN0LWtleS12YWx1ZQ=="
  local dir="${BATS_TEST_TMPDIR}/transfer"
  run bash "${SCRIPT}" --context kind-osramp --emit-remote-secrets "${dir}"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "${dir}")" = "700" ]
  [ "$(stat -c '%a' "${dir}/signalloom-warden-fleet-key.yaml")" = "600" ]
  [ "$(stat -c '%a' "${dir}/signalloom-warden-ingest-token.yaml")" = "600" ]
}

@test "caller-keys: no ingest issuer Secret is exit 1 naming the issuing command" {
  with_ingest_issuer ""
  local dir="${BATS_TEST_TMPDIR}/transfer"
  run bash "${SCRIPT}" --context kind-osramp --emit-remote-secrets "${dir}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sldc-ingest-bearer.sh"* ]]
  [[ "$output" == *"--key signalloom-warden"* ]]
  # Neither file is written: a half-populated transfer directory reads as done.
  [ ! -e "${dir}/signalloom-warden-fleet-key.yaml" ]
  [ ! -e "${dir}/signalloom-warden-ingest-token.yaml" ]
}

@test "caller-keys: no emitted key value reaches argv or the script's output" {
  with_ingest_issuer "aW5nZXN0LWtleS12YWx1ZQ=="
  local dir="${BATS_TEST_TMPDIR}/transfer"
  run bash "${SCRIPT}" --context kind-osramp --emit-remote-secrets "${dir}"
  [ "$status" -eq 0 ]
  local v plain
  for v in "$(value warden)" "aW5nZXN0LWtleS12YWx1ZQ=="; do
    plain="$(printf '%s' "$v" | base64 -d 2>/dev/null || true)"
    if grep -qF -e "$v" "${STATE}/argv"; then echo "key in argv"; return 1; fi
    [[ "$output" != *"$v"* ]]
    [ -z "$plain" ] || [[ "$output" != *"$plain"* ]]
  done
}

@test "caller-keys: no key ever reaches argv or the script's output" {
  run bash "${SCRIPT}" --context kind-osramp
  [ "$status" -eq 0 ]
  local v plain
  for v in "$(value stun-sentinel)" "$(value signalloom-warden)" "$(value fe-signalloom)" "$(value dashboard)" "$(value operator)"; do
    plain="$(printf '%s' "$v" | base64 -d)"
    if grep -qF -e "$v" -e "$plain" "${STATE}/argv"; then echo "key in argv"; return 1; fi
    [[ "$output" != *"$v"* && "$output" != *"$plain"* ]]
  done
}

@test "caller-keys: a re-run keeps every key; --rotate replaces every key" {
  bash "${SCRIPT}" --context kind-osramp
  local before; before="$(value stun-sentinel) $(value signalloom-warden) $(value fe-signalloom) $(value dashboard) $(value operator)"
  bash "${SCRIPT}" --context kind-osramp
  [ "$(value stun-sentinel) $(value signalloom-warden) $(value fe-signalloom) $(value dashboard) $(value operator)" = "$before" ]
  run bash "${SCRIPT}" --context kind-osramp --rotate
  [ "$status" -eq 0 ]
  [ "$(value signalloom-warden)" != "$(echo "$before" | awk '{print $2}')" ]
}

@test "caller-keys: a failed apply is exit 1 and says so" {
  printf '#!/usr/bin/env bash\ncase "$*" in *apply*) cat >/dev/null ;; esac\nexit 1\n' >"${BATS_TEST_TMPDIR}/bin/kubectl"
  run bash "${SCRIPT}" --context kind-osramp
  [ "$status" -eq 1 ]
  [[ "$output" == *"kubectl apply failed for context kind-osramp"* ]]
}
