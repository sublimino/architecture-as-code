#!/usr/bin/env bash
#
# loop.sh — run the Jev exploratory bot over the WHOLE dashboard surface, for
# N iterations, against a dashboard instance this run owns.
#
# Two problems with `make test-bot` as it stood. It explores ONE area, so the
# surface it covers is whatever the caller remembered to type; and it defaults
# to the shared Tailscale deployment, so running it alongside the acceptance
# suites means two test runs interfering through one dashboard and one set of
# backend fixtures. Neither failure is loud: a run that explored one page
# reports PASS exactly like a run that explored forty.
#
# So this script owns its target. It derives the route list from App.tsx (see
# routes.py), starts a dashboard on a free port outside every range the other
# suites reserve, keeps its temp and profile directories inside the run's own
# report directory, and tears the lot down on exit. It then ASSERTS that the
# route list it explored covers the derived surface, and refuses to report a
# partial walk as a pass.
#
# Deliberately NOT using `set -u`: Claude Code's shell snapshot injects
# grep/rg wrapper functions that reference $ZSH_VERSION unguarded, which
# nounset turns into a fatal error on every grep call.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DASHBOARD_DIR="${REPO_ROOT}/d2-signalloom/apps/dashboard-signalloom"

# Ports other suites own. A collision here does not fail cleanly — it either
# steals a port a suite is about to bind, or attaches this run's bot to
# somebody else's server and reports their pages as ours.
#
#   8080-8099     port-forwards (policy-engine, fe-signalloom, and friends)
#   8200          OpenBao
#   5001          the local registry
#   18080-18099   secondary/remote-cluster port-forwards
#   30754         the dashboard NodePort on kind-osramp
#
# The search range below sits well clear of all of them.
PORT_SEARCH_LOW=41000
PORT_SEARCH_HIGH=44999

usage() {
  cat <<'USAGE'
Usage: loop.sh [options]

  --url URL            Explore an existing dashboard; start nothing locally.
  --iterations N       Iterations over the full surface (default: 1).
  --turns N            Max bot turns per route (default: 4).
  --timeout SEC        Max bot seconds per route (default: 10).
  --mock               Force the calibrated simulator (no TypeSafe network).
  --deep               Pass --deep to the bot (backend API sweep).
  --dashboard-mode M   auto | vite | static (default: auto).
  --routes-from FILE   Explore this route list instead of deriving from App.tsx.
  --allow-partial      Permit a route list that does not cover the derived surface.
  --run-id ID          Name the run (default: jev-<timestamp>-<pid>).
  --reports-dir DIR    Report root (default: <repo>/reports/jev).
  --print-port         Print a free, non-reserved port and exit.
  --print-routes       Print the derived route surface and exit.
  -h, --help           This text.

Environment equivalents, for the make wrapper: URL, N, MOCK, TURNS, TIMEOUT,
DEEP, DASHBOARD_MODE, JEV_REPORTS_DIR.

Exit codes: 0 pass · 1 defects found · 2 usage/setup · 3 dashboard would not
start · 4 the explored route list does not cover the derived surface.
USAGE
}

log() { printf '\033[1;36m[jev-loop]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m[jev-loop]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[31m[jev-loop]\033[0m %s\n' "$*" >&2; }

# ── Ports ──────────────────────────────────────────────────────────────────

# Kept as its own function so the bats suite can assert the policy directly
# rather than inferring it from whichever port a run happened to pick.
port_is_reserved() {
  local port="$1"
  [[ "${port}" =~ ^[0-9]+$ ]] || return 0
  (( port < 1024 )) && return 0
  (( port >= 8080 && port <= 8099 )) && return 0
  (( port == 8200 )) && return 0
  (( port == 5001 )) && return 0
  (( port >= 18080 && port <= 18099 )) && return 0
  (( port == 30754 )) && return 0
  return 1
}

port_is_free() {
  python3 - "$1" <<'PY'
import socket, sys
with socket.socket() as s:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", int(sys.argv[1])))
    except OSError:
        sys.exit(1)
sys.exit(0)
PY
}

find_free_port() {
  local attempt port span=$((PORT_SEARCH_HIGH - PORT_SEARCH_LOW + 1))
  for attempt in $(seq 1 200); do
    port=$(( PORT_SEARCH_LOW + RANDOM % span ))
    port_is_reserved "${port}" && continue
    port_is_free "${port}" || continue
    printf '%s\n' "${port}"
    return 0
  done
  fail "no free non-reserved port found in ${PORT_SEARCH_LOW}-${PORT_SEARCH_HIGH} after 200 tries"
  return 3
}

# ── Dashboard lifecycle ────────────────────────────────────────────────────

SERVER_PID=""
SERVER_PGID=""

cleanup() {
  local rc=$?
  if [[ -n "${SERVER_PGID}" ]]; then
    log "stopping dashboard (pgid ${SERVER_PGID})"
    # Negative PID targets the whole process group, which is why the server is
    # spawned under setsid: `vite` forks, and TERMing only the parent leaves
    # an esbuild child holding the port.
    kill -TERM "-${SERVER_PGID}" 2>/dev/null || true
    local waited=0
    while kill -0 "${SERVER_PID}" 2>/dev/null && (( waited < 20 )); do
      sleep 0.25
      waited=$((waited + 1))
    done
    kill -KILL "-${SERVER_PGID}" 2>/dev/null || true
  fi
  # Reports survive; scratch does not.
  [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"
  [[ -n "${PROFILE_DIR}" && -d "${PROFILE_DIR}" ]] && rm -rf "${PROFILE_DIR}"
  exit "${rc}"
}

resolve_dashboard_mode() {
  local requested="$1"
  case "${requested}" in
    vite|static) printf '%s\n' "${requested}"; return 0 ;;
    auto) ;;
    *) fail "unknown --dashboard-mode '${requested}'"; return 2 ;;
  esac
  # `vite` needs an installed dependency tree, and installing one needs the
  # network. Offline — which is the condition the bats suite runs under — the
  # static shell is the only honest option, so prefer it silently rather than
  # failing a run that was never going to have node_modules.
  if [[ -x "${DASHBOARD_DIR}/node_modules/.bin/vite" ]]; then
    printf 'vite\n'
  else
    printf 'static\n'
  fi
}

start_dashboard() {
  local mode="$1" port="$2" log_file="$3"

  case "${mode}" in
    vite)
      log "starting vite dev server on 127.0.0.1:${port} (VITE_SL_ENV=demo)"
      # VITE_SL_ENV=demo is the dashboard's existing documented env flag
      # (src/api/demoMode.ts): with it the runtime demo toggle defaults ON and
      # the api client short-circuits to local fixtures, so no backend is
      # needed. No dashboard source change was required for this.
      (
        cd "${DASHBOARD_DIR}" || exit 3
        exec setsid env \
          VITE_SL_ENV=demo \
          TMPDIR="${TMP_DIR}" \
          XDG_CACHE_HOME="${TMP_DIR}/cache" \
          XDG_CONFIG_HOME="${TMP_DIR}/config" \
          ./node_modules/.bin/vite --host 127.0.0.1 --port "${port}" --strictPort \
          </dev/null >"${log_file}" 2>&1 &
        printf '%s\n' "$!" >"${TMP_DIR}/server.pid"
      )
      ;;
    static)
      log "starting the static SPA shell on 127.0.0.1:${port}"
      (
        exec setsid env \
          TMPDIR="${TMP_DIR}" \
          python3 "${SCRIPT_DIR}/spa-server.py" \
            --directory "${DASHBOARD_DIR}" --port "${port}" \
          </dev/null >"${log_file}" 2>&1 &
        printf '%s\n' "$!" >"${TMP_DIR}/server.pid"
      )
      ;;
  esac

  # Poll for readiness rather than sleeping: a fixed sleep is either slower
  # than it needs to be or shorter than vite's cold start, and usually both.
  local waited=0
  while (( waited < 160 )); do
    if [[ -f "${TMP_DIR}/server.pid" ]]; then
      SERVER_PID="$(cat "${TMP_DIR}/server.pid")"
      SERVER_PGID="$(ps -o pgid= -p "${SERVER_PID}" 2>/dev/null | tr -d ' ')"
    fi
    if python3 - "${port}" <<'PY'
import socket, sys
with socket.socket() as s:
    s.settimeout(0.5)
    sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)
PY
    then
      log "dashboard ready after $((waited * 250))ms (pid ${SERVER_PID:-?}, pgid ${SERVER_PGID:-?})"
      return 0
    fi
    if [[ -n "${SERVER_PID}" ]] && ! kill -0 "${SERVER_PID}" 2>/dev/null; then
      fail "dashboard process exited before serving; last lines of ${log_file}:"
      tail -20 "${log_file}" >&2 || true
      return 3
    fi
    sleep 0.25
    waited=$((waited + 1))
  done
  fail "dashboard did not answer on 127.0.0.1:${port} within 40s"
  tail -20 "${log_file}" >&2 || true
  return 3
}

# ── Surface ────────────────────────────────────────────────────────────────

derive_surface() {
  python3 "${SCRIPT_DIR}/routes.py"
}

# The assertion that makes "cover the whole application surface" enforced
# rather than aspirational: whatever list we are about to explore must contain
# every route derived from App.tsx. A hand-trimmed list is a silent coverage
# regression otherwise.
assert_surface_covered() {
  local routes_file="$1" missing=() route
  local derived_file="${TMP_DIR}/derived-surface.txt"
  derive_surface >"${derived_file}"
  while IFS= read -r route; do
    [[ -z "${route}" ]] && continue
    grep -qxF -- "${route}" "${routes_file}" || missing+=("${route}")
  done <"${derived_file}"

  if (( ${#missing[@]} > 0 )); then
    if [[ "${ALLOW_PARTIAL}" == "true" ]]; then
      warn "route list omits ${#missing[@]} derived route(s); --allow-partial was given: ${missing[*]}"
      return 0
    fi
    fail "the route list does not cover the derived application surface."
    fail "missing ${#missing[@]} route(s): ${missing[*]}"
    fail "either explore them, or pass --allow-partial to accept a narrower walk."
    return 4
  fi
  return 0
}

route_slug() {
  local route="$1"
  if [[ "${route}" == "/" ]]; then
    printf 'root\n'
  else
    printf '%s\n' "${route#/}" | tr -c 'A-Za-z0-9._-' '_'
  fi
}

# ── Main ───────────────────────────────────────────────────────────────────

main() {
  local target_url="${URL:-}"
  local iterations="${N:-1}"
  local turns="${TURNS:-4}"
  local timeout="${TIMEOUT:-10}"
  local mock="${MOCK:-}"
  local deep="${DEEP:-}"
  local dashboard_mode="${DASHBOARD_MODE:-auto}"
  local routes_from=""
  local run_id=""
  local reports_root="${JEV_REPORTS_DIR:-${REPO_ROOT}/reports/jev}"
  local print_port="false" print_routes="false"
  ALLOW_PARTIAL="false"
  TMP_DIR=""
  PROFILE_DIR=""

  while (( $# > 0 )); do
    case "$1" in
      --url) target_url="$2"; shift 2 ;;
      --iterations) iterations="$2"; shift 2 ;;
      --turns) turns="$2"; shift 2 ;;
      --timeout) timeout="$2"; shift 2 ;;
      --mock) mock="true"; shift ;;
      --deep) deep="true"; shift ;;
      --dashboard-mode) dashboard_mode="$2"; shift 2 ;;
      --routes-from) routes_from="$2"; shift 2 ;;
      --allow-partial) ALLOW_PARTIAL="true"; shift ;;
      --run-id) run_id="$2"; shift 2 ;;
      --reports-dir) reports_root="$2"; shift 2 ;;
      --print-port) print_port="true"; shift ;;
      --print-routes) print_routes="true"; shift ;;
      -h|--help) usage; return 0 ;;
      *) fail "unknown option '$1'"; usage >&2; return 2 ;;
    esac
  done

  if [[ "${print_port}" == "true" ]]; then
    find_free_port
    return $?
  fi
  if [[ "${print_routes}" == "true" ]]; then
    derive_surface
    return $?
  fi

  [[ "${iterations}" =~ ^[0-9]+$ ]] || { fail "--iterations must be a number, got '${iterations}'"; return 2; }
  (( iterations >= 1 )) || { fail "--iterations must be at least 1"; return 2; }

  run_id="${run_id:-jev-$(date +%Y%m%d-%H%M%S)-$$}"
  local run_dir="${reports_root}/${run_id}"
  TMP_DIR="${run_dir}/tmp"
  PROFILE_DIR="${run_dir}/browser-profile"

  # Everything this run writes lives under its own report directory. Nothing
  # goes into a shared /tmp path, so two loops — or a loop and an acceptance
  # suite — cannot collide through scratch state.
  mkdir -p "${run_dir}" "${TMP_DIR}" "${PROFILE_DIR}"
  trap cleanup EXIT INT TERM

  # Honoured by anything this run spawns that cares; declared even where the
  # current HTTP-level bot does not use a browser, so that a future
  # browser-driven oracle inherits the isolation instead of reaching into
  # ~/.config.
  export TMPDIR="${TMP_DIR}"
  export XDG_CACHE_HOME="${TMP_DIR}/cache"
  export XDG_CONFIG_HOME="${TMP_DIR}/config"
  export JEV_BROWSER_PROFILE_DIR="${PROFILE_DIR}"
  mkdir -p "${XDG_CACHE_HOME}" "${XDG_CONFIG_HOME}"

  # Route list, then the coverage assertion, BEFORE anything is started: a
  # trimmed list should fail in a second, not after a dashboard boot.
  local routes_file="${run_dir}/routes.txt"
  if [[ -n "${routes_from}" ]]; then
    [[ -f "${routes_from}" ]] || { fail "no such route list: ${routes_from}"; return 2; }
    grep -v '^[[:space:]]*\(#.*\)\?$' "${routes_from}" >"${routes_file}" || true
    log "route list taken from ${routes_from}"
  else
    derive_surface >"${routes_file}"
    log "route surface derived from App.tsx"
  fi
  local route_count
  route_count="$(wc -l <"${routes_file}" | tr -d ' ')"
  (( route_count > 0 )) || { fail "empty route list"; return 2; }
  assert_surface_covered "${routes_file}" || return 4
  log "${route_count} route(s) to explore, ${iterations} iteration(s)"

  # Target: either one that already exists, or one this run owns.
  local base_url port="" started_locally="false" resolved_mode="external"
  if [[ -n "${target_url}" ]]; then
    base_url="${target_url%/}"
    log "targeting the supplied dashboard ${base_url}; starting nothing locally"
  else
    resolved_mode="$(resolve_dashboard_mode "${dashboard_mode}")" || return 2
    port="$(find_free_port)" || return 3
    base_url="http://127.0.0.1:${port}"
    started_locally="true"
    start_dashboard "${resolved_mode}" "${port}" "${run_dir}/dashboard.log" || return 3
  fi

  local bot_flags=()
  [[ "${mock}" == "true" ]] && bot_flags+=(--mock)
  [[ "${deep}" == "true" ]] && bot_flags+=(--deep)

  local iteration iteration_reports=() worst_rc=0
  for (( iteration = 1; iteration <= iterations; iteration++ )); do
    local areas_dir="${run_dir}/iteration-${iteration}-areas"
    mkdir -p "${areas_dir}"
    local started_at
    started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    log "── iteration ${iteration}/${iterations} ──"

    local index=0 route
    while IFS= read -r route; do
      [[ -z "${route}" ]] && continue
      index=$((index + 1))
      local out
      out="$(printf '%s/%03d-%s.json' "${areas_dir}" "${index}" "$(route_slug "${route}")")"
      # The bot exits 1 on any defect. That is a finding, not a reason to stop
      # exploring the rest of the surface, so the status is recorded and the
      # walk continues.
      set +e
      python3 "${SCRIPT_DIR}/bot.py" \
        --url "${base_url}" \
        --area "${route}" \
        --max-turns "${turns}" \
        --timeout "${timeout}" \
        --output "${out}" \
        "${bot_flags[@]}" \
        >>"${run_dir}/iteration-${iteration}.log" 2>&1
      local rc=$?
      set -e
      if (( rc > 1 )); then
        warn "bot exited ${rc} on ${route} (see iteration-${iteration}.log)"
      fi
    done <"${routes_file}"

    local iteration_report="${run_dir}/iteration-${iteration}.json"
    set +e
    python3 "${SCRIPT_DIR}/loop_report.py" iteration \
      --routes "${routes_file}" \
      --area-reports "${areas_dir}" \
      --out "${iteration_report}" \
      --run-id "${run_id}" \
      --iteration "${iteration}" \
      --base-url "${base_url}" \
      --dashboard-mode "${resolved_mode}" \
      --port "${port}" \
      --started-at "${started_at}" \
      --finished-at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --turns "${turns}" \
      --timeout "${timeout}" \
      $( [[ "${started_locally}" == "true" ]] && printf '%s' '--started-locally' )
    local report_rc=$?
    set -e
    if (( report_rc == 4 )); then
      fail "iteration ${iteration}: coverage partition is incomplete — refusing to report"
      return 4
    elif (( report_rc != 0 )); then
      fail "iteration ${iteration}: report generation failed (rc=${report_rc})"
      return 2
    fi
    iteration_reports+=("${iteration_report}")
  done

  local summary="${run_dir}/summary.json"
  python3 "${SCRIPT_DIR}/loop_report.py" summary \
    --iterations "${iteration_reports[@]}" \
    --out "${summary}" \
    --run-id "${run_id}" || return 2

  log "reports under ${run_dir}"
  if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["passed"] else 1)' "${summary}"; then
    log "PASS — no defects across ${iterations} iteration(s)"
    worst_rc=0
  else
    fail "FAIL — defects recorded; see ${summary}"
    worst_rc=1
  fi
  return "${worst_rc}"
}

main "$@"
