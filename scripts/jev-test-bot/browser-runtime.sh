#!/usr/bin/env bash
#
# browser-runtime.sh — is the browser-mode runtime available here?
#
# Browser mode needs four things, and when one is missing the failure needs to
# name itself. A `bats` suite that skips with no reason, or a loop that reports
# "0 routes rendered" because Chromium was never installed, is worse than a
# red test: both read as information about the application.
#
#   1. a JS runtime (bun, or node)
#   2. the Playwright package — the SAME one test/acceptance already installs,
#      not a new dependency (`cd test/acceptance && bun install`)
#   3. a Chromium build Playwright can exec (`bunx playwright install chromium`)
#   4. the dashboard's own node_modules, so vite can serve a bundle a browser
#      can execute (`cd d2-signalloom/apps/dashboard-signalloom && bun install`)
#
# 1-3 are delegated to the driver itself (`browser_driver.mjs --check-runtime`),
# which is the only thing that knows how it resolves Playwright; 4 is checked
# here because it belongs to the dashboard, not the driver.
#
# Usage:
#   browser-runtime.sh --check     # exit 0 available, 1 not; reason on stdout
#   browser-runtime.sh --runtime   # print the JS runtime to use, or exit 1
#
# Deliberately NOT using `set -u`: Claude Code's shell snapshot injects
# grep/rg wrappers that reference $ZSH_VERSION unguarded.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DASHBOARD_DIR="${REPO_ROOT}/d2-signalloom/apps/dashboard-signalloom"

if [[ -z "${PLAYWRIGHT_BROWSERS_PATH:-}" || ! -d "${PLAYWRIGHT_BROWSERS_PATH}" ]]; then
  if [[ -d "${REPO_ROOT}/.cache/ms-playwright" ]]; then
    export PLAYWRIGHT_BROWSERS_PATH="${REPO_ROOT}/.cache/ms-playwright"
  elif [[ -d "${HOME}/.cache/ms-playwright" ]]; then
    export PLAYWRIGHT_BROWSERS_PATH="${HOME}/.cache/ms-playwright"
  fi
fi

# bun first: it is this repo's documented JS runtime and starts faster. node is
# accepted because the driver is plain ESM with no bun-specific API.
js_runtime() {
  if [[ -n "${JEV_JS_RUNTIME}" ]]; then
    command -v "${JEV_JS_RUNTIME}" >/dev/null 2>&1 && { printf '%s\n' "${JEV_JS_RUNTIME}"; return 0; }
    return 1
  fi
  for candidate in bun node; do
    command -v "${candidate}" >/dev/null 2>&1 && { printf '%s\n' "${candidate}"; return 0; }
  done
  return 1
}

check() {
  local runtime
  if ! runtime="$(js_runtime)"; then
    printf 'no JS runtime found (wanted bun or node on PATH)\n'
    return 1
  fi

  # The dashboard bundle. Browser mode against a LOCALLY started dashboard
  # needs vite, because the static SPA shell serves `index.html` pointing at
  # `/src/main.tsx` — which a real browser cannot execute. An externally
  # supplied --url does not need it, but this probe answers the general
  # question and the loop's own default is to start one locally.
  if [[ ! -x "${DASHBOARD_DIR}/node_modules/.bin/vite" ]]; then
    printf 'dashboard node_modules missing — browser mode cannot serve an executable bundle (cd %s && bun install)\n' \
      "d2-signalloom/apps/dashboard-signalloom"
    return 1
  fi

  local out
  if ! out="$("${runtime}" "${SCRIPT_DIR}/browser_driver.mjs" --check-runtime 2>&1)"; then
    printf '%s\n' "${out}"
    return 1
  fi
  printf '%s (js runtime: %s)\n' "${out}" "${runtime}"
  return 0
}

main() {
  case "${1:---check}" in
    --check) check ;;
    --runtime) js_runtime || { printf 'no JS runtime found\n' >&2; return 1; } ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" ;;
    *) printf 'browser-runtime.sh: unknown option %s\n' "$1" >&2; return 2 ;;
  esac
}

main "$@"
