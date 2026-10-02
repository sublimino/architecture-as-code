#!/usr/bin/env bash
# SLAAT-P1-PRE: capture the pre-attack test baseline per attack slice, so the
# Phase 1 probe cards and the Phase 3 replay measure their delta against a
# recorded starting point. Runs offline suites only (plus the read-only
# `make healthcheck`). Every slice runs even if an earlier one fails; the
# per-slice rc and summary tail land in $OUT/summary.tsv, full logs beside it.
#
# Env:
#   SLAAT_BASELINE_OUT   output dir (default: fresh mktemp dir)
#   SLAAT_CACHE_ROOT     parent for Go/uv caches (default: $OUT/cache)
#   SLAAT_SLICES         space-separated subset of slice names to run
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="${SLAAT_BASELINE_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/slaat-baseline.XXXXXX")}"
CACHE_ROOT="${SLAAT_CACHE_ROOT:-$OUT/cache}"
export GOCACHE="$CACHE_ROOT/gocache" GOMODCACHE="$CACHE_ROOT/gomodcache" \
  GOPATH="$CACHE_ROOT/gopath" UV_CACHE_DIR="$CACHE_ROOT/uv-cache" CGO_ENABLED=0 \
  UV_CONFIG_FILE=/dev/null GONOSUMDB='*'
mkdir -p "$OUT" "$GOCACHE" "$GOMODCACHE" "$GOPATH" "$UV_CACHE_DIR"
cd "$REPO_ROOT"

FE_PYTEST=(uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with respx
  --with-requirements requirements.txt python -m pytest tests -q --disable-warnings)

# name|command (bash -c). Order: acceptance gates first, then attack slices.
SLICES=(
  "acceptance-eap-offline|make test-eap-offline"
  "acceptance-postgres-persistence|make test-postgres-persistence"
  "acceptance-zot-cache|make test-zot-cache"
  "acceptance-healthcheck|make healthcheck"
  "ingress-eap-reconcile|bats d2-signalloom/test/eap-ingress-reconcile.bats d2-signalloom/test/api-route-liveness.bats"
  "api-fe-signalloom-pytest|cd d2-signalloom/apps/fe-signalloom/src && ${FE_PYTEST[*]}"
  "api-authz-liveness|bats d2-signalloom/test/authz-suite-liveness.bats"
  "spiffe-agent-trust|make -C d2-agent-trust test"
  "spiffe-bao-spire-proof|make test-bao-spire-proof-harness"
  "containment-stun-sentinel-go|cd d2-signalloom/apps/stun-sentinel && go test ./..."
  "containment-signalloom-stun-sentinel-go|cd d2-signalloom/apps/signalloom-stun-sentinel && go test ./..."
  "containment-nono-probe-go|cd d2-signalloom/apps/nono-containment-probe && go test ./..."
  "containment-olly-sentinel-pytest|cd olly-replica/apps/sentinel && uv run --python 3.12 --with-requirements requirements.txt python -m pytest tests -q"
  "containment-tetragon-bats|make test-tetragon-bats"
  "estate-test-all-offline|make test-all-offline"
)

printf 'slice\trc\tseconds\ttail\n' > "$OUT/summary.tsv"
for entry in "${SLICES[@]}"; do
  name="${entry%%|*}"; cmd="${entry#*|}"
  if [ -n "${SLAAT_SLICES:-}" ] && [[ " $SLAAT_SLICES " != *" $name "* ]]; then continue; fi
  echo ">>> $name" >&2
  start=$(date +%s)
  (bash -c "$cmd") > "$OUT/$name.log" 2>&1 < /dev/null
  rc=$?
  secs=$(( $(date +%s) - start ))
  # Last non-blank line is usually the runner's own verdict (pytest/go/bats/make).
  tail_line="$(rg -v '^\s*$' "$OUT/$name.log" | tail -1 | tr '\t' ' ' | cut -c1-200)"
  printf '%s\t%s\t%s\t%s\n' "$name" "$rc" "$secs" "$tail_line" >> "$OUT/summary.tsv"
  echo "<<< $name rc=$rc ${secs}s" >&2
done
echo "$OUT"
