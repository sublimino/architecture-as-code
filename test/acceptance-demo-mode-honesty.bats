#!/usr/bin/env bats
#
# No acceptance spec may claim live behaviour while running on demo fixtures.
#
# ─── The defect ─────────────────────────────────────────────────────────────
#
# `test/acceptance/helpers.ts` `login()` took `opts?.demoMode ?? true`. In demo
# mode the dashboard api client short-circuits `req()` into `resolveFake()`
# BEFORE any network call is attempted (`d2-signalloom/apps/dashboard-signalloom
# /src/api/client.ts:309`), so no assertion downstream of that call can observe
# a real HTTP response. Only 18 of 47 spec files mentioned `demoMode: false`,
# and one of those was helpers.ts itself: 30 spec files ran entirely on
# fixtures, 10 of them because they wrote `login(page)` and inherited a default
# they never stated.
#
# Two of those were run by `make test-all-browser` and cited as evidence:
#
#   - signal-loom-netebpf.spec.ts called itself an "eBPF LIVE Network Telemetry
#     Acceptance Suite" and passed with no eBPF, no sentinel, no cluster and no
#     network — what it actually failed on was two fixture strings being absent
#     from the DOM.
#   - afm-integration.spec.ts asserted `getByText("AFM connected")` and
#     `/\d+ clusters?/` under the demo default, while live-data.spec.ts's own
#     TOLERATED list tolerates `/api/rbac/` returning 503 `afm_not_deployed`
#     *because CI never runs `demo-signalloom-afm-up`*.
#
# This is the sharper variant of the estate's fabrication problem: machinery
# that looks like it exercises a live system while it does not misleads the
# engineers, and then certifies the fabrication.
#
# ─── Why these checks and not a list ────────────────────────────────────────
#
# One side of every check is derived from the artefact that actually decides —
# helpers.ts for the default, the spec files for the call sites and the titles,
# demoMode.ts for the precedence. A hand-kept inventory of "which specs are
# live" reproduces the original bug one level up: it goes stale exactly when
# someone adds a spec.
#
# The single pinned list, DEMO-MODE-EXCEPTIONS.tsv, is for mixed files that
# legitimately hold a live block and a fixture block side by side. It is
# checked in both directions, so a row cannot outlive the condition that
# justified it.
#
# No cluster, no node_modules, no network: python3 and coreutils only.

setup() {
	repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
	accept_dir="$repo_root/test/acceptance"
	helpers="$accept_dir/helpers.ts"
	exceptions="$accept_dir/DEMO-MODE-EXCEPTIONS.tsv"
	demo_mode_ts="$repo_root/d2-signalloom/apps/dashboard-signalloom/src/api/demoMode.ts"
}

# ── The default ─────────────────────────────────────────────────────────────

# THE MUTATION TARGET. Reverting helpers.ts to `opts?.demoMode ?? true` must
# turn a named test red, or the next person flips it back and nothing notices.
@test "login() defaults to live mode, so fixture use is always opted into by name" {
	run grep -c 'opts?\.demoMode ?? false' "$helpers"
	[ "$status" -eq 0 ]
	[ "$output" = "1" ]

	run grep -n 'opts?\.demoMode ?? true' "$helpers"
	[ "$status" -ne 0 ]
}

@test "loginExpectingDex() can opt out of demo mode" {
	# It hardcoded sl_demo_mode = "true" with no opt-out, so a login-flow spec
	# could not be made live even deliberately.
	run python3 - "$helpers" <<-'PY'
		import re, sys
		src = open(sys.argv[1]).read()
		m = re.search(r'export async function loginExpectingDex\((.*?)\)\s*:', src, re.S)
		assert m, "loginExpectingDex not found"
		sig = m.group(1)
		assert 'demoMode' in sig, f"no demoMode opt-out in signature: {sig!r}"
		body = src[m.end():]
		body = body[:body.index('\n}\n')]
		assert not re.search(r'sl_demo_mode"\s*,\s*"true"', body), \
			"sl_demo_mode is still hardcoded to \"true\" in the body"
	PY
	[ "$status" -eq 0 ] || { echo "$output"; false; }
}

# ── The call sites ──────────────────────────────────────────────────────────

@test "every login() call states its mode instead of inheriting the default" {
	run python3 - "$accept_dir" <<-'PY'
		import pathlib, re, sys
		bad = []
		for p in sorted(pathlib.Path(sys.argv[1]).glob('*.spec.ts')):
		    src = p.read_text()
		    # Strip block and line comments so prose about login(page) in a
		    # docblock is not mistaken for a call site.
		    code = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
		    code = re.sub(r'(?m)^\s*//.*$', '', code)
		    for m in re.finditer(r'\blogin\(\s*page\s*(,\s*\{(?P<opts>[^}]*)\})?\s*\)', code):
		        opts = m.group('opts')
		        if opts is None or 'demoMode' not in opts:
		            line = code[:m.start()].count('\n') + 1
		            bad.append(f"{p.name}:{line}  {m.group(0).strip()}")
		if bad:
		    print("login() call sites with no explicit demoMode:")
		    print("\n".join(bad))
		    sys.exit(1)
	PY
	[ "$status" -eq 0 ] || { echo "$output"; false; }
}

# ── The claims ──────────────────────────────────────────────────────────────

@test "no spec claiming live behaviour runs in demo mode" {
	run python3 - "$accept_dir" "$exceptions" <<-'PY'
		import pathlib, re, sys

		accept = pathlib.Path(sys.argv[1])
		exc_path = pathlib.Path(sys.argv[2])

		LIVE = re.compile(r'\b(live|real-?time)\b', re.I)
		TITLE = re.compile(
		    r'''(?m)^\s*(?:test|describe)(?:\.describe)?(?:\.\w+)*\(\s*(?P<q>["'`])(?P<t>.*?)(?P=q)''')

		def header(src: str) -> str:
		    m = re.match(r'\s*/\*(.*?)\*/', src, re.S)
		    return m.group(1) if m else ''

		exceptions = {}
		if exc_path.exists():
		    for raw in exc_path.read_text().splitlines():
		        if not raw.strip() or raw.lstrip().startswith('#'):
		            continue
		        name, reason = (raw.split('\t', 1) + [''])[:2]
		        exceptions[name.strip()] = reason.strip()

		violations, justified = [], set()
		for p in sorted(accept.glob('*.spec.ts')):
		    src = p.read_text()
		    claims = [m.group('t') for m in TITLE.finditer(src) if LIVE.search(m.group('t'))]
		    if LIVE.search(header(src)):
		        claims.append('<file header docblock>')
		    demo = 'demoMode: true' in src
		    if claims and demo:
		        if p.name in exceptions:
		            justified.add(p.name)
		        else:
		            violations.append(f"{p.name}: demoMode: true alongside live claims -> " +
		                              "; ".join(repr(c) for c in claims[:4]))

		stale = sorted(set(exceptions) - justified)
		if violations or stale:
		    for v in violations:
		        print("CLAIM:", v)
		    for s in stale:
		        print("STALE EXCEPTION:", s, "- no longer both live-claiming and demo-mode")
		    sys.exit(1)
	PY
	[ "$status" -eq 0 ] || { echo "$output"; false; }
}

# ── The precedence this all rests on ────────────────────────────────────────

@test "an explicit sl_demo_mode value beats the SL_ENV default" {
	# `login(page, { demoMode: false })` writes the string "false" into
	# localStorage. It only means anything because readPersisted() consults the
	# stored value BEFORE falling back to SL_ENV — and VITE_SL_ENV defaults to
	# 'demo', so with the key absent demo mode is ON. If this precedence is
	# ever inverted, every `demoMode: false` in the suite silently stops
	# working while every spec stays green.
	run python3 - "$demo_mode_ts" <<-'PY'
		import re, sys
		src = open(sys.argv[1]).read()
		m = re.search(r'function readPersisted\(\)[^{]*\{(.*?)\n\}', src, re.S)
		assert m, "readPersisted() not found"
		body = m.group(1)
		stored = body.index("stored = localStorage.getItem(KEY)")
		explicit = body.index("return stored === 'true'")
		fallback = body.index("if (stored === null) return SL_ENV === 'demo'")
		assert stored < fallback < explicit, \
		    "readPersisted() no longer checks the stored value before SL_ENV"
	PY
	[ "$status" -eq 0 ] || { echo "$output"; false; }
}
