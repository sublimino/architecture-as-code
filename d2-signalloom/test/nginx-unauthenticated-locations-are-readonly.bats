#!/usr/bin/env bats
#
# An nginx proxy location that does NOT forward Authorization must be read-only.
#
# The defect this pins: `location /supercred-api/` proxies to
# fake-integration-proxy and deliberately never sets `proxy_set_header
# Authorization`. The proxy does not check for one either — its stun handler
# reads its own ServiceAccount token and PATCHes the kube-apiserver with it.
# So while POST was reachable through that prefix, ANY browser that could load
# the dashboard could relabel a pod and revoke its OpenBao lease with no
# credential at all, borrowing the proxy's identity.
#
# That hole was closed with `limit_except GET HEAD { deny all; }`. Verified live
# on the running cluster at the time of writing:
#
#   GET    /supercred-api/agents             -> 200   (open by design, see below)
#   POST   /supercred-api/agents/x/stun      -> 403
#   POST   /supercred-api/network-tests/scan -> 403
#   DELETE /supercred-api/_test/requests     -> 403
#   PUT    /supercred-api/_test/fixtures/a   -> 403
#
# But nothing asserted it. `limit_except` appeared in exactly one file in the
# whole repository and in no test, so deleting those three lines would have
# reopened unauthenticated pod-stun while every suite stayed green. A security
# control with no alarm is a security control with a shelf life.
#
# This guard is deliberately written as the GENERAL invariant rather than as a
# pin on that one block: any FUTURE location that forgets to forward
# Authorization is caught the same way, instead of only the one we already know
# about. "Read-only" is the safe default for an unauthenticated upstream.
#
# SCOPE, stated plainly rather than overclaimed: this asserts that unauthenticated
# prefixes reject MUTATION. It does not assert that they are authenticated. Every
# GET through /supercred-api/ still reaches the proxy with no credential, so
# anyone who can reach the dashboard origin can still enumerate the estate — pod
# names, namespaces, labels, crypto proofs, trust topology. That is a known,
# documented, accepted exposure; closing it is a separate change. This guard
# exists so the mutation half cannot silently regress.

setup() {
	repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
	nginx_conf="$repo_root/d2-signalloom/apps/dashboard-signalloom/nginx.conf"
}

# Emit one line per proxy location: "<prefix>\t<forwards_auth>\t<mutation_denied>"
#
# Parsed by brace depth rather than by regex over the whole file, so a nested
# block (limit_except, if, location) is attributed to its enclosing location
# and not to the file at large.
location_matrix() {
	# NOTE: <<- strips leading TABS, so Python's own indentation must be SPACES.
	python3 - "$nginx_conf" <<-'PY'
	import re, sys

	src = open(sys.argv[1]).read()
	# Strip comments so a commented-out directive never counts as present.
	src = re.sub(r'#[^\n]*', '', src)

	lines = src.split('\n')
	depth = 0
	stack = []          # (prefix, depth_at_open, body_lines)
	results = []

	for line in lines:
	    m = re.search(r'location\s+([^\s{]+)\s*{', line)
	    if m and 'limit_except' not in line:
	        stack.append([m.group(1), depth, []])
	    elif stack:
	        stack[-1][2].append(line)

	    depth += line.count('{') - line.count('}')

	    while stack and depth <= stack[-1][1]:
	        prefix, _, body = stack.pop()
	        text = '\n'.join(body)
	        forwards_auth = bool(re.search(
	            r'proxy_set_header\s+Authorization\s+\$http_authorization', text))
	        # Mutation is denied if a limit_except allows only safe methods AND
	        # its body denies everything else.
	        le = re.search(r'limit_except\s+([A-Z\s]+)\{([^}]*)\}', text)
	        mutation_denied = bool(
	            le
	            and re.search(r'deny\s+all', le.group(2))
	            and set(le.group(1).split()) <= {'GET', 'HEAD', 'OPTIONS'}
	        )
	        is_proxy = 'proxy_pass' in text
	        if is_proxy:
	            results.append(f"{prefix}\t{int(forwards_auth)}\t{int(mutation_denied)}")

	print('\n'.join(results))
	PY
}

@test "nginx.conf exists and declares at least one proxy location" {
	[ -f "$nginx_conf" ]
	run location_matrix
	[ "$status" -eq 0 ]
	# Assert the mechanism is present before testing it: a parser that silently
	# matched nothing would make every assertion below pass vacuously.
	[ -n "$output" ]
}

# Prefixes allowed to be unauthenticated AND method-unrestricted, each with the
# reason it is acceptable. A prefix not on this list fails the test below.
#
# This is a LEDGER, not an exemption list: the entries are the ones we have
# looked at and reasoned about, and each is expected to be revisited. Adding a
# prefix here is a decision someone has to write down; forgetting to add one is
# a test failure. That asymmetry is the whole point.
declared_unguarded() {
	cat <<-'LEDGER'
	/dex/
	/dashboard/
	/afm/
	/clusters
	/metrics/
	/health
	/jobs
	/webhooks/
	LEDGER
}

# /dex/       — Dex IS the OIDC provider. Its token endpoint is POST by
#               definition and forwarding a bearer token to the thing that
#               issues bearer tokens is meaningless. Correctly unauthenticated.
#
# The remaining seven all proxy to the SAME upstream,
# afm-platform.fe-k8s-afm.svc.cluster.local:8000, none forward Authorization,
# and none restrict methods. Probed live against the running cluster on
# 2026-08-14 through the Envoy Gateway:
#
#   GET  /clusters   -> 200      POST -> 405
#   GET  /health     -> 200      POST -> 405
#   GET  /dashboard/ -> 200      POST -> 405
#   GET  /afm/       -> 307      POST -> 405
#   GET  /jobs       -> 404      POST -> 404
#   GET  /metrics/   -> 404      POST -> 404
#   GET  /webhooks/… -> 404      POST -> 404
#
# So this is NOT a live vulnerability today — and the reason it is not is worth
# being precise about, because it is not a control. The 405s come from the AFM
# platform not implementing those methods, not from anything refusing them. The
# nginx layer permits POST/PUT/DELETE on all seven. The day AFM adds a POST
# handler to /jobs or /webhooks/, it is reachable from any browser that can load
# the dashboard, with no credential, borrowing the proxy's identity — with no
# code change here and nothing going red.
#
# /webhooks/ is the one to watch: a webhook endpoint is POST by definition, so
# that prefix exists in anticipation of precisely the handler that makes this
# exploitable.
#
# That is exactly how /supercred-api/ got its hole. It had a POST handler (the
# pod stun), and it was reachable unauthenticated until someone added
# limit_except. These seven differ from it only in not having grown the handler
# yet.
#
# The GET side is a separate, accepted exposure: /clusters and /dashboard/
# return estate data to anyone who can reach the origin. Same class as the
# documented /supercred-api/ GET exposure. Closing either is its own change.

@test "no UNDECLARED proxy location drops Authorization while accepting mutation" {
	run location_matrix
	[ "$status" -eq 0 ]
	local matrix="$output"

	local ledger
	ledger="$(declared_unguarded)"

	local offenders=""
	while IFS=$'\t' read -r prefix forwards_auth mutation_denied; do
		[ -z "$prefix" ] && continue
		if [ "$forwards_auth" = "0" ] && [ "$mutation_denied" = "0" ]; then
			if ! grep -qxF "$prefix" <<< "$ledger"; then
				offenders="${offenders}${prefix} "
			fi
		fi
	done <<< "$matrix"

	if [ -n "$offenders" ]; then
		echo "NEW unauthenticated proxy location(s) accepting mutating methods:"
		echo "  $offenders"
		echo ""
		echo "This location proxies to an upstream WITHOUT forwarding Authorization"
		echo "and does not restrict methods. Any browser that can reach the dashboard"
		echo "origin can POST/PUT/DELETE through it with no credential, borrowing the"
		echo "upstream's own identity. That is how the /supercred-api/ pod-stun hole"
		echo "worked."
		echo ""
		echo "Fix by EITHER forwarding Authorization (and checking it upstream), OR"
		echo "adding:  limit_except GET HEAD { deny all; }"
		echo ""
		echo "If it is genuinely fine unauthenticated, add it to declared_unguarded()"
		echo "in this file WITH the reason — that is a decision, and it gets written"
		echo "down."
		echo ""
		echo "Full matrix (prefix / forwards_auth / mutation_denied):"
		echo "$matrix"
		false
	fi
}

@test "the unguarded ledger has no stale entries" {
	# A ledger entry for a prefix that no longer exists is worse than no entry:
	# it reads as "reviewed and accepted" while describing nothing, and it would
	# silently pre-approve the prefix if someone reintroduced it later with a
	# different upstream.
	run location_matrix
	[ "$status" -eq 0 ]
	local matrix="$output"

	local stale=""
	while read -r prefix; do
		[ -z "$prefix" ] && continue
		if ! cut -f1 <<< "$matrix" | grep -qxF "$prefix"; then
			stale="${stale}${prefix} "
		fi
	done <<< "$(declared_unguarded)"

	if [ -n "$stale" ]; then
		echo "declared_unguarded() names prefix(es) that nginx.conf no longer has:"
		echo "  $stale"
		echo "Remove them, so the ledger keeps describing the real config."
		false
	fi
}

@test "the /supercred-api/ prefix specifically is still mutation-denied" {
	# The general invariant above is the durable one, but this names the specific
	# block whose absence was an unauthenticated pod-stun, so a failure says which
	# hole reopened rather than only that some hole did.
	run location_matrix
	[ "$status" -eq 0 ]

	local line
	line="$(echo "$output" | grep -P '^/supercred-api/\t' || true)"
	[ -n "$line" ]

	local mutation_denied
	mutation_denied="$(echo "$line" | cut -f3)"
	[ "$mutation_denied" = "1" ]
}

@test "the /demo-api/ prefix does forward Authorization" {
	# Its mutating routes (POST /runs, POST /reset) are gated server-side on a
	# superadmin claim from the validated Dex JWT. Dropping the header here would
	# 401 every mutating call — a silent demo breakage, not a security failure,
	# but a regression either way. Pinned so the two blocks cannot be "made
	# consistent" by copying the wrong one.
	run location_matrix
	[ "$status" -eq 0 ]

	local line
	line="$(echo "$output" | grep -P '^/demo-api/\t' || true)"
	[ -n "$line" ]

	local forwards_auth
	forwards_auth="$(echo "$line" | cut -f2)"
	[ "$forwards_auth" = "1" ]
}
