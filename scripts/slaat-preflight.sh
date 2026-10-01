#!/usr/bin/env bash
# SLAAT-P1-PRE: environment preflight for the Whole-System Autonomous
# Adversarial Testing mission. Read-only against the repo and the cluster:
# it records tool versions, the cache overrides every later card must use,
# the git baseline relative to the integration branch, and the readiness of
# the shared kind cluster, PostgreSQL and Zot. Emits one JSON document on
# stdout; human-readable progress goes to stderr.
#
# Env:
#   SLAAT_INTEGRATION_REF    integration ref (default refs/heads/integration/slaat-whole-system-adversarial)
#   SLAAT_SKIP_CLUSTER=1     skip the kubectl checks (offline runs)
#   SLAAT_CACHE_ROOT         parent for GOCACHE/GOMODCACHE/GOPATH/UV_CACHE_DIR (default: fresh mktemp dir)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INTEGRATION_REF="${SLAAT_INTEGRATION_REF:-refs/heads/integration/slaat-whole-system-adversarial}"

failures=()
warnings=()
fail() { failures+=("$1"); echo "FAIL: $1" >&2; }
warn() { warnings+=("$1"); echo "WARN: $1" >&2; }
ok() { echo "ok:   $1" >&2; }

# --- 1. Cache overrides (unprivileged sandbox safety) ------------------------
CACHE_ROOT="${SLAAT_CACHE_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/slaat-cache.XXXXXX")}"
export GOCACHE="$CACHE_ROOT/gocache" GOMODCACHE="$CACHE_ROOT/gomodcache" \
  GOPATH="$CACHE_ROOT/gopath" UV_CACHE_DIR="$CACHE_ROOT/uv-cache" CGO_ENABLED=0
mkdir -p "$GOCACHE" "$GOMODCACHE" "$GOPATH" "$UV_CACHE_DIR"
for d in "$GOCACHE" "$GOMODCACHE" "$GOPATH" "$UV_CACHE_DIR"; do
  if [ -w "$d" ]; then ok "writable: $d"; else fail "cache dir not writable: $d"; fi
done
# Prove go honours the overrides rather than trusting the export.
read -r go_cache go_modcache go_cgo < <(go env GOCACHE GOMODCACHE CGO_ENABLED | paste -sd' ')
[ "$go_cache" = "$GOCACHE" ] || fail "go ignores GOCACHE override ($go_cache)"
[ "$go_modcache" = "$GOMODCACHE" ] || fail "go ignores GOMODCACHE override ($go_modcache)"
[ "$go_cgo" = 0 ] || fail "CGO_ENABLED not honoured ($go_cgo)"

# --- 2. Toolchain -----------------------------------------------------------
tool_version() {
  case "$1" in
    go) go version ;;
    kubectl) kubectl version --client 2>/dev/null | head -1 ;;
    pytest) UV_CONFIG_FILE=/dev/null uv run --quiet --python 3.12 --with pytest pytest --version 2>&1 | tail -1 ;;
    *) "$1" --version 2>&1 | head -1 ;;
  esac
}

tools_json='{}'
for t in bats go curl jq kubectl uv python3 pytest; do
  probe="$t"
  [ "$t" = pytest ] && probe=uv
  if ! command -v "$probe" >/dev/null 2>&1; then
    fail "tool missing: $t"
    continue
  fi
  if v="$(tool_version "$t")" && [ -n "$v" ]; then
    tools_json="$(printf '%s' "$tools_json" | jq --arg k "$t" --arg v "$v" '. + {($k): $v}')"
    ok "$t: $v"
  else
    fail "tool not runnable: $t"
  fi
done

# --- 3. Git baseline ---------------------------------------------------------
cd "$REPO_ROOT"
head_sha="$(git rev-parse HEAD)"
common_dir="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
canonical_root="$(dirname "$common_dir")"
dirty="$(git status --porcelain | wc -l | tr -d ' ')"
[ "$dirty" = 0 ] && ok "working tree clean" || fail "working tree has $dirty uncommitted entries"
# Ignored dependency dirs symlinked out of a worktree make `bun install`
# (e.g. `make test-dashboard-weave`) mutate another checkout's tree.
while IFS= read -r link; do
  target="$(readlink -f "$link")"
  case "$target" in "$REPO_ROOT"/*) ;; *) warn "shared dependency dir: ${link#./} -> $target" ;; esac
done < <(fd -H -I -t l -d 6 '^node_modules$' . 2>/dev/null)

integration_sha=""
relation="missing"
behind=0
ahead=0
if integration_sha="$(git rev-parse --verify --quiet "$INTEGRATION_REF^{commit}")"; then
  ahead="$(git rev-list --count "$integration_sha..HEAD")"
  behind="$(git rev-list --count "HEAD..$integration_sha")"
  if [ "$head_sha" = "$integration_sha" ]; then relation="equal"
  elif [ "$ahead" = 0 ]; then relation="behind"
  elif [ "$behind" = 0 ]; then relation="ahead"
  else relation="diverged"
  fi
  # Commits on HEAD that integration already carries as rebased patches are not drift.
  unique_ahead="$(git cherry "$integration_sha" HEAD | rg -c '^\+' || true)"
  [ "$relation" = equal ] || warn "HEAD is $relation integration (ahead=$ahead, patch-unique=${unique_ahead:-0}, behind=$behind)"
else
  fail "integration ref missing: $INTEGRATION_REF"
fi

# --- 4. Cluster, PostgreSQL, Zot (read-only) ----------------------------------
cluster_json='{"skipped": true}'
if [ "${SLAAT_SKIP_CLUSTER:-0}" != 1 ]; then
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  nodes_ready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')"
  nodes_total="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [ "$nodes_total" -gt 0 ] && [ "$nodes_ready" = "$nodes_total" ] || fail "nodes ready $nodes_ready/$nodes_total"
  pod_state() { # namespace, name-regex -> "ready/total restarts" of first match, or "absent"
    kubectl get pods -n "$1" --no-headers 2>/dev/null | awk -v re="$2" '$1 ~ re {print $2, $4; exit}'
  }
  pg="$(pod_state inf-signalloom '^postgresql')"
  zot="$(pod_state registry '^zot')"
  for pair in "postgresql:$pg" "zot:$zot"; do
    name="${pair%%:*}"; state="${pair#*:}"
    case "$state" in
      "") fail "$name pod absent" ;;
      1/1*) ok "$name $state" ;;
      *) fail "$name not ready ($state)" ;;
    esac
  done
  cluster_json="$(jq -n --arg ctx "$ctx" --arg nr "$nodes_ready" --arg nt "$nodes_total" \
    --arg pg "${pg:-absent}" --arg zot "${zot:-absent}" \
    '{skipped: false, context: $ctx, nodes_ready: ($nr|tonumber), nodes_total: ($nt|tonumber),
      postgresql: $pg, zot: $zot}')"
fi

# --- 5. Proof ----------------------------------------------------------------
status=pass
[ "${#failures[@]}" -eq 0 ] || status=fail
jq -n \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg head "$head_sha" \
  --arg iref "$INTEGRATION_REF" --arg isha "$integration_sha" --arg rel "$relation" \
  --arg ahead "$ahead" --arg behind "$behind" --arg root "$canonical_root" \
  --arg cache "$CACHE_ROOT" --arg status "$status" \
  --argjson tools "$tools_json" --argjson cluster "$cluster_json" \
  --argjson failures "$(printf '%s\n' "${failures[@]}" | jq -R . | jq -s 'map(select(length>0))')" \
  --argjson warnings "$(printf '%s\n' "${warnings[@]}" | jq -R . | jq -s 'map(select(length>0))')" \
  '{shortcode: "SLAAT", card: "P1-PRE", timestamp: $ts,
    git: {head: $head, canonical_repo: $root, integration_ref: $iref, integration_sha: $isha,
          relation: $rel, ahead: ($ahead|tonumber), behind: ($behind|tonumber)},
    caches: {root: $cache, GOCACHE: ($cache+"/gocache"), GOMODCACHE: ($cache+"/gomodcache"),
             GOPATH: ($cache+"/gopath"), UV_CACHE_DIR: ($cache+"/uv-cache"), CGO_ENABLED: "0"},
    tools: $tools, cluster: $cluster, warnings: $warnings, failures: $failures,
    status: $status, proceed: ($status == "pass")}'
[ "$status" = pass ]
