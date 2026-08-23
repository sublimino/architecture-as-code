#!/usr/bin/env bats
#
# What happened when this node last asked for a TLS certificate, and what it
# does when the answer is "no".
#
# ─── The sibling suite, and why this is a separate one ──────────────────────
#
# test/terraform-tailscale-cert-persistence.bats covers the durable store: a
# rebuild restores the certificate instead of spending one of Let's Encrypt's
# five-per-168h issuances for this node's exact DNS name. That fixes the
# CAUSE, and it is a create-time change — it rewrites the VM startup script,
# so applying it replaces the instances.
#
# This suite covers what happens when a certificate cannot be had ANYWAY:
# because the lane is already inside a rate-limit window that persistence
# arrived too late to prevent, or because ACME failed for some other reason.
# Nothing here is create-time. It is the delivered tree and the doctor only.
#
# ─── The trap that makes all of this necessary ──────────────────────────────
#
#   `tailscale cert` EXITS 0 WHEN ISSUANCE FAILS THIS WAY.
#
# The 429 appears only in `journalctl -u tailscaled`. Gating on that exit
# status reports a certificate for a node that has none — the same shape as
# this repo's `stat` prints UNKNOWN and exits 0 problem, which was expensive.
# So the verdict is derived from the files and the journal, never the status,
# and a test drives both exit statuses through to prove the verdict does not
# move.
#
# ─── The two properties that are easy to get subtly wrong ───────────────────
#
# 1. WHOSE window. Let's Encrypt counts per exact set of identifiers, so each
#    lane has its own name, its own clock and its own retry-after. Quoting one
#    lane's window as the estate's cost this estate 20 hours. The journal match
#    is anchored on this node's own DNSName, and a test feeds a foreign lane's
#    429 through the parser and fails if it is adopted.
#
# 2. LOUD BUT NON-BLOCKING. A lane inside a rate-limit window must still come
#    up and still be acceptance-tested, so every path returns 0 — loud is a
#    property of the OUTPUT, not the exit code. But a silent downgrade would
#    turn a real certificate outage into a green run, so the fallback prints
#    the cause, the 429 and the retry-after, records them, and the doctor
#    reports it as its OWN non-green state: not a pass, and not the generic
#    failure arm.
#
# test/gcp-demo-tailscale-cert-state-mutation-proof.sh proves every assertion
# below can actually fail. Several are absence-of-bad assertions, trivially
# satisfied by nothing being present, and this file is not evidence of
# anything without that harness.
#
# Offline: every external command the scripts use is injectable. No tailnet,
# no VM, no systemd journal.

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  export CERT_STATE="${REPO_ROOT}/scripts/gcp-tf/tailscale-cert-state.sh"
  export DOCTOR="${REPO_ROOT}/scripts/node-doctor.sh"
  export DEMO_UP="${REPO_ROOT}/scripts/gcp-tf/demo-up.sh"
}

setup() {
  [ -f "${CERT_STATE}" ]
  [ -f "${DOCTOR}" ]
  [ -f "${DEMO_UP}" ]
}

# ── 1. The outcome is determined AT ISSUANCE TIME ──────────────────────────
#
# The requirement: at the moment issuance is attempted, actively determine and
# RECORD the outcome — issued, 429-with-retry-after, or another failure. Never
# infer it later from a curl, and never gate on `tailscale cert`'s exit status,
# which is 0 even when issuance fails this way.

cert_state_harness() {
  CS_TMP="$(mktemp -d)"
  export CS_TMP
  mkdir -p "${CS_TMP}/certs"

  # `tailscale` stub. CERT_EXIT is the trap under test: the real command exits 0
  # on a 429, so the script must not consult it either way.
  cat >"${CS_TMP}/tailscale" <<STUB
#!/bin/sh
case "\$1" in
  status) printf '{"Self":{"DNSName":"sl-ci-1.taild4da3.ts.net."}}' ;;
  cert)   exit \${CERT_EXIT:-0} ;;
  serve)  echo "\$*" >>"${CS_TMP}/serve.log"; exit 0 ;;
esac
STUB

  # `journalctl` stub. JOURNAL_MODE picks what tailscaled "said".
  cat >"${CS_TMP}/journalctl" <<'STUB'
#!/bin/sh
case "${JOURNAL_MODE:-429}" in
  429)
    echo 'vm tailscaled[1]: cert("sl-ci-1.taild4da3.ts.net"): getCertPEM: 429 urn:ietf:params:acme:error:rateLimited: too many certificates (5) already issued for this exact set of identifiers in the last 168h0m0s, retry after 2026-08-23 16:00:00 UTC: see https://letsencrypt.org/docs/rate-limits/'
    ;;
  other)
    echo 'vm tailscaled[1]: cert("sl-ci-1.taild4da3.ts.net"): getCertPEM: 403 urn:ietf:params:acme:error:unauthorized: DNS problem'
    ;;
  otherlane)
    # A 429 belonging to a DIFFERENT lane. Must NOT be adopted as this one's.
    echo 'vm tailscaled[1]: cert("sl-demo-1.taild4da3.ts.net"): getCertPEM: 429 urn:ietf:params:acme:error:rateLimited: retry after 2026-08-22 20:07:00 UTC: see https://letsencrypt.org/docs/rate-limits/'
    ;;
  silent) : ;;
esac
STUB
  chmod +x "${CS_TMP}/tailscale" "${CS_TMP}/journalctl"
}

run_cert_state() {
  SIGNALLOOM_TAILSCALE_CMD="${CS_TMP}/tailscale" \
  SIGNALLOOM_JOURNALCTL_CMD="${CS_TMP}/journalctl" \
  SIGNALLOOM_TS_CERT_DIR="${CS_TMP}/certs" \
  SIGNALLOOM_TS_CERT_STATE="${CS_TMP}/state.json" \
  SIGNALLOOM_APP_PORT=30754 \
  SIGNALLOOM_CERT_STATE_SETTLE=0 \
    bash "${REPO_ROOT}/scripts/gcp-tf/tailscale-cert-state.sh" 2>&1
}

# Mints a real certificate so the openssl validity check has something true to
# check. A fabricated file would make cert_is_valid's -checkend arm untestable.
mint_cert() {
  local days="$1" fq=sl-ci-1.taild4da3.ts.net
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${CS_TMP}/certs/${fq}.key" \
    -out "${CS_TMP}/certs/${fq}.crt" \
    -days "$days" -subj "/CN=${fq}" >/dev/null 2>&1
}

cert_state_teardown() {
  [ -n "${CS_TMP:-}" ] && rm -rf "${CS_TMP}"
  return 0
}

@test "a 429 is recorded as rate_limited with THIS lane's retry-after" {
  cert_state_harness
  run_cert_state >/dev/null

  grep -q '"state": "rate_limited"' "${CS_TMP}/state.json" || {
    echo "state was not recorded as rate_limited:" >&2; cat "${CS_TMP}/state.json" >&2; return 1
  }
  grep -q '"retry_after": "2026-08-23 16:00:00"' "${CS_TMP}/state.json" || {
    echo "the retry-after was not extracted from the journal:" >&2; cat "${CS_TMP}/state.json" >&2; return 1
  }
  cert_state_teardown
}

@test "another lane's 429 is NOT adopted as this lane's window" {
  # The limit is per exact DNS name. Reporting one lane's window as another's
  # is the error that cost this estate 20 hours, so the journal match is
  # anchored on this node's own name.
  cert_state_harness
  JOURNAL_MODE=otherlane run_cert_state >/dev/null

  if grep -q '2026-08-22 20:07:00' "${CS_TMP}/state.json"; then
    echo "sl-demo-1's retry-after was recorded as sl-ci-1's:" >&2
    cat "${CS_TMP}/state.json" >&2
    return 1
  fi
  grep -q '"state": "rate_limited"' "${CS_TMP}/state.json" && {
    echo "a 429 for a DIFFERENT name was treated as this lane being rate limited" >&2
    return 1
  }
  cert_state_teardown
}

@test "the outcome is NOT gated on tailscale cert's exit status" {
  # `tailscale cert` EXITS 0 when issuance fails with a 429, and non-zero for
  # unrelated reasons. Either way the journal is the source of truth, so the
  # recorded state must be identical whichever way the command exits.
  cert_state_harness
  run_cert_state >/dev/null
  local zero; zero="$(cat "${CS_TMP}/state.json")"
  cert_state_teardown

  cert_state_harness
  CERT_EXIT=1 run_cert_state >/dev/null
  local nonzero; nonzero="$(cat "${CS_TMP}/state.json")"
  cert_state_teardown

  # checked_at differs by design; the verdict must not.
  local a b
  a="$(printf '%s' "$zero"    | grep -v checked_at)"
  b="$(printf '%s' "$nonzero" | grep -v checked_at)"
  [ "$a" = "$b" ] || {
    echo "the recorded state changed with tailscale cert's exit status." >&2
    echo "exit 0:   $a" >&2
    echo "exit 1:   $b" >&2
    echo "That command exits 0 on a 429, so gating on it reports a certificate" >&2
    echo "this node does not have." >&2
    return 1
  }
}

@test "the HTTP fallback is applied when no certificate can be obtained" {
  cert_state_harness
  run_cert_state >/dev/null

  grep -q -- '--http=80' "${CS_TMP}/serve.log" || {
    echo "no plain-HTTP serve was configured. serve calls were:" >&2
    cat "${CS_TMP}/serve.log" 2>/dev/null >&2
    return 1
  }
  # reset first, or a dead HTTPS listener survives alongside the new HTTP one
  # and :443 keeps stalling instead of failing cleanly.
  head -n 1 "${CS_TMP}/serve.log" | grep -q 'reset' || {
    echo "serve was not reset before the fallback was applied:" >&2
    cat "${CS_TMP}/serve.log" >&2
    return 1
  }
  cert_state_teardown
}

@test "the fallback is LOUD — cause, the 429, and the retry-after" {
  cert_state_harness
  local out; out="$(run_cert_state)"
  cert_state_teardown

  [[ "${out}" == *"WARNING"* ]]
  [[ "${out}" == *"SERVING OVER PLAIN HTTP"* ]] || {
    echo "the downgrade was not announced. A silent fallback turns a real" >&2
    echo "certificate outage into a green run." >&2
    return 1
  }
  [[ "${out}" == *"429"* ]]
  [[ "${out}" == *"2026-08-23 16:00:00"* ]] || {
    echo "the retry-after was not printed, so nobody can tell when to retry" >&2
    return 1
  }
}

@test "the fallback is NON-BLOCKING — exit 0 so the suite carries on" {
  # Explicitly required: a certificate failure must not abort the estate or the
  # suite. Loud is a property of the OUTPUT; the exit status must stay 0.
  cert_state_harness
  SIGNALLOOM_TAILSCALE_CMD="${CS_TMP}/tailscale" \
  SIGNALLOOM_JOURNALCTL_CMD="${CS_TMP}/journalctl" \
  SIGNALLOOM_TS_CERT_DIR="${CS_TMP}/certs" \
  SIGNALLOOM_TS_CERT_STATE="${CS_TMP}/state.json" \
  SIGNALLOOM_APP_PORT=30754 SIGNALLOOM_CERT_STATE_SETTLE=0 \
    bash "${REPO_ROOT}/scripts/gcp-tf/tailscale-cert-state.sh" >/dev/null 2>&1
  local rc=$?
  cert_state_teardown

  [ "$rc" -eq 0 ] || {
    echo "the cert-state probe exited ${rc} on the fallback path. A rate-limit" >&2
    echo "window would then block acceptance testing of everything else." >&2
    return 1
  }
}

@test "a valid certificate is recorded as issued and serves HTTPS" {
  cert_state_harness
  mint_cert 30
  run_cert_state >/dev/null

  grep -q '"state": "issued"' "${CS_TMP}/state.json" || {
    echo "a valid certificate was not recorded as issued:" >&2
    cat "${CS_TMP}/state.json" >&2
    return 1
  }
  grep -q -- '--https=443' "${CS_TMP}/serve.log"
  cert_state_teardown
}

@test "an EXPIRED restored certificate is not mistaken for a usable one" {
  # The failure mode persistence itself creates. Certs last ~90 days and a
  # persisted one is restored on every rebuild, so an estate left idle restores
  # an expired certificate. Treating presence as validity would leave tailscaled
  # serving something browsers refuse AND never trigger the fallback — strictly
  # worse than having no certificate at all.
  cert_state_harness
  mint_cert 1
  # Backdate past expiry using openssl's own notion of time.
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${CS_TMP}/certs/sl-ci-1.taild4da3.ts.net.key" \
    -out "${CS_TMP}/certs/sl-ci-1.taild4da3.ts.net.crt" \
    -subj "/CN=sl-ci-1.taild4da3.ts.net" \
    -not_before 20200101000000Z -not_after 20200102000000Z >/dev/null 2>&1 || skip "openssl lacks -not_after"

  run_cert_state >/dev/null

  if grep -q '"state": "issued"' "${CS_TMP}/state.json"; then
    echo "an EXPIRED certificate was recorded as issued:" >&2
    cat "${CS_TMP}/state.json" >&2
    return 1
  fi
  grep -q -- '--http=80' "${CS_TMP}/serve.log" || {
    echo "an expired certificate did not trigger the HTTP fallback" >&2
    return 1
  }
  cert_state_teardown
}

@test "a non-429 failure is recorded distinctly, not as a rate limit" {
  cert_state_harness
  JOURNAL_MODE=other run_cert_state >/dev/null

  grep -q '"state": "unavailable"' "${CS_TMP}/state.json" || {
    echo "a non-rate-limit failure was not recorded as 'unavailable':" >&2
    cat "${CS_TMP}/state.json" >&2
    return 1
  }
  grep -q '"state": "rate_limited"' "${CS_TMP}/state.json" && {
    echo "a 403 was reported as a rate limit, which names the wrong remedy" >&2
    return 1
  }
  cert_state_teardown
}

@test "the recorded state file carries no key material" {
  cert_state_harness
  mint_cert 30
  run_cert_state >/dev/null

  local body; body="$(cat "${CS_TMP}/state.json")"
  cert_state_teardown

  if [[ "${body}" == *"BEGIN "* || "${body}" == *"PRIVATE KEY"* ]]; then
    echo "the state file contains key material" >&2
    return 1
  fi
}

# ── 2. node-doctor tells the four 000s apart ───────────────────────────────

nd_classifier() {
  # The REAL function, extracted from the shipped file. A reimplementation here
  # would agree with itself no matter what node-doctor does.
  bash -c "$(sed -n '/^nd_classify_tailnet()/,/^}/p' "${REPO_ROOT}/scripts/node-doctor.sh"); nd_classify_tailnet '$1' '$2'"
}

@test "node-doctor classifies all five tailnet states from real measurements" {
  # Every row measured against the live estate 2026-08-23 — see the comment
  # above probe_tailnet_detail in scripts/node-doctor.sh.
  [ "$(nd_classifier '200:0'  '000:7')" = "HTTPS_OK" ]
  [ "$(nd_classifier '000:28' '200:0')" = "HTTP_FALLBACK" ]
  [ "$(nd_classifier '000:28' '000:7')" = "TLS_NEVER_COMPLETES" ]
  [ "$(nd_classifier '000:6'  '000:6')" = "NAME_UNRESOLVED" ]
  [ "$(nd_classifier '000:7'  '000:7')" = "NOTHING_SERVING" ]
}

@test "HTTP fallback is its own state — not HTTPS_OK and not a generic failure" {
  # The requirement in one assertion. If HTTP_FALLBACK ever collapses into
  # HTTPS_OK a certificate outage reports green; if it collapses into the
  # generic failure arm, an EXPECTED rate-limit window fails the whole run.
  local s; s="$(nd_classifier '000:28' '200:0')"
  [ "$s" = "HTTP_FALLBACK" ]
  [ "$s" != "HTTPS_OK" ]
  [ "$s" != "TLS_NEVER_COMPLETES" ]
  [ "$s" != "NOTHING_SERVING" ]
}

@test "the HTTP fallback arm routes to nd_degraded, not nd_warn or nd_fail" {
  # COMMENTS ARE STRIPPED, and that is load bearing rather than tidy. The arm
  # carries a long comment explaining why nd_degraded and not nd_warn — so a
  # grep over the raw block matches the PROSE and stays green when the call
  # itself is changed to nd_pass. Caught by mutation, 2026-08-23; it is the
  # same shape as this repo's guard-satisfied-by-its-own-explanation defects.
  local block
  block="$(sed -n '/HTTP_FALLBACK)/,/;;/p' "${REPO_ROOT}/scripts/node-doctor.sh" \
    | grep -vE '^[[:space:]]*#')"
  [ -n "${block}" ] || {
    echo "node-doctor has no HTTP_FALLBACK arm at all" >&2
    return 1
  }
  [[ "${block}" == *"nd_degraded"* ]] || {
    echo "the HTTP_FALLBACK arm does not call nd_degraded. nd_warn is NOT a" >&2
    echo "substitute: that counter does not move the summary verdict, so the" >&2
    echo "lane would report HEALTHY while serving no TLS at all." >&2
    return 1
  }
  [[ "${block}" == *"nd_fail"* ]] && {
    echo "the HTTP_FALLBACK arm calls nd_fail, so an EXPECTED rate-limit window" >&2
    echo "fails the run. A run that reports red for the expected condition is as" >&2
    echo "bad as one that reports green for a broken one." >&2
    return 1
  }
  return 0
}

@test "one degraded check makes the SUMMARY VERDICT non-green without failing" {
  # The assertion that the source-grep above cannot make. A call site can name
  # the right reporter and still summarise as HEALTHY if that reporter feeds a
  # counter the verdict ignores — which is exactly what nd_warn does, and what
  # this arm did in its first draft. So this runs the real nd_summary and reads
  # the machine-readable line the sweep consumes.
  local out rc
  out="$(
    set +u
    . "${REPO_ROOT}/scripts/node-doctor/lib.sh"
    nd_pass "a check that really passed" >/dev/null
    nd_degraded "serving over HTTP because the certificate is unavailable" >/dev/null
    nd_summary demo-1 demo
  )" && rc=0 || rc=$?

  local line
  line="$(printf '%s\n' "$out" | grep '^NODE-DOCTOR ' | tail -n 1)"
  [ -n "$line" ] || { echo "no machine-readable verdict line was emitted" >&2; return 1; }

  [[ "$line" == *" DEGRADED "* ]] || {
    echo "a degraded check did not produce a DEGRADED verdict. The line was:" >&2
    echo "  ${line}" >&2
    echo "The sweep reads this token. Any other value here means a certificate" >&2
    echo "outage is reported as something it is not." >&2
    return 1
  }
  [[ "$line" == *" PASS "* ]] && {
    echo "the verdict is PASS despite a degraded check: ${line}" >&2
    return 1
  }
  [[ "$line" == *"degraded=1"* ]] || {
    echo "the degraded count is not carried on the verdict line: ${line}" >&2
    return 1
  }

  # rc=0 ON PURPOSE, and asserted so it cannot drift. `make doctor-node-all`
  # propagates this, so a non-zero status here would fail the sweep and block
  # acceptance testing on a condition that cannot be fixed for up to 168h.
  # Visibility is the VERDICT TOKEN's job, not the exit status's.
  [ "$rc" -eq 0 ] || {
    echo "nd_summary exited ${rc} on a degraded-only run. That fails the sweep," >&2
    echo "which is the outcome the non-blocking requirement rules out." >&2
    return 1
  }
}

@test "a degraded check does not mask a real failure" {
  # FAIL must still win. Otherwise the new arm becomes a way to downgrade any
  # genuine fault that happens to share a run with a certificate outage.
  local out rc
  out="$(
    set +u
    . "${REPO_ROOT}/scripts/node-doctor/lib.sh"
    nd_degraded "serving over HTTP because the certificate is unavailable" >/dev/null
    nd_fail "something genuinely broken" >/dev/null
    nd_summary demo-1 demo
  )" && rc=0 || rc=$?

  printf '%s\n' "$out" | grep '^NODE-DOCTOR ' | grep -q ' FAIL ' || {
    echo "a real failure alongside a degraded check did not report FAIL:" >&2
    printf '%s\n' "$out" | grep '^NODE-DOCTOR ' >&2
    return 1
  }
  [ "$rc" -ne 0 ] || {
    echo "nd_summary exited 0 despite a failed check" >&2
    return 1
  }
}

@test "the TLS-never-completes arm names the cert as the cause" {
  # From curl alone this state is byte-identical to 'not on the tailnet'. The
  # whole value of the arm is saying which one it is.
  local block
  block="$(sed -n '/TLS_NEVER_COMPLETES)/,/;;/p' "${REPO_ROOT}/scripts/node-doctor.sh")"
  [[ "${block}" == *"CERTIFICATE"* || "${block}" == *"certificate"* ]]
  [[ "${block}" == *"getCertPEM"* ]]
}

# ── 3. The deploy path runs the probe and is never blocked by it ───────────

@test "demo-up runs the certificate-state probe" {
  # \b anchored: without it a rename to assert_tailnet_cert_state_REMOVED
  # still CONTAINS the searched string and the guard stays green under exactly
  # the mutation it exists to catch. Same substring trap as the bucket-variable
  # assertion above; `_` is a word character, so \b refuses the longer form.
  grep -qE 'assert_tailnet_cert_state\b' "${REPO_ROOT}/scripts/gcp-tf/demo-up.sh" || {
    echo "demo-up.sh never determines the certificate state, so a lane can" >&2
    echo "finish a run serving plain HTTP with nothing recording that." >&2
    return 1
  }
}

@test "the certificate-state probe can never fail a deploy" {
  # Non-blocking is a hard requirement, and the guard is the `|| warn` at the
  # call site. Asserted on the call line rather than trusted.
  local call
  call="$(grep -A1 '^  assert_tailnet_cert_state' "${REPO_ROOT}/scripts/gcp-tf/demo-up.sh")"
  [[ "${call}" == *"||"* ]] || {
    echo "assert_tailnet_cert_state is called without a '|| warn' guard, so a" >&2
    echo "certificate outage can abort the deploy. A lane inside a 168h" >&2
    echo "rate-limit window must still finish and still be tested." >&2
    return 1
  }
  [[ "${call}" == *"warn"* ]]
}

@test "POSITIVE CONTROL: the cert-state script exists and is executable" {
  [ -x "${REPO_ROOT}/scripts/gcp-tf/tailscale-cert-state.sh" ] || {
    echo "scripts/gcp-tf/tailscale-cert-state.sh is missing or not executable;" >&2
    echo "every assertion in section 9 is vacuous" >&2
    return 1
  }
  run bash -n "${REPO_ROOT}/scripts/gcp-tf/tailscale-cert-state.sh"
  [ "$status" -eq 0 ]
}
