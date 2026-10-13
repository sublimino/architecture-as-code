#!/usr/bin/env bats
# ed25519-keygen interop: prove the openssl replacement in BOTH directions.
#
# Decision 10 is reversed: openssl is not shipped with the appliance, and the
# two Ed25519 keypairs the Makefile mints come from cmd/ed25519-keygen instead.
# That is only safe if the encodings are interchangeable, so this suite proves
# interchange rather than asserting it.
#
#   forward   openssl reads a key the helper wrote, and the public half openssl
#             derives from it is byte-identical to the one the helper wrote
#   reverse   the helper reads a key openssl wrote and derives the same key id
#             openssl's own DER-then-sha256 pipeline derives
#   shape     the ASN.1 structure and the PEM/DER sizes match the measured
#             OpenSSL output on both halves
#
# Key BYTES are never compared between the two tools: the keys are random, so
# equal bytes would mean a broken RNG, not compatibility. Only structure and
# round-tripping are compared.
#
# openssl is a HARD precondition here and its absence fails rather than skips.
# A skip in this suite would report green for exactly the claim the suite
# exists to test. The appliance does not need openssl; this proof does.

setup() {
  repo="$BATS_TEST_DIRNAME/.."
  tmp="$(mktemp -d)"
  export PATH="/home/linuxbrew/.linuxbrew/bin:/usr/bin:$PATH"
  export GOPATH="/tmp/gopath"
  export GOCACHE="${GOCACHE:-/tmp/gocache}"
  export GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}"
  export GONOSUMDB="*"
  export CGO_ENABLED=0
  export LC_ALL=C
  export LANG=C

  if ! command -v openssl >/dev/null 2>&1; then
    echo "HARNESS ERROR: openssl is required to prove interop with openssl." >&2
    echo "It is not an appliance dependency; it is this proof's instrument." >&2
    return 1
  fi

  fm="$(cd "$repo/d2-signalloom/apps/fleet-manager" && pwd)"
}

teardown() {
  rm -rf "$tmp"
}

# keygen ARGS... — the helper, invoked exactly as the Makefile invokes it.
keygen() {
  go -C "$fm" run ./cmd/ed25519-keygen "$@"
}

@test "interop: helper output has the PEM and DER sizes openssl produces" {
  run keygen generate --key "$tmp/mine.pem" --pub "$tmp/mine-pub.pem"
  [ "$status" -eq 0 ]

  openssl genpkey -algorithm ed25519 -out "$tmp/theirs.pem" 2>/dev/null
  openssl pkey -in "$tmp/theirs.pem" -pubout -out "$tmp/theirs-pub.pem" 2>/dev/null

  # Sizes are a property of the encoding, not of the key, so equality here is
  # meaningful where equality of key bytes would not be.
  mine_priv=$(wc -c < "$tmp/mine.pem")
  theirs_priv=$(wc -c < "$tmp/theirs.pem")
  mine_pub=$(wc -c < "$tmp/mine-pub.pem")
  theirs_pub=$(wc -c < "$tmp/theirs-pub.pem")

  [ "$mine_priv" -eq "$theirs_priv" ]
  [ "$mine_pub" -eq "$theirs_pub" ]
  # Measured against OpenSSL 3.6.2.
  [ "$mine_priv" -eq 119 ]
  [ "$mine_pub" -eq 113 ]

  mine_der=$(openssl pkey -in "$tmp/mine.pem" -outform DER | wc -c)
  theirs_der=$(openssl pkey -in "$tmp/theirs.pem" -outform DER | wc -c)
  [ "$mine_der" -eq "$theirs_der" ]
  # 48 bytes of DER: a two-byte SEQUENCE header over 46 bytes of content. The
  # 46 that asn1parse prints is the SEQUENCE length, NOT the DER length.
  [ "$mine_der" -eq 48 ]
}

@test "interop: ASN.1 structure of the helper's private key matches openssl's" {
  run keygen generate --key "$tmp/mine.pem" --pub "$tmp/mine-pub.pem"
  [ "$status" -eq 0 ]
  openssl genpkey -algorithm ed25519 -out "$tmp/theirs.pem" 2>/dev/null

  # Reduce each parse to its shape: depth, header length, content length, type
  # and the ASN.1 tag name, with the random seed bytes dropped. Two keys of the
  # same structure reduce to the same text; the seeds differ and are excluded.
  shape() {
    openssl asn1parse -in "$1" \
      | sed -E 's/^ *[0-9]+:/:/; s/\[HEX DUMP\]:[0-9A-F]+/[HEX]/' \
      | sed -E 's/ +$//'
  }

  shape "$tmp/mine.pem" > "$tmp/mine.shape"
  shape "$tmp/theirs.pem" > "$tmp/theirs.shape"
  run diff -u "$tmp/theirs.shape" "$tmp/mine.shape"
  if [ "$status" -ne 0 ]; then
    echo "ASN.1 shape differs from openssl's:" >&2
    cat "$tmp/mine.shape" >&2
    false
  fi

  # And the shape is the documented one, not merely self-consistent.
  run grep -c 'OBJECT *:ED25519' "$tmp/mine.shape"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
  run grep -c 'OCTET STRING *\[HEX\]' "$tmp/mine.shape"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
  # The seed is wrapped in its own OCTET STRING: 0420 is the inner DER header
  # for a 32-byte octet string, so the outer content is 34 bytes.
  run grep -c 'l= *34 prim: OCTET STRING' "$tmp/mine.shape"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "interop forward: openssl reads the helper's key and derives the same public half" {
  run keygen generate --key "$tmp/mine.pem" --pub "$tmp/mine-pub.pem"
  [ "$status" -eq 0 ]

  # openssl must be able to read a key this tool wrote at all.
  run openssl pkey -in "$tmp/mine.pem" -pubout -out "$tmp/openssl-derived-pub.pem"
  [ "$status" -eq 0 ]

  # The public half openssl derives must be byte-identical to the one the
  # helper wrote. These are the SAME key, so byte equality is the right test
  # here -- it is only across two independently generated keys that it is not.
  run diff -u "$tmp/mine-pub.pem" "$tmp/openssl-derived-pub.pem"
  [ "$status" -eq 0 ]

  # The SPKI base64 prefix openssl emits for Ed25519.
  run grep -c '^MCowBQYDK2VwAyEA' "$tmp/mine-pub.pem"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "interop reverse: the helper reads an openssl key and agrees on the key id" {
  openssl genpkey -algorithm ed25519 -out "$tmp/theirs.pem" 2>/dev/null
  openssl pkey -in "$tmp/theirs.pem" -pubout -out "$tmp/theirs-pub.pem" 2>/dev/null

  openssl_id="$(openssl pkey -pubin -in "$tmp/theirs-pub.pem" -outform DER \
    | openssl dgst -sha256 -r | cut -d' ' -f1)"
  [ -n "$openssl_id" ]

  run keygen key-id --pub "$tmp/theirs-pub.pem"
  [ "$status" -eq 0 ]
  [ "$output" = "$openssl_id" ]

  # And the other way round on the helper's own key, so neither tool is
  # merely echoing the other's convention.
  run keygen generate --key "$tmp/mine.pem" --pub "$tmp/mine-pub.pem"
  [ "$status" -eq 0 ]
  mine_openssl_id="$(openssl pkey -pubin -in "$tmp/mine-pub.pem" -outform DER \
    | openssl dgst -sha256 -r | cut -d' ' -f1)"
  run keygen key-id --pub "$tmp/mine-pub.pem"
  [ "$status" -eq 0 ]
  [ "$output" = "$mine_openssl_id" ]

  # Positive control for the two assertions above: distinct keys must yield
  # DISTINCT ids, otherwise agreement would be satisfied by a constant.
  [ "$openssl_id" != "$mine_openssl_id" ]
}

@test "interop: a signature made with the helper's key verifies under openssl" {
  run keygen generate --key "$tmp/mine.pem" --pub "$tmp/mine-pub.pem"
  [ "$status" -eq 0 ]

  printf 'segment attestation payload' > "$tmp/msg"
  run openssl pkeyutl -sign -inkey "$tmp/mine.pem" -rawin \
    -in "$tmp/msg" -out "$tmp/msg.sig"
  [ "$status" -eq 0 ]
  run openssl pkeyutl -verify -pubin -inkey "$tmp/mine-pub.pem" -rawin \
    -in "$tmp/msg" -sigfile "$tmp/msg.sig"
  [ "$status" -eq 0 ]

  # Negative control: the same signature over mutated bytes must NOT verify,
  # so the success above is evidence of verification and not of openssl
  # accepting anything handed to it.
  printf 'segment attestation payloaX' > "$tmp/msg.bad"
  run openssl pkeyutl -verify -pubin -inkey "$tmp/mine-pub.pem" -rawin \
    -in "$tmp/msg.bad" -sigfile "$tmp/msg.sig"
  [ "$status" -ne 0 ]
}

# The consumers of witness.pem are real crypto, not fixtures: signal-ingest
# loads it via x509.ParsePKCS8PrivateKey to sign segment attestations, and the
# Python audit_anchor verifier checks those signatures against witness-pub.pem
# and the key id pinned in segment-signing-policy.json. A key the helper mints
# has to survive that whole chain, which is the acceptance test that matters --
# everything above it is about encodings.
#
# This drives `make signing-keys` rather than the helper directly, so the
# Makefile rewiring is under test too. KEYS_DIR is a throwaway inside $tmp: the
# shared .keys/ holds the cosign key the running cluster trusts and every mint
# clause is `if [ ! -f ]`, so pointing at it would either do nothing or
# invalidate live trust.
@test "consumer: a make signing-keys witness key signs and verifies through the real path" {
  keys="$tmp/keys"
  mkdir -p "$keys"
  run make -C "$repo" signing-keys KEYS_DIR="$keys"
  [ "$status" -eq 0 ]
  [ -f "$keys/witness.pem" ]
  [ -f "$keys/witness-pub.pem" ]

  expected_key_id="$(jq -er '.expected_key_ids[0]' "$keys/segment-signing-policy.json")"
  [ -n "$expected_key_id" ]

  proof="$tmp/proof"
  mkdir -p "$proof/store" "$proof/evidence" "$proof/protected"
  journal="$proof/evidence/segments.jsonl"

  # 1. signal-ingest signs a real Parquet segment with the minted private key.
  run env \
    SIGNAL_SEGMENT_PROOF_DIR="$proof" \
    SIGNAL_SEGMENT_STORE_DIR="$proof/store" \
    SIGNAL_SEGMENT_EVIDENCE_DIR="$proof/evidence" \
    SIGNAL_SEGMENT_HIGHWATER="$proof/protected/highwater.json" \
    SIGNAL_SEGMENT_SIGNING_KEY="$keys/witness.pem" \
    SIGNAL_SEGMENT_PUBLIC_KEY="$keys/witness-pub.pem" \
    SIGNAL_SEGMENT_EXPECTED_KEY_ID="$expected_key_id" \
    go -C "$repo/d2-signalloom/apps/signal-ingest" test -tags=frostdb ./store \
      -run '^TestGoEvidenceAcceptedThenMutationRejectedByPythonVerifier$' -count=1
  [ "$status" -eq 0 ]
  [ -s "$journal" ]

  # 2. The independent verifier accepts those signatures under the minted
  #    public key and the key id derived from it.
  run env AUDIT_ANCHOR_DIR="$proof/evidence/checkpoints" \
    PYTHONPATH="$repo/d2-signalloom/apps/fe-signalloom/src" \
    python3 -m audit_anchor \
      --public-key "$keys/witness-pub.pem" \
      --expected-key-id "$expected_key_id" \
      --source segments \
      --segment-journal "$journal" \
      --segment-root "$proof/store" \
      --protected-high-water "$proof/protected/highwater.json" \
      verify --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status": "intact"'* ]]
}

@test "consumer: an unrelated minted key is rejected by the same verifier" {
  # Positive control for the test above. Acceptance there only means something
  # if the verifier can also REJECT, and if it rejects for the key rather than
  # for the evidence. Same evidence, different public key.
  keys="$tmp/keys"
  mkdir -p "$keys"
  run make -C "$repo" signing-keys KEYS_DIR="$keys"
  [ "$status" -eq 0 ]
  expected_key_id="$(jq -er '.expected_key_ids[0]' "$keys/segment-signing-policy.json")"

  proof="$tmp/proof"
  mkdir -p "$proof/store" "$proof/evidence" "$proof/protected"
  journal="$proof/evidence/segments.jsonl"
  run env \
    SIGNAL_SEGMENT_PROOF_DIR="$proof" \
    SIGNAL_SEGMENT_STORE_DIR="$proof/store" \
    SIGNAL_SEGMENT_EVIDENCE_DIR="$proof/evidence" \
    SIGNAL_SEGMENT_HIGHWATER="$proof/protected/highwater.json" \
    SIGNAL_SEGMENT_SIGNING_KEY="$keys/witness.pem" \
    SIGNAL_SEGMENT_PUBLIC_KEY="$keys/witness-pub.pem" \
    SIGNAL_SEGMENT_EXPECTED_KEY_ID="$expected_key_id" \
    go -C "$repo/d2-signalloom/apps/signal-ingest" test -tags=frostdb ./store \
      -run '^TestGoEvidenceAcceptedThenMutationRejectedByPythonVerifier$' -count=1
  [ "$status" -eq 0 ]

  # A second, unrelated keypair from the same helper.
  run keygen generate --key "$tmp/other.pem" --pub "$tmp/other-pub.pem"
  [ "$status" -eq 0 ]
  other_id="$(keygen key-id --pub "$tmp/other-pub.pem")"
  [ "$other_id" != "$expected_key_id" ]

  run env AUDIT_ANCHOR_DIR="$proof/evidence/checkpoints" \
    PYTHONPATH="$repo/d2-signalloom/apps/fe-signalloom/src" \
    python3 -m audit_anchor \
      --public-key "$tmp/other-pub.pem" \
      --expected-key-id "$other_id" \
      --source segments \
      --segment-journal "$journal" \
      --segment-root "$proof/store" \
      --protected-high-water "$proof/protected/highwater.json" \
      verify --json
  if [ "$status" -eq 0 ]; then
    echo "verifier accepted evidence under an unrelated public key:" >&2
    echo "$output" >&2
    false
  fi

  # Positive control: prove the verifier RAN and reached a verdict. Without
  # this, an import error, a missing file or a bad flag exits non-zero too and
  # the rejection above would be indistinguishable from the check never
  # happening. An earlier revision of this suite failed exactly that way --
  # PYTHONPATH was unset, `python3 -m audit_anchor` could not be imported, and
  # this test reported ok while testing nothing.
  if [[ "$output" != *'"status"'* ]]; then
    echo "verifier produced no JSON verdict; it probably never ran:" >&2
    echo "$output" >&2
    false
  fi
  [[ "$output" != *"No module named"* ]]
}

@test "interop: the helper refuses to re-mint over an existing key" {
  run keygen generate --key "$tmp/mine.pem" --pub "$tmp/mine-pub.pem"
  [ "$status" -eq 0 ]
  before="$(sha256sum "$tmp/mine.pem" | cut -d' ' -f1)"

  run keygen generate --key "$tmp/mine.pem" --pub "$tmp/mine-pub.pem"
  [ "$status" -ne 0 ]
  after="$(sha256sum "$tmp/mine.pem" | cut -d' ' -f1)"
  [ "$before" = "$after" ]
}
