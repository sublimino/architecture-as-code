#!/usr/bin/env bats
#
# The Tailscale TLS certificate must survive `terraform destroy`.
#
# ─── The defect this suite exists to prevent ────────────────────────────────
#
# tailscaled keeps its Let's Encrypt certificate under /var/lib/tailscale/certs,
# which is on the BOOT DISK. Measured on sl-ci-1-vm 2026-08-23:
#
#   /var/lib/tailscale/        drwx------ Aug 22 17:56   <- the VM rebuild time
#   /var/lib/tailscale/certs/  acme-account.key.pem ONLY, no cert and no key
#
# A destroy takes the disk and every path on it, so the next build starts with
# an empty cert store. The MagicDNS name does NOT reset — it is stable per lane
# — and Let's Encrypt rate-limits on the exact set of identifiers: five
# certificates per 168h. So rebuilding does not clear the limit, rebuilding is
# what CONSUMES it, and roughly five rebuilds in a week exhaust it:
#
#   tailscaled: cert("sl-ci-1.taild4da3.ts.net"): getCertPEM: 429
#   urn:ietf:params:acme:error:rateLimited: too many certificates (5) already
#   issued for this exact set of identifiers in the last 168h0m0s
#
# The lane then completes NO TLS handshake at all: TCP connects to :443 and
# curl reports 000, because tailscaled has no certificate to present.
#
# ─── The two properties that are easy to get subtly wrong ───────────────────
#
# 1. WHERE the store lives. /opt/signalloom/keys and /opt/signalloom/zot-cache
#    survive a re-DELIVERY, because delivery only removes the checkout. They do
#    NOT survive a DESTROY, which removes the whole disk. Only the destroy burns
#    the ACME allowance, so a store built to the existing sibling-directory
#    pattern would look right, pass a re-delivery test, and fix nothing. The
#    bucket therefore lives in terraform/bootstrap. Two reasons: `gcp-tf-destroy`
#    refuses to run against it, and it is the ONLY root whose applying identity
#    holds bucket-creation rights — test/terraform-state-protection.bats fails if
#    any google_storage_bucket appears in a consuming root, and it caught this
#    being put in terraform/platform during development.
#
# 2. WHEN the restore runs. Measured on sl-ci-1-vm:
#
#      boot          2026-08-22 17:55:23
#      cert request  2026-08-22T17:56:05  cert("sl-ci-1.taild4da3.ts.net")
#
#    42 seconds after boot, driven by signalloom-tailscale-serve.service, not by
#    anyone visiting the URL. Any restore that runs later than tailscaled's
#    start — including every path in scripts/gcp-tf/demo-up.sh, which cannot SSH
#    in that early — arrives after the issuance has already been spent. Moving
#    the call one line down in install_tailscale breaks nothing visible and
#    silently restores the old behaviour, which is why the ORDER is asserted.
#
# test/gcp-demo-tailscale-cert-persistence-mutation-proof.sh proves every
# assertion below can actually fail. Several are absence-of-bad assertions,
# trivially satisfied by nothing being present, and this file is not evidence of
# anything without that harness.
#
# ─── The sibling suite ──────────────────────────────────────────────────────
#
# This one covers the CAUSE: a rebuild reuses the stored certificate instead of
# spending an issuance. It cannot help a lane that is already inside a
# rate-limit window, because persistence arrived too late to stop that window
# opening. test/terraform-tailscale-cert-state.bats covers that case — what the
# node records at issuance time and how it serves when there is no certificate
# to serve with. The two are separate suites because this one rewrites the VM
# startup script and is therefore create-time, and that one is not.
#
# Offline: reads files and runs the startup script's own functions with stubs.
# No network, no cloud, no VM.

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  export STARTUP="${REPO_ROOT}/terraform/modules/compute/startup/demo-vm.sh"
  export BOOTSTRAP_MAIN="${REPO_ROOT}/terraform/bootstrap/main.tf"
  export BOOTSTRAP_VARS="${REPO_ROOT}/terraform/bootstrap/variables.tf"
  export BOOTSTRAP_OUT="${REPO_ROOT}/terraform/bootstrap/outputs.tf"
  export PLATFORM_MAIN="${REPO_ROOT}/terraform/platform/main.tf"
  export ENV_MAIN="${REPO_ROOT}/terraform/environments/main.tf"
  export COMPUTE_MAIN="${REPO_ROOT}/terraform/modules/compute/main.tf"
  export COMPUTE_VARS="${REPO_ROOT}/terraform/modules/compute/variables.tf"
}

setup() {
  [ -f "${STARTUP}" ]
  [ -f "${BOOTSTRAP_MAIN}" ]
  [ -f "${ENV_MAIN}" ]
  [ -f "${COMPUTE_MAIN}" ]
}

# ── Harness ─────────────────────────────────────────────────────────────────
#
# Sources the REAL startup script with `main "$@"` removed and the paths it
# writes to redirected into a scratch directory, so the shipped functions run
# unmodified. A reimplementation here would be a second copy of the logic that
# agrees with itself no matter what the shipped code does — the contract-halves
# failure this repo has already paid for once.
mk_harness() {
  TMP="$(mktemp -d)"
  export TMP
  mkdir -p "${TMP}/stubs" "${TMP}/certs" "${TMP}/signalloom"

  sed -e "s|^readonly TS_CERT_DIR=.*|readonly TS_CERT_DIR=\"${TMP}/certs\"|" \
    -e "s|^readonly TS_CERT_MARKER=.*|readonly TS_CERT_MARKER=\"${TMP}/signalloom/tailscale-cert-restore-failed\"|" \
    -e "s|^readonly TS_CERT_SAVE_HELPER=.*|readonly TS_CERT_SAVE_HELPER=\"${TMP}/helper\"|" \
    -e "s|^readonly TS_CERT_SAVE_UNIT=.*|readonly TS_CERT_SAVE_UNIT=\"${TMP}/save.service\"|" \
    -e "s|^readonly TS_CERT_SAVE_TIMER=.*|readonly TS_CERT_SAVE_TIMER=\"${TMP}/save.timer\"|" \
    -e 's|^main "\$@"$||' \
    "${STARTUP}" >"${TMP}/lib.sh"

  printf '#!/bin/sh\nexit 0\n' >"${TMP}/stubs/systemctl"
  chmod +x "${TMP}/stubs/systemctl"
}

# curl stub whose behaviour is chosen per test. MODE is read from the
# environment at call time.
#
#   token-ok     mint a token, then behave per LIST_MODE / GET_MODE
#   token-fail   the metadata server issues nothing
write_curl_stub() {
  cat >"${TMP}/stubs/curl" <<'STUB'
#!/usr/bin/env bash
args="$*"

case "$args" in
*service-accounts/default/token*)
  if [ "${TOKEN_MODE:-ok}" = "fail" ]; then exit 22; fi
  printf '{"access_token":"ya29.stub","expires_in":3599}'
  exit 0
  ;;
*"/o?prefix="*)
  case "${LIST_MODE:-ok}" in
  fail) exit 22 ;;
  empty) printf '{"kind":"storage#objects"}' ; exit 0 ;;
  crt-only)
    # A listing with a certificate and NO key. Every download then SUCCEEDS, so
    # the partial-failure branch never fires and the incomplete-pair check is
    # the only thing that can catch it. Failing the .key download instead —
    # which is what this stub originally did — is caught by the partial-file
    # branch first, leaving the pair check unexercised and its guard vacuous.
    printf '{"kind":"storage#objects","items":[{"name":"demo-1/sl-demo-1.taild4da3.ts.net.crt"},{"name":"demo-1/acme-account.key.pem"}]}'
    exit 0
    ;;
  *)
    printf '{"kind":"storage#objects","items":[{"name":"demo-1/sl-demo-1.taild4da3.ts.net.crt"},{"name":"demo-1/sl-demo-1.taild4da3.ts.net.key"},{"name":"demo-1/acme-account.key.pem"}]}'
    exit 0
    ;;
  esac
  ;;
*alt=media*)
  # Output path is the argument after --output.
  out=""
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--output" ]; then out="$a"; fi
    prev="$a"
  done
  case "${GET_MODE:-ok}" in
  fail)
    # curl --fail still creates the output file before failing. Reproducing
    # that is the point: the partial-file cleanup is the thing under test.
    [ -n "$out" ] && : >"$out"
    exit 22
    ;;
  crt-only)
    case "$args" in
    *.key*) [ -n "$out" ] && : >"$out" ; exit 22 ;;
    esac
    [ -n "$out" ] && printf 'STUBCERT\n' >"$out"
    exit 0
    ;;
  *)
    [ -n "$out" ] && printf 'STUBDATA\n' >"$out"
    exit 0
    ;;
  esac
  ;;
esac
exit 0
STUB
  chmod +x "${TMP}/stubs/curl"
}

run_restore() {
  PATH="${TMP}/stubs:${PATH}" bash -c "source '${TMP}/lib.sh'; restore_tailscale_certs '$1' '$2'" 2>&1
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "${TMP}"
  return 0
}

# ── 1. The store survives DESTROY, not merely re-delivery ───────────────────

@test "the certificate bucket is declared in the bootstrap root" {
  # The whole point. A bucket declared in terraform/environments is deleted by
  # `make gcp-tf-destroy ENV=<that environment>` — the exact operation whose
  # cost it exists to remove. bootstrap is also the only root whose applying
  # identity may create a bucket at all.
  grep -q 'resource "google_storage_bucket" "tailnet_certs"' "${BOOTSTRAP_MAIN}" || {
    echo "google_storage_bucket.tailnet_certs is not declared in terraform/bootstrap/main.tf." >&2
    echo "In terraform/environments it is destroyed by gcp-tf-destroy, which is the" >&2
    echo "operation that burns the Let's Encrypt allowance. In terraform/platform it" >&2
    echo "cannot be created at all: that root's identity holds no bucket-creation" >&2
    echo "rights, so the apply fails 403." >&2
    return 1
  }
}

@test "the certificate bucket is NOT declared in a consuming root" {
  # terraform/platform and terraform/environments both CONSUME buckets and
  # create none. Asserted here as well as in test/terraform-state-protection.bats
  # because that suite states the estate-wide rule while this one states why it
  # binds THIS bucket — and a reader chasing a 403 on a cert-bucket apply will
  # be reading this file.
  local root
  for root in "${PLATFORM_MAIN}" "${ENV_MAIN}"; do
    if grep -q 'resource "google_storage_bucket"' "${root}"; then
      echo "${root} declares a storage bucket. Consuming roots must declare none:" >&2
      echo "their applying identities deliberately hold no bucket-creation rights," >&2
      echo "and anything they own is destroyed by gcp-tf-destroy." >&2
      return 1
    fi
  done
}

@test "the certificate bucket is NOT declared in the environments root" {
  # The negative half. Asserted separately from the positive because a COPY in
  # the environments root would satisfy the test above while reintroducing the
  # defect for whichever root actually owns the resource.
  if grep -q 'resource "google_storage_bucket" "tailnet_certs"' "${ENV_MAIN}"; then
    echo "google_storage_bucket.tailnet_certs is declared in terraform/environments/main.tf." >&2
    echo "gcp-tf-destroy ENV=<key> deletes it, so the certificate does not survive the" >&2
    echo "destroy — which is the only event that consumes an ACME issuance." >&2
    return 1
  fi
}

@test "the certificate bucket carries prevent_destroy" {
  # Scoped to the tailnet_certs resource body rather than grepped file-wide:
  # terraform/bootstrap also uses prevent_destroy, and a file-wide match would
  # pass on somebody else's lifecycle block.
  run bash -c "sed -n '/resource \"google_storage_bucket\" \"tailnet_certs\"/,/^}/p' '${BOOTSTRAP_MAIN}'"
  [ "$status" -eq 0 ]
  [[ "${output}" == *"prevent_destroy = true"* ]] || {
    echo "the tailnet_certs bucket does not set prevent_destroy = true" >&2
    return 1
  }
  [[ "${output}" == *"force_destroy = false"* ]] || {
    echo "the tailnet_certs bucket does not set force_destroy = false" >&2
    return 1
  }
}

# ── 2. The private key is access-controlled ─────────────────────────────────

@test "the certificate bucket blocks public access and disables ACLs" {
  run bash -c "sed -n '/resource \"google_storage_bucket\" \"tailnet_certs\"/,/^}/p' '${BOOTSTRAP_MAIN}'"
  [ "$status" -eq 0 ]
  # ACLs off means IAM is the only answer to "who can read this private key",
  # and that answer is then readable in this repo rather than in the console.
  [[ "${output}" == *"uniform_bucket_level_access = true"* ]]
  [[ "${output}" == *'public_access_prevention    = "enforced"'* ]]
}

@test "each lane's grant is conditioned on its own object prefix" {
  # Without the condition every runtime account could read every other lane's
  # TLS private key. The condition is a security boundary, and an IAM condition
  # that silently stops matching is indistinguishable from no condition at all
  # when you are only looking at whether the deploy worked.
  run bash -c "sed -n '/resource \"google_storage_bucket_iam_member\" \"tailnet_cert_writers\"/,/^}/p' '${BOOTSTRAP_MAIN}'"
  [ "$status" -eq 0 ]
  [[ "${output}" == *"condition {"* ]] || {
    echo "the per-lane IAM member has no condition block, so every lane can read" >&2
    echo "every other lane's TLS private key." >&2
    return 1
  }
  [[ "${output}" == *"resource.name.startsWith"* ]]
  # Anchored on the lane key AND on the objects/ path segment. Anchoring on the
  # bucket alone would match every object in it.
  [[ "${output}" == *'/objects/${each.key}/'* ]] || {
    echo "the IAM condition does not anchor on \"/objects/\${each.key}/\"." >&2
    echo "Anchoring on the bucket alone matches every object in the bucket." >&2
    return 1
  }
}

@test "the grant is objectAdmin, not a role that can rewrite the bucket's IAM" {
  run bash -c "sed -n '/resource \"google_storage_bucket_iam_member\" \"tailnet_cert_writers\"/,/^}/p' '${BOOTSTRAP_MAIN}'"
  [ "$status" -eq 0 ]
  [[ "${output}" == *'role   = "roles/storage.objectAdmin"'* ]]
  # storage.admin would let a compromised VM remove the prefix condition that
  # confines it, which makes the boundary self-defeating.
  if [[ "${output}" == *"roles/storage.admin"* ]]; then
    echo "the runtime account holds roles/storage.admin, which can rewrite the" >&2
    echo "bucket IAM that confines it to its own prefix." >&2
    return 1
  fi
}

@test "no credential is published to instance metadata" {
  # Only bucket COORDINATES go into metadata; the VM authenticates with a token
  # its own metadata server mints. This is the property the auth-key path was
  # built to have and it must not be quietly given up here.
  run bash -c "sed -n '/tailscale_metadata = var.tailscale_enabled/,/} : {}/p' '${COMPUTE_MAIN}'"
  [ "$status" -eq 0 ]
  [[ "${output}" == *"signalloom-tailscale-cert-bucket"* ]]
  [[ "${output}" == *"signalloom-tailscale-cert-prefix"* ]]
  # A key, a cert or a token in metadata would be readable by anything on the
  # instance that can reach the metadata server, including a container.
  if [[ "${output}" == *"cert-key"* || "${output}" == *"private_key"* || "${output}" == *"BEGIN "* ]]; then
    echo "instance metadata appears to carry key material." >&2
    return 1
  fi
}

# ── 3. Restore happens before tailscaled can ask ACME ───────────────────────

@test "restore_tailscale_certs is called BEFORE install_tailscale_package" {
  # THE mechanism. install_tailscale_package ends with
  # `systemctl enable --now tailscaled`; the certificate has to be on disk
  # before tailscaled starts looking. Measured: the request fires 42s after
  # boot. Reordering these two lines breaks no other test and silently restores
  # the defect, so the order is asserted explicitly.
  local body restore_line pkg_line
  # COMMENTS STRIPPED FIRST, and that is not tidiness. The comment above the
  # restore call explains why it must precede install_tailscale_package, so it
  # NAMES install_tailscale_package several lines earlier than the real call.
  # Matching prose instead of code made this assertion fail against correct
  # code — the same "prose parsed as data" shape that has produced false
  # findings in this repo before. A derived guard must read the code only.
  body="$(sed -n '/^install_tailscale() {/,/^}/p' "${STARTUP}" | sed -e 's/#.*$//')"

  restore_line="$(printf '%s\n' "${body}" | grep -n 'restore_tailscale_certs' | head -n 1 | cut -d: -f1)"
  pkg_line="$(printf '%s\n' "${body}" | grep -n 'install_tailscale_package' | head -n 1 | cut -d: -f1)"

  [ -n "${restore_line}" ] || {
    echo "install_tailscale never calls restore_tailscale_certs" >&2
    return 1
  }
  [ -n "${pkg_line}" ] || {
    echo "install_tailscale no longer calls install_tailscale_package" >&2
    return 1
  }
  [ "${restore_line}" -lt "${pkg_line}" ] || {
    echo "restore_tailscale_certs runs at line ${restore_line} of install_tailscale," >&2
    echo "AFTER install_tailscale_package at line ${pkg_line}. That function ends with" >&2
    echo "'systemctl enable --now tailscaled', so tailscaled starts before the" >&2
    echo "certificate is on disk and requests a new one — spending one of the five" >&2
    echo "issuances Let's Encrypt allows per 168h for this node's exact DNS name." >&2
    return 1
  }
}

@test "the node identity state file is deliberately NOT persisted" {
  # Considered and rejected: this estate runs `tailscale logout` at shutdown to
  # RELEASE the device record so the next build can reclaim the name. A state
  # file captured after that logout restores nothing; one captured before it
  # reinstates an identity the estate just deliberately released.
  if grep -q 'tailscaled\.state' "${STARTUP}"; then
    local ctx
    ctx="$(grep -n 'tailscaled\.state' "${STARTUP}")"
    # Naming it in the explanatory comment is required; copying it is not.
    printf '%s\n' "${ctx}" | grep -qv '^\s*[0-9]*:\s*#' && {
      echo "tailscaled.state is referenced outside a comment in the startup script:" >&2
      printf '%s\n' "${ctx}" >&2
      echo "Persisting the node identity fights signalloom-tailscale-logout, which" >&2
      echo "releases the device record on purpose." >&2
      return 1
    }
  fi
  return 0
}

# ── 4. Restore failure is loud, never silent ────────────────────────────────

@test "a successful restore writes the certs and leaves no failure marker" {
  mk_harness
  write_curl_stub
  run_restore sl-certs demo-1

  [ -f "${TMP}/certs/sl-demo-1.taild4da3.ts.net.crt" ]
  [ -f "${TMP}/certs/sl-demo-1.taild4da3.ts.net.key" ]
  [ -f "${TMP}/certs/acme-account.key.pem" ]
  [ ! -f "${TMP}/signalloom/tailscale-cert-restore-failed" ]
}

@test "restored key material is not world-readable" {
  mk_harness
  write_curl_stub
  run_restore sl-certs demo-1

  local mode
  mode="$(stat -c '%a' "${TMP}/certs/sl-demo-1.taild4da3.ts.net.key")"
  [ "${mode}" = "600" ] || {
    echo "the restored private key is mode ${mode}, expected 600" >&2
    return 1
  }
}

@test "a failed listing writes the marker and says the allowance will be spent" {
  mk_harness
  write_curl_stub
  output="$(LIST_MODE=fail run_restore sl-certs demo-1)"

  [ -f "${TMP}/signalloom/tailscale-cert-restore-failed" ] || {
    echo "a failed listing left no marker, so the failure is silent — it looks" >&2
    echo "identical to a first-ever boot and burns an issuance unnoticed." >&2
    return 1
  }
  [[ "${output}" == *"WARNING"* ]]
  [[ "${output}" == *"NEW Let's Encrypt certificate"* ]]
}

@test "a missing access token writes the marker" {
  mk_harness
  write_curl_stub
  output="$(TOKEN_MODE=fail run_restore sl-certs demo-1)"

  [ -f "${TMP}/signalloom/tailscale-cert-restore-failed" ]
  [[ "${output}" == *"no access token"* ]]
}

@test "a partial download is removed rather than left as a truncated key" {
  # A truncated .key is worse than an absent one: tailscaled fails to parse it
  # instead of falling through to requesting a certificate.
  mk_harness
  write_curl_stub
  GET_MODE=fail run_restore sl-certs demo-1 >/dev/null

  local leftovers
  leftovers="$(find "${TMP}/certs" -maxdepth 1 -type f | wc -l)"
  [ "${leftovers}" -eq 0 ] || {
    echo "${leftovers} partial file(s) survived a failed download:" >&2
    find "${TMP}/certs" -maxdepth 1 -type f >&2
    return 1
  }
  [ -f "${TMP}/signalloom/tailscale-cert-restore-failed" ]
}

@test "a certificate without its key is refused as an incomplete pair" {
  mk_harness
  write_curl_stub
  # LIST_MODE, not GET_MODE: every download must SUCCEED so that the
  # partial-failure branch stays out of the way and this test exercises the
  # incomplete-pair check specifically. Proven by mutation — disabling that
  # check under the GET_MODE variant left this test green.
  output="$(LIST_MODE=crt-only run_restore sl-certs demo-1)"

  [ -f "${TMP}/signalloom/tailscale-cert-restore-failed" ] || {
    echo "a crt with no key was accepted as a successful restore. tailscaled will" >&2
    echo "request a new certificate anyway, so this must not report success." >&2
    return 1
  }
  [[ "${output}" == *"WARNING"* ]]
  # And the certificate really did arrive, so this is the pair check firing
  # rather than a download failure being caught upstream of it.
  [ -f "${TMP}/certs/sl-demo-1.taild4da3.ts.net.crt" ]
}

@test "the failure marker carries a reason and no key material" {
  mk_harness
  write_curl_stub
  LIST_MODE=fail run_restore sl-certs demo-1 >/dev/null

  local marker
  marker="$(cat "${TMP}/signalloom/tailscale-cert-restore-failed")"
  [ -n "${marker}" ]
  # Same property TS_NAME_MARKER is held to, asserted rather than intended.
  if [[ "${marker}" == *"BEGIN "* || "${marker}" == *"PRIVATE KEY"* || "${marker}" == *"ya29."* ]]; then
    echo "the failure marker contains key or token material:" >&2
    printf '%s\n' "${marker}" >&2
    return 1
  fi
}

# ── 5. Absent configuration is not a failure ────────────────────────────────

@test "an unconfigured bucket skips the restore without writing a marker" {
  # Persistence is opt-in. An estate that has not created the bucket must behave
  # exactly as it did before this existed — and must NOT be reported as broken,
  # or the marker becomes noise that stops meaning anything.
  mk_harness
  write_curl_stub
  output="$(run_restore '' '')"

  [ ! -f "${TMP}/signalloom/tailscale-cert-restore-failed" ] || {
    echo "an unconfigured estate was marked as a restore failure" >&2
    return 1
  }
  [[ "${output}" == *"not configured"* ]]
}

@test "an empty prefix is reported as a first boot, not as a failure" {
  # The ONE case where requesting a new certificate is correct. It must not be
  # confused with the failure paths, in either direction.
  mk_harness
  write_curl_stub
  output="$(LIST_MODE=empty run_restore sl-certs demo-1)"

  [ ! -f "${TMP}/signalloom/tailscale-cert-restore-failed" ]
  [[ "${output}" == *"first boot"* ]]
}

# ── 6. The save path exists and is syntactically real ───────────────────────

@test "the generated save helper is valid bash" {
  # The helper is written by a heredoc. A heredoc that produces broken bash
  # passes `bash -n` on the outer file and fails only on the VM at boot, where
  # the message goes to a serial console this instance disables.
  mk_harness
  PATH="${TMP}/stubs:${PATH}" bash -c \
    "source '${TMP}/lib.sh'; install_tailscale_cert_save_unit sl-certs demo-1" >/dev/null 2>&1

  [ -f "${TMP}/helper" ] || {
    echo "install_tailscale_cert_save_unit wrote no helper" >&2
    return 1
  }

  # Existence and `bash -n` are BOTH satisfied by a ZERO-BYTE file, and that is
  # not hypothetical: the redirection creates the file before the heredoc is
  # expanded, so any expansion error — an unbound variable under `set -u`, for
  # one — leaves an empty helper behind. `bash -n` on an empty file exits 0, the
  # `if ! cat` guard never fires because the shell dies at the expansion rather
  # than in cat, and the install reads as healthy while the timer runs a script
  # that does nothing. Measured while proving this suite red, 2026-08-23.
  [ -s "${TMP}/helper" ] || {
    echo "the generated save helper is EMPTY. bash -n passes an empty file, so" >&2
    echo "this would otherwise read as a successful install of a helper that" >&2
    echo "silently saves nothing and lets the next rebuild spend an issuance." >&2
    return 1
  }
  grep -q 'uploadType=media' "${TMP}/helper" || {
    echo "the generated helper contains no upload call, so the heredoc was" >&2
    echo "truncated before the part that does the work:" >&2
    cat "${TMP}/helper" >&2
    return 1
  }

  run bash -n "${TMP}/helper"
  [ "$status" -eq 0 ] || {
    echo "the generated save helper is not valid bash:" >&2
    echo "${output}" >&2
    return 1
  }
}

@test "the save helper substitutes the bucket coordinates it was given" {
  mk_harness
  PATH="${TMP}/stubs:${PATH}" bash -c \
    "source '${TMP}/lib.sh'; install_tailscale_cert_save_unit sl-certs demo-1" >/dev/null 2>&1

  grep -q 'BUCKET="sl-certs"' "${TMP}/helper"
  grep -q 'PREFIX="demo-1"' "${TMP}/helper"
  # An unexpanded ${bucket} would produce a helper that uploads to a literal
  # path and reports success while storing nothing retrievable.
  if grep -q '\${bucket}\|\${prefix}' "${TMP}/helper"; then
    echo "the generated helper contains unexpanded shell variables" >&2
    return 1
  fi
}

@test "the save timer is enabled AND started" {
  # An enabled-but-never-started timer is armed for the NEXT boot only — the
  # exact shape of a guard that looks installed and has never fired, which this
  # repo has already been bitten by in install_tailscale_logout_unit.
  mk_harness
  cat >"${TMP}/stubs/systemctl" <<STUB
#!/bin/sh
echo "\$*" >>"${TMP}/systemctl.log"
exit 0
STUB
  chmod +x "${TMP}/stubs/systemctl"

  PATH="${TMP}/stubs:${PATH}" bash -c \
    "source '${TMP}/lib.sh'; install_tailscale_cert_save_unit sl-certs demo-1" >/dev/null 2>&1

  grep -q "^enable signalloom-tailscale-cert-save.timer$" "${TMP}/systemctl.log" || {
    echo "the save timer is never enabled. systemctl calls were:" >&2
    cat "${TMP}/systemctl.log" >&2
    return 1
  }
  grep -q "^start signalloom-tailscale-cert-save.timer$" "${TMP}/systemctl.log" || {
    echo "the save timer is enabled but never started, so it is armed for the NEXT" >&2
    echo "boot only and has never once run. systemctl calls were:" >&2
    cat "${TMP}/systemctl.log" >&2
    return 1
  }
}

@test "an unconfigured bucket installs no save timer" {
  mk_harness
  PATH="${TMP}/stubs:${PATH}" bash -c \
    "source '${TMP}/lib.sh'; install_tailscale_cert_save_unit '' ''" >/dev/null 2>&1

  [ ! -f "${TMP}/helper" ] || {
    echo "a save helper was installed for an estate with no bucket configured" >&2
    return 1
  }
}

# ── 6b. The save path can never destroy the persisted copy ──────────────────
#
# This is the assertion that makes KEEPING the deregistration flow safe, and it
# is the one place where the two standing decisions — persist the certificate,
# and keep `ts-logout --force` exactly as it is — actually meet.
#
# `tailscale logout` runs at shutdown to release the device record. Whether it
# also removes /var/lib/tailscale/certs is NOT established here and does not
# need to be, because the durable copy is in GCS and the node never deletes
# from GCS. Both possible logout behaviours are therefore survivable:
#
#   logout leaves the certs        the next save is a no-op, GCS unchanged
#   logout deletes the certs       the loop finds nothing, GCS unchanged
#
# A save helper that MIRRORED instead of uploading would invert this: logout
# would empty the local directory, the next tick would reconcile the bucket to
# match, and the persisted certificate would be deleted by the very mechanism
# that exists to keep it. The estate would then look correct for up to an hour
# and lose the certificate on the shutdown that mattered.
#
# So the property is "upload-only", asserted both ways: no delete verb reaches
# the bucket when the local directory has been emptied, and no delete verb
# appears in the helper at all.

# Redirects the generated helper's hardcoded stamp directory into the scratch
# tree so this runs unprivileged, and logs every curl invocation.
prep_save_helper() {
  local before after
  before="$(md5sum "${TMP}/helper" | cut -d' ' -f1)"
  sed -i -e "s|^STAMP_DIR=.*|STAMP_DIR=\"${TMP}/stamps\"|" "${TMP}/helper"
  after="$(md5sum "${TMP}/helper" | cut -d' ' -f1)"

  # Assert the edit landed. A non-matching sed no-ops while reporting success,
  # and the test would then run against an unmodified helper and pass for the
  # wrong reason.
  [ "$before" != "$after" ] || {
    echo "the STAMP_DIR redirect matched nothing — this test is not hermetic" >&2
    return 1
  }

  cat >"${TMP}/stubs/curl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${TMP}/curl.log"
case "\$*" in
*service-accounts/default/token*) printf '{"access_token":"ya29.stub"}' ;;
esac
exit 0
STUB
  chmod +x "${TMP}/stubs/curl"
}

@test "an emptied cert directory does not delete the persisted copy" {
  # The post-logout state, if logout does remove the certificate files: the
  # local directory exists and is empty.
  mk_harness
  PATH="${TMP}/stubs:${PATH}" bash -c \
    "source '${TMP}/lib.sh'; install_tailscale_cert_save_unit sl-certs demo-1" >/dev/null 2>&1
  prep_save_helper

  PATH="${TMP}/stubs:${PATH}" bash "${TMP}/helper" >/dev/null 2>&1
  local rc=$?

  [ "$rc" -eq 0 ] || {
    echo "the save helper exited ${rc} on an empty certificate directory." >&2
    echo "That is the normal state on a rate-limited lane and after a logout;" >&2
    echo "a non-zero exit there makes the timer look broken on a healthy estate." >&2
    return 1
  }

  if grep -qiE 'DELETE|/o/[^?]*\?[^ ]*delete' "${TMP}/curl.log" 2>/dev/null; then
    echo "the save helper issued a delete against the bucket after finding no" >&2
    echo "local certificates. A logout would then destroy the persisted copy," >&2
    echo "which is the one outcome the durable store must not have. Calls:" >&2
    cat "${TMP}/curl.log" >&2
    return 1
  fi
}

@test "the save helper is upload-only — no delete verb reaches the bucket" {
  mk_harness
  PATH="${TMP}/stubs:${PATH}" bash -c \
    "source '${TMP}/lib.sh'; install_tailscale_cert_save_unit sl-certs demo-1" >/dev/null 2>&1

  # Static, and paired with the executable test above on purpose: a delete
  # could be added on a branch the empty-directory run never reaches.
  if grep -nE -- '-X[[:space:]]+DELETE|--request[[:space:]]+DELETE|DELETE' "${TMP}/helper"; then
    echo "the generated save helper contains a DELETE. The bucket is the only" >&2
    echo "copy of this lane's certificate that survives a destroy, and the node" >&2
    echo "is the least trusted thing holding a credential for it — it may write" >&2
    echo "its own prefix and must never remove from it." >&2
    return 1
  fi
}

# ── 7. Wiring holds end to end ──────────────────────────────────────────────

@test "the platform output is consumed by the environments root" {
  # A bucket nothing reads is a bucket that persists nothing.
  grep -q 'output "tailnet_cert_bucket_name"' "${BOOTSTRAP_OUT}" || {
    echo "terraform/bootstrap/outputs.tf does not export tailnet_cert_bucket_name" >&2
    return 1
  }
  # \b, and it is load-bearing. Without it this grep matches any identifier that
  # merely STARTS with the variable name — a rename to
  # `var.tailnet_cert_bucket_name_gone` still contains the searched string as a
  # substring, so the guard stayed green under exactly the mutation it exists to
  # catch. `_` is a word character, so \b refuses the longer form.
  grep -qE 'var\.tailnet_cert_bucket_name\b' "${ENV_MAIN}" || {
    echo "the environments root never reads var.tailnet_cert_bucket_name, so the" >&2
    echo "bucket exists and the VM is never told about it." >&2
    return 1
  }
  grep -q 'tailscale_cert_bucket_name = local\.tailnet_cert_bucket_name' "${ENV_MAIN}" || {
    echo "the resolved bucket name is not passed to the compute module" >&2
    return 1
  }
}

@test "the lane prefix passed to the VM is the environment key" {
  # It must equal the key the bootstrap root used to build its IAM condition, or
  # every read and write from the VM is denied by that condition.
  grep -q 'tailscale_cert_prefix      = local\.tailnet_cert_bucket_name == "" ? "" : each\.key' "${ENV_MAIN}" || {
    echo "the cert prefix passed to the compute module is not each.key. The bootstrap" >&2
    echo "root anchors its IAM condition on \"objects/\${each.key}/\", so any other" >&2
    echo "value makes every read and write from the VM Forbidden." >&2
    return 1
  }
}

@test "the compute module refuses a prefix that would widen the IAM anchor" {
  # A prefix containing a slash or ".." changes what the bootstrap root's
  # startsWith condition matches, which is a change to a security boundary
  # rather than a formatting preference.
  run bash -c "sed -n '/^variable \"tailscale_cert_prefix\"/,/^}/p' '${COMPUTE_VARS}'"
  [ "$status" -eq 0 ]
  [[ "${output}" == *"validation {"* ]] || {
    echo "tailscale_cert_prefix has no validation block" >&2
    return 1
  }
  [[ "${output}" == *"COMPUTE-RULE-08-CERT-PREFIX"* ]]
}

@test "the bucket name variable rejects a value suggesting it holds an auth key" {
  # The bucket's IAM grants every lane write access to its own prefix. That is
  # right for a TLS certificate and wrong for the credential that joins the
  # tailnet, which belongs in Secret Manager where fetch_tailscale_authkey
  # already reads it.
  run bash -c "sed -n '/^variable \"tailnet_cert_bucket_name\"/,/^}/p' '${BOOTSTRAP_VARS}'"
  [ "$status" -eq 0 ]
  # bootstrap's own convention is "<variable> validation failed: ...", not the
  # RULE-NN codes the compute module uses. Matched here rather than normalised,
  # because a suite that quietly imports another root's convention is how the
  # two drift.
  [[ "${output}" == *"tailnet_cert_bucket_name validation failed"* ]]
  [[ "${output}" == *"auth key"* ]]
}

@test "persistence is off by default in both roots" {
  # An environment that never asked for Tailscale must still plan and apply
  # cleanly — the rule tailscale_enabled already follows.
  run bash -c "sed -n '/^variable \"tailnet_cert_bucket_name\"/,/^}/p' '${BOOTSTRAP_VARS}'"
  [ "$status" -eq 0 ]
  [[ "${output}" == *'default     = ""'* ]]

  run bash -c "sed -n '/^variable \"tailscale_cert_bucket_name\"/,/^}/p' '${COMPUTE_VARS}'"
  [ "$status" -eq 0 ]
  [[ "${output}" == *'default     = ""'* ]]
}

# ── 8. Positive controls ────────────────────────────────────────────────────
#
# Every assertion above is a grep or a file check, and a grep against a file
# that moved passes or fails for reasons unrelated to the property. These prove
# the harness is looking at real, non-empty files with the expected shape — so a
# green suite above is evidence rather than an artefact of an empty read.

@test "POSITIVE CONTROL: the files under test exist and are non-trivial" {
  for f in "${STARTUP}" "${BOOTSTRAP_MAIN}" "${BOOTSTRAP_VARS}" "${BOOTSTRAP_OUT}" \
    "${ENV_MAIN}" "${COMPUTE_MAIN}" "${COMPUTE_VARS}"; do
    [ -s "${f}" ] || {
      echo "${f} is missing or empty; every assertion in this suite is vacuous" >&2
      return 1
    }
    # 20, not 50. bootstrap/outputs.tf is legitimately short — five outputs and
    # their descriptions. A floor set from the largest file in the list would
    # fail on the smallest for being itself, which is a guard failing on correct
    # code and the fastest way to get the whole control disabled.
    [ "$(wc -l <"${f}")" -gt 20 ] || {
      echo "${f} has fewer than 20 lines, which is not the file this suite expects" >&2
      return 1
    }
  done
}

@test "POSITIVE CONTROL: the harness really executes the shipped function" {
  # If mk_harness silently produced an unsourceable file, every behaviour test
  # above would run nothing and report success on the absence of a marker.
  mk_harness
  write_curl_stub
  run bash -c "source '${TMP}/lib.sh'; declare -F restore_tailscale_certs"
  [ "$status" -eq 0 ] || {
    echo "restore_tailscale_certs is not defined after sourcing the harness copy," >&2
    echo "so every behaviour test in this suite exercised nothing." >&2
    return 1
  }
}

@test "POSITIVE CONTROL: the curl stub is reached rather than the real curl" {
  mk_harness
  write_curl_stub
  run_restore sl-certs demo-1 >/dev/null

  # STUBDATA can only come from the stub. Real curl against a real bucket would
  # need network, credentials and a bucket that does not exist in this suite.
  grep -q 'STUBDATA' "${TMP}/certs/sl-demo-1.taild4da3.ts.net.key" || {
    echo "the restored file does not contain the stub's marker, so the tests were" >&2
    echo "not exercising the stubbed path they claim to." >&2
    return 1
  }
}

