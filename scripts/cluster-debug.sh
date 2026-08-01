#!/usr/bin/env bash
# Cluster debug report — surfaces all errors, warnings, and unhealthy state
# at a glance. Designed for quick triage, not exhaustive auditing.
set -eo pipefail

RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
RST='\033[0m'

section() { printf '\n%b━━━ %s ━━━%b\n' "$CYN" "$1" "$RST"; }
recommendations=()
recommend() { recommendations+=("$1"); }

cluster_name="${CLUSTER_NAME:-osramp}"
context="$(kubectl config current-context 2>/dev/null || printf '<unavailable>')"
api_server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || printf '<unavailable>')"

if ! kubectl get nodes --no-headers >/dev/null 2>&1; then
  section "CLUSTER UNAVAILABLE"
  printf '%b  ✗ Kubernetes API server is unreachable%b\n' "$RED" "$RST"
  printf '  context: %s\n' "$context"
  printf '  API server: %s\n' "$api_server"
  printf '  expected Kind cluster: %s\n' "$cluster_name"

  section "LOCAL KIND AND DOCKER STATE"
  if ! command -v docker >/dev/null 2>&1; then
    printf '%b  ✗ docker CLI is unavailable%b\n' "$RED" "$RST"
  elif ! docker info >/dev/null 2>&1; then
    printf '%b  ✗ Docker daemon is unavailable%b\n' "$RED" "$RST"
  else
    printf '%b  ✓ Docker daemon is available%b\n' "$GRN" "$RST"
    printf '  Docker server version: %s\n' "$(docker version --format '{{.Server.Version}}' 2>/dev/null || printf '<unknown>')"
    if command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null | grep -Fxq "$cluster_name"; then
      printf '%b  ✓ Kind cluster %s exists%b\n' "$GRN" "$cluster_name" "$RST"
    else
      printf '%b  ✗ Kind cluster %s does not exist%b\n' "$RED" "$cluster_name" "$RST"
    fi

    control_plane="$(docker ps -a --filter "name=^/${cluster_name}-control-plane$" --format '{{.Names}} {{.Status}}' 2>/dev/null || true)"
    if [[ -n "$control_plane" ]]; then
      printf '  control-plane container: %s\n' "$control_plane"
      section "CONTROL-PLANE LOGS (last 100 lines)"
      docker logs "${cluster_name}-control-plane" --tail=100 2>&1 || true
    else
      printf '%b  ✗ Control-plane container %s-control-plane was not found%b\n' "$RED" "$cluster_name" "$RST"
    fi
  fi

  section "RECOVERY"
  printf '  Start or recreate the shared Kind cluster: make cluster\n'
  printf '  Then re-run this report: make doctor\n'
  exit 1
fi

section "CLUSTER INFO"
printf '  context: %s\n' "$context"
printf '  API server: %s\n' "$api_server"
kubectl cluster-info 2>/dev/null | head -3
printf '  nodes: %s\n' "$(kubectl get nodes --no-headers 2>/dev/null | wc -l)"

section "UNHEALTHY PODS (not Running/Completed)"
unhealthy=$(kubectl get pods -A --no-headers 2>/dev/null | grep -vE 'Running|Completed' || true)
if [[ -n "$unhealthy" ]]; then
  printf '%b%s%b\n' "$RED" "$unhealthy" "$RST"
  echo
  while IFS= read -r line; do
    ns=$(echo "$line" | awk '{print $1}')
    pod=$(echo "$line" | awk '{print $2}')
    status=$(echo "$line" | awk '{print $4}')
    printf '%b  → %s/%s (%s):%b\n' "$YEL" "$ns" "$pod" "$status" "$RST"
    kubectl -n "$ns" logs "$pod" --tail=3 2>&1 | sed 's/^/    /'
    recommend "Inspect pod: kubectl -n $ns describe pod $pod"
    recommend "Read logs: kubectl -n $ns logs pod/$pod --tail=200"
  done <<<"$unhealthy"
else
  printf '%b  all pods healthy%b\n' "$GRN" "$RST"
fi

section "POD RESTART COUNTS (>2)"
kubectl get pods -A --no-headers 2>/dev/null \
  | awk '$5 > 2 {printf "  %-40s %-30s restarts=%s\n", $1, $2, $5}' || true

section "RECENT WARNING EVENTS (last 10 min)"
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null \
  | tail -15 || printf '  none\n'

section "FLUX KUSTOMIZATIONS"
all_kust=$(kubectl get kustomization -A --no-headers 2>/dev/null || true)
ready=$(echo "$all_kust" | grep -c 'True' || true)
total=$(echo "$all_kust" | grep -c '.' || true)
not_ready=$(echo "$all_kust" | grep -v 'True' || true)
printf '  %s/%s Ready\n' "$ready" "$total"
if [[ -n "$not_ready" ]]; then
  printf '%b%s%b\n' "$RED" "$not_ready" "$RST"
  recommend "Inspect non-ready Flux resources: flux get all -A --status-selector ready=false"
fi

section "FLUX RESOURCESETS"
kubectl -n flux-system get resourceset --no-headers 2>/dev/null \
  | awk '{ready=$3; if (ready != "True") printf "\033[0;31m"; printf "  %-30s Ready=%s  %s\n", $1, $3, substr($0,index($0,$4)); if (ready != "True") printf "\033[0m"}' || true

section "FLUX ERRORS (non-ready sources)"
source_errors=$(kubectl get ocirepository,helmrepository,gitrepository -A --no-headers 2>/dev/null \
  | grep -v True | head -10 || true)
if [[ -n "$source_errors" ]]; then
  printf '%s\n' "$source_errors"
  recommend "Inspect Flux sources: kubectl get ocirepository,helmrepository,gitrepository -A"
else
  printf '  all sources ready\n'
fi

section "FLUX BUILD FAILURES (kustomize/patch errors)"
# A Kustomization that fails its build never creates its downstream ResourceSets
# (e.g. a bad JSON6902 patch index in `tenants` blocks policies/infra) — the
# symptom (waits hanging on objects that never appear) is far from this cause.
build_fail=$(kubectl get kustomization -A -o json 2>/dev/null | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  for k in d.get('items',[]):
    ns=k['metadata']['namespace']; name=k['metadata']['name']
    for c in k.get('status',{}).get('conditions',[]):
      if c.get('type')=='Ready' and c.get('status')=='False':
        msg=c.get('message','')
        if 'build failed' in msg or 'does not apply' in msg or 'missing path' in msg:
          print(f'  {ns}/{name}: {msg}')
except: pass
" 2>/dev/null || true)
if [[ -n "$build_fail" ]]; then
  printf '%b%s%b\n' "$RED" "$build_fail" "$RST"
  recommend "A Kustomization build error blocks its downstream ResourceSets. Fix the patch/index it names — often d2-osramp-fleet/tenants/local/kustomization.yaml: use 'op: add' not 'op: replace' for /spec/resources/N/spec/verify, and confirm the index still points at the OCIRepository."
else
  printf '  no kustomize build failures\n'
fi

section "EXPECTED RESOURCESETS"
# On a healthy foundation these must exist. If a Kustomization build failed they
# are silently never created and every downstream wait hangs.
for rs in policies infra; do
  if kubectl -n flux-system get resourceset "$rs" >/dev/null 2>&1; then
    printf '%b  ✓ resourceset/%s present%b\n' "$GRN" "$rs" "$RST"
  else
    printf '%b  ✗ resourceset/%s MISSING — the foundation cannot converge%b\n' "$RED" "$rs" "$RST"
    recommend "resourceset/$rs is absent — see FLUX BUILD FAILURES above; the tenants Kustomization likely failed to build."
  fi
done

section "NODE RESOURCES"
kubectl top nodes 2>/dev/null || printf '  metrics-server not available\n'

section "IMAGES (InvalidImageName/ImagePullBackOff)"
image_failures=$(kubectl get pods -A -o json 2>/dev/null | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  for pod in d.get('items',[]):
    ns=pod['metadata']['namespace']
    name=pod['metadata']['name']
    for cs in pod.get('status',{}).get('containerStatuses',[]) + pod.get('status',{}).get('initContainerStatuses',[]):
      waiting = cs.get('state',{}).get('waiting',{})
      reason = waiting.get('reason','')
      if reason in ('ImagePullBackOff','ErrImagePull','InvalidImageName'):
        image = cs.get('image','?')
        print(f'  {ns}/{name}: {reason} — {image}')
except: pass
" 2>/dev/null || true)
if [[ -n "$image_failures" ]]; then
  printf '%s\n' "$image_failures"
  recommend "Inspect image-pull failures: kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp'"
else
  printf '  no image-pull failures\n'
fi

section "ZOT REGISTRY & CACHE"
zot_pod=$(kubectl -n registry get pod -l app=zot --no-headers 2>/dev/null | head -1 || true)
if [[ -z "$zot_pod" ]]; then
  printf '%b  ✗ no zot pod in the registry namespace%b\n' "$RED" "$RST"
  recommend "Deploy the registry: make registry"
else
  zot_name=$(echo "$zot_pod" | awk '{print $1}')
  zot_ready=$(echo "$zot_pod" | awk '{print $2}')
  zot_status=$(echo "$zot_pod" | awk '{print $3}')
  printf '  pod: %s  ready=%s  status=%s\n' "$zot_name" "$zot_ready" "$zot_status"
  if [[ "$zot_ready" != "1/1" || "$zot_status" != "Running" ]]; then
    # Signature failure: a stale cache.db owned by the wrong uid in the
    # persistent host cache, corrupted by concurrent/killed `make up` runs.
    zot_logs=$(kubectl -n registry logs "$zot_name" -c zot --tail=20 2>/dev/null || true)
    if echo "$zot_logs" | grep -qiE 'cache\.db|permission denied'; then
      printf '%b  ✗ zot cannot write its cache (permission denied on cache.db)%b\n' "$RED" "$RST"
      printf '    → the persistent host cache holds a stale file owned by the wrong uid\n'
      recommend "Reset the zot cache: make zot-cache-reset && kubectl -n registry delete pod -l app=zot"
      recommend "If it still crashes, recreate clean: kind delete cluster --name $cluster_name && rm -rf .cache/zot && docker volume rm -f osramp-zot-cache && make up"
    else
      printf '%b  ✗ zot is unhealthy%b\n' "$RED" "$RST"
      echo "$zot_logs" | sed 's/^/    /'
      recommend "Inspect zot: kubectl -n registry logs -l app=zot -c zot --tail=200"
    fi
  else
    printf '%b  ✓ zot registry healthy%b\n' "$GRN" "$RST"
  fi
fi
# Host-backed cache ownership (zot runs as uid 65532; drift => crash on start).
zot_cache_dir="${ZOT_CACHE_DIR:-.cache/zot}"
if command -v stat >/dev/null 2>&1 && [[ -e "$zot_cache_dir" ]]; then
  owner=$(stat -c '%u:%a' "$zot_cache_dir" 2>/dev/null || printf '?')
  if [[ "$owner" != "65532:750" && "$owner" != "?" ]]; then
    printf '%b  ⚠ host cache %s owned %s (expected 65532:750)%b\n' "$YEL" "$zot_cache_dir" "$owner" "$RST"
    recommend "Zot cache ownership drift can crash the pod: make zot-cache-reset"
  fi
fi

section "PULL-THROUGH REGISTRY MIRROR"
mirror_up=$(docker ps --filter name=registry-cache --format '{{.Names}}' 2>/dev/null | grep -c . || true)
printf '  %s/5 pull-through proxies running\n' "$mirror_up"
if [[ "$mirror_up" -lt 5 ]]; then
  printf '%b  ⚠ some registry-cache proxies are down — cold-start pulls hit upstream%b\n' "$YEL" "$RST"
  recommend "Restart the pull-through caches: bash scripts/registry-cache.sh up"
fi
# An empty hosts.toml silently disables the mirror for that registry.
if docker ps --filter "name=^/${cluster_name}-control-plane$" --format '{{.Names}}' 2>/dev/null | grep -q .; then
  empty_hosts=$(docker exec "${cluster_name}-control-plane" sh -c 'for d in /etc/containerd/certs.d/*/; do [ -s "${d}hosts.toml" ] || echo "${d}"; done' 2>/dev/null || true)
  if [[ -n "$empty_hosts" ]]; then
    printf '%b  ⚠ empty containerd hosts.toml (mirror bypassed):%b\n%s\n' "$YEL" "$RST" "$empty_hosts"
    recommend "Re-apply the mirror node config: bash -c 'source scripts/registry-cache.sh && registry_cache_configure_node ${cluster_name}-control-plane'"
  fi
fi

section "SIGNALLOOM SERVICES"
for ns in fe-signalloom inf-signalloom inf-bao; do
  pods=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | wc -l)
  ready=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | grep -c 'Running' || true)
  printf '  %-20s %s/%s pods running\n' "$ns" "$ready" "$pods"
done

section "SLOWEST WAITS (WAIT_STAT ranking)"
# If the last run exported WAIT_STAT_FILE (scripts/lib/wait.sh), rank waits by
# how much of their budget they consumed — a deterministic list of exactly which
# deadlines to raise, far better than inferring it from retry noise.
wait_stat_file="${WAIT_STAT_FILE:-/tmp/osramp-wait-stats}"
if [[ -s "$wait_stat_file" ]]; then
  grep '^WAIT_STAT' "$wait_stat_file" 2>/dev/null | while IFS= read -r line; do
    ratio=$(printf '%s' "$line" | grep -oE 'ratio=[0-9]+' | cut -d= -f2)
    site=$(printf '%s' "$line" | sed -E 's/.*site="([^"]*)".*/\1/')
    result=$(printf '%s' "$line" | grep -oE 'result=[a-z]+' | cut -d= -f2)
    printf '%s|%s|%s\n' "${ratio:-0}" "$site" "${result:-?}"
  done | sort -t'|' -k1 -rn | head -5 \
    | awk -F'|' '{printf "  %3s%%  %-40s (%s)\n", $1, $2, $3}'
  recommend "Raise the deadline on any wait consistently near 100% ratio above (edit its call in scripts/, or run with WAIT_DEADLINE_SCALE for a saturated host)."
else
  printf '  no WAIT_STAT_FILE — export WAIT_STAT_FILE before a run to rank slow waits\n'
fi

section "SUMMARY"
if [[ -z "$unhealthy" ]]; then
  printf '%b  ✓ Cluster healthy%b\n' "$GRN" "$RST"
else
  count=$(echo "$unhealthy" | wc -l)
  printf '%b  ✗ %s unhealthy pod(s)%b\n' "$RED" "$count" "$RST"
fi

section "RECOMMENDED NEXT STEPS"
if [[ ${#recommendations[@]} -eq 0 ]]; then
  printf '%b  ✓ No corrective action is recommended%b\n' "$GRN" "$RST"
else
  printf '  Run these read-only inspections before making a change:\n'
  printf '  - %s\n' "${recommendations[@]}"
fi
