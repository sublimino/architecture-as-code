#!/usr/bin/env bats
#
# @id      fleet-operator-keys
# @target  scripts/fleet-operator-keys.sh
# @doc     docs/EAP/enforcement.md
#
# The operator-key bootstrap against a fake kubectl that records argv and the
# applied manifest, and a fake resume-token whose keygen writes a fresh
# keypair per call. No cluster, no go.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/fleet-operator-keys.sh"
  STATE="${BATS_TEST_TMPDIR}/state"
  KEYS="${BATS_TEST_TMPDIR}/keys"
  OPS="${KEYS}/fleet-operators"
  mkdir -p "${STATE}" "${BATS_TEST_TMPDIR}/bin"
  cat >"${BATS_TEST_TMPDIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_STATE}/argv"
case "$*" in
  *" apply -f -"*) cat >"${FAKE_STATE}/applied" ;;
esac
EOF
  # keygen --operator ID --out DIR --name N: a private key that differs on
  # every call (a counter), its public half, and the public entry on stdout.
  cat >"${BATS_TEST_TMPDIR}/bin/resume-token" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_STATE}/rt-argv"
[ "$1" = "keygen" ] || { echo "fake resume-token: only keygen" >&2; exit 2; }
shift
op=""; out=""; name=""
while [ $# -gt 0 ]; do
  case "$1" in
    --operator) op="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    *) echo "fake resume-token: bad arg $1" >&2; exit 2 ;;
  esac
done
[ -n "$op" ] && [ -n "$out" ] && [ -n "$name" ] || exit 2
[ "${FAKE_KEYGEN_FAIL:-0}" = "0" ] || exit 1
n=0; [ -f "${FAKE_STATE}/counter" ] && n="$(cat "${FAKE_STATE}/counter")"
n=$((n + 1)); echo "$n" >"${FAKE_STATE}/counter"
priv="$(printf 'private%02d%s' "$n" "$name" | sha256sum | cut -c1-64)"
pub="$(printf 'public%02d%s' "$n" "$name" | sha256sum | cut -c1-64)"
printf '%s\n' "$priv" >"${out}/${name}.key"
chmod 600 "${out}/${name}.key"
printf '%s\n' "$pub" >"${out}/${name}.pub"
printf '{"operator_id":"%s","public_key":"%s"}\n' "$op" "$pub"
EOF
  chmod +x "${BATS_TEST_TMPDIR}/bin/kubectl" "${BATS_TEST_TMPDIR}/bin/resume-token"
  export SLDC_KUBECTL="${BATS_TEST_TMPDIR}/bin/kubectl" FAKE_STATE="${STATE}" KUBECONFIG=/dev/null
  export RESUME_TOKEN_BIN="${BATS_TEST_TMPDIR}/bin/resume-token" KEYS_DIR="${KEYS}"
}

keygen_calls() { [ -f "${STATE}/rt-argv" ] && grep -c '^keygen ' "${STATE}/rt-argv" || echo 0; }

@test "operator-keys: --context is required, exit 2, nothing minted or applied" {
  run bash "${SCRIPT}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--context is required"* ]]
  [ ! -e "${STATE}/applied" ]
  [ "$(keygen_calls)" -eq 0 ]
}

@test "operator-keys: creates alice and bob under keys_dir and applies the public ConfigMap" {
  run bash "${SCRIPT}" --context kind-osramp
  [ "$status" -eq 0 ]
  [ "$(keygen_calls)" -eq 2 ]
  local n
  for n in alice bob; do
    [ -s "${OPS}/${n}.key" ] && [ -s "${OPS}/${n}.pub" ] && [ -s "${OPS}/${n}.json" ]
    [ "$(stat -c '%a' "${OPS}/${n}.key")" = "600" ]
  done
  [ "$(stat -c '%a' "${OPS}")" = "700" ]
  # The manifest: name, namespace, key, both SPIFFE IDs, both public keys.
  grep -q '^  name: fleet-manager-operator-keys$' "${STATE}/applied"
  grep -q '^  namespace: fe-signalloom$' "${STATE}/applied"
  grep -q '^  keys.json: |$' "${STATE}/applied"
  grep -qF 'spiffe://signalloom.demo/operator/alice' "${STATE}/applied"
  grep -qF 'spiffe://signalloom.demo/operator/bob' "${STATE}/applied"
  grep -qF "$(cat "${OPS}/alice.pub")" "${STATE}/applied"
  grep -qF "$(cat "${OPS}/bob.pub")" "${STATE}/applied"
  # keys.json on disk is the array the ConfigMap carries.
  [ "$(head -c1 "${OPS}/keys.json")" = "[" ]
  [[ "$output" == *"ConfigMap fe-signalloom/fleet-manager-operator-keys key keys.json"* ]]
  [[ "$output" == *"created: alice bob"* ]]
}

@test "operator-keys: keygen is handed a directory and a name, never key bytes" {
  run bash "${SCRIPT}" --context kind-osramp
  [ "$status" -eq 0 ]
  grep -q -- "--operator spiffe://signalloom.demo/operator/alice --out ${OPS} --name alice" "${STATE}/rt-argv"
  grep -q -- "--operator spiffe://signalloom.demo/operator/bob --out ${OPS} --name bob" "${STATE}/rt-argv"
}

@test "operator-keys: a re-run keeps both keypairs and calls keygen zero more times" {
  bash "${SCRIPT}" --context kind-osramp
  local a b
  a="$(cat "${OPS}/alice.key")"; b="$(cat "${OPS}/bob.key")"
  rm -f "${STATE}/applied"
  run bash "${SCRIPT}" --context kind-osramp
  [ "$status" -eq 0 ]
  [ "$(keygen_calls)" -eq 2 ]
  [ "$(cat "${OPS}/alice.key")" = "$a" ]
  [ "$(cat "${OPS}/bob.key")" = "$b" ]
  # The ConfigMap is still converged on every run.
  grep -qF "$(cat "${OPS}/alice.pub")" "${STATE}/applied"
  [[ "$output" == *"kept: alice bob"* ]]
  [[ "$output" != *"created:"* ]]
}

@test "operator-keys: --rotate replaces every keypair and the ConfigMap carries only the new public keys" {
  bash "${SCRIPT}" --context kind-osramp
  local a_old b_old a_pub_old
  a_old="$(cat "${OPS}/alice.key")"; b_old="$(cat "${OPS}/bob.key")"; a_pub_old="$(cat "${OPS}/alice.pub")"
  run bash "${SCRIPT}" --context kind-osramp --rotate
  [ "$status" -eq 0 ]
  [ "$(keygen_calls)" -eq 4 ]
  [ "$(cat "${OPS}/alice.key")" != "$a_old" ]
  [ "$(cat "${OPS}/bob.key")" != "$b_old" ]
  [ "$(stat -c '%a' "${OPS}/alice.key")" = "600" ]
  grep -qF "$(cat "${OPS}/alice.pub")" "${STATE}/applied"
  ! grep -qF "$a_pub_old" "${STATE}/applied"
  [[ "$output" == *"rotated"* ]]
  [[ "$output" == *"rollout restart deploy/fleet-manager"* ]]
}

@test "operator-keys: no private key reaches kubectl argv, the ConfigMap, or the script's output" {
  run bash "${SCRIPT}" --context kind-osramp
  [ "$status" -eq 0 ]
  local n priv
  for n in alice bob; do
    priv="$(cat "${OPS}/${n}.key")"
    [ -n "$priv" ]
    if grep -qF -e "$priv" "${STATE}/argv"; then echo "private key in kubectl argv"; return 1; fi
    if grep -qF -e "$priv" "${STATE}/applied"; then echo "private key in the ConfigMap"; return 1; fi
    if grep -qF -e "$priv" "${STATE}/rt-argv"; then echo "private key in keygen argv"; return 1; fi
    [[ "$output" != *"$priv"* ]]
  done
  # The manifest carries nothing but the public entries: no .key path either.
  ! grep -q '\.key' "${STATE}/applied"
}

@test "operator-keys: --operators takes bare names under the default prefix and full spiffe IDs as given" {
  run bash "${SCRIPT}" --context kind-osramp --operators carol,spiffe://pilot.example/op/dave
  [ "$status" -eq 0 ]
  [ -s "${OPS}/carol.key" ] && [ -s "${OPS}/dave.key" ]
  [ ! -e "${OPS}/alice.key" ]
  grep -qF '"operator_id":"spiffe://signalloom.demo/operator/carol"' "${STATE}/applied"
  grep -qF '"operator_id":"spiffe://pilot.example/op/dave"' "${STATE}/applied"
}

@test "operator-keys: a failed keygen is exit 1 and nothing is applied" {
  FAKE_KEYGEN_FAIL=1 run bash "${SCRIPT}" --context kind-osramp
  [ "$status" -eq 1 ]
  [[ "$output" == *"keygen failed"* ]]
  [ ! -e "${STATE}/applied" ]
}

@test "operator-keys: a failed apply is exit 1 and says so" {
  printf '#!/usr/bin/env bash\ncase "$*" in *apply*) cat >/dev/null ;; esac\nexit 1\n' >"${BATS_TEST_TMPDIR}/bin/kubectl"
  run bash "${SCRIPT}" --context kind-osramp
  [ "$status" -eq 1 ]
  [[ "$output" == *"kubectl apply failed for context kind-osramp"* ]]
}

@test "operator-keys: an unusable RESUME_TOKEN_BIN is exit 1, not a fall-through to go" {
  RESUME_TOKEN_BIN="${BATS_TEST_TMPDIR}/nope" run bash "${SCRIPT}" --context kind-osramp
  [ "$status" -eq 1 ]
  [[ "$output" == *"not executable"* ]]
  [ ! -e "${STATE}/applied" ]
}
