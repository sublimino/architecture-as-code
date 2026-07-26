#!/usr/bin/env bash
# Runtime proof for the one intentionally bounded OpenBao/SPIRE relationship.
set -euo pipefail

namespace="${SIGNALLOOM_NAMESPACE:-fe-signalloom}"
positive="${BAO_SPIRE_POSITIVE_JOB:-bao-spire-positive-proof}"
negative="${BAO_SPIRE_NEGATIVE_JOB:-bao-spire-negative-proof}"
timeout="${DEMO_WAIT_TIMEOUT:-10m}"

command -v kubectl >/dev/null 2>&1 || { echo 'kubectl is required for Bao/SPIRE proof' >&2; exit 1; }
kubectl -n "$namespace" wait "job/$positive" --for=condition=complete --timeout="$timeout"
if kubectl -n "$namespace" wait "job/$negative" --for=condition=complete --timeout=1s >/dev/null 2>&1; then
  echo 'negative Bao/SPIRE identity unexpectedly succeeded' >&2
  exit 1
fi
kubectl -n "$namespace" wait "job/$negative" --for=condition=failed --timeout="$timeout"
if ! kubectl -n "$namespace" logs "job/$negative" -c jwt-svid | grep -Fq 'denied as expected'; then
  echo 'negative Bao/SPIRE proof did not emit its denial marker' >&2
  exit 1
fi
printf 'bounded Bao/SPIRE positive and negative identity proof passed\n'
