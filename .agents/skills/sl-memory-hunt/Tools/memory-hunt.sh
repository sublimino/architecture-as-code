#!/usr/bin/env bash
# memory-hunt.sh — find OOM/restart loops and measure working-set memory over time
#
# @id     sl-memory-hunt
# @doc    .agents/skills/sl-memory-hunt/SKILL.md
# @rules  .agents/skills/sl-memory-hunt/References/Classification.md
# @tests  test/sl-memory-hunt.bats
#
# Subcommands
#   scan    containers whose last termination was OOMKilled or whose restartCount
#           exceeds a threshold. Exit 1 when any is found.
#   sample  working-set series for a pod container (via the kind node's crictl, so
#           distroless images with no shell still work) or a host PID (/proc).
#   env     image + runtime env of a pod container (GOMAXPROCS, GOMEMLIMIT, ...).
#
# Exit codes: 0 clean/ok, 1 scan found OOM or restart loop, 2 usage, 3 tool or
# target error (cluster unreachable, pod not found, zero samples taken).
#
# Injectable boundaries (tests run against fixtures, no cluster):
#   KUBECTL     kubectl binary            (default: kubectl)
#   DOCKER      docker binary             (default: docker)
#   CRICTL_NODE kind node to exec crictl on (default: the pod's spec.nodeName)
#   PROC_ROOT   procfs root               (default: /proc)
#   SLEEP       sleep binary              (default: sleep)
set -o pipefail

KUBECTL="${KUBECTL:-kubectl}"
DOCKER="${DOCKER:-docker}"
PROC_ROOT="${PROC_ROOT:-/proc}"
SLEEP="${SLEEP:-sleep}"
CRICTL_NODE="${CRICTL_NODE:-}"

usage() {
  cat <<'EOF'
Usage:
  memory-hunt.sh scan   [-n NS | -A] [--threshold N] [--json]
  memory-hunt.sh sample (--pod POD [-n NS] [-c CONTAINER] | --pid PID)
                        [--interval SECS] [--duration SECS] [--json]
  memory-hunt.sh env    --pod POD [-n NS] [-c CONTAINER] [--json]

scan    Flags containers with lastState.terminated.reason == OOMKilled (or
        currently terminated OOMKilled) or restartCount > threshold (default 5).
        Exit 1 when any container is flagged.
sample  Working set every --interval seconds (default 15) for --duration
        seconds (default 60). Pods: crictl stats on the kind node
        (memory.workingSetBytes). PIDs: /proc/<pid>/status VmRSS, plus VmHWM.
        Prints the series, then first/last/peak MiB and peak % of limit.
env     Image config Env (crictl inspecti) and runtime env (crictl inspect).

A single sample misleads. Always take a series.
EOF
}

die() { echo "memory-hunt: $*" >&2; exit "${2:-3}"; }

need_jq() { command -v jq >/dev/null 2>&1 || die "jq not found"; }

# Kubernetes memory quantity -> bytes (integer). Empty/unknown -> empty.
quantity_to_bytes() {
  local q="$1"
  [ -z "$q" ] && return 0
  awk -v q="$q" 'BEGIN {
    n = q; sub(/[A-Za-z]+$/, "", n); u = substr(q, length(n) + 1)
    m["Ki"]=1024; m["Mi"]=1048576; m["Gi"]=1073741824; m["Ti"]=1099511627776
    m["k"]=1000; m["K"]=1000; m["M"]=1000000; m["G"]=1000000000; m["T"]=1000000000000
    m[""]=1
    if (!(u in m)) exit 0
    printf "%.0f\n", n * m[u]
  }'
}

mib() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1048576 }'; }

# ---------------------------------------------------------------- scan
cmd_scan() {
  local ns_args=(-A) threshold=5 json=false
  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--namespace) [ -n "${2:-}" ] || die "-n needs a value" 2; ns_args=(-n "$2"); shift 2 ;;
      -A|--all-namespaces) ns_args=(-A); shift ;;
      --threshold) [ -n "${2:-}" ] || die "--threshold needs a value" 2; threshold="$2"; shift 2 ;;
      --json) json=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "scan: unknown option '$1'" 2 ;;
    esac
  done
  case "$threshold" in ''|*[!0-9]*) die "--threshold must be a non-negative integer" 2 ;; esac
  need_jq

  local pods
  pods=$("$KUBECTL" get pods "${ns_args[@]}" -o json 2>/dev/null) || die "kubectl get pods failed (cluster unreachable?)"
  printf '%s' "$pods" | jq -e '.items | type == "array"' >/dev/null 2>&1 || die "kubectl returned no pod list"

  local findings
  findings=$(printf '%s' "$pods" | jq --argjson t "$threshold" '
    [ .items[] as $p
      | ($p.spec.containers // []) as $specs
      | (($p.status.containerStatuses // []) + ($p.status.initContainerStatuses // []))[]
      | . as $cs
      | ($cs.lastState.terminated // {}) as $last
      | ($cs.state.terminated // {}) as $now
      | (($last.reason == "OOMKilled") or ($now.reason == "OOMKilled")) as $oom
      | (($cs.restartCount // 0) > $t) as $loop
      | select($oom or $loop)
      | {
          namespace: $p.metadata.namespace,
          pod: $p.metadata.name,
          container: $cs.name,
          restarts: ($cs.restartCount // 0),
          last_reason: ($last.reason // $now.reason // null),
          last_finished_at: (if $now.reason == "OOMKilled" then $now.finishedAt else ($last.finishedAt // null) end),
          last_oom_at: (if $now.reason == "OOMKilled" then $now.finishedAt
                        elif $last.reason == "OOMKilled" then $last.finishedAt else null end),
          memory_limit: ([ $specs[] | select(.name == $cs.name) | .resources.limits.memory ] | first // null),
          flags: ([ (if $oom then "oom" else empty end), (if $loop then "restarts" else empty end) ])
        }
    ]')

  local count
  count=$(printf '%s' "$findings" | jq 'length')
  if $json; then
    printf '%s' "$findings" | jq --argjson t "$threshold" '{threshold: $t, flagged: length, containers: .}'
  else
    if [ "$count" -eq 0 ]; then
      echo "CLEAN: no OOMKilled containers, none above ${threshold} restarts"
    else
      echo "FLAGGED: ${count} container(s) (OOMKilled last state, or restarts > ${threshold})"
      printf '%s' "$findings" | jq -r '.[] |
        "  \(.namespace)/\(.pod) [\(.container)] restarts=\(.restarts) last=\(.last_reason // "-") at=\(.last_finished_at // "-") limit=\(.memory_limit // "none") flags=\(.flags | join(","))" +
        (if .last_oom_at then " last_oom=\(.last_oom_at)" else "" end)'
    fi
  fi
  [ "$count" -eq 0 ] || return 1
  return 0
}

# ---------------------------------------------------------------- pod resolution
# Sets: POD_NODE POD_CID POD_CONTAINER POD_LIMIT POD_IMAGE_REF
resolve_pod() {
  local ns="$1" pod="$2" container="$3" json matches
  if ! json=$("$KUBECTL" get pod "$pod" -n "$ns" -o json 2>/dev/null); then
    # Pods churn (rollouts, OOM restarts with a new ReplicaSet): accept a name
    # prefix such as "signal-ingest" when exactly one Running pod matches.
    matches=$("$KUBECTL" get pods -n "$ns" -o json 2>/dev/null | jq -r --arg p "$pod" '
      [.items[] | select((.metadata.name | startswith($p + "-")) and .status.phase == "Running") | .metadata.name] | .[]') \
      || die "pod ${ns}/${pod} not found"
    [ -n "$matches" ] || die "pod ${ns}/${pod} not found (no exact name, no Running pod with that prefix)"
    [ "$(printf '%s\n' "$matches" | wc -l | tr -d ' ')" -eq 1 ] \
      || die "pod prefix '${pod}' is ambiguous in ${ns}: $(printf '%s' "$matches" | tr '\n' ' ')"
    pod="$matches"
    json=$("$KUBECTL" get pod "$pod" -n "$ns" -o json 2>/dev/null) || die "pod ${ns}/${pod} not found"
  fi
  RESOLVED_POD="$pod"
  [ -n "$container" ] || container=$(printf '%s' "$json" | jq -r '.spec.containers[0].name')
  POD_CONTAINER="$container"
  POD_NODE="${CRICTL_NODE:-$(printf '%s' "$json" | jq -r '.spec.nodeName // empty')}"
  POD_CID=$(printf '%s' "$json" | jq -r --arg c "$container" '
    [.status.containerStatuses[]? | select(.name == $c) | .containerID] | first // empty' | sed 's|^[a-z]*://||')
  POD_IMAGE_REF=$(printf '%s' "$json" | jq -r --arg c "$container" '
    [.status.containerStatuses[]? | select(.name == $c) | .imageID] | first // empty')
  POD_LIMIT=$(quantity_to_bytes "$(printf '%s' "$json" | jq -r --arg c "$container" '
    [.spec.containers[] | select(.name == $c) | .resources.limits.memory] | first // empty')")
  [ -n "$POD_NODE" ] || die "cannot resolve node for ${ns}/${pod}"
  [ -n "$POD_CID" ] || die "container '${container}' in ${ns}/${pod} has no running containerID"
}

read_pod_ws() {
  "$DOCKER" exec "$POD_NODE" crictl stats -o json "$POD_CID" 2>/dev/null \
    | jq -r '.stats[0].memory.workingSetBytes.value // empty' 2>/dev/null
}

# VmRSS in bytes, or empty if the process is gone
read_pid_field() {
  local pid="$1" field="$2" f="${PROC_ROOT}/$1/status"
  [ -r "$f" ] || return 0
  awk -v k="${field}:" '$1 == k { printf "%.0f\n", $2 * 1024; exit }' "$f"
}

# ---------------------------------------------------------------- sample
cmd_sample() {
  local ns="default" pod="" container="" pid="" interval=15 duration=60 json=false
  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--namespace) ns="${2:?}"; shift 2 ;;
      --pod) pod="${2:?}"; shift 2 ;;
      -c|--container) container="${2:?}"; shift 2 ;;
      --pid) pid="${2:?}"; shift 2 ;;
      --interval) interval="${2:?}"; shift 2 ;;
      --duration) duration="${2:?}"; shift 2 ;;
      --json) json=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "sample: unknown option '$1'" 2 ;;
    esac
  done
  if [ -n "$pod" ] && [ -n "$pid" ]; then die "sample: --pod and --pid are exclusive" 2; fi
  if [ -z "$pod" ] && [ -z "$pid" ]; then die "sample: need --pod or --pid" 2; fi
  case "$interval$duration" in *[!0-9]*) die "--interval/--duration must be integers (seconds)" 2 ;; esac
  [ "$interval" -gt 0 ] || die "--interval must be > 0" 2
  need_jq

  local target limit="" mode
  if [ -n "$pod" ]; then
    resolve_pod "$ns" "$pod" "$container"
    target="${ns}/${RESOLVED_POD}/${POD_CONTAINER}"; limit="$POD_LIMIT"; mode="crictl"
  else
    [ -r "${PROC_ROOT}/${pid}/status" ] || die "pid ${pid}: ${PROC_ROOT}/${pid}/status not readable"
    target="pid:${pid}"; mode="proc"
  fi

  local n=$(( (duration + interval - 1) / interval )); [ "$n" -ge 1 ] || n=1
  local i=0 v t series="" hwm=""
  $json || echo "sampling ${target} via ${mode}: every ${interval}s for ${duration}s (${n} samples)"
  while [ "$i" -lt "$n" ]; do
    if [ "$mode" = crictl ]; then v=$(read_pod_ws); else v=$(read_pid_field "$pid" VmRSS); fi
    [ -n "$v" ] || { $json || echo "  t=$((i * interval))s target gone or unreadable, stopping"; break; }
    if [ "$mode" = proc ]; then hwm=$(read_pid_field "$pid" VmHWM); fi
    t=$((i * interval))
    series="${series}${t} ${v}"$'\n'
    $json || printf '  t=%4ss  %10s MiB  (%s)\n' "$t" "$(mib "$v")" "$(date -u +%H:%M:%SZ)"
    i=$((i + 1))
    [ "$i" -lt "$n" ] && "$SLEEP" "$interval"
  done
  [ -n "$series" ] || die "no samples taken for ${target}"

  local stats
  stats=$(printf '%s' "$series" | awk 'NF == 2 {
      if (c == 0) first = $2; last = $2; if ($2 > peak) { peak = $2; pt = $1 }; c++ }
    END { printf "%d %.0f %.0f %.0f %d\n", c, first, last, peak, pt }')
  local count first last peak peak_t
  read -r count first last peak peak_t <<EOF
$stats
EOF
  local pct=""
  [ -n "$limit" ] && [ "$limit" -gt 0 ] 2>/dev/null && pct=$(awk -v p="$peak" -v l="$limit" 'BEGIN { printf "%.1f", 100 * p / l }')

  if $json; then
    printf '%s' "$series" | jq -R -s \
      --arg target "$target" --arg mode "$mode" --argjson interval "$interval" \
      --argjson peak "$peak" --argjson first "$first" --argjson last "$last" --argjson peak_t "$peak_t" \
      --arg limit "$limit" --arg pct "$pct" --arg hwm "$hwm" '
      { target: $target, source: $mode, interval_s: $interval,
        samples: [ split("\n")[] | select(length > 0) | split(" ") | {t_s: (.[0] | tonumber), bytes: (.[1] | tonumber)} ],
        first_bytes: $first, last_bytes: $last, peak_bytes: $peak, peak_at_s: $peak_t,
        peak_mib: (($peak / 1048576 * 10 | round) / 10),
        limit_bytes: (if $limit == "" then null else ($limit | tonumber) end),
        peak_pct_of_limit: (if $limit == "" then null else (($peak / ($limit | tonumber) * 1000 | round) / 10) end),
        vmhwm_bytes: (if $hwm == "" then null else ($hwm | tonumber) end) }'
  else
    echo "samples=${count} first=$(mib "$first") MiB last=$(mib "$last") MiB peak=$(mib "$peak") MiB at t=${peak_t}s"
    [ -n "$limit" ] && echo "limit=$(mib "$limit") MiB peak_pct_of_limit=${pct:-?}%"
    [ -n "$hwm" ] && echo "VmHWM=$(mib "$hwm") MiB (kernel high-water mark since process start)"
  fi
  return 0
}

# ---------------------------------------------------------------- env
cmd_env() {
  local ns="default" pod="" container="" json=false
  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--namespace) ns="${2:?}"; shift 2 ;;
      --pod) pod="${2:?}"; shift 2 ;;
      -c|--container) container="${2:?}"; shift 2 ;;
      --json) json=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "env: unknown option '$1'" 2 ;;
    esac
  done
  [ -n "$pod" ] || die "env: need --pod" 2
  need_jq
  resolve_pod "$ns" "$pod" "$container"
  local img_env run_env image
  image=$("$DOCKER" exec "$POD_NODE" crictl inspect "$POD_CID" 2>/dev/null | jq -r '.status.image.image // .status.imageRef // empty')
  img_env=$("$DOCKER" exec "$POD_NODE" crictl inspecti "${image:-$POD_IMAGE_REF}" 2>/dev/null | jq -c '.info.imageSpec.config.Env // []')
  run_env=$("$DOCKER" exec "$POD_NODE" crictl inspect "$POD_CID" 2>/dev/null | jq -c '.info.runtimeSpec.process.env // []')
  if $json; then
    jq -n --arg image "$image" --argjson i "${img_env:-[]}" --argjson r "${run_env:-[]}" \
      '{image: $image, image_env: $i, runtime_env: $r}'
  else
    echo "image: ${image:-unknown}"
    echo "image env:";   printf '%s' "${img_env:-[]}" | jq -r '.[] | "  " + .'
    echo "runtime env:"; printf '%s' "${run_env:-[]}" | jq -r '.[] | "  " + .'
  fi
}

main() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    scan) cmd_scan "$@" ;;
    sample) cmd_sample "$@" ;;
    env) cmd_env "$@" ;;
    -h|--help|help) usage ;;
    "") usage >&2; exit 2 ;;
    *) echo "memory-hunt: unknown subcommand '$sub'" >&2; usage >&2; exit 2 ;;
  esac
}

main "$@"
