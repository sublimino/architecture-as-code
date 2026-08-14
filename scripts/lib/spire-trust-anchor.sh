#!/usr/bin/env bash
# The trust anchor OpenBao uses to validate SPIRE-issued JWT-SVIDs.
#
# OpenBao's JWT auth is configured here with `jwt_validation_pubkeys` — a static
# copy of SPIRE's JWT-SVID signing keys, taken once at bring-up. SPIRE rotates
# those keys on its own CA schedule (ca_ttl, 24h by default), so the copy is a
# snapshot of something that moves. When SPIRE activates the next key, every
# SPIFFE->OpenBao login fails with
#
#   error validating token: error verifying token signature:
#   no known key successfully validated the token signature
#
# and stays failed until the copy is refreshed. Nothing else breaks: the SPIRE
# entries still carry their selectors, the roles are still bound to the right
# subject and audience, and the workload still fetches a valid SVID. That is why
# the outage reads as an identity-wiring problem when it is a key-material one —
# on 2026-08-14 it presented as two probes failing and a coincidentally young
# planner pod, and the pod had nothing to do with it.
#
# ONE derivation, read by both sides. `sync_*` writes what `assert_*` reads, and
# both normalise SPIRE's JWK and OpenBao's PEM through openssl to the same
# canonical DER so they cannot disagree about what "the same key" means. A
# second, independent derivation would drift the way the snapshot did.

# base64(DER SubjectPublicKeyInfo) for one P-256 JWK coordinate pair.
_spire_jwk_to_der_b64() {
  local x="$1" y="$2" der status coordinate value
  der="$(mktemp)"
  {
    # SubjectPublicKeyInfo header for an uncompressed P-256 public key.
    printf '\x30\x59\x30\x13\x06\x07\x2a\x86\x48\xce\x3d\x02\x01\x06\x08\x2a\x86\x48\xce\x3d\x03\x01\x07\x03\x42\x00\x04'
    for coordinate in "$x" "$y"; do
      value="${coordinate//-/+}"
      value="${value//_/\/}"
      case $((${#value} % 4)) in
        2) value="${value}==" ;;
        3) value="${value}=" ;;
      esac
      printf '%s' "$value" | base64 -d
    done
  } >"$der"
  # Round-tripping through openssl rather than emitting the bytes we just built
  # is deliberate: OpenBao returns PEM, and only a shared canonicaliser makes a
  # key derived from a JWK and the same key read back from a PEM comparable.
  openssl pkey -pubin -inform DER -in "$der" -outform DER 2>/dev/null | base64 -w0
  status=$?
  rm -f "$der"
  ((status == 0)) || return 1
  printf '\n'
}

_der_b64_to_pem() {
  printf '%s' "$1" | base64 -d | openssl pkey -pubin -inform DER -outform PEM
}

# Every key SPIRE is currently willing to sign JWT-SVIDs with, one per line.
# SPIRE publishes both the outgoing and the incoming key across a rotation, so
# this is a set, never a single value.
spire_jwt_svid_keys() {
  local namespace="$1" bundle jwk x y
  local -a jwks=()
  bundle="$(kubectl -n "$namespace" exec deployment/spire-server -- \
    /opt/spire/bin/spire-server bundle show -format spiffe)" || return 1
  mapfile -t jwks < <(jq -r '
    .keys[] | select(.use == "jwt-svid" and .kty == "EC" and .crv == "P-256")
    | [.x, .y] | @tsv' <<<"$bundle")
  ((${#jwks[@]} > 0)) || {
    printf 'SPIRE bundle contains no P-256 JWT-SVID validation key\n' >&2
    return 1
  }
  for jwk in "${jwks[@]}"; do
    IFS=$'\t' read -r x y <<<"$jwk"
    _spire_jwk_to_der_b64 "$x" "$y" || return 1
  done
}

# Every key OpenBao will currently accept a JWT-SVID signature from, one per
# line, in the same encoding as spire_jwt_svid_keys.
openbao_jwt_validation_keys() {
  local namespace="$1" token="$2" config encoded pem
  local -a encoded_pems=()
  config="$(kubectl -n "$namespace" exec deployment/openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$token" \
    bao read -format=json auth/jwt/config)" || return 1
  # @base64 per element: a PEM spans several lines, so a bare `[]` would split
  # one key across several array entries and compare nothing meaningful.
  mapfile -t encoded_pems < <(jq -r '(.data.jwt_validation_pubkeys // [])[] | @base64' <<<"$config")
  for encoded in ${encoded_pems[@]+"${encoded_pems[@]}"}; do
    pem="$(printf '%s' "$encoded" | base64 -d)"
    printf '%s' "$pem" | openssl pkey -pubin -outform DER 2>/dev/null | base64 -w0 || return 1
    printf '\n'
  done
}

# Point OpenBao at the keys SPIRE is signing with now.
sync_openbao_jwt_validation() {
  local namespace="$1" token="$2" key pem csv
  local -a keys=() pems=()
  mapfile -t keys < <(spire_jwt_svid_keys "$namespace")
  ((${#keys[@]} > 0)) || {
    printf 'refusing to write an empty JWT validation key set to OpenBao\n' >&2
    return 1
  }
  for key in "${keys[@]}"; do
    pem="$(_der_b64_to_pem "$key")" || return 1
    pems+=("$pem")
  done
  printf -v csv '%s,' "${pems[@]}"
  csv="${csv%,}"
  kubectl -n "$namespace" exec deployment/openbao -- env \
    BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$token" \
    bao write auth/jwt/config jwt_validation_pubkeys="$csv"
}

# The gate. Both sides are derived from the artefacts that actually decide —
# SPIRE's live bundle and OpenBao's live config — so neither can be satisfied by
# a hardcoded expectation that has quietly stopped being true.
#
# Binding assertions alone could not catch this: bound_subject, bound_audiences
# and the SPIRE selectors were all still exactly right while every login failed.
assert_openbao_accepts_spire_jwt_keys() {
  local namespace="$1" token="$2" key held found
  local -a spire_keys=() bao_keys=()
  mapfile -t spire_keys < <(spire_jwt_svid_keys "$namespace") || return 1
  mapfile -t bao_keys < <(openbao_jwt_validation_keys "$namespace" "$token") || return 1
  for key in ${spire_keys[@]+"${spire_keys[@]}"}; do
    [[ -n "$key" ]] || continue
    found=false
    for held in ${bao_keys[@]+"${bao_keys[@]}"}; do
      [[ "$held" == "$key" ]] && { found=true; break; }
    done
    [[ "$found" == true ]] && continue
    printf 'OpenBao cannot validate the JWT-SVIDs SPIRE is signing now: SPIRE publishes %d JWT-SVID key(s), OpenBao holds %d, and at least one SPIRE key is absent from auth/jwt/config\n' \
      "${#spire_keys[@]}" "${#bao_keys[@]}" >&2
    printf 'SPIRE rotated its JWT signing key and OpenBao still holds the pre-rotation snapshot; every SPIFFE login fails with "no known key successfully validated the token signature" until the identity plane is re-synced\n' >&2
    return 1
  done
}
