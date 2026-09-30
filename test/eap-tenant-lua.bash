# shellcheck shell=bash
# eap-tenant-lua.bash — run the REAL tenant Envoy Lua filter under LuaJIT.
#
# tenant_lua_load [policy.yaml]  extracts .spec.lua[0].inline from the
#                                EnvoyExtensionPolicy into $TENANT_LUA
# envoy_lua [--body] name=value  runs envoy_on_request via the harness;
#                                values are percent-decoded (%0D%0A = CRLF)
# lua_field <key>                reads one key=value line from $output

TENANT_LUA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TENANT_LUA_HARNESS="$TENANT_LUA_ROOT/test/fixtures/tenant/envoy_lua_harness.lua"

tenant_lua_load() {
	local policy="${1:-$TENANT_LUA_ROOT/d2-infra/components/ingress/tenant-filter-policy.yaml}"
	TENANT_LUA="$BATS_TEST_TMPDIR/tenant-filter.lua"
	yq 'select(.kind == "EnvoyExtensionPolicy") | .spec.lua[0].inline' "$policy" >"$TENANT_LUA"
	grep -q 'function envoy_on_request' "$TENANT_LUA"
}

envoy_lua() {
	local body=()
	if [[ "${1:-}" == "--body" ]]; then
		body=(--body)
		shift
	fi
	luajit "$TENANT_LUA_HARNESS" "${body[@]}" "$TENANT_LUA" "$@"
}

lua_field() {
	sed -n "s/^$1=//p" <<<"$output"
}
