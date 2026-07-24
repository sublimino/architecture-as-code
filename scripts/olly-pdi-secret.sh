#!/usr/bin/env bash
# Create the `servicenow-pdi` secret in the olly-replica namespace from a
# local .env file, so the io-mapping-service stub writes enrichment to a real
# ServiceNow PDI instead of its in-memory store. Best-effort and idempotent:
# with no .env (or the ServiceNow vars unset) it prints a note and exits 0,
# so `make up` stays green whether or not a PDI is configured.
#
# The .env file is gitignored; credentials never get committed. Copy
# .env.example to .env to fill it in.
set -uo pipefail

cd "$(dirname "$0")/.."

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

if [ -z "${SERVICENOW_URL:-}" ] || [ -z "${SERVICENOW_USER:-}" ] || [ -z "${SERVICENOW_PASSWORD:-}" ]; then
  echo "no ServiceNow PDI credentials in .env; the mapping stub keeps its in-memory ticket store."
  echo "  to wire a PDI: cp .env.example .env, fill it in, then rerun 'make olly-pdi-secret'."
  exit 0
fi

echo "waiting for the olly-replica namespace..."
for _ in $(seq 1 60); do
  kubectl get ns olly-replica >/dev/null 2>&1 && break
  sleep 5
done
if ! kubectl get ns olly-replica >/dev/null 2>&1; then
  echo "olly-replica namespace never appeared; is the cluster up and reconciled?" >&2
  exit 1
fi

echo "creating the servicenow-pdi secret (${SERVICENOW_URL})"
kubectl -n olly-replica create secret generic servicenow-pdi \
  --from-literal=SERVICENOW_URL="${SERVICENOW_URL}" \
  --from-literal=SERVICENOW_USER="${SERVICENOW_USER}" \
  --from-literal=SERVICENOW_PASSWORD="${SERVICENOW_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart the stub so it picks up the secret (envFrom is read at start).
if kubectl -n olly-replica get deploy io-mapping-stub >/dev/null 2>&1; then
  echo "restarting io-mapping-stub to pick up the credentials"
  kubectl -n olly-replica rollout restart deploy/io-mapping-stub
fi

echo "done: enrichment work notes will now flow to the ServiceNow PDI."
