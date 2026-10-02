#!/usr/bin/env bats
# @id d2-signalloom/test/ingest-routes-offline.bats
# @target d2-signalloom/test/helpers/ingest-routes.bash
#
# Offline tier for the registration readback that api-route-liveness.bats uses
# against the RUNNING signal-ingest. The fake kubectl emits the startup log in
# the shape slog's JSON handler writes, with the fields
# api.TestEveryRegisteredRouteIsAnnouncedInTheStartupLog pins (msg, method,
# route), interleaved with the noise a real log carries.

FE_NS=fe-signalloom

setup() {
	export KUBECONFIG=/dev/null
	load helpers/ingest-routes
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/kubectl.log"
if [[ -n "${FAKE_RC:-}" ]]; then
	echo "Unable to connect to the server" >&2
	exit "$FAKE_RC"
fi
cat "$FAKE_LOG_FILE"
STUB
	chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
	PATH="$BATS_TEST_TMPDIR/bin:$PATH"
	export FAKE_LOG_FILE="$BATS_TEST_TMPDIR/ingest.log"
	cat >"$FAKE_LOG_FILE" <<'LOG'
{"time":"2026-10-02T21:29:01Z","level":"INFO","msg":"signal store initialized","type":"","dir":""}
{"time":"2026-10-02T21:29:01Z","level":"INFO","msg":"HTTP authorization route registered","method":"GET","route":"/healthz","permission":"health:read","enumeration":false}
{"time":"2026-10-02T21:29:01Z","level":"INFO","msg":"HTTP authorization route registered","method":"POST","route":"/api/v1/correlate","permission":"analysis:run","enumeration":true}
{"time":"2026-10-02T21:29:01Z","level":"INFO","msg":"HTTP authorization route registered","method":"GET","route":"/api/v1/actors/{id}","permission":"actors:read","enumeration":false}
not json at all
{"time":"2026-10-02T21:29:02Z","level":"WARN","msg":"audit write failed","route":"/api/v1/actors","method":"GET"}
LOG
}

@test "the readback lists exactly the announced routes, method first" {
	run running_ingest_routes
	[ "$status" -eq 0 ]
	[ "$output" = $'GET\t/healthz\nPOST\t/api/v1/correlate\nGET\t/api/v1/actors/{id}' ]
	rg -q -e "-n fe-signalloom logs deploy/signal-ingest -c signal-ingest --tail=-1" "$BATS_TEST_TMPDIR/kubectl.log"
}

@test "a rotated log reads as empty, which the suite must treat as 'cannot tell'" {
	: >"$FAKE_LOG_FILE"
	run running_ingest_routes
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "an unreachable cluster reads as empty, never as a route table" {
	FAKE_RC=1 run running_ingest_routes
	[ -z "$output" ]
}

@test "registration is decided by method and pattern, parameter segments matching any value" {
	routes=$(running_ingest_routes)
	[ "$(ingest_route_absent POST /api/v1/correlate "$routes")" = present ]
	[ "$(ingest_route_absent GET /api/v1/correlate "$routes")" = absent ]
	[ "$(ingest_route_absent GET /api/v1/actors/route-liveness-probe "$routes")" = present ]
	[ "$(ingest_route_absent GET /api/v1/actors "$routes")" = absent ]
	[ "$(ingest_route_absent GET /api/v1/actors/a/b "$routes")" = absent ]
	[ "$(ingest_route_absent GET /api/v1/route-liveness-falsification-1 "$routes")" = absent ]
	[ "$(ingest_route_absent GET /api/v1/actors "")" = absent ]
}
