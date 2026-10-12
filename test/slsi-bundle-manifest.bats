#!/usr/bin/env bats
#
# SLSI-P1-3: Manifest compilation and bundle assembly acceptance suite.
# Hermetic, offline verification of MANIFEST.json schema, cryptographic gates,
# dual-aspect sealing (correctness & completeness), and archive determinism.
#
# @id     slsi-bundle-manifest-bats
# @target scripts/package-tenant-bundle.sh
# @schema schemas/slsi-appliance-manifest-schema.json
# @task   SLSI-P1-3

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCHEMA_FILE="$REPO_ROOT/schemas/slsi-appliance-manifest-schema.json"
  SCHEMA_VALIDATOR="$REPO_ROOT/scripts/lib/json-schema-lite.jq"
  DIST_DIR="$REPO_ROOT/dist"
  MANIFEST_JSON="$DIST_DIR/MANIFEST.json"
  ARCHIVE="$(ls "$DIST_DIR"/slsi-appliance-*.tar.gz 2>/dev/null | head -n 1 || true)"
  TMP="$(mktemp -d)"

  # Decision 10 is reversed. The image it named, controlplane/slsi-util:v0.1.0
  # at this digest, was never published, has no Dockerfile in this tree, and
  # resolves in no registry. Nothing may reference it.
  FORBIDDEN_UTIL_DIGEST="sha256:2235e37c43f3223d26ab7f35e8dfe1a662db1fa196648ab66b0d50f55e5ef51b"
  STAGED_TOOLS=$'cosign\ned25519-keygen\nflux\njq\nkind\nkubectl'
}

teardown() {
  rm -rf "$TMP"
}

# ── shared predicates for the three inverted Decision 10 assertions ──────────
#
# Each of these asserts an ABSENCE, and an absence check that cannot run looks
# exactly like one that passed. So each predicate is a function, applied twice:
# once to the real artefacts, which must pass, and once to a synthetic fixture
# carrying the forbidden thing, which must fail. The fixture half runs whether
# or not dist/ was built, so the controls can never silently stop firing.

# utility_image_refs MANIFEST — prints every reference to a containerised
# utility image. Empty output is the post-reversal state.
utility_image_refs() {
  jq -r '
    [ .images[]? | select((.role? == "utility") or ((.ref? // "") | test("slsi-util"))) ]
    | .[] | (.ref // .digest // "unnamed")
  ' "$1"
}

# index_has_forbidden_digest INDEX — prints matching manifest digests.
index_has_forbidden_digest() {
  jq -r --arg d "$FORBIDDEN_UTIL_DIGEST" \
    '[.manifests[]? | select(.digest == $d)] | .[] | .digest' "$1"
}

# write_poisoned_manifest PATH — a minimal MANIFEST-shaped fixture that DOES
# carry the utility image, for use as a positive control.
write_poisoned_manifest() {
  jq -n --arg d "$FORBIDDEN_UTIL_DIGEST" '{
    images: [
      { ref: "ghcr.io/fluxcd/source-controller@sha256:aa", reference: "ghcr.io/fluxcd/source-controller", digest: "sha256:aa" },
      { ref: ("controlplane/slsi-util:v0.1.0@" + $d), reference: "controlplane/slsi-util",
        digest: $d, role: "utility", provides: ["envsubst", "openssl"] }
    ]
  }' > "$1"
}

# write_poisoned_index PATH — an index fixture that DOES carry the digest.
write_poisoned_index() {
  jq -n --arg d "$FORBIDDEN_UTIL_DIGEST" '{
    schemaVersion: 2,
    manifests: [ { digest: "sha256:bb" }, { digest: $d } ]
  }' > "$1"
}

@test "MANIFEST.json exists and conforms to slsi-bundle/v1 schema" {
  [ -f "$MANIFEST_JSON" ]
  [ -f "$SCHEMA_FILE" ]
  [ -f "$SCHEMA_VALIDATOR" ]

  run jq -e '.schema == "slsi-bundle/v1"' "$MANIFEST_JSON"
  [ "$status" -eq 0 ]

  violations="$(jq -n -r --slurpfile schema "$SCHEMA_FILE" --slurpfile doc "$MANIFEST_JSON" --arg ptr '#' -f "$SCHEMA_VALIDATOR")"
  [ -z "$violations" ]
}

@test "MANIFEST.json carries all required root fields with non-empty type-correct values" {
  [ -f "$MANIFEST_JSON" ]
  run jq -e '
    .schema == "slsi-bundle/v1" and
    (.bundle.name | test("^slsi-appliance-")) and
    (.bundle.version | test("^[0-9]")) and
    (.git.commit | test("^[0-9a-f]{40}$")) and
    (.releaseKey.fingerprint | test("^[0-9a-f]{64}$")) and
    (.payload | length > 0) and
    (.images | length > 0) and
    ([.payload[].sha256] | map(select(test("^[0-9a-f]{64}$"))) | length) == (.payload | length)
  ' "$MANIFEST_JSON"
  [ "$status" -eq 0 ]
}

@test "Seal CORRECTNESS: every path listed in payload matches its claimed checksum" {
  [ -n "$ARCHIVE" ]
  [ -f "$ARCHIVE" ]

  bundle_root="$(mktemp -d)"
  tar -xzf "$ARCHIVE" -C "$bundle_root"

  (
    cd "$bundle_root" && \
    jq -r '.payload[] | "\(.sha256) \(.path)"' MANIFEST.json | sha256sum -c --strict -
  )
  status_c=$?

  rm -rf "$bundle_root"
  [ "$status_c" -eq 0 ]
}

@test "Seal COMPLETENESS: no file exists in bundle that is unlisted in MANIFEST.json" {
  [ -n "$ARCHIVE" ]
  [ -f "$ARCHIVE" ]

  bundle_root="$(mktemp -d)"
  tar -xzf "$ARCHIVE" -C "$bundle_root"

  on_disk="$(cd "$bundle_root" && find . -type f ! -name MANIFEST.json | sed 's|^\./||' | LC_ALL=C sort)"
  declared="$(jq -r '.payload[].path' "$bundle_root/MANIFEST.json" | LC_ALL=C sort)"

  [ -n "$on_disk" ]
  [ -n "$declared" ]
  diff <(printf '%s\n' "$on_disk") <(printf '%s\n' "$declared")
  diff_status=$?

  rm -rf "$bundle_root"
  [ "$diff_status" -eq 0 ]
}

@test "Every image in MANIFEST.json is pinned by immutable digest with zero tag-only references" {
  [ -f "$MANIFEST_JSON" ]
  [ -f "$REPO_ROOT/bundle/images/index.json" ]

  run jq -e '
    ([.images[].digest] | map(select(test("^sha256:[0-9a-f]{64}$"))) | length) == (.images | length) and
    ([.images[] | select(.reference | test(":[^@/]+$"))] | length) == 0
  ' "$MANIFEST_JSON"
  [ "$status" -eq 0 ]

  diff <(jq -r '.images[].digest' "$MANIFEST_JSON" | LC_ALL=C sort -u) \
       <(jq -r '.manifests[].digest' "$REPO_ROOT/bundle/images/index.json" | LC_ALL=C sort -u)
}

# Inverted from "Decision 10 utility image is present, digest-pinned, and
# provides openssl and envsubst". The image that assertion required was never
# published, so requiring it meant requiring the manifest to describe something
# that does not exist. Absence is now the invariant, and the gate for it is
# Gate 7 in scripts/package-tenant-bundle.sh.
@test "Decision 10 reversed: no containerised utility image in MANIFEST.json or the images index" {
  [ -f "$MANIFEST_JSON" ]
  [ -f "$REPO_ROOT/bundle/images/index.json" ]

  found="$(utility_image_refs "$MANIFEST_JSON")"
  if [ -n "$found" ]; then
    echo "MANIFEST.json still references a containerised utility image:" >&2
    printf '%s\n' "$found" >&2
    false
  fi

  found="$(index_has_forbidden_digest "$REPO_ROOT/bundle/images/index.json")"
  if [ -n "$found" ]; then
    echo "bundle/images/index.json still claims the unpublishable slsi-util digest:" >&2
    printf '%s\n' "$found" >&2
    false
  fi

  # The manifest must also say so positively, rather than merely omitting the
  # field: an absent block is indistinguishable from an older schema.
  run jq -e '
    (.containerisedUtilities == null) and
    (.hostUtilities.notShipped | sort == ["envsubst", "openssl"]) and
    (.hostUtilities.replacedBy.binary == "bin/<arch>/ed25519-keygen")
  ' "$MANIFEST_JSON"
  [ "$status" -eq 0 ]
}

@test "positive control: the utility-image predicates fire when the image is reintroduced" {
  # Proves the two absence checks above can fail. Without this, a predicate
  # broken into always printing nothing would make that test vacuous.
  write_poisoned_manifest "$TMP/poisoned-manifest.json"
  found="$(utility_image_refs "$TMP/poisoned-manifest.json")"
  [ -n "$found" ]
  [[ "$found" == *"slsi-util"* ]]

  write_poisoned_index "$TMP/poisoned-index.json"
  found="$(index_has_forbidden_digest "$TMP/poisoned-index.json")"
  [ "$found" = "$FORBIDDEN_UTIL_DIGEST" ]

  # And they stay quiet on a clean fixture, so they are not simply always-true.
  jq -n '{images: [{ref: "ghcr.io/fluxcd/source-controller@sha256:aa", digest: "sha256:aa"}]}' > "$TMP/clean-manifest.json"
  [ -z "$(utility_image_refs "$TMP/clean-manifest.json")" ]
  jq -n '{schemaVersion: 2, manifests: [{digest: "sha256:bb"}]}' > "$TMP/clean-index.json"
  [ -z "$(index_has_forbidden_digest "$TMP/clean-index.json")" ]
}

# Was "covers exactly the five staged binaries": ten entries, five tools across
# two arches. ed25519-keygen makes it twelve entries and six tools. It is built
# from this repository's source rather than downloaded, so unlike the other
# five its digest is computed at stage time rather than pinned as a literal --
# which is why this test checks the NAME set and leaves digest verification to
# `--check-pins`, where the helper is verified by rebuilding it.
@test "bundle/bin/checksums.txt covers exactly the six staged binaries without openssl or envsubst" {
  [ -f "$REPO_ROOT/bundle/bin/checksums.txt" ]

  staged="$(grep -E '(amd64|arm64)/' "$REPO_ROOT/bundle/bin/checksums.txt" | cut -d' ' -f3- | xargs -n1 basename | LC_ALL=C sort -u)"
  diff <(printf '%s\n' "$staged") <(printf '%s\n' "$STAGED_TOOLS")

  # Both arches carry all six, and nothing else: 12 entries exactly.
  entries="$(grep -cE '^[0-9a-f]{64}  (amd64|arm64)/' "$REPO_ROOT/bundle/bin/checksums.txt")"
  [ "$entries" -eq 12 ]

  # Neither tool Decision 10 containerised may reappear, under any arch.
  banned="$(printf '%s\n' "$staged" | grep -E '^(openssl|envsubst)$' || true)"
  if [ -n "$banned" ]; then
    echo "checksums.txt lists a tool that is not shipped:" >&2
    printf '%s\n' "$banned" >&2
    false
  fi
}

@test "positive control: the checksums.txt banned-tool check fires on a planted entry" {
  # The check above is an absence assertion over a file this suite does not
  # write, so prove the grep actually discriminates.
  cp "$REPO_ROOT/bundle/bin/checksums.txt" "$TMP/checksums.txt" 2>/dev/null || \
    printf '%s  amd64/kind\n' "$(printf '0%.0s' $(seq 64))" > "$TMP/checksums.txt"
  printf '%s  amd64/openssl\n' "$(printf 'a%.0s' $(seq 64))" >> "$TMP/checksums.txt"

  staged="$(grep -E '(amd64|arm64)/' "$TMP/checksums.txt" | cut -d' ' -f3- | xargs -n1 basename | LC_ALL=C sort -u)"
  banned="$(printf '%s\n' "$staged" | grep -E '^(openssl|envsubst)$' || true)"
  [ "$banned" = "openssl" ]
}

@test "No unresolved-digest sentinel reaches MANIFEST.json" {
  [ -f "$MANIFEST_JSON" ]
  run grep -cF 'DIGEST-UNRESOLVED' "$MANIFEST_JSON"
  [ "$output" = "0" ]

  run grep -cF 'UNRESOLVED_UPSTREAM' "$MANIFEST_JSON"
  [ "$output" = "0" ]
}

@test "Release public key fingerprint matches shipped release.pub" {
  [ -n "$ARCHIVE" ]
  [ -f "$ARCHIVE" ]
  [ -f "$REPO_ROOT/scripts/lib/eap-evidence.sh" ]

  bundle_root="$(mktemp -d)"
  tar -xzf "$ARCHIVE" -C "$bundle_root"

  source "$REPO_ROOT/scripts/lib/eap-evidence.sh"
  fp="$(cd "$bundle_root" && eap_pubkey_fingerprint ./keys/release.pub)"
  [ -n "$fp" ]

  manifest_fp="$(jq -r .releaseKey.fingerprint "$bundle_root/MANIFEST.json")"
  rm -rf "$bundle_root"

  [ "$fp" = "$manifest_fp" ]
}

@test "Git metadata accurately describes source tree" {
  [ -f "$MANIFEST_JSON" ]
  expected_commit="$(git -c log.showSignature=false rev-parse HEAD)"
  expected_dirty="$([ -n "$(git status --porcelain)" ] && echo true || echo false)"

  run jq -r .git.commit "$MANIFEST_JSON"
  [ "$output" = "$expected_commit" ]

  run jq -r .git.dirty "$MANIFEST_JSON"
  [ "$output" = "$expected_dirty" ]
}

@test "Archive filesystem hierarchy contains exactly declared top-level trees" {
  [ -n "$ARCHIVE" ]
  [ -f "$ARCHIVE" ]
  [ -f "$REPO_ROOT/test/fixtures/slsi/expected-toplevel.txt" ]

  members="$(tar -tzf "$ARCHIVE")"
  [ -n "$members" ]

  diff <(printf '%s\n' "$members" | awk -F/ 'NF>0 {print $1}' | LC_ALL=C sort -u) \
       "$REPO_ROOT/test/fixtures/slsi/expected-toplevel.txt"
}

@test "Manifest payload uses relative paths with dot verification root" {
  [ -f "$MANIFEST_JSON" ]
  run jq -e '
    (.payload | map(select(.path | test("^/") or test("^\\.\\.") or test("^\\./"))) | length == 0) and
    (.verify.root == "." and (.verify.command | test("sha256sum")))
  ' "$MANIFEST_JSON"
  [ "$status" -eq 0 ]
}

@test "Zero private keys or sensitive credentials exist in archive" {
  [ -n "$ARCHIVE" ]
  [ -f "$ARCHIVE" ]

  bundle_root="$(mktemp -d)"
  tar -xzf "$ARCHIVE" -C "$bundle_root"

  privkey_content="$(grep -rEn '-----BEGIN ([A-Z0-9 ]+)?PRIVATE KEY-----' "$bundle_root" || true)"
  privkey_files="$(find "$bundle_root" -type f \( -name "*.key" -o -name "cosign.key" -o -name "release.key" -o -name "*-escrow.tar.enc" \) || true)"
  rm -rf "$bundle_root"

  [ -z "$privkey_content" ]
  [ -z "$privkey_files" ]
}

@test "Gate G-COVERAGE: coverageExclusions reasons are restricted to permitted set" {
  # Three permitted reasons since AJM decision OSD-2 added dev-deferred-pin, and
  # every entry must carry a justification: the reason word alone cannot say why
  # THIS reference was excused, so an unjustified entry is an oversight wearing a
  # reason. The deferral-specific shape (tag, mutableTag) is asserted in
  # test/slsi-bundle-osd.bats, which owns that decision.
  [ -f "$MANIFEST_JSON" ]
  run jq -e '
    (.coverageExclusions | length > 0) and
    ([.coverageExclusions[] | select(.reason == "helm-chart-repository" or .reason == "local-never-pulled" or .reason == "dev-deferred-pin")] | length) == (.coverageExclusions | length) and
    ([.coverageExclusions[] | select(((.justification // "") | length) >= 40)] | length) == (.coverageExclusions | length)
  ' "$MANIFEST_JSON"
  [ "$status" -eq 0 ]
}

# Inverted. This used to require exactly one slsi-util image in the coverage
# domain, and the bundler appended the ref to the domain itself -- so the
# coverage gate counted a non-existent image as covered. The flux-controller
# half is unchanged and is what keeps this test from being pure absence: a
# manifest with no images at all would satisfy the slsi-util clause but fail
# the controllers clause.
@test "Gate G-COVERAGE: no slsi-util image, and flux controllers are digest-pinned in MANIFEST.json" {
  [ -f "$MANIFEST_JSON" ]
  run jq -e '
    ([.images[] | select((.ref // "") | test("slsi-util"))] | length == 0) and
    ([.images[] | select((.ref // "") | test("ghcr.io/fluxcd"))] | length >= 4) and
    ([.images[] | select((.ref // "") | test("ghcr.io/fluxcd"))]
      | all(.digest | test("^sha256:[0-9a-f]{64}$")))
  ' "$MANIFEST_JSON"
  [ "$status" -eq 0 ]
}

@test "positive control: G-COVERAGE rejects a manifest in which slsi-util reappears" {
  # Same filter, a fixture that carries four digest-pinned flux controllers AND
  # the slsi-util ref. Only the slsi-util clause can decide it, so a pass here
  # would prove that clause does nothing.
  jq -n --arg d "$FORBIDDEN_UTIL_DIGEST" '{
    images: (
      ["source", "kustomize", "helm", "notification"]
      | map({ ref: ("ghcr.io/fluxcd/" + . + "-controller@sha256:" + ("a" * 64)),
              digest: ("sha256:" + ("a" * 64)) })
      + [{ ref: ("controlplane/slsi-util:v0.1.0@" + $d), digest: $d, role: "utility" }]
    )
  }' > "$TMP/gcov-poisoned.json"

  run jq -e '
    ([.images[] | select((.ref // "") | test("slsi-util"))] | length == 0) and
    ([.images[] | select((.ref // "") | test("ghcr.io/fluxcd"))] | length >= 4) and
    ([.images[] | select((.ref // "") | test("ghcr.io/fluxcd"))]
      | all(.digest | test("^sha256:[0-9a-f]{64}$")))
  ' "$TMP/gcov-poisoned.json"
  [ "$status" -ne 0 ]

  # And the same fixture WITHOUT the slsi-util entry must pass, so the failure
  # above is attributable to that entry and not to the fixture being malformed.
  jq 'del(.images[] | select((.ref // "") | test("slsi-util")))' "$TMP/gcov-poisoned.json" > "$TMP/gcov-clean.json"
  run jq -e '
    ([.images[] | select((.ref // "") | test("slsi-util"))] | length == 0) and
    ([.images[] | select((.ref // "") | test("ghcr.io/fluxcd"))] | length >= 4) and
    ([.images[] | select((.ref // "") | test("ghcr.io/fluxcd"))]
      | all(.digest | test("^sha256:[0-9a-f]{64}$")))
  ' "$TMP/gcov-clean.json"
  [ "$status" -eq 0 ]
}
