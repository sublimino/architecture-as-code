#!/usr/bin/env sh
set -eu

image="$1"
container="netassert-controller-test-$$"
cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --rm --name "$container" "$image" >/dev/null
for _ in $(seq 1 20); do
  if docker exec "$container" python -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8080/health")' 2>/dev/null; then break; fi
  sleep 1
done
docker exec "$container" python - <<'PY'
import json
import urllib.request

response = urllib.request.urlopen("http://127.0.0.1:8080/health")
assert response.status == 200
assert json.load(response) == {"status": "ok"}
PY
