#!/usr/bin/env bash
# ==============================================================================
# scripts/eap/emit-eap-webhook.sh
# Synthetic Webhook Emitter CLI for Signal Loom EAP Environment Triggering
#
# Generates authenticated GitHub and generic webhook payloads with HMAC-SHA256
# signatures, timestamp drift protection, and negative security tamper modes.
#
# Usage:
#   emit-eap-webhook.sh github-pr --company kurasi --pr 42 --action opened [--dry-run]
#   emit-eap-webhook.sh generic --company kurasi --action provision --ttl 120 [--dry-run]
#   emit-eap-webhook.sh tamper --company kurasi --pr 42 --action opened
#   emit-eap-webhook.sh hash kurasi
# ==============================================================================
set -euo pipefail

DEFAULT_SECRET="${EAP_WEBHOOK_SECRET:-signalloom-eap-webhook-secret-dev-2026-q3}"
DEFAULT_BASE_URL="${EAP_BASE_URL:-http://localhost:8080}"
SALT="${EAP_SALT:-signalloom-eap-salt-2026-q3}"

compute_hash() {
    local company="${1:-kurasi}"
    local salted="${SALT}:${company}"
    if command -v sha256sum >/dev/null 2>&1; then
        printf "%s" "$salted" | sha256sum | cut -c1-8
    elif command -v shasum >/dev/null 2>&1; then
        printf "%s" "$salted" | shasum -a 256 | cut -c1-8
    else
        python3 -c "import hashlib; print(hashlib.sha256(b'$salted').hexdigest()[:8])"
    fi
}

compute_hmac() {
    local data="$1"
    local secret="$2"
    if command -v openssl >/dev/null 2>&1; then
        printf "%s" "$data" | openssl dgst -sha256 -hmac "$secret" | awk '{print $NF}'
    else
        python3 -c "import hmac, hashlib; print(hmac.new(b'$secret', '''$data'''.encode('utf-8'), hashlib.sha256).hexdigest())"
    fi
}

usage() {
    cat <<'EOF'
Signal Loom EAP Webhook Emitter CLI (SLTE)

Subcommands:
  github-pr    Simulate GitHub pull_request webhook delivery (opened, synchronize, closed)
  generic      Simulate Signal Loom generic webhook event delivery
  tamper       Simulate adversarial forged/tampered signature delivery
  hash         Compute salted 8-char customer hash

Options for github-pr:
  --company <name>     Customer/tenant company name (e.g. kurasi) [default: kurasi]
  --pr <number>        Pull request number [default: 42]
  --action <act>       PR action (opened, synchronize, closed) [default: opened]
  --endpoint <url>     Webhook target endpoint [default: $EAP_BASE_URL/api/v1/webhooks/github]
  --secret <str>       HMAC secret string [default: $EAP_WEBHOOK_SECRET]
  --dry-run            Print headers and payload without sending HTTP request

Options for generic:
  --company <name>     Customer/tenant company name [default: kurasi]
  --action <act>       Event action (provision, teardown) [default: provision]
  --ttl <minutes>      Environment TTL in minutes [default: 120]
  --endpoint <url>     Webhook target endpoint [default: $EAP_BASE_URL/api/v1/webhooks/generic]
  --secret <str>       HMAC secret string [default: $EAP_WEBHOOK_SECRET]
  --dry-run            Print headers and payload without sending HTTP request

Options for tamper:
  Same as github-pr, but corrupts the HMAC signature before transmission.

Examples:
  emit-eap-webhook.sh github-pr --company kurasi --pr 101 --action opened --dry-run
  emit-eap-webhook.sh generic --company kurasi --action provision --ttl 60
  emit-eap-webhook.sh hash kurasi  # prints: 6f82ad81
EOF
    exit "${1:-0}"
}

cmd_github_pr() {
    local company="kurasi"
    local pr="42"
    local action="opened"
    local endpoint="${DEFAULT_BASE_URL}/api/v1/webhooks/github"
    local secret="$DEFAULT_SECRET"
    local dry_run=0
    local tamper=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --company) company="$2"; shift 2 ;;
            --pr) pr="$2"; shift 2 ;;
            --action) action="$2"; shift 2 ;;
            --endpoint) endpoint="$2"; shift 2 ;;
            --secret) secret="$2"; shift 2 ;;
            --dry-run) dry_run=1; shift ;;
            --tamper) tamper=1; shift ;;
            --help|-h) usage 0 ;;
            *) echo "Unknown option: $1" >&2; usage 2 ;;
        esac
    done

    local delivery_id
    delivery_id="del-$(date +%s%N | cut -c1-12)"
    local state="open"
    if [[ "$action" == "closed" ]]; then
        state="closed"
    fi

    # Build canonical JSON payload
    local payload
    payload=$(cat <<EOF
{"action":"${action}","number":${pr},"pull_request":{"number":${pr},"state":"${state}","title":"EAP Integration Test PR #${pr}","head":{"ref":"feat/eap-preview-${pr}","sha":"a1b2c3d4e5f67890123456789abcdef012345678"}},"repository":{"name":"${company}-service","full_name":"org/${company}-service"}}
EOF
)

    local sig
    sig=$(compute_hmac "$payload" "$secret")
    if [[ "$tamper" -eq 1 ]]; then
        # Corrupt first character of signature hex
        sig="0000${sig:4}"
    fi

    local header_sig="sha256=${sig}"

    if [[ "$dry_run" -eq 1 ]]; then
        echo "=== DRY RUN: GitHub PR Webhook ==="
        echo "Endpoint: ${endpoint}"
        echo "Headers:"
        echo "  Content-Type: application/json"
        echo "  X-GitHub-Event: pull_request"
        echo "  X-GitHub-Delivery: ${delivery_id}"
        echo "  X-Hub-Signature-256: ${header_sig}"
        echo "Payload:"
        echo "$payload"
        return 0
    fi

    echo "Sending GitHub PR webhook [${action}] for ${company} PR #${pr} to ${endpoint}..."
    curl -sS -X POST "$endpoint" \
        -H "Content-Type: application/json" \
        -H "X-GitHub-Event: pull_request" \
        -H "X-GitHub-Delivery: ${delivery_id}" \
        -H "X-Hub-Signature-256: ${header_sig}" \
        -d "$payload"
    echo ""
}

cmd_generic() {
    local company="kurasi"
    local action="provision"
    local ttl=120
    local endpoint="${DEFAULT_BASE_URL}/api/v1/webhooks/generic"
    local secret="$DEFAULT_SECRET"
    local dry_run=0
    local tamper=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --company) company="$2"; shift 2 ;;
            --action) action="$2"; shift 2 ;;
            --ttl) ttl="$2"; shift 2 ;;
            --endpoint) endpoint="$2"; shift 2 ;;
            --secret) secret="$2"; shift 2 ;;
            --dry-run) dry_run=1; shift ;;
            --tamper) tamper=1; shift ;;
            --help|-h) usage 0 ;;
            *) echo "Unknown option: $1" >&2; usage 2 ;;
        esac
    done

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local payload
    payload=$(cat <<EOF
{"company_name":"${company}","action":"${action}","ttl_minutes":${ttl}}
EOF
)

    local sig_input="${timestamp}:${payload}"
    local sig
    sig=$(compute_hmac "$sig_input" "$secret")
    if [[ "$tamper" -eq 1 ]]; then
        sig="deadbeef${sig:8}"
    fi

    if [[ "$dry_run" -eq 1 ]]; then
        echo "=== DRY RUN: Generic EAP Webhook ==="
        echo "Endpoint: ${endpoint}"
        echo "Headers:"
        echo "  Content-Type: application/json"
        echo "  X-SignalLoom-Timestamp: ${timestamp}"
        echo "  X-SignalLoom-Signature: sha256=${sig}"
        echo "Payload:"
        echo "$payload"
        return 0
    fi

    echo "Sending generic webhook [${action}] for ${company} to ${endpoint}..."
    curl -sS -X POST "$endpoint" \
        -H "Content-Type: application/json" \
        -H "X-SignalLoom-Timestamp: ${timestamp}" \
        -H "X-SignalLoom-Signature: sha256=${sig}" \
        -d "$payload"
    echo ""
}

cmd_tamper() {
    cmd_github_pr --tamper "$@"
}

main() {
    if [[ $# -lt 1 ]]; then
        usage 2
    fi

    local subcmd="$1"
    shift

    case "$subcmd" in
        github-pr) cmd_github_pr "$@" ;;
        generic)   cmd_generic "$@" ;;
        tamper)    cmd_tamper "$@" ;;
        hash)      compute_hash "$@" ;;
        --help|-h|help) usage 0 ;;
        *) echo "Unknown subcommand: $subcmd" >&2; usage 2 ;;
    esac
}

main "$@"
