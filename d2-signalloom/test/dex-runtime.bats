#!/usr/bin/env bats

setup() {
  root="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  dex_manifest="$root/d2-signalloom/infra/inf-signalloom/base/dex.yaml"
  workdir="$(mktemp -d)"
  container="signalloom-dex-auth-test-$$"
  port=""
  config="$workdir/config.yaml"
  discovery="$workdir/discovery.json"
}

start_dex() {
  awk '/^  config.yaml: \|/{capture=1; next} capture && /^---$/{exit} capture {sub(/^    /, ""); print}' "$dex_manifest" >"$config"
  run docker run --rm -d --name "$container" -p "127.0.0.1::5556" -v "$config:/etc/dex/config.yaml:ro" ghcr.io/dexidp/dex:v2.41.1 dex serve /etc/dex/config.yaml
  [ "$status" -eq 0 ]
  port="$(docker port "$container" 5556/tcp | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p')"
  [ -n "$port" ]

  for _ in {1..30}; do
    curl -fsS "http://127.0.0.1:${port}/dex/.well-known/openid-configuration" >"$discovery" && break
    sleep 1
  done
  test -s "$discovery"
}

teardown() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$workdir"
}

@test "Dex serves discovery and JWKS from its local issuer" {
  command -v docker >/dev/null
  docker info >/dev/null

  start_dex
  expected_issuer="$(awk '/^  config.yaml: \|/{c=1;next} c && /^---$/{exit} c && /issuer:/{sub(/.*issuer: */,"");print;exit}' "$dex_manifest")"
  python3 -c "import json, sys; d = json.load(sys.stdin); assert d['issuer'] == '$expected_issuer', f'issuer {d[\"issuer\"]} != $expected_issuer'; assert d['jwks_uri'].endswith('/dex/keys')" <"$discovery"

  run curl -fsS "http://127.0.0.1:${port}/dex/keys"
  [ "$status" -eq 0 ]
  python3 -c 'import json, sys; assert json.load(sys.stdin)["keys"]' <<<"$output"

}

@test "Dex issues a signed ID token for the deterministic demo user" {
  command -v docker >/dev/null
  docker info >/dev/null
  [ -n "${DEX_DEMO_PASSWORD:-}" ] || skip "set DEX_DEMO_PASSWORD to run the credential exchange"

  start_dex
  response="$workdir/token.json"
  # signalloom-dashboard is a public OIDC client (public: true in dex.yaml) — it
  # has no secret, so the token request uses client_id as a form parameter, not
  # HTTP Basic Auth. Using --user with a secret Dex doesn't expect causes a
  # connection reset.
  run curl -fsS \
    --data-urlencode 'grant_type=password' \
    --data-urlencode 'client_id=signalloom-dashboard' \
    --data-urlencode 'username=demo-user@signalloom.local' \
    --data-urlencode "password=$DEX_DEMO_PASSWORD" \
    --data-urlencode 'scope=openid profile email groups' \
    "http://127.0.0.1:${port}/dex/token"
  [ "$status" -eq 0 ]
  printf '%s' "$output" >"$response"

  python3 - "$response" "$discovery" "$port" <<'PY'
import base64
import json
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

token_response = json.loads(Path(sys.argv[1]).read_text())
discovery = json.loads(Path(sys.argv[2]).read_text())
assert token_response["access_token"]
token = token_response["id_token"]
header_raw, payload_raw, signature_raw = token.split(".")
decode = lambda value: base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
header = json.loads(decode(header_raw))
payload = json.loads(decode(payload_raw))
assert header["alg"] == "RS256"
assert payload["iss"] == discovery["issuer"]
assert payload["aud"] == "signalloom-dashboard"
assert payload["sub"] == "CglkZW1vLXVzZXISBWxvY2Fs"
assert payload["email"] == "demo-user@signalloom.local"
assert payload["name"] == "demo-user"
assert isinstance(payload["iat"], int) and isinstance(payload["exp"], int)
assert payload["exp"] > payload["iat"]

jwks = json.load(urllib.request.urlopen("http://127.0.0.1:%s/dex/keys" % sys.argv[3]))
jwk = next(key for key in jwks["keys"] if key["kid"] == header["kid"])
assert jwk["kty"] == "RSA" and jwk["alg"] == "RS256"

def length(value):
    return bytes([value]) if value < 128 else bytes([0x80 | ((value.bit_length() + 7) // 8)]) + value.to_bytes((value.bit_length() + 7) // 8, "big")

def tlv(tag, value):
    return bytes([tag]) + length(len(value)) + value

def integer(value):
    if value[0] & 0x80:
        value = b"\0" + value
    return tlv(0x02, value)

n = decode(jwk["n"])
e = decode(jwk["e"])
rsa_public_key = tlv(0x30, integer(n) + integer(e))
rsa_encryption_oid = bytes.fromhex("06092a864886f70d010101")
algorithm_identifier = tlv(0x30, rsa_encryption_oid + b"\x05\x00")
subject_public_key_info = tlv(0x30, algorithm_identifier + tlv(0x03, b"\0" + rsa_public_key))
pem = "-----BEGIN PUBLIC KEY-----\n" + base64.encodebytes(subject_public_key_info).decode() + "-----END PUBLIC KEY-----\n"
with tempfile.TemporaryDirectory() as directory:
    directory = Path(directory)
    (directory / "key.pem").write_text(pem)
    (directory / "signed").write_text(header_raw + "." + payload_raw)
    (directory / "signature").write_bytes(decode(signature_raw))
    subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(directory / "key.pem"), "-signature", str(directory / "signature"), str(directory / "signed")], check=True, capture_output=True)
PY
}
