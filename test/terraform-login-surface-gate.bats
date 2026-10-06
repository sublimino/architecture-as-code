#!/usr/bin/env bats
#
# scripts/ci/login-surface-gate.sh — the verdict lattice, and the one way this
# gate could come back green over a broken login.
#
# Offline. No cluster, no tailnet, no network: curl is injected via
# LOGIN_GATE_CURL, which is the whole reason that boundary exists.
#
# ═══ What these tests are FOR ═══════════════════════════════════════════════
#
# The gate's headline assertion is NEGATIVE — "the response must not contain
# Unregistered redirect_uri". An empty body satisfies that perfectly. So the
# failure mode that matters here is not "the gate misses a subtle case", it is
# "the gate reports WORKING because it received nothing at all", and that is the
# state a broken lane is MOST likely to be in. § INVERSION is the reason this
# file exists; everything else is scaffolding around it.
#
# Every mutation test below states whether the RED was WATCHED. All of them
# were: `mutate` refuses to proceed on a sed expression that matched nothing, so
# a mutation proof here cannot silently run against correct code.

setup_file() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export REPO_ROOT
	export REAL_GATE="${REPO_ROOT}/scripts/ci/login-surface-gate.sh"
}

setup() {
	# Presence first, always. A suite that silently tests nothing because its
	# subject moved is the failure this repo has shipped before.
	[ -f "${REAL_GATE}" ]

	WORK="${BATS_TEST_TMPDIR}/w"
	mkdir -p "${WORK}"

	# The gate is COPIED and the copy is what runs. Mutation tests below rewrite
	# it, and a harness that mutated the tree in place leaves the repo mutated
	# when the run is killed — EXIT traps survive SIGTERM but not SIGKILL.
	GATE="${WORK}/login-surface-gate.sh"
	cp "${REAL_GATE}" "${GATE}"
	chmod +x "${GATE}"

	# ─── The injected curl ────────────────────────────────────────────────
	#
	# Emits `<body>\n<code>`, which is exactly the shape
	# `curl -o /dev/stdout -w '\n%{http_code}'` produces. Each path's status and
	# body are chosen per-test from the environment, so a test steers the
	# cluster's behaviour without any cluster.
	#
	# The URL is the LAST argument. Matching on `$*` instead would let the
	# `--max-time` value or a header collide with a path and dispatch the wrong
	# fixture.
	STUBCURL="${WORK}/curl"
	cat >"${STUBCURL}" <<-'STUB'
		#!/usr/bin/env bash
		url=""
		for a in "$@"; do url="$a"; done

		emit() { printf '%s\n%s' "$1" "$2"; }

		case "$url" in
			*/dex/.well-known/openid-configuration)
				[ "${STUB_DISCO_CODE:-200}" = "000" ] && { emit "" "000"; exit 0; }
				emit "${STUB_DISCO_BODY-{\"issuer\":\"${STUB_ISSUER-}\"}}" "${STUB_DISCO_CODE:-200}" ;;
			*/dex/auth*)
				[ "${STUB_AUTH_CODE:-200}" = "000" ] && { emit "" "000"; exit 0; }
				emit "${STUB_AUTH_BODY-<html>Sign in</html>}" "${STUB_AUTH_CODE:-200}" ;;
			*)
				[ "${STUB_ROOT_CODE:-200}" = "000" ] && { emit "" "000"; exit 0; }
				emit "<html>dashboard</html>" "${STUB_ROOT_CODE:-200}" ;;
		esac
		exit 0
	STUB
	chmod +x "${STUBCURL}"

	ORIGIN="https://sl-test-1.example-tailnet.ts.net"
	export ORIGIN
	# The happy path IS the happy path unless a test says otherwise. `${VAR=}`
	# and not `${VAR:=}`: the colon form treats EMPTY as absent, so a test
	# setting an empty issuer on purpose would silently be handed the default
	# and would test the happy path instead.
	: "${STUB_ISSUER=${ORIGIN}/dex}"
	export STUB_ISSUER
}

# Apply a sed expression to the gate copy, and PROVE it applied.
#
# A sed expression that matches nothing exits 0 and changes nothing, so the
# mutation test that follows would run against CORRECT code and pass — a
# mutation proof proving the opposite of what it claims.
mutate() {
	local before after
	before="$(md5sum <"${GATE}")"
	sed -i "$1" "${GATE}"
	after="$(md5sum <"${GATE}")"
	[ "$before" != "$after" ] || {
		echo "the mutation '$1' matched nothing — the test that follows would be vacuous"
		return 1
	}
}

run_gate() {
	run env LOGIN_GATE_CURL="${STUBCURL}" bash "${GATE}" --base-url "${ORIGIN}"
}

# ─── § THE HAPPY PATH ───────────────────────────────────────────────────────

@test "LOGIN a healthy origin with a matching issuer and an accepted callback is WORKING" {
	run_gate
	[ "$status" -eq 0 ] || { echo "expected exit 0, got ${status}"; echo "$output"; return 1; }
	[[ "$output" == *"VERDICT: WORKING"* ]] || { echo "$output"; return 1; }
}

@test "LOGIN the happy path states what it did NOT prove" {
	# A gate that says "login works" when it has sent no credentials is
	# overclaiming, and an overclaiming green is how the next outage gets past
	# the person reading this output.
	run_gate
	[[ "$output" == *"NOT PROVEN"* ]] || {
		echo "the pass line claims success without bounding it"
		echo "$output"; return 1;
	}
}

# ─── § THE OUTAGE ───────────────────────────────────────────────────────────

@test "LOGIN an unregistered callback is ORIGIN_NOT_CLAIMED and fails" {
	# The principal-visible outage, verbatim. Body captured from a live Dex:
	# HTTP 400 with HTML-escaped quotes around the URI.
	STUB_AUTH_CODE=400 \
	STUB_AUTH_BODY='<html><h2>Bad Request</h2><p>Unregistered redirect_uri (&#34;https://sl-test-1.example-tailnet.ts.net/callback&#34;).</p></html>' \
		run_gate

	[ "$status" -eq 1 ] || { echo "expected exit 1, got ${status}"; echo "$output"; return 1; }
	[[ "$output" == *"VERDICT: ORIGIN_NOT_CLAIMED"* ]] || { echo "$output"; return 1; }
}

@test "LOGIN the ORIGIN_NOT_CLAIMED failure names the unsudoed repair command" {
	# The repair is the whole value of the verdict. It is also the command that
	# fails confusingly when sudoed — sudo drops the kubeconfig and kubectl then
	# reports 'localhost:8080 connection refused', which reads as a cluster
	# fault rather than as a wrong invocation.
	STUB_AUTH_CODE=400 \
	STUB_AUTH_BODY='Unregistered redirect_uri (&#34;x&#34;).' \
		run_gate

	[[ "$output" == *"dex-origin.sh apply tailscale ${ORIGIN}"* ]] || {
		echo "the failure does not name the repair command"; echo "$output"; return 1;
	}
	[[ "$output" == *"UNSUDOED"* ]] || {
		echo "the failure does not warn against sudo"; echo "$output"; return 1;
	}
}

@test "LOGIN an issuer serving a DIFFERENT origin is ORIGIN_NOT_CLAIMED" {
	# The half the callback check cannot see. The SPA validates the ID token's
	# iss against the origin it was served from, so this is a login that takes
	# the password and then rejects the token.
	STUB_ISSUER="https://dashboard.osramp.acme.local:30754/dex" run_gate

	[ "$status" -eq 1 ] || { echo "expected exit 1, got ${status}"; echo "$output"; return 1; }
	[[ "$output" == *"VERDICT: ORIGIN_NOT_CLAIMED"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"issuer MISMATCH"* ]] || { echo "$output"; return 1; }
}

@test "LOGIN the issuer check runs even when the callback is accepted" {
	# The two assertions are independent on purpose: _dex_origin_write patches
	# flux-system and each tenant copy separately and tolerates failure on the
	# tenant ones, so a half-written origin is reachable state. Here the auth
	# endpoint is perfectly happy and ONLY the issuer is wrong.
	STUB_ISSUER="https://somewhere.else/dex" \
	STUB_AUTH_CODE=200 \
	STUB_AUTH_BODY='<html>Sign in</html>' \
		run_gate

	[ "$status" -eq 1 ] || {
		echo "a correct callback masked a mismatched issuer — the halves are not independent"
		echo "$output"; return 1;
	}
}

# ─── § INVERSION — the reason this file exists ──────────────────────────────
#
# "The body must not contain Unregistered redirect_uri" is satisfied by an empty
# body. Each test here puts the gate in a state where it receives NOTHING and
# asserts it does not call that a working login.

@test "INVERSION a transport failure at the auth endpoint must NOT report WORKING" {
	# THE test. Dex is gone; /dex/auth returns nothing; the refusal literal is
	# absent because there is no response, not because the callback is
	# registered. A gate that passes here is a gate that goes green during an
	# outage.
	STUB_AUTH_CODE=000 run_gate

	[ "$status" -ne 0 ] || {
		echo "the gate reported SUCCESS having received NO RESPONSE from /dex/auth."
		echo "the negative assertion inverted: an empty body contains no refusal,"
		echo "so the absence of evidence was read as evidence of a working login."
		echo "$output"; return 1;
	}
	[[ "$output" != *"VERDICT: WORKING"* ]] || { echo "$output"; return 1; }
}

@test "INVERSION a transport failure at the auth endpoint is DEX_DOWN, not a pass" {
	STUB_AUTH_CODE=000 run_gate
	[[ "$output" == *"VERDICT: DEX_DOWN"* ]] || {
		echo "expected DEX_DOWN for an unanswered auth endpoint"; echo "$output"; return 1;
	}
}

@test "INVERSION an unreachable origin must NOT report WORKING" {
	STUB_ROOT_CODE=000 run_gate
	[ "$status" -ne 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"VERDICT: TAILNET_UNREACHABLE"* ]] || { echo "$output"; return 1; }
}

@test "INVERSION an unreachable origin is reported as ABSENT, not as a broken login" {
	# Different verdict, different person, different fix. Telling someone their
	# login is broken about a lane that was never deployed is how a red gate
	# gets switched off.
	STUB_ROOT_CODE=000 run_gate
	[[ "$output" == *"NOBODY'S LOGIN IS BROKEN"* ]] || {
		echo "an absent lane was reported as a login outage"; echo "$output"; return 1;
	}
}

@test "INVERSION a 502 behind /dex must NOT report WORKING" {
	# nginx up, Dex gone. `/` is 200 throughout — which is exactly why a 200 on
	# `/` is never consulted as evidence.
	STUB_DISCO_CODE=502 run_gate
	[ "$status" -ne 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"VERDICT: DEX_DOWN"* ]] || { echo "$output"; return 1; }
}

@test "INVERSION a 200 that is not a discovery document must NOT report WORKING" {
	# An SPA index.html served on the discovery path — the shape a catch-all
	# route produces. It is 200 and it parses as nothing.
	STUB_DISCO_CODE=200 STUB_DISCO_BODY='<html><body>dashboard</body></html>' run_gate
	[ "$status" -ne 0 ] || {
		echo "an unparseable 200 was accepted as a valid issuer"; echo "$output"; return 1;
	}
	[[ "$output" == *"VERDICT: DEX_DOWN"* ]] || { echo "$output"; return 1; }
}

@test "INVERSION an empty issuer field must NOT satisfy the issuer match" {
	STUB_ISSUER="" run_gate
	[ "$status" -ne 0 ] || {
		echo "an absent issuer compared equal to the expected one"; echo "$output"; return 1;
	}
}

# ─── § THE UNACCOUNTED RESPONSE ─────────────────────────────────────────────

@test "LOGIN a 400 with no recognisable refusal is AUTH_REFUSED, not ORIGIN_NOT_CLAIMED" {
	# An unregistered client_id, not an unregistered callback. Naming the origin
	# mechanism here would send someone to re-claim an origin that is already
	# correct.
	STUB_AUTH_CODE=400 STUB_AUTH_BODY='<html>Invalid client_id</html>' run_gate

	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"VERDICT: AUTH_REFUSED"* ]] || { echo "$output"; return 1; }
	[[ "$output" != *"ORIGIN_NOT_CLAIMED"* ]] || {
		echo "a client_id fault was misreported as an origin-claim fault"; echo "$output"; return 1;
	}
}

# ─── § CANNOT RUN ───────────────────────────────────────────────────────────

@test "LOGIN no base URL is CANNOT-RUN (exit 2), never a pass" {
	run env LOGIN_GATE_CURL="${STUBCURL}" LOGIN_GATE_BASE_URL="" bash "${GATE}"
	[ "$status" -eq 2 ] || { echo "expected exit 2, got ${status}"; echo "$output"; return 1; }
}

@test "LOGIN there is no localhost default" {
	# A gate that defaults somewhere asserts about the wrong Dex and is
	# confidently wrong. The origin IS the subject here.
	run env LOGIN_GATE_CURL="${STUBCURL}" LOGIN_GATE_BASE_URL="" bash "${GATE}"
	[[ "$output" != *"VERDICT"* ]] || {
		echo "the gate rendered a verdict with no origin to render it about"
		echo "$output"; return 1;
	}
}

# ─── § MUTATION — every RED below was WATCHED ───────────────────────────────

@test "MUTATION deleting the unregistered-redirect check makes the outage invisible" {
	# WATCHED: with the case arm removed, the 400 body falls through to the
	# non-200 branch. The gate must still fail — but it must NOT be the case
	# that removing the literal check leaves the OUTAGE verdict intact, because
	# that would mean the check is not what produces it.
	mutate 's|^    \*"\${LOGIN_GATE_UNREGISTERED}"\*)|    *"__MUTATED_NEVER_MATCHES__"*)|'

	STUB_AUTH_CODE=400 \
	STUB_AUTH_BODY='Unregistered redirect_uri (&#34;x&#34;).' \
		run_gate

	[[ "$output" != *"ORIGIN_NOT_CLAIMED"* ]] || {
		echo "the ORIGIN_NOT_CLAIMED verdict survived deletion of the check that"
		echo "is supposed to produce it — the verdict comes from somewhere else,"
		echo "and the literal check is not carrying the weight it claims."
		echo "$output"; return 1;
	}
}

@test "MUTATION deleting the issuer comparison lets a mismatched issuer pass" {
	# WATCHED: forcing the comparison always-equal makes the mismatch case go
	# green, which is what proves the comparison is the thing catching it.
	# `if false` rather than `[ "$iss" != "$iss" ]`. Both make the branch
	# unreachable, but the second is a literal tautology and VAC004 flags it —
	# correctly, since it cannot tell an assertion from a mutation payload. The
	# checker being unable to distinguish them is a good reason not to write
	# one, not a reason to allowlist it.
	mutate 's|^  if \[ "\$iss" != "\$want" \]; then|  if false; then|'

	STUB_ISSUER="https://dashboard.osramp.acme.local:30754/dex" run_gate

	[ "$status" -eq 0 ] || {
		echo "expected the mutated gate to PASS a mismatched issuer, got ${status}"
		echo "if it still fails, something other than the issuer comparison is"
		echo "producing the verdict and the real test above proves less than it says"
		echo "$output"; return 1;
	}
}

@test "MUTATION removing the transport-failure guard makes an unanswered auth endpoint pass" {
	# WATCHED, and this is the mutation that matters most. Delete the 000 check
	# from assert_callback_registered and the negative assertion inverts exactly
	# as predicted: no response, no refusal literal, code != 200 ... which the
	# AUTH_REFUSED branch still catches. So this mutation proves the ORDERING is
	# what matters, not merely that some branch exists.
	mutate 's|^  if \[ "\$code" = "000" \]; then$|  if [ "$code" = "__NEVER__" ]; then|'

	STUB_AUTH_CODE=000 run_gate

	[[ "$output" != *"VERDICT: DEX_DOWN"* ]] || {
		echo "DEX_DOWN survived deletion of the transport-failure guard in"
		echo "assert_callback_registered — the verdict is not coming from there."
		echo "$output"; return 1;
	}
}

@test "MUTATION detail-on-stdout reintroduces the captured-verdict bug" {
	# WATCHED. This is a REGRESSION test for a defect this gate actually had on
	# its first live run: `detail` printed to stdout, every assert_* is captured
	# with $(...), so the diagnostics became the verdict string and a WORKING
	# lane reported FAILED. Sending detail back to stdout must break the happy
	# path, which is what makes the >&2 load-bearing rather than decorative.
	mutate 's|printf '"'"'        %s\\n'"'"' "\$\*" >&2|printf '"'"'        %s\\n'"'"' "$*"|'

	run_gate

	[ "$status" -ne 0 ] || {
		echo "detail-on-stdout no longer breaks the gate, so the >&2 is not what"
		echo "keeps diagnostics out of the verdict and the comment explaining it"
		echo "is now guarding nothing."
		echo "$output"; return 1;
	}
}
