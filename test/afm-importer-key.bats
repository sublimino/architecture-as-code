#!/usr/bin/env bats
#
# @id      afm-importer-key
# @target  scripts/afm-importer-key.sh
#
# The script reads a key from stdin whenever stdin is not a terminal, so
# every case that means "no key" runs it with </dev/null; inheriting bats'
# stdin hung under a backgrounded runner (test/afm-importer-key-stdin.bats).
# @doc     docs/Proposal — Signal Loom Spireless Token-Based Agent Identity Migration (2026-Q4).md
#
# The AFM importer key bootstrap against a fake kubectl that records argv and
# the applied manifests. No cluster.

# `run !` (used by the --cluster-id cases) needs 1.5.0 or later.
bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/afm-importer-key.sh"
  STATE="${BATS_TEST_TMPDIR}/state"
  mkdir -p "${STATE}" "${BATS_TEST_TMPDIR}/bin"
  cat >"${BATS_TEST_TMPDIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_STATE}/argv"
case "$*" in
  *"cluster-info"*)
    if [ "${FAKE_KUBECTL_FAIL_CLUSTER_INFO:-0}" = "1" ]; then
      echo "Unable to connect to the server" >&2
      exit 1
    fi
    echo "Kubernetes control plane is running" ;;
  *" apply -f -"*)
    cat >"${FAKE_STATE}/applied"
    cp "${FAKE_STATE}/applied" "${FAKE_STATE}/stored" ;;
  *"get secret fe-signalloom-afm-importer-key"*)
    [ -f "${FAKE_STATE}/stored" ] || exit 1
    k="$(sed -n 's/.*{\.data\.\([a-z0-9._-]*\)}.*/\1/p' <<<"$*")"
    awk -v k="  ${k}:" 'index($0,k)==1 {print $2; exit}' "${FAKE_STATE}/stored" | tr -d '\n' ;;
esac
EOF
  chmod +x "${BATS_TEST_TMPDIR}/bin/kubectl"
  export SLDC_KUBECTL="${BATS_TEST_TMPDIR}/bin/kubectl" FAKE_STATE="${STATE}" KUBECONFIG=/dev/null
}

# value <secret-key>: a data value from the last applied manifest.
value() { awk -v k="  $1:" 'index($0,k)==1 {print $2; exit}' "${STATE}/applied"; }

@test "afm-importer-key: --context is required, exit 2, nothing applied" {
  run bash "${SCRIPT}" </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"--context is required"* ]]
  [ ! -e "${STATE}/applied" ]
}

@test "afm-importer-key: fresh run creates verifier and consumer secrets with >=32 byte key and valid expiry" {
  run bash "${SCRIPT}" --context kind-osramp </dev/null
  [ "$status" -eq 0 ]
  local key exp tok
  key="$(value afm-importer)"
  exp="$(value afm-importer.expires)"
  tok="$(value token)"

  [ -n "$key" ]
  [ -n "$exp" ]
  [ -n "$tok" ]
  # Consumer token matches verifier key
  [ "$tok" = "$key" ]

  # Check verifier secret namespace and consumer secret namespace
  grep -q 'name: fe-signalloom-afm-importer-key' "${STATE}/applied"
  grep -q 'namespace: fe-signalloom' "${STATE}/applied"
  grep -q 'name: signalloom-rbac-exporter-afm-key' "${STATE}/applied"
  grep -q 'namespace: fe-signalloom-agents' "${STATE}/applied"

  # Base64 decoded key must be >= 32 bytes
  local decoded_len
  decoded_len="$(printf '%s' "$key" | base64 -d | wc -c)"
  [ "$decoded_len" -ge 32 ]

  # Expiry decoded must be ISO 8601 / RFC 3339 timestamp
  local decoded_exp
  decoded_exp="$(printf '%s' "$exp" | base64 -d)"
  [[ "$decoded_exp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]]
}

@test "afm-importer-key: accepts key from stdin" {
  local custom_key="my_super_secret_custom_token_1234567890_32bytes"
  printf '%s' "${custom_key}" | bash "${SCRIPT}" --context kind-osramp
  local key tok
  key="$(value afm-importer)"
  tok="$(value token)"
  [ "$(printf '%s' "$key" | base64 -d)" = "${custom_key}" ]
  [ "$tok" = "$key" ]
}

@test "afm-importer-key: re-run with no change is a no-op (zero apply calls)" {
  bash "${SCRIPT}" --context kind-osramp </dev/null
  [ -f "${STATE}/applied" ]
  rm -f "${STATE}/applied"

  # Re-run: should detect existing secret and NOT re-apply
  run bash "${SCRIPT}" --context kind-osramp </dev/null
  [ "$status" -eq 0 ]
  [ ! -f "${STATE}/applied" ]
}

@test "afm-importer-key: --rotate generates a new key and updates both secrets" {
  bash "${SCRIPT}" --context kind-osramp </dev/null
  local key1
  key1="$(value afm-importer)"

  run bash "${SCRIPT}" --context kind-osramp --rotate </dev/null
  [ "$status" -eq 0 ]
  local key2
  key2="$(value afm-importer)"

  [ "$key1" != "$key2" ]
  [ "$(value token)" = "$key2" ]
}

@test "afm-importer-key: key value never appears in argv, stdout, or stderr" {
  local custom_key="my_secret_token_never_in_argv_1234567890_bytes"
  run bash -c "printf '%s' '${custom_key}' | bash '${SCRIPT}' --context kind-osramp"
  [ "$status" -eq 0 ]

  # Key value must not be in recorded argv
  if grep -qF "${custom_key}" "${STATE}/argv"; then
    echo "Key found in argv log!"
    return 1
  fi

  # Key value must not be in output
  [[ "$output" != *"${custom_key}"* ]]
}

@test "afm-importer-key: unreachable cluster context fails before writing" {
  export FAKE_KUBECTL_FAIL_CLUSTER_INFO=1
  run bash "${SCRIPT}" --context unreachable-ctx </dev/null
  [ "$status" -ne 0 ]
  [ ! -f "${STATE}/applied" ]
}

# --- --cluster-id -------------------------------------------------------------
#
# The portal refuses an import whose key is bound to another cluster
# (AFM_IMPORT_KEYS). --cluster-id records that binding and, for anything other
# than the default, gives the key its own issuer Secret.

@test "afm-importer-key: the default run records cluster kind-osramp on the issuer Secret" {
  run bash "${SCRIPT}" --context kind-osramp </dev/null
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$(value afm-importer.cluster)" | base64 -d)" = "kind-osramp" ]
  # The default is the committed AFM_IMPORT_KEYS row, so the Secret name does
  # not change and nothing that reads it has to learn a new one.
  grep -q '^  name: fe-signalloom-afm-importer-key$' "${STATE}/applied"
}

@test "afm-importer-key: --cluster-id binds the key and gives it its own issuer Secret" {
  run bash "${SCRIPT}" --context kind-signalloom-hub --cluster-id kusari-prod </dev/null
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$(value afm-importer.cluster)" | base64 -d)" = "kusari-prod" ]
  # Its own issuer Secret: one name for two clusters means the second mint
  # silently replaces the first cluster's key.
  grep -q '^  name: fe-signalloom-afm-importer-key-kusari-prod$' "${STATE}/applied"
  run ! grep -q '^  name: fe-signalloom-afm-importer-key$' "${STATE}/applied"
  # The consumer Secret keeps its single name: it is read by the exporter
  # CronJob on whichever cluster that CronJob runs, and there is one per cluster.
  grep -q '^  name: signalloom-rbac-exporter-afm-key$' "${STATE}/applied"
}

@test "afm-importer-key: a non-default cluster id prints the AFM_IMPORT_KEYS row to commit" {
  # The row is a manifest, so it is printed and committed, never patched.
  run bash "${SCRIPT}" --context kind-signalloom-hub --cluster-id kusari-prod </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *'"cluster":"kusari-prod"'* ]]
  [[ "$output" == *'AFM_IMPORT_KEYS'* ]]
  [[ "$output" == *'AFM_CLUSTER_ID=kusari-prod'* ]]
}

@test "afm-importer-key: the existence check reads the cluster's OWN issuer Secret" {
  # This is what keeps two clusters' keys apart. The idempotence check must
  # query fe-signalloom-afm-importer-key-<id>, so a key already minted for
  # kind-osramp does not read as "kusari-prod already has one".
  #
  # Asserted on argv rather than on the two values, because the fake kubectl
  # matches a Secret name by prefix and cannot tell the two names apart.
  run bash "${SCRIPT}" --context kind-osramp --cluster-id kusari-prod </dev/null
  [ "$status" -eq 0 ]
  grep -q 'get secret fe-signalloom-afm-importer-key-kusari-prod' "${STATE}/argv"
}

@test "afm-importer-key: --cluster-id with no value, or not a DNS label, is exit 2" {
  run bash "${SCRIPT}" --context kind-osramp --cluster-id </dev/null
  [ "$status" -eq 2 ]
  # Rejected before any key is generated, not by the API server afterwards.
  run bash "${SCRIPT}" --context kind-osramp --cluster-id 'Kusari_Prod' </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"DNS label"* ]]
  [ ! -e "${STATE}/applied" ]
}

@test "afm-importer-key: failed apply exits 1" {
  printf '#!/usr/bin/env bash\ncase "$*" in *cluster-info*) echo "ok"; exit 0;; *apply*) cat >/dev/null; exit 1;; esac\nexit 0\n' >"${BATS_TEST_TMPDIR}/bin/kubectl"
  run bash "${SCRIPT}" --context kind-osramp </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"kubectl apply failed"* ]]
}
