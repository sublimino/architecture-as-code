#!/usr/bin/env bash
# Complete SLDPB25-P3-2 gate. Independent stages continue after failures so the
# resulting output records every boundary attempted during one invocation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FAILURES=0

run_stage() {
  local name="$1"
  shift
  printf '\n==> TEST-1: %s\n' "$name"
  if "$@"; then
    printf '==> TEST-1 PASS: %s\n' "$name"
  else
    local status=$?
    printf '==> TEST-1 FAIL: %s (exit %d)\n' "$name" "$status" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

cd "$REPO_ROOT"

run_stage "static topology, Gateway, probes, Dex, and policy contracts" \
  env LC_ALL=C LANG=C make -C d2-signalloom test
run_stage "API contracts and persistence" \
  bash -c 'cd d2-signalloom/apps/fe-signalloom/src && \
    uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist \
      --with-requirements requirements.txt python -m pytest tests -q'
run_stage "deterministic fake integrations" \
  env PYTHONPATH=d2-signalloom/apps/fake-integration-proxy \
    python3 -m unittest discover \
    -s d2-signalloom/apps/fake-integration-proxy/test -p 'test_proxy.py'
run_stage "dashboard API ownership contract" \
  bash -c 'cd tools/demo-console && go test ./...'
run_stage "TEST-1 harness contract" \
  bats test/signalloom-test-1-harness.bats
run_stage "Flux and workload convergence" \
  env LC_ALL=C LANG=C make demo-signalloom-test
run_stage "Gateway, probes, Dex, and NetworkPolicy runtime negatives" \
  env LC_ALL=C LANG=C bats \
    d2-signalloom/test/runtime.bats d2-signalloom/test/test-1-runtime.bats
run_stage "Dex and complete dashboard journey matrix" \
  ./scripts/acceptance-test.sh signalloom-test-1.spec.ts

if ((FAILURES > 0)); then
  printf '\nTEST-1 failed in %d stage(s).\n' "$FAILURES" >&2
  exit 1
fi

printf '\nTEST-1 passed every integrated stage.\n'
