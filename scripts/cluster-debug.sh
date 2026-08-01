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

section "SIGNALLOOM SERVICES"
for ns in fe-signalloom inf-signalloom inf-bao; do
  pods=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | wc -l)
  ready=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | grep -c 'Running' || true)
  printf '  %-20s %s/%s pods running\n' "$ns" "$ready" "$pods"
done

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
