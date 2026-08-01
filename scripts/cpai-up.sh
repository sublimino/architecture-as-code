#!/usr/bin/env bash
# cpai-up.sh — Deploy the CPAI runtime proxy into its own namespace.
# Idempotent: safe to re-run. Does not touch other demos.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/wait.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/wait.sh"

echo "==> Applying CPAI runtime manifests to cpai namespace"
kubectl apply -k d2-cpai/apps/cpai-runtime/local

# The runtime calls Vertex AI, so it needs Application Default Credentials
# mounted as the cpai-gcp-adc secret. Create/refresh it from the local ADC so a
# clean `make up` -> `make demo-cpai-up` works hands-off. The deployment mounts
# the secret as optional, so a missing ADC only degrades model calls (the pod
# and /healthz still come up) — warn rather than fail.
ADC_FILE="${GOOGLE_APPLICATION_CREDENTIALS:-$HOME/.config/gcloud/application_default_credentials.json}"
if [[ -f "${ADC_FILE}" ]]; then
  echo "==> Creating/refreshing cpai-gcp-adc secret from ${ADC_FILE}"
  kubectl -n cpai create secret generic cpai-gcp-adc \
    --from-file=adc.json="${ADC_FILE}" \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "!!  WARNING: no ADC at ${ADC_FILE} — model calls will fail." >&2
  echo "!!  Run 'gcloud auth application-default login' then re-run, or set" >&2
  echo "!!  GOOGLE_APPLICATION_CREDENTIALS to a service-account key file." >&2
fi

# The image tag is :latest with imagePullPolicy IfNotPresent, so a re-apply
# after `make cpai-images` produces no manifest diff and would keep serving the
# stale pod. Force a fresh pod so a freshly built+signed image is always picked
# up. Harmless on first deploy (the new deployment simply gets one more revision).
echo "==> Forcing rollout so a freshly built image is picked up"
kubectl -n cpai rollout restart deployment/cpai-runtime

echo "==> Waiting for cpai-runtime deployment to roll out"
wait_rollout cpai-runtime -n cpai 120

echo "==> CPAI runtime is up in namespace 'cpai'"
kubectl -n cpai get pods -l app.kubernetes.io/name=cpai-runtime
