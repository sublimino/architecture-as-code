#!/usr/bin/env bash
# A kubectl that answers from environment variables, for testing what
# supercred-evidence.sh CONCLUDES rather than what a cluster happens to be doing.
#
# It deliberately answers BOTH the flattened readiness jsonpath the probe used to
# ask for and the per-pod one it asks for now, so the same fixtures can be run
# against a pre-fix copy of the script. Without that, a "test" of the fix would
# only be testing the stub.
#
# STUB_PODS is the source of truth for pod state, one pod per line:
#     <name>=<phase>=<ready...>
# Everything else is a literal the matching command prints.

set -eo pipefail

args="$*"

emit_pods_new() { printf '%s\n' "${STUB_PODS}" | while IFS= read -r l; do [ -n "$l" ] && printf '%s\n' "$l"; done; }

# The old shape: readiness of every pod, flattened into one space-separated
# string with no pod names and no entry at all for a pod without containers.
emit_pods_old() {
  local first=1 l ready
  printf '%s\n' "${STUB_PODS}" | while IFS= read -r l; do
    [ -z "$l" ] && continue
    ready="${l##*=}"
    [ -z "$ready" ] && continue
    if [ "$first" -eq 1 ]; then first=0; else printf ' '; fi
    printf '%s' "$ready"
  done
}

case "$args" in
  cluster-info*)
    exit 0
    ;;

  # Namespace resolution: `{.items[0].metadata.name}` and nothing else.
  *"get pod -l signalloom.ai/supercred=true -o jsonpath={.items[0].metadata.name}")
    if grep -q 'fe-signalloom-agents' <<<"$args" && [ -n "${STUB_PODS}" ]; then
      printf '%s' "${STUB_PODS%%=*}"
      exit 0
    fi
    exit 1
    ;;

  *"get pod"*"stunned-at"*)
    printf '%s\n' "${STUB_ANNOTATION}"
    ;;

  *"get pod"*"status.phase"*)
    emit_pods_new
    ;;

  *"get pod"*"containerStatuses"*)
    emit_pods_old
    ;;

  *"get pod"*"securityContext"*)
    printf '%s' "${STUB_SECURITY_CONTEXT:-}"
    ;;

  *"get pod -l app.kubernetes.io/name=spire-server"*)
    printf '%s' "${STUB_SPIRE_POD:-spire-server-0}"
    ;;

  *"get pod"*"-o name")
    printf '%s\n' "${STUB_PODS}" | while IFS= read -r l; do
      [ -n "$l" ] && printf 'pod/%s\n' "${l%%=*}"
    done
    ;;

  *"spire-server entry show"*)
    printf '%s\n' "${STUB_SPIRE_ENTRY}"
    ;;

  *"get networkpolicy -o name")
    printf '%s\n' "${STUB_NETPOL}"
    ;;

  # The root token lookup, which also stands in for "is OpenBao deployed".
  *"get deployment openbao -o jsonpath"*)
    [ "${STUB_BAO_DEPLOYED:-1}" = "1" ] || exit 1
    printf 'BAO_DEV_ROOT_TOKEN_ID=stub-token\n'
    ;;

  *"get deployment openbao")
    [ "${STUB_BAO_DEPLOYED:-1}" = "1" ] || exit 1
    printf 'openbao   1/1\n'
    ;;

  *"bao kv metadata get"*)
    printf '%s\n' "${STUB_KV_META}"
    ;;

  # Both halves matter, so the stub can drive both: `bao` prints its diagnostics
  # on stderr (which bao_exec merges into stdout) AND sets an exit status, and a
  # revoked secret is only distinguishable from a live one by using both.
  *"bao kv get -field=username"*)
    if [ -n "${STUB_KV_FIELD}" ]; then
      printf '%s\n' "${STUB_KV_FIELD}"
      exit "${STUB_KV_FIELD_STATUS:-0}"
    fi
    exit "${STUB_KV_FIELD_STATUS:-2}"
    ;;

  *"bao read auth/jwt/role"*)
    printf '%s\n' "${STUB_ROLE}"
    ;;

  *)
    printf 'kubectl stub: unhandled command: %s\n' "$args" >&2
    exit 127
    ;;
esac
