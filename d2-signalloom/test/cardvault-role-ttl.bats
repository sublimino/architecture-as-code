#!/usr/bin/env bats
#
# Every writer of auth/jwt/role/signalloom-cardvault-agent bounds its tokens.
#
# Live, 2026-10-03: OpenBao held 3,188 tokens for this policy, all from JWT
# logins with no expiry (vault_token_count_by_ttl{creation_ttl="+Inf"}). The
# Flux bootstrap (openbao-supercred-bootstrap.yaml) had already bounded the
# role (SLAAT-P1-3-F1: 5m, batch), but scripts/supercred-demo.sh and
# scripts/supercred-fleet-demo.sh deleted and rewrote it with no TTL, so the
# role inherited the auth/jwt mount default (768h) whenever a demo ran last.
#
# Each writer's actual command is extracted from the repository and run
# against a recording `bao`, so the assertion is on what OpenBao would be
# sent, in either form (key=value arguments or a JSON heredoc).

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
  ROLE='auth/jwt/role/signalloom-cardvault-agent'
}

# writers lists the non-test files that write the role.
writers() {
  rg -l -e "bao write ${ROLE}([[:space:]]|\$)" "$repo_root" \
    --glob '!docs/**' --glob '!ci-evidence/**' --glob '!**/test/**' --glob '!test/**' --glob '!**/*_test.go'
}

# role_params <file> prints key=value lines for every write of the role in
# file, one block per write separated by "--".
role_params() {
  local file="$1"
  # The role name must end there: signalloom-cardvault-agentx is not it.
  awk -v role="bao write ${ROLE}([[:space:]]|$)" '
    $0 ~ role && /<<.ROLE./ { mode = "json"; buf = ""; next }
    mode == "json" && $0 ~ /^[[:space:]]*ROLE[[:space:]]*$/ { print "JSON\t" buf; mode = ""; next }
    mode == "json" { buf = buf $0 " "; next }
    $0 ~ role { mode = "args"; buf = substr($0, index($0, "bao write")) }
    mode == "args" && $0 !~ role { buf = buf " " $0 }
    mode == "args" && $0 !~ /\\[[:space:]]*$/ { print "ARGS\t" buf; mode = "" }
  ' "$file" | while IFS=$'\t' read -r kind body; do
    if [ "$kind" = "JSON" ]; then
      printf '%s' "$body" | jq -r 'to_entries[] | "\(.key)=\(.value|tostring)"'
    else
      (
        NAMESPACE_AGENTS=fe-signalloom-agents
        bao() { shift 2; printf '%s\n' "$@"; }
        eval "${body//\\$'\n'/ }"
      )
    fi
    echo "--"
  done
}

seconds() {
  case "$1" in
    *h) echo $(( ${1%h} * 3600 )) ;;
    *m) echo $(( ${1%m} * 60 )) ;;
    *s) echo "${1%s}" ;;
    *) echo "$1" ;;
  esac
}

@test "the cardvault role has at least the three known writers" {
  run writers
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -ge 3 ]
  [[ "$output" == *"openbao-supercred-bootstrap.yaml"* ]]
  [[ "$output" == *"scripts/supercred-demo.sh"* ]]
  [[ "$output" == *"scripts/supercred-fleet-demo.sh"* ]]
}

@test "every write of the cardvault role issues batch tokens of at most 5 minutes" {
  local file writes=0 bad=""
  while IFS= read -r file; do
    local block="" line
    while IFS= read -r line; do
      if [ "$line" = "--" ]; then
        writes=$(( writes + 1 ))
        local ttl max type
        ttl="$(printf '%s\n' "$block" | sed -n 's/^token_ttl=//p')"
        max="$(printf '%s\n' "$block" | sed -n 's/^token_max_ttl=//p')"
        type="$(printf '%s\n' "$block" | sed -n 's/^token_type=//p')"
        if [ -z "$ttl" ] || [ -z "$max" ] || [ "$(seconds "$ttl")" -gt 300 ] || [ "$(seconds "$max")" -gt 300 ] || [ "$type" != "batch" ]; then
          bad="${bad}${file#"$repo_root"/}: token_ttl='${ttl}' token_max_ttl='${max}' token_type='${type}'"$'\n'
        fi
        block=""
      else
        block="${block}${line}"$'\n'
      fi
    done < <(role_params "$file")
  done < <(writers)
  [ "$writes" -ge 3 ] || { echo "only ${writes} writes parsed"; return 1; }
  [ -z "$bad" ] || { printf 'unbounded writes:\n%s' "$bad"; return 1; }
}
