#!/usr/bin/env bats
#
# No nginx proxy prefix may shadow a client-side route registered in App.tsx.
#
# The defect this pins: `location /supercred/` proxied to fake-integration-proxy
# while `/supercred` was also a React route. nginx matches proxy locations before
# `location /` reaches try_files, so any redirect that added a trailing slash put
# the browser into the API proxy and the page could never render. Combined with
# nginx's default absolute redirects — built from its own listen port, not the
# gateway's — a browser on https://…:30754/supercred was sent to
# http://…:8080/supercred/ and got ERR_CONNECTION_REFUSED.

setup() {
	repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
	dashboard="$repo_root/d2-signalloom/apps/dashboard-signalloom"
	nginx_conf="$dashboard/nginx.conf"
	app_tsx="$dashboard/src/App.tsx"
}

# First path segment of every SPA route, one per line.
spa_segments() {
	# NOTE: <<- strips leading TABS, so Python's own indentation must be SPACES.
	python3 - "$app_tsx" <<-'PY'
	import re, sys
	src = open(sys.argv[1]).read()
	out = []
	for path in re.findall(r'path="([^"]+)"', src):
	    if not path.startswith("/") or path == "/":
	        continue
	    segment = path.lstrip("/").split("/")[0]
	    if segment and not segment.startswith(":"):
	        out.append(segment)
	print("\n".join(sorted(set(out))))
	PY
}

# Full path of every nginx location that proxies upstream, trailing slash
# stripped, one per line.
proxy_locations() {
	# NOTE: <<- strips leading TABS, so Python's own indentation must be SPACES.
	python3 - "$nginx_conf" <<-'PY'
	import re, sys
	src = open(sys.argv[1]).read()
	out = []
	for match in re.finditer(r'location\s+(=\s*)?(\S+)\s*\{', src):
	    path = match.group(2)
	    start = match.end()
	    depth, i = 1, start
	    while i < len(src) and depth:
	        if src[i] == "{":
	            depth += 1
	        elif src[i] == "}":
	            depth -= 1
	        i += 1
	    if "proxy_pass" not in src[start:i] or path == "/":
	        continue
	    out.append(path.rstrip("/") or "/")
	print("\n".join(sorted(set(out))))
	PY
}

# First path segment of every nginx location that proxies upstream, one per line.
proxy_segments() {
	# NOTE: <<- strips leading TABS, so Python's own indentation must be SPACES.
	python3 - "$nginx_conf" <<-'PY'
	import re, sys
	src = open(sys.argv[1]).read()
	out = []
	# Walk each `location <match> { ... }` block and keep the ones that proxy.
	for match in re.finditer(r'location\s+(=\s*)?(\S+)\s*\{', src):
	    path = match.group(2)
	    start = match.end()
	    depth, i = 1, start
	    while i < len(src) and depth:
	        if src[i] == "{":
	            depth += 1
	        elif src[i] == "}":
	            depth -= 1
	        i += 1
	    body = src[start:i]
	    if "proxy_pass" not in body or path == "/":
	        continue
	    segment = path.lstrip("/").split("/")[0]
	    if segment:
	        out.append(segment)
	print("\n".join(sorted(set(out))))
	PY
}

@test "both route surfaces parse and are non-empty" {
	run spa_segments
	[ "$status" -eq 0 ]
	[[ "$output" == *"supercred"* ]]
	[[ "$output" == *"agents"* ]]

	run proxy_segments
	[ "$status" -eq 0 ]
	[[ "$output" == *"api"* ]]
}

@test "no proxy prefix shadows a SPA route" {
	local spa proxy collisions
	spa="$(spa_segments)"
	proxy="$(proxy_segments)"
	collisions="$(comm -12 <(echo "$spa") <(echo "$proxy"))"

	[ -z "$collisions" ] || {
		echo "nginx proxy prefixes shadow these SPA routes: $collisions"
		echo "a page whose name matches a proxy prefix can never render;"
		echo "namespace the API under /api/ instead ($nginx_conf)"
		return 1
	}
}

@test "the SuperCred API has its own prefix and no longer owns /supercred/" {
	run grep -c 'location /supercred-api/ {' "$nginx_conf"
	[ "$status" -eq 0 ]
	[ "$output" -eq 1 ]

	# The colliding prefix must be gone, not merely supplemented.
	run grep -E '^\s*location /supercred/ \{' "$nginx_conf"
	[ "$status" -ne 0 ]
}

@test "the SuperCred page calls that same prefix" {
	run grep -c "'/supercred-api'" "$dashboard/src/pages/SuperCredPage.tsx"
	[ "$status" -eq 0 ]
	[ "$output" -eq 1 ]

	# No fetch may target the bare /supercred/ prefix any more.
	run grep -E "fetch\(['\"\`]/supercred/" "$dashboard/src/pages/SuperCredPage.tsx"
	[ "$status" -ne 0 ]
}

@test "no nginx proxy prefix sits under a gateway path routed away from the dashboard" {
	# The trap that rules out the otherwise-natural /api/supercred/: the gateway
	# sends PathPrefix /api to fe-signalloom-api, a longer prefix than the
	# dashboard's own `/`, so nothing under /api ever reaches this nginx. An
	# nginx location there is dead config that looks correct.
	command -v yq >/dev/null || skip "yq is required to read the HTTPRoutes"
	local route_file="$dashboard/../fe-signalloom/base/gateway-route.yaml"
	[ -f "$route_file" ] || skip "gateway-route.yaml not found"

	local foreign=()
	while read -r path backend; do
		[ -n "$path" ] || continue
		[ "$backend" = "dashboard-signalloom" ] && continue
		foreign+=("$path")
	done < <(yq eval-all '.spec.rules[]? | (.matches[]?.path.value + " " + (.backendRefs[]?.name))' "$route_file")

	# Known-benign EXACT overlaps. For these two, nginx and the gateway send the
	# path to the same backend (/api -> fe-signalloom-api, /dex -> dex), so the
	# nginx block is unreachable-but-harmless dead config for gateway traffic
	# while still serving in-cluster callers that reach nginx directly.
	#
	# The exemption is deliberately exact-match only. A location NESTED under a
	# foreign prefix — /api/supercred/ being the obvious temptation — is a real
	# defect, because the gateway hands the whole /api subtree to another backend
	# and nginx never sees it.
	local exempt=("/api" "/dex")

	local loc prefix skip_it offenders=()
	while read -r loc; do
		[ -n "$loc" ] || continue
		skip_it=0
		for prefix in "${exempt[@]}"; do
			if [ "$loc" = "$prefix" ]; then
				skip_it=1
			fi
		done
		if [ "$skip_it" -eq 0 ]; then
			for prefix in "${foreign[@]}"; do
				if [ "$loc" = "$prefix" ] || [ "${loc#"$prefix"/}" != "$loc" ]; then
					offenders+=("$loc")
				fi
			done
		fi
	done < <(proxy_locations)

	[ "${#offenders[@]}" -eq 0 ] || {
		echo "nginx proxies ${offenders[*]}, but the gateway routes those paths away"
		echo "from the dashboard — requests never reach nginx. Pick another prefix."
		return 1
	}
}

@test "the proxy NetworkPolicy admits the dashboard pod" {
	# Routing the browser to the right place is not enough: nginx must be able to
	# open the upstream connection. A NetworkPolicy drop is silent, so the fetch
	# hangs until nginx times out instead of failing fast — indistinguishable
	# from a dead page.
	command -v yq >/dev/null || skip "yq is required to read the NetworkPolicy"
	local policy="$repo_root/d2-signalloom/infra/inf-signalloom/configs/base/fake-integration-proxy-networkpolicy.yaml"
	[ -f "$policy" ] || skip "proxy NetworkPolicy not found"

	# The dashboard's own pod label must appear in an ingress `from` selector.
	run yq eval-all '[.spec.ingress[]?.from[]?.podSelector.matchLabels."app.kubernetes.io/name"] | .[]' "$policy"
	[ "$status" -eq 0 ]
	[[ "$output" == *"dashboard-signalloom"* ]]
}

@test "redirects stay relative so they cannot leave the gateway origin" {
	run grep -c '^\s*absolute_redirect off;' "$nginx_conf"
	[ "$status" -eq 0 ]
	[ "$output" -eq 1 ]

	run grep -c '^\s*port_in_redirect off;' "$nginx_conf"
	[ "$status" -eq 0 ]
	[ "$output" -eq 1 ]
}
