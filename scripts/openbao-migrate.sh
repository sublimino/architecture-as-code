#!/usr/bin/env bash
#
# openbao-migrate.sh - move OpenBao state from the retiring dev server to the
# persistent server, and prove it arrived (SA-TODO-003 cutover).
#
# @id     openbao-migrate
# @tests  test/openbao-migrate.bats
# @doc    docs/signalloom/security-architecture-todos.md
#
# Usage:
#   scripts/openbao-migrate.sh export --file FILE [--context CONTEXT] [--from dev|admin]
#   scripts/openbao-migrate.sh import --file FILE [--context CONTEXT] [--to admin|dev]
#   scripts/openbao-migrate.sh verify --file FILE [--context CONTEXT] [--to admin|dev]
#
# What moves: every KV v2 value on every kv-v2 mount, every ACL policy except
# root and inf-bao-admin, and every JWT/OIDC auth mount with its config and
# roles (except role inf-bao-admin). The import creates missing mounts.
#
# What does not move, on purpose: tokens and leases (they expire; restart the
# agents), identity entities (openbao-agent-generic-role-setup recreates the
# named ones; logins recreate the rest), and anything owned by openbao-init
# (root, inf-bao-admin, audit device, auth/jwt itself).
#
# export --from dev (the default) reads the dev server in deploy/openbao with
# its dev root token, read INSIDE that pod from its own environment; it is the
# one-shot path off the retiring server and stops working once it is gone.
# --from admin reads through deploy/openbao-admin, for a restart-survival
# check. import and verify write/read as inf-bao-admin; --to dev targets a
# dev server instead, the rollback path after a revert.
#
# The export FILE holds secret values in clear: it is created 0600 and the
# runbook keeps it on tmpfs and shreds it after verify. Logs carry only
# sha256 (first 16 hex) of canonical JSON, never a value.
#
# verify compares key by key. KV values and policies must match exactly; for
# roles and auth config every exported field must match, so fields that a
# newer server adds with defaults do not count as drift. Exit 1 on any
# mismatch or missing key.
#
# Test seams: OPENBAO_MIGRATE_SRC_BAO / OPENBAO_MIGRATE_DST_BAO name an
# executable used in place of `bao` on each side.
set -o pipefail

CONTEXT=""
FROM="dev"
TO="admin"
NS="${OPENBAO_MIGRATE_NAMESPACE:-inf-bao}"

usage() { sed -n '3,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { printf 'openbao-migrate: %s\n' "$1" >&2; exit "${2:-1}"; }

_kubectl() {
  if [ -n "${CONTEXT}" ]; then kubectl --context "${CONTEXT}" -n "${NS}" "$@"; else kubectl -n "${NS}" "$@"; fi
}

dev_bao() {
  # shellcheck disable=SC2016 # expands inside the dev pod only
  _kubectl exec -i deployment/openbao -c openbao -- \
    sh -c 'BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$BAO_DEV_ROOT_TOKEN_ID" exec bao "$@"' bao "$@"
}

admin_bao() {
  _kubectl exec -i deployment/openbao-admin -c bao -- bao-admin "$@"
}

src() {
  if [ -n "${OPENBAO_MIGRATE_SRC_BAO:-}" ]; then "${OPENBAO_MIGRATE_SRC_BAO}" "$@"; return; fi
  if [ "${FROM}" = "admin" ]; then admin_bao "$@"; else dev_bao "$@"; fi
}

dst() {
  if [ -n "${OPENBAO_MIGRATE_DST_BAO:-}" ]; then "${OPENBAO_MIGRATE_DST_BAO}" "$@"; return; fi
  if [ "${TO}" = "dev" ]; then dev_bao "$@"; else admin_bao "$@"; fi
}

h() { jq -S -c . | sha256sum | cut -c1-16; }

# list SIDE PATH -> one key per line; empty when the path has no children.
list_keys() {
  local out
  out="$("$1" list -format=json "$2" </dev/null 2>/dev/null)" || return 0
  jq -r '.[]' <<<"${out}"
}

# ── export ────────────────────────────────────────────────────────────────────

export_kv_tree() { # MOUNT PREFIX
  local key
  while IFS= read -r key; do
    [ -n "${key}" ] || continue
    if [[ "${key}" == */ ]]; then
      export_kv_tree "$1" "$2${key}" || return 1
      continue
    fi
    local data
    data="$(src read -format=json "$1data/$2${key}" </dev/null | jq -c '.data.data')" || return 1
    if [ "${data}" = "null" ]; then
      printf 'skip kv %s%s (deleted)\n' "$1" "$2${key}"
      continue
    fi
    jq -n -c --arg m "$1" --arg p "$2${key}" --argjson d "${data}" '{mount: $m, path: $p, data: $d}' >>"${WORK}/kv.ndjson"
    printf 'kv %s%s sha256=%s\n' "$1" "$2${key}" "$(h <<<"${data}")"
  done < <(list_keys src "$1metadata/$2")
}

do_export() {
  local file="$1" mounts auth m name body
  umask 077
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/openbao-migrate.XXXXXX")" || die "mktemp failed"
  trap 'rm -rf "${WORK}"' EXIT
  : >"${WORK}/kv.ndjson"; : >"${WORK}/policies.ndjson"; : >"${WORK}/roles.ndjson"

  mounts="$(src read -format=json sys/mounts </dev/null)" || die "cannot read sys/mounts from the source" 1
  auth="$(src read -format=json sys/auth </dev/null)" || die "cannot read sys/auth from the source" 1

  jq -c '[.data | to_entries[] | select(.value.type == "kv") | {path: .key, version: (.value.options.version // "1")}]' <<<"${mounts}" >"${WORK}/kv_mounts.json"
  if [ "$(jq '[.[] | select(.version != "2")] | length' "${WORK}/kv_mounts.json")" != "0" ]; then
    die "a kv v1 mount exists on the source; this script moves kv-v2 only" 1
  fi
  jq -c '[.data | to_entries[] | select(.value.type == "jwt" or .value.type == "oidc") | {path: .key, type: .value.type}]' <<<"${auth}" >"${WORK}/auth_mounts.json"

  while IFS= read -r m; do
    export_kv_tree "${m}" "" || die "reading ${m} failed" 1
  done < <(jq -r '.[].path' "${WORK}/kv_mounts.json")

  while IFS= read -r name; do
    case "${name}" in ''|root|inf-bao-admin) continue ;; esac
    body="$(src read -format=json "sys/policies/acl/${name}" </dev/null | jq -c '.data.policy')" || die "reading policy ${name} failed" 1
    jq -n -c --arg n "${name}" --argjson p "${body}" '{name: $n, policy: $p}' >>"${WORK}/policies.ndjson"
    printf 'policy %s sha256=%s\n' "${name}" "$(h <<<"${body}")"
  done < <(list_keys src sys/policies/acl)

  local cfgs="[]"
  while IFS= read -r m; do
    body="$(src read -format=json "auth/${m}config" </dev/null 2>/dev/null | jq -c '.data')" || body="null"
    if [ "${body}" != "null" ] && [ -n "${body}" ]; then
      cfgs="$(jq -c --arg m "${m}" --argjson c "${body}" '. + [{mount: $m, config: $c}]' <<<"${cfgs}")"
      printf 'auth-config %s sha256=%s\n' "${m}" "$(h <<<"${body}")"
    fi
    while IFS= read -r name; do
      [ -n "${name}" ] || continue
      [ "${m}${name}" = "jwt/inf-bao-admin" ] && continue
      body="$(src read -format=json "auth/${m}role/${name}" </dev/null | jq -c '.data')" || die "reading role ${m}${name} failed" 1
      jq -n -c --arg m "${m}" --arg n "${name}" --argjson r "${body}" '{mount: $m, name: $n, config: $r}' >>"${WORK}/roles.ndjson"
      printf 'role %s%s sha256=%s\n' "${m}" "${name}" "$(h <<<"${body}")"
    done < <(list_keys src "auth/${m}role")
  done < <(jq -r '.[].path' "${WORK}/auth_mounts.json")

  jq -n --slurpfile kv "${WORK}/kv.ndjson" --slurpfile pol "${WORK}/policies.ndjson" \
        --slurpfile roles "${WORK}/roles.ndjson" --slurpfile kvm "${WORK}/kv_mounts.json" \
        --slurpfile am "${WORK}/auth_mounts.json" --argjson cfgs "${cfgs}" \
    '{format: "signalloom.openbao-export/v1", kv_mounts: $kvm[0], auth_mounts: $am[0],
      kv: $kv, policies: $pol, auth_configs: $cfgs, jwt_roles: $roles}' >"${WORK}/export.json" \
    || die "assembling the export failed" 1
  mkdir -p "$(dirname "${file}")"
  install -m 0600 "${WORK}/export.json" "${file}" || die "cannot write ${file}" 1
  printf 'exported kv=%s policies=%s auth_mounts=%s jwt_roles=%s auth_configs=%s -> %s\n' \
    "$(jq '.kv|length' "${file}")" "$(jq '.policies|length' "${file}")" \
    "$(jq '.auth_mounts|length' "${file}")" "$(jq '.jwt_roles|length' "${file}")" \
    "$(jq '.auth_configs|length' "${file}")" "${file}"
}

# ── import / verify share one walk over the export ────────────────────────────

# current KIND ITEM_JSON -> the target's value for that item, or empty if absent
current() {
  local kind="$1" item="$2" out
  case "${kind}" in
    kv)     out="$(dst read -format=json "$(jq -r '.mount + "data/" + .path' <<<"${item}")" </dev/null 2>/dev/null)" || return 0
            jq -c '.data.data' <<<"${out}" ;;
    policy) out="$(dst read -format=json "sys/policies/acl/$(jq -r .name <<<"${item}")" </dev/null 2>/dev/null)" || return 0
            jq -c '.data.policy' <<<"${out}" ;;
    role)   out="$(dst read -format=json "$(jq -r '"auth/" + .mount + "role/" + .name' <<<"${item}")" </dev/null 2>/dev/null)" || return 0
            jq -c '.data' <<<"${out}" ;;
    config) out="$(dst read -format=json "$(jq -r '"auth/" + .mount + "config"' <<<"${item}")" </dev/null 2>/dev/null)" || return 0
            jq -c '.data' <<<"${out}" ;;
  esac
}

wanted() { # KIND ITEM_JSON
  case "$1" in kv) jq -c '.data' <<<"$2" ;; policy) jq -c '.policy' <<<"$2" ;; *) jq -c '.config' <<<"$2" ;; esac
}

label() { # KIND ITEM_JSON
  case "$1" in
    kv) jq -r '"kv " + .mount + .path' <<<"$2" ;;
    policy) jq -r '"policy " + .name' <<<"$2" ;;
    role) jq -r '"role " + .mount + .name' <<<"$2" ;;
    config) jq -r '"auth-config " + .mount' <<<"$2" ;;
  esac
}

# compare KIND WANT GOT -> hash of GOT as compared (roles/config: exported fields only)
compared_got() {
  case "$1" in
    role|config) jq -c --argjson want "$2" 'with_entries(select(.key as $k | $want | has($k)))' <<<"$3" ;;
    *) printf '%s' "$3" ;;
  esac
}

items() { # FILE -> "KIND<TAB>ITEM_JSON" lines
  jq -r '(.kv[] | "kv\t" + tojson), (.policies[] | "policy\t" + tojson),
         (.auth_configs[] | "config\t" + tojson), (.jwt_roles[] | "role\t" + tojson)' "$1"
}

protected() { # KIND ITEM_JSON -> 0 if openbao-init owns it
  case "$1" in
    policy) case "$(jq -r .name <<<"$2")" in root|inf-bao-admin) return 0 ;; esac ;;
    role) [ "$(jq -r '.mount + .name' <<<"$2")" = "jwt/inf-bao-admin" ] && return 0 ;;
  esac
  return 1
}

do_import() {
  local file="$1" mounts auth path type created=0 written=0 unchanged=0 kind item want got
  mounts="$(dst read -format=json sys/mounts </dev/null)" || die "cannot read sys/mounts from the target (deploy/openbao-admin)" 1
  auth="$(dst read -format=json sys/auth </dev/null)" || die "cannot read sys/auth from the target" 1
  while IFS= read -r path; do
    jq -e --arg p "${path}" '.data | has($p)' <<<"${mounts}" >/dev/null && continue
    printf '{"type":"kv","options":{"version":"2"}}' | dst write "sys/mounts/${path%/}" - >/dev/null \
      || die "enabling kv mount ${path} failed" 1
    printf 'created kv mount %s\n' "${path}"; created=$((created + 1))
  done < <(jq -r '.kv_mounts[].path' "${file}")
  while IFS=$'\t' read -r path type; do
    jq -e --arg p "${path}" '.data | has($p)' <<<"${auth}" >/dev/null && continue
    jq -n -c --arg t "${type}" '{type: $t}' | dst write "sys/auth/${path%/}" - >/dev/null \
      || die "enabling auth mount ${path} failed" 1
    printf 'created auth mount %s\n' "${path}"; created=$((created + 1))
  done < <(jq -r '.auth_mounts[] | .path + "\t" + .type' "${file}")

  while IFS=$'\t' read -r kind item; do
    protected "${kind}" "${item}" && continue
    want="$(wanted "${kind}" "${item}")"
    got="$(current "${kind}" "${item}")"
    if [ -n "${got}" ] && [ "${got}" != "null" ] \
       && [ "$(h <<<"$(compared_got "${kind}" "${want}" "${got}")")" = "$(h <<<"${want}")" ]; then
      unchanged=$((unchanged + 1)); continue
    fi
    case "${kind}" in
      kv) jq -c '{data: .data}' <<<"${item}" | dst write "$(jq -r '.mount + "data/" + .path' <<<"${item}")" - >/dev/null ;;
      policy) jq -c '{policy: .policy}' <<<"${item}" | dst write "sys/policies/acl/$(jq -r .name <<<"${item}")" - >/dev/null ;;
      role) jq -c '.config' <<<"${item}" | dst write "$(jq -r '"auth/" + .mount + "role/" + .name' <<<"${item}")" - >/dev/null ;;
      config) jq -c '.config' <<<"${item}" | dst write "$(jq -r '"auth/" + .mount + "config"' <<<"${item}")" - >/dev/null ;;
    esac || die "writing $(label "${kind}" "${item}") failed" 1
    printf 'wrote %s sha256=%s\n' "$(label "${kind}" "${item}")" "$(h <<<"${want}")"
    written=$((written + 1))
  done < <(items "${file}")
  printf 'imported written=%s unchanged=%s mounts_created=%s\n' "${written}" "${unchanged}" "${created}"
}

do_verify() {
  local file="$1" matched=0 mismatched=0 missing=0 kind item want got wh gh
  dst status </dev/null >/dev/null 2>&1 || die "the target is unreachable" 1
  while IFS=$'\t' read -r kind item; do
    protected "${kind}" "${item}" && continue
    want="$(wanted "${kind}" "${item}")"
    got="$(current "${kind}" "${item}")"
    if [ -z "${got}" ] || [ "${got}" = "null" ]; then
      printf 'MISSING %s\n' "$(label "${kind}" "${item}")"; missing=$((missing + 1)); continue
    fi
    wh="$(h <<<"${want}")"
    gh="$(h <<<"$(compared_got "${kind}" "${want}" "${got}")")"
    if [ "${wh}" = "${gh}" ]; then
      matched=$((matched + 1))
    else
      printf 'MISMATCH %s want=%s got=%s\n' "$(label "${kind}" "${item}")" "${wh}" "${gh}"
      mismatched=$((mismatched + 1))
    fi
  done < <(items "${file}")
  printf 'verified matched=%s mismatched=%s missing=%s\n' "${matched}" "${mismatched}" "${missing}"
  [ "${mismatched}" -eq 0 ] && [ "${missing}" -eq 0 ]
}

main() {
  local cmd="${1:-}" file=""
  [ $# -gt 0 ] && shift
  case "${cmd}" in export|import|verify) ;; -h|--help) usage; exit 0 ;; *) usage >&2; exit 2 ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --file) file="${2:-}"; shift 2 || die "--file needs a value" 2 ;;
      --context) CONTEXT="${2:-}"; shift 2 || die "--context needs a value" 2 ;;
      --from) FROM="${2:-}"; shift 2 || die "--from needs a value" 2 ;;
      --to) TO="${2:-}"; shift 2 || die "--to needs a value" 2 ;;
      *) die "unknown option: $1" 2 ;;
    esac
  done
  [ -n "${file}" ] || die "--file is required" 2
  case "${FROM}" in dev|admin) ;; *) die "--from must be dev or admin" 2 ;; esac
  case "${TO}" in dev|admin) ;; *) die "--to must be admin or dev" 2 ;; esac
  command -v jq >/dev/null || die "jq is required" 1
  case "${cmd}" in
    export) do_export "${file}" ;;
    import) [ -r "${file}" ] || die "cannot read ${file}" 1; do_import "${file}" ;;
    verify) [ -r "${file}" ] || die "cannot read ${file}" 1; do_verify "${file}" ;;
  esac
}

main "$@"
