#!/usr/bin/env bash
#
# docs-render-check.sh — build the docs portal, serve it, render-check it in
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
  if ss -tln 2>/dev/null | grep -q ":${PORT} "; then
    for p in $(seq 4326 4399); do
      if ! ss -tln 2>/dev/null | grep -q ":${p} "; then
        PORT="${p}"
        break
      fi
    done
  fi
fi
PREVIEW_PID=""
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/tmp/.config}"
export BUN_TMPDIR="${BUN_TMPDIR:-/tmp}"
export PW_CHANNEL="${PW_CHANNEL:-chromium}"

cleanup() {
  if [[ -n "${PREVIEW_PID}" ]]; then
    kill -TERM -"${PREVIEW_PID}" 2>/dev/null || kill "${PREVIEW_PID}" 2>/dev/null || true
    wait "${PREVIEW_PID}" 2>/dev/null || true
  fi
  bun run --cwd "${DOCS_APP}" astro preview stop 2>/dev/null || true
  rm -f "${DOCS_APP}/.astro/preview.json"
}
trap cleanup EXIT INT TERM

echo "==> [1/4] Building the documentation portal"
ASTRO_TELEMETRY_DISABLED=1 bun run --cwd "${DOCS_APP}" build

echo "==> [2/4] Auditing internal links in the build"
bun run --cwd "${DOCS_APP}" audit:links

echo "==> [3/4] Serving dist on 127.0.0.1:${PORT}"
# setsid plus all three fds redirected. Without setsid the child dies with this
# shell's session; without the fd redirection it keeps writing into whatever
# stream the caller handed us, which makes a harness read the run as unfinished.
setsid env ASTRO_TELEMETRY_DISABLED=1 XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/tmp/.config}" bun run --cwd "${DOCS_APP}" astro preview \
  --root "${DOCS_APP}" --port "${PORT}" --host 127.0.0.1 \
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
if [[ -z "${PLAYWRIGHT_BROWSERS_PATH:-}" ]]; then
  if [[ -d "${REPO_ROOT}/.cache/ms-playwright" ]]; then
    export PLAYWRIGHT_BROWSERS_PATH="${REPO_ROOT}/.cache/ms-playwright"
  elif [[ -d "${HOME}/.cache/ms-playwright" ]]; then
    export PLAYWRIGHT_BROWSERS_PATH="${HOME}/.cache/ms-playwright"
  fi
fi

bun run playwright test --config=playwright.config.ts --project=docs "$@"

echo "✅ Documentation portal built, link-audited and render-checked."
