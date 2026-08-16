#!/usr/bin/env bats
# cosign-signing-consistency.bats — every `cosign sign` in this repo must agree,
# and the self-check after signing must test what the CLUSTER will do.
#
# ─── Why this exists ────────────────────────────────────────────────────────
#
# On 2026-08-13 ocirepository/flux-system sat at Ready=False for hours:
#
#   VerificationError: failed to verify the signature using provider 'cosign':
#   no matching signatures were found for .../acme/fleet@sha256:246c7fc4...
#
# while `push-local.sh` had printed "all artifacts pushed and signed" and its own
# post-sign `cosign verify` had passed. Both were telling the truth about
# different things. The push signed with `.keys/cosign.key` and then verified
# with `.keys/cosign.pub` — the matching half of the very key it had just used.
# That check can only ever pass. It proves the signature is internally
# consistent; it proves nothing about whether the consumer accepts it.
#
# The cluster trusted a DIFFERENT key. `.keys/` is gitignored, so it is
# per-checkout, while the kind cluster and the zot registry are shared. The
# cluster had been bootstrapped from a git worktree whose `make signing-keys`
# generated its own keypair; a later push from the main checkout signed with
# that checkout's keypair. cosign reports a signature made by an untrusted key
# as "no matching signatures were found" — the same wording it uses for an
# artifact that was never signed at all. So a key mismatch reads as "unsigned",
# and the operator goes hunting for a missing signature that is in fact present.
#
# Two guards come out of that, and this file asserts both:
#
#   1. The post-sign verify must use the key the CLUSTER trusts, fetched from
#      the cosign-pub secret — never the local public half of the signing key.
#   2. Every `cosign sign` call site must carry the same flags, so a fix applied
#      to one path cannot silently miss another.
#
# ─── On --registry-referrers-mode ───────────────────────────────────────────
#
# Measured against cosign v3.0.6 and zot on 2026-08-13: `legacy`, `oci-1-1` and
# omitting the flag entirely all store a key-based signature the same way — one
# OCI referrer of artifactType application/vnd.dev.sigstore.bundle.v0.3+json, and
# NO `sha256-<digest>.sig` tag. The flag was a no-op here regardless of whether
# `--signing-config` was passed. Flux source-controller v1.9.4 reads that
# referrer correctly; seven OCIRepositories in this demo verify against exactly
# that format with no `.sig` tag anywhere in the registry. The flag was removed
# rather than propagated, because a flag that provably does nothing while
# carrying a comment claiming it prevents a Flux-visibility bug is what sent the
# first investigation after the storage format instead of the key.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  cd "${REPO_ROOT}"
}

# Every line that invokes `cosign sign`, with its backslash continuations
# folded in, derived from the tree rather than listed here. A new signing call
# site is picked up automatically, which is the point — the flux-system stall
# happened in a path nobody remembered to update.
collect_sign_invocations() {
  local f
  for f in Makefile $(git ls-files 'scripts/*.sh' 'scripts/**/*.sh' 2>/dev/null); do
    [ -f "${f}" ] || continue
    awk -v file="${f}" '
      # Prose mentions `cosign sign` constantly -- in shell comments, and in
      # Makefile `## help text`. Only real invocations count, so strip comments
      # before matching. Without this the guard matches its own documentation
      # and reports a target definition as a malformed signing call.
      {
        code = $0
        sub(/#.*/, "", code)
      }
      code ~ /cosign[ \t]+sign([ \t]|$)/ { collecting = 1; buf = ""; }
      collecting {
        line = code
        sub(/^[ \t]+/, "", line)
        buf = buf " " line
        if (line !~ /\\$/) {
          gsub(/\\/, "", buf)
          gsub(/[ \t]+/, " ", buf)
          print file "\t" buf
          collecting = 0
        }
        next
      }
    ' "${f}"
  done
}

@test "every cosign sign call site is discovered (guard against a silent zero)" {
  run collect_sign_invocations
  [ "$status" -eq 0 ]
  local count
  count=$(echo "$output" | grep -c 'cosign sign')
  # A derivation-based test that finds nothing passes vacuously. The repo had
  # five signing call sites when this guard was written; fewer means the
  # collector broke, not that the risk went away.
  [ "$count" -ge 5 ]
}

@test "no cosign sign call site passes --registry-referrers-mode" {
  run collect_sign_invocations
  [ "$status" -eq 0 ]
  # Measured no-op under the pinned cosign v3.0.6 (see header). If a future
  # cosign makes it meaningful again, re-add it EVERYWHERE and update this test
  # to assert its presence — the failure mode being guarded is divergence.
  if echo "$output" | grep -q 'registry-referrers-mode'; then
    echo "call sites still passing the no-op flag:"
    echo "$output" | grep 'registry-referrers-mode'
    false
  fi
}

@test "every cosign sign call site signs by digest, never by tag" {
  run collect_sign_invocations
  [ "$status" -eq 0 ]
  # Signing a tag races a concurrent re-push: the tag can move between the push
  # and the sign, leaving the signature on a digest nobody serves.
  local line
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    # Either the reference is built inline -- `@${digest}` in shell, `@$${DIGEST}`
    # in a Makefile recipe -- or it is a single variable that was assembled from
    # a digest earlier, which by this repo's naming says DIGEST in its name
    # (build-sign-dashboard.sh signs "${LOCAL_DIGEST_REF}"). A tag reference such
    # as "${REGISTRY}/${repo}:latest" matches neither, which is the case to catch.
    echo "${line}" | grep -qE '@\$+\{?[A-Za-z_]|\$\{[A-Za-z_]*DIGEST[A-Za-z_]*\}' || {
      echo "signs something that is not a digest reference: ${line}"
      false
    }
    # A digest SOMEWHERE on the line is not the same claim as "no tag is signed".
    #
    # The check above passes as soon as one digest reference appears, so adding a
    # SECOND, tag-style image argument beside the digest slipped through -- and
    # that is a real defect, not a hypothetical: cosign signs every reference it
    # is given, so the tag signature is created just the same, and the tag can
    # move under a concurrent push exactly as this test's own comment warns.
    #
    # Found by test/guard-falsification-proof.sh, which registered it as a BLIND
    # SPOT after its positive control proved the guard was otherwise live. Its
    # first report of this case said GUARD DID NOT FIRE -- "decoration" -- which
    # was false and sent me to "fix" a guard that was working; the oracle that
    # confirms the injected defect is really present is what turned a false
    # accusation into this true, narrower one.
    #
    # An image argument is a bare (unflagged) token containing a registry-ish
    # path and a `:tag` suffix, with no `@` digest on it.
    local tagref
    tagref="$(printf '%s\n' "${line}" | tr ' ' '\n' \
      | tr -d '\042\047' \
      | grep -vE '^-' \
      | grep -E '[A-Za-z0-9_}$)/-]+/[A-Za-z0-9_}$)./-]+:[A-Za-z0-9_.${}-]+$' \
      | grep -v '@' || true)"
    if [ -n "${tagref}" ]; then
      echo "signs a TAG reference alongside a digest: ${tagref}"
      echo "  in: ${line}"
      false
    fi
  done <<< "$(echo "$output" | grep 'cosign sign')"
}

@test "every cosign sign call site uses the same key and signing-config idiom" {
  run collect_sign_invocations
  [ "$status" -eq 0 ]
  local line
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    echo "${line}" | grep -q -- '--key' || { echo "no --key: ${line}"; false; }
    echo "${line}" | grep -q -- '--signing-config' || { echo "no --signing-config: ${line}"; false; }
    echo "${line}" | grep -q -- '--allow-insecure-registry' || { echo "no --allow-insecure-registry: ${line}"; false; }
  done <<< "$(echo "$output" | grep 'cosign sign')"
}

@test "push-local.sh verifies against the cluster's trusted key, not its own" {
  # The tautology guard. Verifying with the public half of the key just used to
  # sign is unfalsifiable; it is what let an untrusted-key push report success.
  run bash -c "grep -A6 'cosign verify' scripts/push-local.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'TRUSTED_PUB\|cluster' \
    || { echo "post-sign verify does not reference the cluster-trusted key"; false; }
  # It must NOT fall back to deriving the pub key from the signing key path.
  if echo "$output" | grep -q 'COSIGN_KEY%.key'; then
    echo "post-sign verify still derives the pub key from the signing key:"
    echo "$output"
    false
  fi
}

@test "push-local.sh refuses to push when its key is not the one the cluster trusts" {
  grep -q 'assert_signing_key_is_trusted' scripts/push-local.sh \
    || { echo "no pre-push trust assertion in push-local.sh"; false; }
  # The assertion has to run BEFORE the first push, not after. Discovering the
  # mismatch post-push means the shared registry already carries an artifact the
  # cluster will refuse, and `latest` may already have moved onto it.
  local assert_line push_line
  assert_line=$(grep -n 'assert_signing_key_is_trusted$' scripts/push-local.sh | tail -1 | cut -d: -f1)
  push_line=$(grep -n '^case "${mode}"' scripts/push-local.sh | head -1 | cut -d: -f1)
  [ -n "${assert_line}" ] && [ -n "${push_line}" ] && [ "${assert_line}" -lt "${push_line}" ]
}

@test "live: the local signing key is the key the cluster trusts" {
  kubectl -n flux-system get secret cosign-pub >/dev/null 2>&1 \
    || skip "no cluster, or no flux-system/cosign-pub secret"
  [ -f .keys/cosign.pub ] || skip "no local .keys/cosign.pub in this checkout"

  # Compared as files, not as $(...) captures: command substitution strips the
  # trailing newline, so the fingerprints printed on failure would not match what
  # an operator gets from `sha256sum .keys/cosign.pub` while chasing the message.
  local cluster_pub="${BATS_TEST_TMPDIR:-/tmp}/cluster-cosign.pub"
  kubectl -n flux-system get secret cosign-pub \
    -o jsonpath='{.data.cosign\.pub}' | base64 -d > "${cluster_pub}"

  # This is the assertion that would have caught the original stall in seconds.
  diff -q "${cluster_pub}" .keys/cosign.pub >/dev/null 2>&1 || {
    echo "signing key does not match the cluster's trusted key."
    echo "  cluster cosign-pub sha256: $(sha256sum < "${cluster_pub}"    | cut -c1-16)"
    echo "  local .keys/cosign.pub   : $(sha256sum < .keys/cosign.pub | cut -c1-16)"
    echo "  .keys/ is gitignored and therefore per-checkout; the cluster was"
    echo "  probably bootstrapped from a different worktree."
    false
  }
}
