#!/usr/bin/env bash
#
# docs-render-check.sh — build both docs portals, serve them, render-check in
# Chromium, tear the server down. No cluster, no auth, no gateway.
#
# Why it serves the tree's own build rather than probing the demo cluster:
# docs/signalloom/slon-p3-docs-portal-provenance.md §4 records that every Flux
# source in the demo cluster is an OCIRepository carrying no git revision, and
# that the running docs-signalloom image was published from
# feat/signal-loop-and-bootstrap-refactor. A probe of
# https://dashboard.osramp.acme.local/docs is therefore evidence about a
# deployed artifact and never about the branch under test — SLON-P1-PRE already
# recorded /docs/ -> 200 OK as a property of the integration line when it was a
# property of a different branch.
#
# Runs: docs.spec.ts
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS_APP="${REPO_ROOT}/d2-signalloom/apps/docs-signalloom"
TEST_DIR="${REPO_ROOT}/test/acceptance"
PORT="${DOCS_PREVIEW_PORT:-}"
if [[ -z "${PORT}" ]]; then
  PORT=4325
  if grep -q ":${PORT} " <<<"$(ss -tln 2>/dev/null)"; then
    for p in $(seq 4326 4399); do
      if ! grep -q ":${p} " <<<"$(ss -tln 2>/dev/null)"; then
        PORT="${p}"
        break
      fi
    done
  fi
fi
PREVIEW_PID=""
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/tmp/.config}"
export BUN_TMPDIR="${BUN_TMPDIR:-/tmp}"

cleanup() {
  if [[ -n "${PREVIEW_PID}" ]]; then
    kill -TERM -"${PREVIEW_PID}" 2>/dev/null || kill "${PREVIEW_PID}" 2>/dev/null || true
    wait "${PREVIEW_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

echo "==> [1/4] Building both documentation portals"
ASTRO_TELEMETRY_DISABLED=1 bun run --cwd "${DOCS_APP}" build:all

echo "==> [2/4] Auditing internal links in the build"
bun run --cwd "${DOCS_APP}" audit:links

echo "==> [3/4] Serving dist and dist-dev-docs on 127.0.0.1:${PORT}"
# setsid plus all three fds redirected. Without setsid the child dies with this
# shell's session; without the fd redirection it keeps writing into whatever
# stream the caller handed us, which makes a harness read the run as unfinished.
setsid env DOCS_PREVIEW_PORT="${PORT}" node "${DOCS_APP}/scripts/preview-portals.mjs" \
  </dev/null >/dev/null 2>&1 &
PREVIEW_PID=$!

# Poll for readiness rather than sleeping a fixed interval: a sleep is either a
# wasted wall-clock or a flake, depending on the machine.
ready=0
for _ in $(seq 1 60); do
  if curl -sf -o /dev/null "http://127.0.0.1:${PORT}/docs/"; then ready=1; break; fi
  sleep 0.5
done
if [[ "${ready}" -ne 1 ]]; then
  echo "    ERROR: preview server did not answer on 127.0.0.1:${PORT} within 30s." >&2
  exit 1
fi
echo "    ✓ preview server ready"

echo "==> [4/4] Rendering the docs pages in Chromium"
cd "${TEST_DIR}"
if [[ ! -d node_modules/@playwright ]]; then
  bun install --frozen-lockfile 2>/dev/null || bun install
fi

export DOCS_BASE_URL="http://127.0.0.1:${PORT}/docs"
export DEV_DOCS_BASE_URL="http://127.0.0.1:${PORT}/dev-docs"
if [[ -z "${PLAYWRIGHT_BROWSERS_PATH:-}" ]]; then
  if [[ -d "${REPO_ROOT}/.cache/ms-playwright" ]]; then
    export PLAYWRIGHT_BROWSERS_PATH="${REPO_ROOT}/.cache/ms-playwright"
  elif [[ -d "${HOME}/.cache/ms-playwright" ]]; then
    export PLAYWRIGHT_BROWSERS_PATH="${HOME}/.cache/ms-playwright"
  fi
fi

if [[ -z "${PW_CHANNEL:-}" ]]; then
  if node --input-type=module -e 'import { chromium } from "@playwright/test"; const browser = await chromium.launch({ headless: true, timeout: 5000 }); await browser.close();' 2>/dev/null; then
    export PW_CHANNEL=chromium
  elif command -v google-chrome >/dev/null 2>&1 || command -v google-chrome-stable >/dev/null 2>&1; then
    export PW_CHANNEL=chrome
  else
    echo "ERROR: Install Playwright Chromium or set PW_CHANNEL to an installed browser." >&2
    exit 1
  fi
fi

bun run playwright test --config=playwright.config.ts --project=docs "$@"

echo "✅ Documentation portals built, link-audited and render-checked."
