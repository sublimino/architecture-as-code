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

@test "caller-keys: writes three distinct keys and mirrors the sentinel's to its namespace" {
  run bash "${SCRIPT}" --context kind-osramp
  [ "$status" -eq 0 ]
  local s f o tok
  s="$(value stun-sentinel)"; f="$(value fe-signalloom)"; o="$(value operator)"; tok="$(value token)"
  [ -n "$s" ] && [ -n "$f" ] && [ -n "$o" ]
  [ "$s" != "$f" ] && [ "$s" != "$o" ] && [ "$f" != "$o" ]
  [ "$tok" = "$s" ]
  grep -q 'namespace: fe-signalloom-agents' "${STATE}/applied"
  # 32 random bytes: base64 of the 44-char key decodes to >= 32 bytes.
  [ "$(printf '%s' "$s" | base64 -d | base64 -d | wc -c)" -ge 32 ]
}

@test "caller-keys: no key ever reaches argv or the script's output" {
  run bash "${SCRIPT}" --context kind-osramp
  [ "$status" -eq 0 ]
  local v plain
  for v in "$(value stun-sentinel)" "$(value fe-signalloom)" "$(value operator)"; do
    plain="$(printf '%s' "$v" | base64 -d)"
    if grep -qF -e "$v" -e "$plain" "${STATE}/argv"; then echo "key in argv"; return 1; fi
    [[ "$output" != *"$v"* && "$output" != *"$plain"* ]]
  done
}

@test "caller-keys: a re-run keeps every key; --rotate replaces every key" {
  bash "${SCRIPT}" --context kind-osramp
  local before; before="$(value stun-sentinel) $(value fe-signalloom) $(value operator)"
  bash "${SCRIPT}" --context kind-osramp
  [ "$(value stun-sentinel) $(value fe-signalloom) $(value operator)" = "$before" ]
  run bash "${SCRIPT}" --context kind-osramp --rotate
  [ "$status" -eq 0 ]
  [ "$(value stun-sentinel)" != "${before%% *}" ]
  [ "$(value token)" = "$(value stun-sentinel)" ]
}

@test "caller-keys: a failed apply is exit 1 and says so" {
  printf '#!/usr/bin/env bash\ncase "$*" in *apply*) cat >/dev/null ;; esac\nexit 1\n' >"${BATS_TEST_TMPDIR}/bin/kubectl"
  run bash "${SCRIPT}" --context kind-osramp
  [ "$status" -eq 1 ]
  [[ "$output" == *"kubectl apply failed for context kind-osramp"* ]]
}
