# shellcheck shell=bash
# ingest-routes.bash — read signal-ingest's live route table and decide registration.
# Loaded by api-route-liveness.bats (live) and tested offline by
# ingest-routes-offline.bats against the log format api.TestEveryRegisteredRouteIsAnnouncedInTheStartupLog pins.
# Needs FE_NS and kubectl on PATH.

# The RUNNING signal-ingest's own route table, read out of its startup log.
#
# Not an HTTP probe, and that is forced, not chosen. Every route sits behind
# api.ProtectedRouter, which authenticates before it routes:
#
#   anonymous, any path                -> 401   says nothing about registration
#   GET on a POST-only route           -> 403 unregistered_route   (ServeMux
#                                         reports no pattern for a method
#                                         mismatch, so it reads as ABSENT)
#   authenticated POST on its route    -> the handler RUNS; collectors/seed
#                                         seeds the store
#
# So the old GET-probe discrimination (200 / 405 / Go's plain 404) is gone, and
# probing with a credential would either prove nothing or fire the POST routes
# this suite must never fire. The router announces each route it registers as
# one JSON log line ("HTTP authorization route registered", with method and
# route) — the same readback-from-the-running-process the portal tier gets from
# /openapi.json. api.TestEveryRegisteredRouteIsAnnouncedInTheStartupLog pins
# that the line is emitted for every route, with those fields.
#
# Output: "<METHOD>\t<pattern>" per route. Empty when the log no longer holds
# the startup lines (kubelet rotated it); callers must treat empty as
# "cannot tell", never as "nothing missing".
running_ingest_routes() {
  kubectl -n "$FE_NS" logs deploy/signal-ingest -c signal-ingest --tail=-1 2>/dev/null \
    | python3 -c '
import json, sys
for line in sys.stdin:
    try:
        rec = json.loads(line)
    except ValueError:
        continue
    if rec.get("msg") == "HTTP authorization route registered":
        print(rec["method"] + "\t" + rec["route"])
'
}

# ingest_route_absent METHOD PATH ROUTES -> "absent" or "present".
#
# A {param} segment in a registered pattern matches any one concrete segment,
# exactly as ServeMux does; the method must match too, because a GET to a
# POST-only route is not served.
ingest_route_absent() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
method, path, routes = sys.argv[1], sys.argv[2], sys.argv[3]
want = path.strip("/").split("/")
for line in routes.splitlines():
    m, pattern = line.split("\t", 1)
    segs = pattern.strip("/").split("/")
    if m == method and len(segs) == len(want) and all(
            s == w or (s.startswith("{") and s.endswith("}")) for s, w in zip(segs, want)):
        print("present")
        break
else:
    print("absent")
PY
}
