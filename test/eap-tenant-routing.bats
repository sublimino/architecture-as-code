#!/usr/bin/env bats
# ==============================================================================
# SLDC-P3-2 EAP tenant ingress routing, Envoy tenant filter and Dex alignment.
#
# Hermetic: manifests are parsed with yq, and the tenant filter is the REAL Lua
# from tenant-filter-policy.yaml executed under LuaJIT against a strict stub of
# Envoy's request handle (test/fixtures/tenant/envoy_lua_harness.lua). No
# kubectl, no cluster. Mutation proof: test/eap-tenant-routing-mutation-proof.sh
#
# @id     eap-tenant-routing-bats
# @target d2-infra/components/ingress/tenant-filter-policy.yaml
# @target deploy/eap-tenant-httproute.yaml
# @target scripts/verify-tenant-routing.sh
# @task   SLDC-P3-2
# ==============================================================================

load eap-tenant-lua

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	HTTPROUTE="$REPO_ROOT/deploy/eap-tenant-httproute.yaml"
	DEX_CONFIG="$REPO_ROOT/d2-signalloom/infra/dex/dex-config-eap.yaml"
	DEX_BASE="$REPO_ROOT/d2-signalloom/infra/inf-signalloom/base/dex.yaml"
	POLICY="$REPO_ROOT/d2-infra/components/ingress/tenant-filter-policy.yaml"
	VERIFY="$REPO_ROOT/scripts/verify-tenant-routing.sh"
	export KUBECONFIG=/dev/null
	# No live traffic can leave this suite: any non-hermetic curl is "refused".
	mkdir -p "$BATS_TEST_TMPDIR/nocurl"
	printf '#!/usr/bin/env bash\nexit 7\n' >"$BATS_TEST_TMPDIR/nocurl/curl"
	chmod +x "$BATS_TEST_TMPDIR/nocurl/curl"
	export PATH="$BATS_TEST_TMPDIR/nocurl:$PATH"
	HASH="$(SIGNAL_LOOM_EAP_SALT=signalloom-eap-salt-2026-q3 python3 "$REPO_ROOT/scripts/derive_tenant_hash.py" --quiet kusari)"
	tenant_lua_load "$POLICY"
}

# Asserts the filter answered with the exact 403 local reply for <tenant>.
assert_rejected() { # <cleaned-tenant> <header=value>...
	local want="$1"
	shift
	run envoy_lua "$@"
	[ "$status" -eq 0 ]
	[ "$(lua_field action)" = "respond" ]
	[ "$(lua_field status)" = "403" ]
	[ "$(lua_field resp.content-type)" = "application/json" ]
	[ "$(lua_field resp.x-signalloom-tenant-status)" = "rejected" ]
	[ "$(lua_field resp.x-signalloom-security-gate)" = "tenant-filter-policy" ]
	run envoy_lua --body "$@"
	jq -e --arg t "$want" '. == {error: "Forbidden", message: ("Invalid or mismatched tenant header: " + $t), tenant: $t, status: 403}' <<<"$output"
}

# Asserts the request continues upstream carrying only the canonical tenant.
assert_canonicalised() { # <header=value>...
	run envoy_lua "$@"
	[ "$status" -eq 0 ]
	[ "$(lua_field action)" = "continue" ]
	[ "$(lua_field req.x-tenant-id)" = "kusari" ]
	[ "$(lua_field req.x-signalloom-tenant)" = "kusari" ]
}

# --- Manifests (yq, no kubectl) ----------------------------------------------

@test "HTTPRoute hostnames and tenant labels are derived from the salted kusari hash" {
	[ "$HASH" = "4b53ab6b" ]
	[ "$(yq '.apiVersion + " " + .kind + " " + .metadata.namespace + "/" + .metadata.name' "$HTTPROUTE")" = \
		"gateway.networking.k8s.io/v1 HTTPRoute fe-signalloom/eap-tenant-kusari" ]
	[ "$(yq -o=json -I=0 '.spec.hostnames' "$HTTPROUTE")" = "[\"sl-eap-$HASH.ts.net\",\"sl-eap-$HASH.demo.signalloom.io\"]" ]
	[ "$(yq '.metadata.labels["signalloom.ai/tenant"]' "$HTTPROUTE")" = "kusari" ]
	[ "$(yq '.metadata.labels["signalloom.ai/tenant-hash"]' "$HTTPROUTE")" = "$HASH" ]
}

@test "HTTPRoute attaches to signalloom-gateway and sends / to fe-signalloom-service:3000" {
	[ "$(yq -o=json -I=0 '.spec.parentRefs' "$HTTPROUTE")" = \
		'[{"group":"gateway.networking.k8s.io","kind":"Gateway","name":"signalloom-gateway","namespace":"envoy-gateway-system"}]' ]
	[ "$(yq -o=json -I=0 '.spec.rules' "$HTTPROUTE")" = \
		'[{"matches":[{"path":{"type":"PathPrefix","value":"/"}}],"backendRefs":[{"name":"fe-signalloom-service","port":3000}]}]' ]
}

@test "both tenant policies target the HTTPRoute in its own namespace" {
	[ "$(yq -N '.kind' "$POLICY" | sort | tr '\n' ' ')" = "EnvoyExtensionPolicy SecurityPolicy " ]
	want="$(yq '.metadata.namespace + "/gateway.networking.k8s.io/HTTPRoute/" + .metadata.name' "$HTTPROUTE")"
	for target in $(yq -N '.metadata.namespace + "/" + .spec.targetRef.group + "/" + .spec.targetRef.kind + "/" + .spec.targetRef.name' "$POLICY"); do
		[ "$target" = "$want" ] || { echo "policy targets $target, route is $want"; return 1; }
	done
}

@test "Dex registers /auth/callback and /callback for every routed hostname and no other sl-eap host" {
	uris="$(yq '.data["config.yaml"]' "$DEX_CONFIG" | yq '.staticClients[] | select(.id == "signalloom-dashboard") | .redirectURIs[]')"
	[ -n "$uris" ]
	for host in $(yq '.spec.hostnames[]' "$HTTPROUTE"); do
		grep -qxF "https://$host/auth/callback" <<<"$uris" || { echo "missing $host/auth/callback"; return 1; }
		grep -qxF "https://$host/callback" <<<"$uris" || { echo "missing $host/callback"; return 1; }
	done
	# every sl-eap redirect host must be one the HTTPRoute actually serves
	for host in $(sed -n 's|^https://\(sl-eap-[^/]*\)/.*|\1|p' <<<"$uris" | sort -u); do
		yq -e ".spec.hostnames[] | select(. == \"$host\")" "$HTTPROUTE" >/dev/null || { echo "unrouted redirect host $host"; return 1; }
	done
	[ "$(yq '.data["config.yaml"]' "$DEX_CONFIG" | yq '.issuer')" = "https://sl-eap-$HASH.ts.net/dex" ]
}

@test "Dex base manifest carries the canonical tenant callback" {
	grep -qF "https://sl-eap-$HASH.ts.net/auth/callback" "$DEX_BASE"
	! grep -qE 'kurasi|6f82ad81' "$DEX_BASE"
}

@test "the inline Lua compiles under LuaJIT and defines envoy_on_request only" {
	run luajit -e "local f = assert(loadfile('$TENANT_LUA')); local e = {}; setfenv(f, e); f(); for k in pairs(e) do print(k) end"
	[ "$status" -eq 0 ]
	[ "$output" = "envoy_on_request" ]
}

# --- Envoy Lua filter: accepted and canonicalised ----------------------------

@test "lua: canonical x-tenant-id continues and both tenant headers are rewritten to kusari" {
	assert_canonicalised "x-tenant-id=kusari"
}

@test "lua: canonical x-signalloom-tenant continues" {
	assert_canonicalised "x-signalloom-tenant=kusari"
}

@test "lua: the tenant hash 4b53ab6b is accepted and rewritten to the tenant name" {
	assert_canonicalised "x-tenant-id=4b53ab6b"
}

@test "lua: surrounding whitespace, upper case and one pair of quotes normalise to kusari" {
	assert_canonicalised "x-tenant-id=%20%09KUSARI%20%20"
	assert_canonicalised 'x-tenant-id="kusari"'
	assert_canonicalised "x-signalloom-tenant='KuSaRi'"
}

@test "lua: no tenant header continues with the canonical tenant injected" {
	assert_canonicalised
}

@test "lua: a spoofed tenant header can never reach upstream unchanged" {
	for v in kusari 4b53ab6b "%20KUSARI" ""; do
		run envoy_lua "x-tenant-id=$v" "x-forwarded-tenant=rogue"
		[ "$(lua_field action)" = "continue" ]
		[ "$(lua_field req.x-tenant-id)" = "kusari" ]
	done
}

# --- Envoy Lua filter: rejected with the exact 403 local reply ---------------

@test "lua: mismatched tenants are 403 with the exact JSON body" {
	assert_rejected rogue "x-signalloom-tenant=rogue"
	assert_rejected unauthorized-org "x-tenant-id=unauthorized-org"
	assert_rejected d9d69501 "x-tenant-id=d9d69501"
}

@test "lua: the retired typo kurasi and its hash 6f82ad81 are 403 in any case or padding" {
	assert_rejected kurasi "x-tenant-id=kurasi"
	assert_rejected kurasi "x-tenant-id=%20%20KuRaSi%20"
	assert_rejected 6f82ad81 "x-signalloom-tenant=6f82ad81"
	assert_rejected 6f82ad81 "x-tenant-id=6F82AD81"
}

@test "lua: homoglyph tenants (Cyrillic i, fullwidth k, Turkish dotted I) are 403" {
	run envoy_lua "x-tenant-id=kusar%D1%96"
	[ "$(lua_field status)" = "403" ]
	run envoy_lua "x-tenant-id=%EF%BD%8Busari"
	[ "$(lua_field status)" = "403" ]
	run envoy_lua "x-tenant-id=KUSAR%C4%B0"
	[ "$(lua_field status)" = "403" ]
}

@test "lua: duplicate x-tenant-id headers (joined by Envoy with a comma) are 403" {
	assert_rejected "kusari,rogue" "x-tenant-id=kusari" "x-tenant-id=rogue"
	assert_rejected "kusari,kusari" "x-tenant-id=kusari" "x-tenant-id=kusari"
}

@test "lua: a whitespace-only tenant header is 403, not treated as absent" {
	assert_rejected "" "x-tenant-id=%20%20%20"
}

@test "lua: CRLF inside the tenant value is 403" {
	run envoy_lua "x-tenant-id=kusari%0D%0Ax-evil:%201"
	[ "$(lua_field status)" = "403" ]
}

@test "lua: conflicting tenant headers are 403 even when x-tenant-id is canonical" {
	assert_rejected rogue "x-tenant-id=kusari" "x-signalloom-tenant=rogue"
	assert_rejected rogue "x-tenant-id=4b53ab6b" "x-signalloom-tenant=%20ROGUE"
}

@test "lua: an empty x-tenant-id does not hide a rogue x-signalloom-tenant" {
	assert_rejected rogue "x-tenant-id=" "x-signalloom-tenant=rogue"
}

@test "lua: the 403 body stays valid JSON and echoes the tenant exactly for hostile values" {
	for v in 'ku%22sari' 'ku%5Csari' 'kusari%0D%0Ax-evil:%201' 'ku%FFsari' '%22%7D,%22status%22:200,%22x%22:%7B%22'; do
		run envoy_lua --body "x-tenant-id=$v"
		jq -e '.status == 403 and .error == "Forbidden" and (.tenant | type) == "string"' <<<"$output" ||
			{ echo "invalid 403 body for $v: $output"; return 1; }
		[ "$(jq -r '.status' <<<"$output")" = "403" ]
	done
	run envoy_lua --body 'x-tenant-id=ku%22sari'
	[ "$(jq -r '.tenant' <<<"$output")" = 'ku"sari' ]
}

@test "lua: the security audit log line cannot be split by CR/LF in the tenant value" {
	run envoy_lua "x-tenant-id=rogue%0D%0A[SECURITY_AUDIT]%20forged"
	[ "$(lua_field status)" = "403" ]
	warn="$(lua_field log.warn)"
	[[ "$warn" == "[SECURITY_AUDIT] Tenant rejection:"* ]]
	[[ "$warn" != *%0A* && "$warn" != *%0D* ]]
}

# --- verify-tenant-routing.sh --hermetic (HTTPRoute + real Lua) -------------

@test "verify --hermetic passes all 11 probes against the shipped config" {
	run "$VERIFY" --hermetic --json
	[ "$status" -eq 0 ]
	[ "$(jq -r '.summary | "\(.total) \(.passed) \(.failed) \(.status)"' <<<"$output")" = "11 11 0 PASS" ]
	[ "$(jq -r '[.probes[] | .id + "=" + .actual] | join(" ")' <<<"$output")" = \
		"P1=200 P2=200 P3=200 P4=403 P5=403 P6=403 P7=403 P8=200 P9=403 P10=404 P11=200" ]
}

@test "verify --hermetic answers from the policy file: a filter that admits kurasi fails P6 and P9" {
	sed 's/clean_tenant == "kurasi" or //; s/clean_tenant ~= "kusari" and/clean_tenant ~= "kusari" and clean_tenant ~= "kurasi" and/' "$POLICY" >"$BATS_TEST_TMPDIR/policy.yaml"
	! cmp -s "$POLICY" "$BATS_TEST_TMPDIR/policy.yaml"
	SLDC_TENANT_POLICY_MANIFEST="$BATS_TEST_TMPDIR/policy.yaml" run "$VERIFY" --hermetic --json
	[ "$status" -eq 1 ]
	json="$(sed -n '/^{/,$p' <<<"$output")"
	[ "$(jq -r '[.probes[] | select(.pass == false) | .id + "=" + .actual] | join(" ")' <<<"$json")" = "P6=200 P9=200" ]
}

@test "verify --hermetic routes by the HTTPRoute: an unlisted host is 404, the retired host too" {
	yq '.spec.hostnames = ["sl-eap-4b53ab6b.ts.net"]' "$HTTPROUTE" >"$BATS_TEST_TMPDIR/route.yaml"
	SLDC_HTTPROUTE_MANIFEST="$BATS_TEST_TMPDIR/route.yaml" run "$VERIFY" --hermetic --json
	[ "$status" -eq 1 ]
	json="$(sed -n '/^{/,$p' <<<"$output")"
	[ "$(jq -r '[.probes[] | select(.pass == false) | .id + "=" + .actual] | join(" ")' <<<"$json")" = "P11=404" ]
	[ "$(jq -r '.probes[] | select(.id == "P10") | .actual' <<<"$json")" = "404" ]
}

@test "verify --hermetic refuses to run without luajit (exit 2), never falls back to a mock" {
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	for t in bash yq jq grep sed mktemp rm cat dirname date; do ln -sf "$(command -v "$t")" "$BATS_TEST_TMPDIR/bin/$t"; done
	PATH="$BATS_TEST_TMPDIR/bin" run "$VERIFY" --hermetic
	[ "$status" -eq 2 ]
	[[ "$output" == *"--hermetic needs luajit"* ]]
}

@test "verify rejects an unknown option with exit 2" {
	run "$VERIFY" --bogus
	[ "$status" -eq 2 ]
	[[ "$output" == *"Unknown option: --bogus"* ]]
}
