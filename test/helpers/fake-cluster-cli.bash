#!/usr/bin/env bash
# fake-cluster-cli.bash — a `kubectl` and a `flux` that remember things.
#
# The origin mechanism is almost entirely decision logic — is this origin well
# formed, is it already active, does someone else hold it — wrapped around four
# cluster calls. Testing it against a real cluster would test kubectl; testing
# it against stubs that forget everything between calls cannot test idempotence
# or the lease at all, because both are questions about what the PREVIOUS call
# wrote.
#
# So these stubs keep ConfigMap state in a directory and implement exactly the
# three kubectl behaviours dex-origin.sh depends on:
#
#   get configmap -o jsonpath={.data.KEY}   including the no-trailing-newline
#                                           quirk that makes `read` unsafe
#   patch configmap --type=merge            including null-removes-the-key
#   get/rollout on a deployment             presence and restart
#
# Every invocation is also appended to a call log, so a test can assert what was
# NOT called — which is the only way to prove a no-op really was one.

# Writes a kubectl + flux pair into $1 and points PATH at them.
fake_cluster_install() {
  local dir="$1"
  mkdir -p "$dir/bin" "$dir/state"

  export FAKE_CLUSTER_STATE="$dir/state"
  export FAKE_CLUSTER_LOG="$dir/state/calls.log"
  : > "$FAKE_CLUSTER_LOG"

  cat > "$dir/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# Deliberately NOT `set -e`: this stands in for a real binary, and a real
# kubectl reports failure through its exit status rather than by aborting.
printf 'kubectl %s\n' "$*" >> "$FAKE_CLUSTER_LOG"

state="$FAKE_CLUSTER_STATE"

ns=""
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) ns="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"

cm_file="${state}/cm-${ns}.json"

case "${1:-}" in
  get)
    case "${2:-}" in
      configmap|cm)
        # Absent ConfigMap: kubectl exits non-zero and prints nothing.
        [[ -f "$cm_file" ]] || { echo "Error from server (NotFound): configmaps \"${3}\" not found" >&2; exit 1; }
        for a in "$@"; do
          if [[ "$a" == -o ]]; then continue; fi
          if [[ "$a" == jsonpath=* ]]; then
            key="${a#jsonpath=\{.data.}"; key="${key%\}}"
            # No trailing newline, exactly as kubectl does it. This is the
            # quirk that makes `read -r a b < <(kubectl ...)` return non-zero.
            printf '%s' "$(jq -r --arg k "$key" '.[$k] // ""' "$cm_file")"
            exit 0
          fi
        done
        exit 0
        ;;
      kustomization)
        # Every Kustomization the tests use has a source; the name is derived
        # so a test can tell one target's reconcile from another's.
        [[ -n "${FAKE_CLUSTER_NO_KUSTOMIZATION:-}" ]] && exit 1
        printf '%s' "src-${3}"
        exit 0
        ;;
      deploy|deployment)
        [[ -n "${FAKE_CLUSTER_NO_DEX:-}" ]] && exit 1
        exit 0
        ;;
    esac
    exit 0
    ;;
  patch)
    case "${2:-}" in
      configmap|cm)
        [[ -n "${FAKE_CLUSTER_PATCH_FAILS:-}" ]] && { echo "forced patch failure" >&2; exit 1; }
        # A namespace the test never created stands in for "namespace does not
        # exist yet", which is a real state on a partially-built cluster.
        if [[ ! -f "$cm_file" ]]; then
          echo "Error from server (NotFound): configmaps \"${3}\" not found" >&2
          exit 1
        fi
        payload=""
        prev=""
        for a in "$@"; do
          [[ "$prev" == -p || "$prev" == --patch ]] && payload="$a"
          prev="$a"
        done
        # Merge semantics: a null value REMOVES the key. `del` rather than
        # assignment, or the key would survive as a JSON null and read back as
        # the string "null".
        tmp="$(mktemp)"
        jq --argjson patch "$(jq -c '.data' <<< "$payload")" '
          reduce ($patch | to_entries[]) as $e (.; if $e.value == null then del(.[$e.key]) else .[$e.key] = $e.value end)
        ' "$cm_file" > "$tmp" && mv "$tmp" "$cm_file"
        exit 0
        ;;
    esac
    exit 0
    ;;
  rollout)
    exit 0
    ;;
esac
exit 0
STUB

  cat > "$dir/bin/flux" <<'STUB'
#!/usr/bin/env bash
printf 'flux %s\n' "$*" >> "$FAKE_CLUSTER_LOG"
exit 0
STUB

  chmod +x "$dir/bin/kubectl" "$dir/bin/flux"
  export PATH="$dir/bin:$PATH"
}

# Create a ConfigMap in a namespace. With no further arguments it is empty,
# which is the state of a freshly built cluster that has never published.
fake_cluster_configmap() {
  local ns="$1"; shift
  local file="${FAKE_CLUSTER_STATE}/cm-${ns}.json"
  echo '{}' > "$file"
  while [[ $# -gt 0 ]]; do
    local key="${1%%=*}" value="${1#*=}"
    local tmp; tmp="$(mktemp)"
    jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$file" > "$tmp" && mv "$tmp" "$file"
    shift
  done
}

fake_cluster_get() {
  local ns="$1" key="$2"
  jq -r --arg k "$key" '.[$k] // ""' "${FAKE_CLUSTER_STATE}/cm-${ns}.json"
}

fake_cluster_has_key() {
  local ns="$1" key="$2"
  jq -e --arg k "$key" 'has($k)' "${FAKE_CLUSTER_STATE}/cm-${ns}.json" >/dev/null
}

fake_cluster_calls() {
  cat "$FAKE_CLUSTER_LOG"
}

fake_cluster_reset_log() {
  : > "$FAKE_CLUSTER_LOG"
}
