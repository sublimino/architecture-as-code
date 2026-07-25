#!/usr/bin/env sh
set -eu

image="$1"
container="fake-integration-proxy-test-$$"
cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --rm --name "$container" -e SIGNALLOOM_DEMO_PROFILE=demo "$image" >/dev/null
for _ in $(seq 1 20); do
  if docker exec "$container" python -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8080/health")' 2>/dev/null; then break; fi
  sleep 1
done
docker exec "$container" python - <<'PY'
import json
import urllib.request

request = urllib.request.Request("http://127.0.0.1:8080/llm/assistants", data=b'{"token":"secret"}', method="POST", headers={"Authorization":"Bearer secret", "Content-Type":"application/json"})
assert urllib.request.urlopen(request).status == 200
captured = json.load(urllib.request.urlopen("http://127.0.0.1:8080/_test/requests"))
assert captured["requests"][0]["body"]["token"] == "[REDACTED]"
assert "secret" not in json.dumps(captured)
PY
