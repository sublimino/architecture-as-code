#!/usr/bin/env bash
#
# Determines this node's TLS certificate state AT ISSUANCE TIME, records it, and
# falls back to plain HTTP over the tailnet when no certificate can be had.
#
# Runs ON THE VM. Delivered with the repo and invoked at boot by
# signalloom-tailscale-cert-state.service (installed by demo-vm.sh), and safely
# re-runnable by hand at any time.
#
# ═══ WHY THE EXIT STATUS OF `tailscale cert` IS NEVER CONSULTED ═════════════
#
# Because it lies. `tailscale cert` EXITS 0 when issuance fails this way; the
# 429 appears only in `journalctl -u tailscaled`. Gating on the exit status
# therefore reports "certificate obtained" for a node that has none — the same
# shape as this repo's `stat` prints UNKNOWN and exits 0 problem, and the
# reason that one was expensive.
#
# So the state is derived from two things that cannot lie:
#
#   1. the FILES — is there a cert on disk, and is it currently valid;
#   2. the JOURNAL — what did tailscaled say when we just asked it.
#
# ═══ WHY THE JOURNAL IS READ FROM A CURSOR, NOT FROM ALL OF TIME ════════════
#
# A 429 from yesterday is not evidence about today. This script records the
# journal position BEFORE the issuance attempt and reads only what appears
# AFTER it, so the recorded verdict describes the attempt it just made. Reading
# the whole journal would resurrect a stale rate-limit window and report a lane
# as blocked hours after it recovered — which is exactly the mistake that cost
# this estate 20 hours when one lane's window was quoted as the estate's.
#
# ═══ THE RATE LIMIT IS PER EXACT DNS NAME, SO PER LANE ══════════════════════
#
# Let's Encrypt counts certificates per exact set of identifiers. Each lane has
# its own name and therefore its own clock and its own retry-after. Measured
# 2026-08-22/23: demo-1 retry-after 20:07 UTC (since rolled — it now serves
# HTTPS), ci-1 retry-after ~16:00 UTC 2026-08-23. NEVER report one lane's
# window as the estate's; this script only ever writes the window belonging to
# the node it is running on.
#
# ═══ THE FALLBACK IS LOUD AND NON-BLOCKING ══════════════════════════════════
#
# A node that cannot get a certificate still serves — over plain HTTP on the
# tailnet, which is defensible because tailnet traffic is already WireGuard
# encrypted end to end. This exists so a rate-limit window does not block
# acceptance testing of everything else.
#
# It must never be silent. A quiet downgrade converts a real certificate outage
# into a green run, which is the vacuous-pass shape this repo has been bitten by
# repeatedly. So:
#
#   * every fallback prints a WARNING naming the cause, the 429 and the
#     retry-after;
#   * the state is written to a file the doctor and the tests read, as its OWN
#     value — never collapsed into "up" and never into the generic failure arm;
#   * the exit status stays 0 on the fallback path, because the caller must
#     CARRY ON. Loud is a property of the output, not of the exit code.
#
# Offline-testable: every external command is overridable, see the block below.

set -uo pipefail

# ─── Injectable boundaries ──────────────────────────────────────────────────
#
# Every external dependency is overridable so the bats suite can exercise this
# without a tailnet, a VM, or a systemd journal.
TS_CMD="${SIGNALLOOM_TAILSCALE_CMD:-tailscale}"
JOURNAL_CMD="${SIGNALLOOM_JOURNALCTL_CMD:-journalctl}"
OPENSSL_CMD="${SIGNALLOOM_OPENSSL_CMD:-openssl}"

CERT_DIR="${SIGNALLOOM_TS_CERT_DIR:-/var/lib/tailscale/certs}"
STATE_FILE="${SIGNALLOOM_TS_CERT_STATE:-/var/lib/signalloom/tailscale-cert-state.json}"
APP_PORT="${SIGNALLOOM_APP_PORT:-}"
FQDN="${SIGNALLOOM_TS_FQDN:-}"

# Whether to actually reconfigure `tailscale serve`. The bats suite sets this
# false so it can assert on the DECISION without a tailnet.
APPLY="${SIGNALLOOM_CERT_STATE_APPLY:-true}"

log()  { printf '[signalloom-cert-state] %s\n' "$*"; }
warn() { printf '[signalloom-cert-state] WARNING: %s\n' "$*" >&2; }

# ─── Discover this node's own name ──────────────────────────────────────────
#
# From `tailscale status --json`, never from the hostname: the tailnet suffix is
# not derivable locally, and a node whose name drifted (sl-demo-1 -> sl-demo-1-1)
# must report the name it ACTUALLY has, or the certificate state recorded here
# describes a name nothing is served on.
resolve_fqdn() {
  [ -z "$FQDN" ] || { printf '%s' "$FQDN"; return 0; }

  local json name
  json="$("$TS_CMD" status --json 2>/dev/null)" || return 1
  name="$(printf '%s' "$json" \
    | tr ',' '\n' \
    | sed -n 's/.*"DNSName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1)"
  name="${name%.}"

  [ -n "$name" ] || return 1
  printf '%s' "$name"
}

# ─── Is there a VALID certificate on disk right now? ────────────────────────
#
# Presence is not validity. A restored certificate can be PAST ITS EXPIRY —
# certs last ~90 days and a persisted one is restored on every rebuild, so an
# estate left idle for three months restores an expired certificate. Treating
# that as "have a cert" would leave tailscaled serving something browsers
# refuse, which is worse than having none because it never triggers the
# fallback. `openssl -checkend 0` is what distinguishes the two.
cert_is_valid() {
  local fqdn="$1" crt="${CERT_DIR}/${1}.crt" key="${CERT_DIR}/${1}.key"

  [ -s "$crt" ] || return 1
  [ -s "$key" ] || return 1

  # -checkend 0 exits non-zero if the certificate has ALREADY expired. This is
  # one of the few exit statuses in this script that is trustworthy, and it is
  # still paired with a file-size check above so a truncated file cannot pass.
  "$OPENSSL_CMD" x509 -in "$crt" -noout -checkend 0 >/dev/null 2>&1
}

# ─── Ask tailscaled for a certificate, then read what it SAID ───────────────
#
# The return value of the tailscale command is deliberately discarded — see the
# header. What matters is what lands in the journal after this moment.
attempt_issuance() {
  local fqdn="$1"

  # Cursor first. Everything read afterwards is attributable to this attempt.
  local since
  since="$(date -u '+%Y-%m-%d %H:%M:%S')"

  # Output to /dev/null: this script must never write key material anywhere
  # except the directory tailscaled already owns. `|| true` because the exit
  # status is meaningless here and errexit is not wanted for it either.
  "$TS_CMD" cert --cert-file /dev/null --key-file /dev/null "$fqdn" >/dev/null 2>&1 || true

  printf '%s' "$since"
}

# Extracts the retry-after from the most recent 429 for THIS name since the
# cursor. Empty when there is no such line.
journal_retry_after() {
  local fqdn="$1" since="$2" line

  line="$("$JOURNAL_CMD" -u tailscaled --no-pager --since "$since" 2>/dev/null \
    | grep -F "cert(\"${fqdn}\")" 2>/dev/null \
    | grep -F 'rateLimited' 2>/dev/null \
    | tail -n 1)" || line=""

  [ -n "$line" ] || return 1

  printf '%s' "$line" | sed -n 's/.*retry after \([0-9-]* [0-9:]*\) UTC.*/\1/p'
}

# Any non-429 complaint about this name since the cursor, for the "unavailable
# for another reason" arm. Reported verbatim rather than summarised, because a
# cause this script has never seen before is exactly the one worth reading.
journal_other_error() {
  local fqdn="$1" since="$2"

  "$JOURNAL_CMD" -u tailscaled --no-pager --since "$since" 2>/dev/null \
    | grep -F "cert(\"${fqdn}\")" 2>/dev/null \
    | grep -Fv 'rateLimited' 2>/dev/null \
    | grep -F 'getCertPEM' 2>/dev/null \
    | tail -n 1
}

write_state() {
  local state="$1" fqdn="$2" retry="$3" detail="$4"

  mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true

  # Hand-written JSON because jq is not a prerequisite on these VMs. The four
  # interpolated values are a fixed enum, a DNS name, a timestamp and a journal
  # line; the journal line is the only one that could contain a quote, so it is
  # escaped rather than trusted.
  local safe_detail
  safe_detail="$(printf '%s' "$detail" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n')"

  cat >"$STATE_FILE" <<JSON
{
  "state": "${state}",
  "fqdn": "${fqdn}",
  "retry_after": "${retry}",
  "checked_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "detail": "${safe_detail}"
}
JSON

  # World-readable ON PURPOSE, unlike the certificate itself: node-doctor and
  # the acceptance tests read this, it contains no key material, and a state
  # file only root can read is a state file nothing reports on.
  chmod 0644 "$STATE_FILE" 2>/dev/null || true
}

# ─── Serve configuration ────────────────────────────────────────────────────
#
# HTTPS on 443 when there is a certificate, plain HTTP on 80 when there is not.
#
# `tailscale serve reset` first: serve config is additive, so a node that was
# serving HTTPS and has now lost its certificate would otherwise keep the dead
# HTTPS listener alongside the new HTTP one — and a probe of :443 would still
# hang rather than fail cleanly, which is the state that is byte-identical to
# "not on the tailnet at all".
apply_serve() {
  local mode="$1" port="$2"

  if [ "$APPLY" != "true" ]; then
    log "APPLY is false, not reconfiguring serve (would have chosen: ${mode})"
    return 0
  fi

  if [ -z "$port" ]; then
    warn "no app port known, cannot configure serve"
    return 1
  fi

  "$TS_CMD" serve reset >/dev/null 2>&1 || true

  if [ "$mode" = "https" ]; then
    "$TS_CMD" serve --bg --https=443 "http://127.0.0.1:${port}" >/dev/null 2>&1
    return $?
  fi

  "$TS_CMD" serve --bg --http=80 "http://127.0.0.1:${port}" >/dev/null 2>&1
}

main() {
  local fqdn
  fqdn="$(resolve_fqdn)" || {
    warn "this node is not on the tailnet, or tailscaled is not answering."
    warn "no certificate state can be determined; recording 'unknown'."
    write_state "unknown" "" "" "tailscale status returned no DNSName"
    # Exit 0: the caller must carry on. See the header — loud is a property of
    # the output, not of the exit status.
    return 0
  }

  log "node is ${fqdn}"

  if [ -z "$APP_PORT" ]; then
    APP_PORT="$(curl --fail --silent --show-error \
      --header 'Metadata-Flavor: Google' \
      'http://169.254.169.254/computeMetadata/v1/instance/attributes/signalloom-app-port' \
      2>/dev/null)" || APP_PORT=""
  fi

  # Already holding a valid certificate: nothing to attempt, nothing to warn
  # about. Recorded explicitly rather than by silence, so a test can tell
  # "checked and healthy" from "never checked".
  if cert_is_valid "$fqdn"; then
    log "a valid certificate is present for ${fqdn}"
    write_state "issued" "$fqdn" "" "certificate present and not expired"
    apply_serve https "$APP_PORT" || warn "could not configure HTTPS serve"
    return 0
  fi

  log "no valid certificate for ${fqdn}; asking tailscaled for one now"

  local since retry other
  since="$(attempt_issuance "$fqdn")"

  # Give tailscaled a moment to log the outcome. The ACME round trip is not
  # instant and the journal is written by a different process than the one the
  # CLI returned from, so reading immediately races the log.
  sleep "${SIGNALLOOM_CERT_STATE_SETTLE:-5}"

  # It may simply have worked.
  if cert_is_valid "$fqdn"; then
    log "certificate obtained for ${fqdn}"
    write_state "issued" "$fqdn" "" "certificate obtained on this attempt"
    apply_serve https "$APP_PORT" || warn "could not configure HTTPS serve"
    return 0
  fi

  if retry="$(journal_retry_after "$fqdn" "$since")" && [ -n "$retry" ]; then
    write_state "rate_limited" "$fqdn" "$retry" "Let's Encrypt returned 429 for this exact name"

    warn "═══════════════════════════════════════════════════════════════"
    warn "SERVING OVER PLAIN HTTP — no TLS certificate could be obtained."
    warn ""
    warn "  node          ${fqdn}"
    warn "  cause         Let's Encrypt 429 rateLimited"
    warn "                5 certificates already issued for this EXACT name"
    warn "                in the last 168h. The name outlives the disk, so"
    warn "                rebuilding does not reset this — rebuilding is what"
    warn "                consumes it."
    warn "  retry after   ${retry} UTC   (this lane only — every lane has its"
    warn "                own name and therefore its own window)"
    warn ""
    warn "  The tailnet URL is now  http://${fqdn}/  (port 80, NOT https)."
    warn "  Tailnet traffic is WireGuard-encrypted end to end, so this is"
    warn "  safe on the tailnet — but it is NOT the intended posture and it"
    warn "  must not be reported as a healthy HTTPS surface."
    warn ""
    warn "  state recorded at ${STATE_FILE}"
    warn "═══════════════════════════════════════════════════════════════"

    apply_serve http "$APP_PORT" || warn "could not configure the HTTP fallback"
    return 0
  fi

  other="$(journal_other_error "$fqdn" "$since")"
  write_state "unavailable" "$fqdn" "" "${other:-no certificate and no explanatory journal line}"

  warn "═══════════════════════════════════════════════════════════════"
  warn "SERVING OVER PLAIN HTTP — no TLS certificate could be obtained."
  warn ""
  warn "  node    ${fqdn}"
  warn "  cause   NOT a rate limit. tailscaled logged:"
  warn "          ${other:-(nothing about this name since the attempt)}"
  warn ""
  warn "  The tailnet URL is now  http://${fqdn}/  (port 80, NOT https)."
  warn "  state recorded at ${STATE_FILE}"
  warn "═══════════════════════════════════════════════════════════════"

  apply_serve http "$APP_PORT" || warn "could not configure the HTTP fallback"
  return 0
}

main "$@"
