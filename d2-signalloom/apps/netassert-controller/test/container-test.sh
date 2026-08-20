#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# shellcheck source=scripts/lib/wait.sh
source "${REPO_ROOT}/scripts/lib/wait.sh"

image="$1"
container="netassert-controller-test-$$"
cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --rm --name "$container" "$image" >/dev/null
_wait_retry 20 "netassert-controller container health" \
  "docker exec '$container' python -c 'import urllib.request; urllib.request.urlopen(\"http://127.0.0.1:8080/health\")' >/dev/null 2>&1"
docker exec "$container" python - <<'PY'
import json
import urllib.request

response = urllib.request.urlopen("http://127.0.0.1:8080/health")
assert response.status == 200
assert json.load(response) == {"status": "ok"}
PY
