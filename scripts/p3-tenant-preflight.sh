#!/usr/bin/env bash
# ==============================================================================
# SLDC-P3-PRE tenant domain preflight audit (read-only).
#
# Recomputes the tenant hash vectors from their definitions, inventories every
# occurrence of the retired tenant typo and the rejected unsalted digest, probes
# OpenBao for the EAP salt, and emits one machine-readable JSON report.
#
# It never writes to OpenBao, the cluster, or any tracked file other than the
# --out path it is given. It is an audit oracle, not the P3-1 hash generator.
#
# Injectable boundaries (tests set these):
#   P3_REPO            repository root to scan        (default: git toplevel)
#   KUBECTL            kubectl binary                 (default: kubectl)
#   P3_BAO_CONTEXT     kube context hosting OpenBao   (default: kind-osramp)
#   P3_BAO_NAMESPACE   namespace of the openbao deploy (default: inf-bao)
#   P3_SKIP_CLUSTER=1  skip the live OpenBao probe; report it as "skipped"
#   P3_LEGACY_ALLOWLIST  guards allowed to name the typo
#                      (default: test/fixtures/tenant/legacy-typo-allowlist.txt)
#
# Usage:
#   p3-tenant-preflight.sh vectors            JSON hash vectors
#   p3-tenant-preflight.sh classify <name|hash>
#                                             exit 0 canonical, 3 retired/rejected, 4 unknown
#   p3-tenant-preflight.sh scan               JSON inventory of legacy strings
#   p3-tenant-preflight.sh bao                JSON OpenBao salt probe
#   p3-tenant-preflight.sh gateway            JSON HTTPRoute/Dex readiness for the canonical host
#   p3-tenant-preflight.sh audit [--out FILE] full JSON report
#   p3-tenant-preflight.sh legacy-gate        exit 0 if every active file naming the
#                                             typo is allowlisted, 3 otherwise
# ==============================================================================
set -eo pipefail

CANONICAL_TENANT="kusari"
CANONICAL_HASH="4b53ab6b"
RETIRED_TENANT="kurasi"
RETIRED_HASH="6f82ad81"
UNSALTED_HASH="d9d69501"
PILOT_SALT="signalloom-eap-salt-2026-q3"
SALT_PATH="secret/signalloom/eap"

REPO="${P3_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KUBECTL="${KUBECTL:-kubectl}"
BAO_CONTEXT="${P3_BAO_CONTEXT:-kind-osramp}"
BAO_NAMESPACE="${P3_BAO_NAMESPACE:-inf-bao}"

# This audit's own deliverables name the legacy strings on purpose; scanning
# them would make the inventory count itself.
SELF_EXCLUDES=(
  ":!scripts/p3-tenant-preflight.sh"
  ":!test/p3-tenant-preflight.bats"
  ":!ci-evidence/p3-preflight-audit.json"
  ":!docs/eap/SLDC-P3-TENANT-INVENTORY.md"
)

die() { echo "p3-tenant-preflight: $*" >&2; exit 2; }

# The formula every production derivation in the repo implements
# (environment_routing.derive_customer_hash, tailscale-eap-env.sh):
#   sha256(salt + ":" + lower(trim(tenant)))[0:8]
salted_hash() { printf '%s:%s' "$1" "$2" | sha256sum | cut -c1-8; }
hmac_hash() { printf '%s' "$2" | openssl dgst -sha256 -hmac "$1" -r | cut -c1-8; }
raw_hash() { printf '%s' "$1" | sha256sum | cut -c1-8; }

cmd_vectors() {
  local k r
  k="$(salted_hash "$PILOT_SALT" "$CANONICAL_TENANT")"
  r="$(salted_hash "$PILOT_SALT" "$RETIRED_TENANT")"
  jq -n \
    --arg salt "$PILOT_SALT" \
    --arg ct "$CANONICAL_TENANT" --arg ch "$CANONICAL_HASH" --arg k "$k" \
    --arg rt "$RETIRED_TENANT" --arg rh "$RETIRED_HASH" --arg r "$r" \
    --arg uh "$UNSALTED_HASH" --arg u "$(raw_hash "$CANONICAL_TENANT")" \
    --arg hk "$(hmac_hash "$PILOT_SALT" "$CANONICAL_TENANT")" \
    --arg hr "$(hmac_hash "$PILOT_SALT" "$RETIRED_TENANT")" '
    {
      salt: $salt,
      implemented_formula: "sha256(salt + \":\" + lower(trim(tenant)))[0:8]",
      canonical: {tenant: $ct, expected: $ch, computed: $k, match: ($k == $ch), status: "canonical"},
      retired:   {tenant: $rt, expected: $rh, computed: $r, match: ($r == $rh), status: "retired-fail-closed"},
      unsalted:  {formula: "sha256(tenant)[0:8]", tenant: $ct, expected: $uh, computed: $u, match: ($u == $uh), status: "rejected"},
      card_formula_check: {
        formula: "HMAC-SHA256(key=salt, msg=tenant)[0:8]",
        kusari: $hk, kurasi: $hr,
        yields_canonical_hash: ($hk == $ch),
        note: "The card text names HMAC-SHA256, but 4b53ab6b is only produced by the implemented salted-concatenation formula."
      }
    }'
}

cmd_classify() {
  local v="${1:-}"
  [[ -n "$v" ]] || die "classify needs a tenant name or 8-hex hash"
  v="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  case "$v" in
    "$CANONICAL_TENANT" | "$CANONICAL_HASH" | "sl-eap-$CANONICAL_HASH")
      echo "canonical"; return 0 ;;
    "$RETIRED_TENANT" | "$RETIRED_HASH" | "sl-eap-$RETIRED_HASH" | "eap-$RETIRED_HASH")
      echo "retired: $v is the legacy typo vector; fail closed" >&2; return 3 ;;
    "$UNSALTED_HASH" | "sl-eap-$UNSALTED_HASH")
      echo "rejected: $v is the unsalted sha256(tenant) digest" >&2; return 3 ;;
    *)
      echo "unknown: $v is not a registered EAP tenant vector" >&2; return 4 ;;
  esac
}

# Buckets a repo-relative path by how much an occurrence there matters.
classify_path() {
  local p="$1"
  case "$p" in
    .kanban-review-ledger.json | ci-evidence/* | .evidence/* | docs/* | *.log | */evidence/*) echo "historical_record" ;;
    *_test.go | */tests/* | test/* | */test/* | *.bats | */fixtures/*) echo "test_fixture" ;;
    *.md | *.mdx) echo "published_docs" ;;
    *) echo "active_code" ;;
  esac
}

scan_pattern() {
  local pattern="$1"
  # git grep exits 1 for "no match", which is a valid (and hoped-for) result;
  # only exit codes above 1 are real errors.
  ( cd "$REPO" && { rc=0; git grep -n -I -i -E "$pattern" -- . "${SELF_EXCLUDES[@]}" || rc=$?; [[ $rc -le 1 ]]; } ) | while IFS= read -r line; do
    local file="${line%%:*}" rest="${line#*:}"
    local lineno="${rest%%:*}" text="${rest#*:}"
    jq -cn --arg f "$file" --argjson n "$lineno" --arg c "$(classify_path "$file")" --arg t "${text:0:160}" \
      '{file: $f, line: $n, category: $c, text: $t}'
  done | jq -s '.'
}

summarise() {
  jq '{
    total: length,
    files: (map(.file) | unique | length),
    by_category: (group_by(.category) | map({key: .[0].category, value: length}) | from_entries),
    active_files: (map(select(.category == "active_code" or .category == "published_docs")) | map(.file) | unique),
    historical_files: (map(select(.category == "historical_record")) | map(.file) | unique),
    # Historical records (ledgers, evidence, reports) are counted and listed by
    # file only; they describe past runs and are not rewritten.
    occurrences: map(select(.category != "historical_record"))
  }'
}

# Is the ingress/IdP surface ready for sl-eap-<canonical hash>? Read-only: this
# reports what P3-2 must change, it does not change it.
cmd_gateway() {
  local tpl="d2-infra/components/ingress/eap-httproute-template.yaml"
  local dex="d2-signalloom/infra/inf-signalloom/base/dex.yaml"
  local tpl_param=false dex_canonical=false dex_legacy=false concrete
  grep -qF 'sl-eap-${EAP_HASH}.ts.net' "$REPO/$tpl" 2>/dev/null && tpl_param=true
  grep -qF "sl-eap-$CANONICAL_HASH" "$REPO/$dex" 2>/dev/null && dex_canonical=true
  grep -qE "sl-eap-($RETIRED_HASH|$UNSALTED_HASH)" "$REPO/$dex" 2>/dev/null && dex_legacy=true
  concrete="$( (cd "$REPO" && { rc=0; git grep -l -I -E "sl-eap-$CANONICAL_HASH" -- '*.yaml' '*.yml' "${SELF_EXCLUDES[@]}" || rc=$?; [[ $rc -le 1 ]]; }) | jq -R . | jq -s .)"
  printf '%s' "$concrete" | jq --arg tpl "$tpl" --arg dex "$dex" --arg host "sl-eap-$CANONICAL_HASH.ts.net" \
    --argjson tp "$tpl_param" --argjson dc "$dex_canonical" --argjson dl "$dex_legacy" '{
      canonical_host: $host,
      httproute_template: {path: $tpl, parameterised_on_eap_hash: $tp},
      dex: {path: $dex, has_canonical_redirect: $dc, has_legacy_redirect: $dl},
      manifests_naming_canonical_host: .
    }'
}

cmd_scan() {
  git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "$REPO is not a git repository"
  # Inventories reach megabytes; they travel through files, never argv
  # (MAX_ARG_STRLEN is 128 KiB per argument).
  local tmp
  tmp="$(mktemp -d)"
  scan_pattern "${RETIRED_TENANT}|${RETIRED_HASH}" | summarise >"$tmp/legacy.json"
  scan_pattern "$UNSALTED_HASH" | summarise >"$tmp/unsalted.json"
  jq -n --slurpfile l "$tmp/legacy.json" --slurpfile u "$tmp/unsalted.json" \
    '{legacy_typo: ({pattern: "kurasi|6f82ad81"} + $l[0]), unsalted_digest: ({pattern: "d9d69501"} + $u[0])}'
  rm -rf "$tmp"
}

# Zero-tolerance gate: every active_code file naming the retired typo must be a
# listed guard (a rejector or detector). Tests, docs and records are exempt.
cmd_legacy_gate() {
  local allow="${P3_LEGACY_ALLOWLIST:-$REPO/test/fixtures/tenant/legacy-typo-allowlist.txt}"
  [[ -f "$allow" ]] || die "legacy-gate: allowlist not found: $allow"
  local tmp unexcused listed
  tmp="$(mktemp -d)"
  cmd_scan >"$tmp/scan.json"
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$allow" | jq -R . | jq -s . >"$tmp/allow.json"
  unexcused="$(jq -r --slurpfile a "$tmp/allow.json" \
    '[.legacy_typo.occurrences[] | select(.category == "active_code") | .file] | unique - $a[0] | .[]' "$tmp/scan.json")"
  listed="$(jq 'length' "$tmp/allow.json")"
  rm -rf "$tmp"
  if [[ -n "$unexcused" ]]; then
    sed 's/^/legacy-gate: unexcused legacy tenant typo in /' <<<"$unexcused" >&2
    return 3
  fi
  echo "legacy-gate: 0 unexcused files ($listed allowlisted)"
}

cmd_bao() {
  if [[ "${P3_SKIP_CLUSTER:-0}" == "1" ]]; then
    jq -n --arg p "$SALT_PATH" '{status: "skipped", path: $p}'
    return 0
  fi
  local out rc salt
  set +e
  out="$("$KUBECTL" --context "$BAO_CONTEXT" exec -n "$BAO_NAMESPACE" deploy/openbao -c openbao -- \
    sh -c "BAO_ADDR=http://127.0.0.1:8200 bao kv get -format=json $SALT_PATH" 2>&1)"
  rc=$?
  set -e
  # The salt value itself never leaves this function: only presence, length
  # and whether it equals the pilot salt are reported.
  if [[ $rc -eq 0 ]] && salt="$(printf '%s' "$out" | jq -er '.data.data.salt' 2>/dev/null)"; then
    jq -n --arg ctx "$BAO_CONTEXT" --arg p "$SALT_PATH" --argjson len "${#salt}" \
      --argjson pilot "$([[ "$salt" == "$PILOT_SALT" ]] && echo true || echo false)" \
      '{status: "provisioned", context: $ctx, path: $p, salt_length: $len, equals_pilot_salt: $pilot}'
  else
    local reason
    reason="$(printf '%s\n' "$out" | grep -v '^Defaulted container' | tail -1)"
    jq -n --arg ctx "$BAO_CONTEXT" --arg p "$SALT_PATH" --argjson rc "$rc" --arg r "$reason" \
      '{status: "unprovisioned", context: $ctx, path: $p, exit_code: $rc, detail: $r}'
  fi
}

cmd_audit() {
  local out=""
  if [[ "${1:-}" == "--out" ]]; then out="${2:-}"; [[ -n "$out" ]] || die "--out needs a path"; fi
  local tmp report
  tmp="$(mktemp -d)"
  cmd_vectors >"$tmp/v.json"
  cmd_scan >"$tmp/s.json"
  cmd_bao >"$tmp/b.json"
  cmd_gateway >"$tmp/g.json"
  report="$(jq -n --slurpfile vs "$tmp/v.json" --slurpfile ss "$tmp/s.json" --slurpfile bs "$tmp/b.json" --slurpfile gs "$tmp/g.json" \
    --arg head "$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unresolved)" \
    --arg when "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
    $vs[0] as $v | $ss[0] as $s | $bs[0] as $b | $gs[0] as $g |
    {
      card: "SLDC-P3-PRE",
      generated_at: $when,
      scanned_commit: $head,
      vectors: $v,
      openbao: $b,
      gateway: $g,
      scan: $s,
      verdict: {
        canonical_vector_holds: $v.canonical.match,
        card_hmac_formula_yields_canonical: $v.card_formula_check.yields_canonical_hash,
        active_legacy_files: ($s.legacy_typo.active_files | length),
        unsalted_digest_occurrences: $s.unsalted_digest.total,
        salt_provisioned: ($b.status == "provisioned"),
        dex_ready_for_canonical_host: $g.dex.has_canonical_redirect
      }
    }')"
  rm -rf "$tmp"
  if [[ -n "$out" ]]; then
    printf '%s\n' "$report" >"$out"
  else
    printf '%s\n' "$report"
  fi
}

main() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    vectors) cmd_vectors ;;
    classify) cmd_classify "$@" ;;
    scan) cmd_scan ;;
    bao) cmd_bao ;;
    gateway) cmd_gateway ;;
    audit) cmd_audit "$@" ;;
    legacy-gate) cmd_legacy_gate ;;
    -h | --help | help) sed -n '2,32p' "$0" ;;
    *) sed -n '2,32p' "$0" >&2; exit 2 ;;
  esac
}

main "$@"
