#!/usr/bin/env bats
#
# @id      dex-subject-tenants
# @target  d2-signalloom/apps/fe-signalloom/base/deployment.yaml
# @doc     docs/eap/SLDC-P5-1-E2E-CONTAINMENT.md
#
# fe-signalloom resolves a caller's tenant from API_SUBJECT_TENANTS, keyed on the
# JWT `sub`. Dex does not put the userID in `sub`: it puts a base64url protobuf of
# (userID, connector id). A Dex user whose ENCODED subject is not in the map
# logs in and is then refused every API call with tenant_forbidden, and a tenant
# no subject maps to cannot own anything a product path writes. Step 2 of the
# Kusari pilot failed for exactly that reason: no subject mapped to tenant kusari.
#
# The encoding is computed here, from the Dex config, independently of the map.
# Offline: yq, jq, base64, and bun for the bcrypt check.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  DEX="${REPO_ROOT}/d2-signalloom/infra/inf-signalloom/base/dex.yaml"
  API="${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/base/deployment.yaml"
  CONFIG_PY="${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/src/config.py"
  TENANTS="$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[].env[]? | select(.name == "API_SUBJECT_TENANTS") | .value' "${API}")"
  USERS="$(yq -r 'select(.kind == "Secret") | .stringData."config.yaml"' "${DEX}" | yq -r '.staticPasswords[].userID')"
}

# dex_sub USERID — Dex's `sub` for a password-DB user: base64url (no padding) of
# protobuf {1: userID, 2: "local"}. Valid for userIDs under 128 bytes.
dex_sub() {
  local id="$1"
  printf "\\x0a\\x$(printf '%02x' "${#id}")%s\\x12\\x05local" "$id" | base64 -w0 | tr '+/' '-_' | tr -d '='
}

@test "dex-subjects: the encoder reproduces the known demo-user subject" {
  # The mechanism check: if the encoder is wrong, every test below compares
  # against garbage. CglkZW1vLXVzZXISBWxvY2Fs was captured from a live token.
  [ "$(dex_sub demo-user)" = "CglkZW1vLXVzZXISBWxvY2Fs" ]
}

@test "dex-subjects: every Dex static user's encoded subject has a tenant" {
  local n=0 missing="" u
  while read -r u; do
    [ -n "$u" ] || continue
    n=$((n + 1))
    jq -e --arg k "$(dex_sub "$u")" 'has($k)' <<<"${TENANTS}" >/dev/null || missing="${missing} ${u}"
  done <<<"${USERS}"
  [ "$n" -ge 3 ]
  [ -z "$missing" ] || { echo "Dex users with no tenant for their encoded sub:${missing}"; return 1; }
}

@test "dex-subjects: kusari-operator maps to exactly tenant kusari, encoded and raw" {
  grep -qx kusari-operator <<<"${USERS}"
  run jq -r --arg k "$(dex_sub kusari-operator)" '.[$k] + "|" + .["kusari-operator"]' <<<"${TENANTS}"
  [ "$output" = "kusari|kusari" ]
}

@test "dex-subjects: no subject maps to a tenant that is not plain ASCII" {
  # A homoglyph (Cyrillic і in kusarі) is a different tenant that renders the
  # same. Tenant ids are lowercase ASCII labels; anything else is a forgery.
  run jq -r '.[]' <<<"${TENANTS}"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  while read -r t; do
    [[ "$t" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { echo "non-label tenant: $t"; return 1; }
  done <<<"$output"
}

@test "dex-subjects: kusari-operator is on neither superadmin allowlist" {
  run grep -E '^\s*api_superadmin_(emails|subjects):' "${CONFIG_PY}"
  [ "$status" -eq 0 ]
  [ "$(grep -c . <<<"$output")" -eq 2 ]
  [[ "$output" != *kusari* ]]
}

@test "dex-subjects: kusari-operator's hash verifies against its documented password" {
  local hash
  hash="$(yq -r 'select(.kind == "Secret") | .stringData."config.yaml"' "${DEX}" \
    | yq -r '.staticPasswords[] | select(.userID == "kusari-operator") | .hash')"
  [[ "$hash" == '$2b$'* ]]
  run bun -e 'const [p, h] = (await Bun.stdin.text()).split("\n"); process.exit(await Bun.password.verify(p, h) ? 0 : 1)' \
    <<<"kusari-operator"$'\n'"${hash}"
  [ "$status" -eq 0 ]
}
