#!/usr/bin/env bats
#
# The authorization suite must actually be collected by pytest.
#
# WHY THIS LIVES OUTSIDE PYTHON. tests/test_tenant_isolation.py carries its own
# manifest check (`test_every_declared_attack_case_was_actually_collected`),
# which catches an attack being deleted or a sweep table being truncated. It
# cannot catch the one failure that matters most: the whole FILE ceasing to be
# collected. A test inside an uncollected file does not run, does not fail, and
# does not report its own absence. Exit code 0, no warning, nothing red.
#
# THE HAZARD, CONCRETELY. This branch and its siblings merge into
# feat/signal-loop-and-bootstrap-refactor. A merge conflict in `pytest.ini`,
# in a `conftest.py`, in `testpaths`, or in `addopts` resolved to one side
# leaves every spec file on disk while changing which ones are collected. This
# repo has already shipped that exact shape twice with different runners:
# four Playwright specs matched no project's `testMatch` and were silently
# skipped (test/acceptance-spec-coverage.bats exists because of it), and 33 of
# 68 .bats suites were never invoked by any runner (test/bats-registry-coverage
# .bats exists because of that one).
#
# For an adversarial suite green is the suspicious state, so this asserts the
# suite is present and collected BEFORE anyone believes a green run.
#
# The manifest is parsed out of the Python source with `ast` rather than by
# importing the module: importing needs asyncpg, fastapi, PyJWT and the rest,
# which is exactly the dependency surface that makes a guard skip itself when
# the environment is not perfect. A guard that can silently skip is not a guard.

setup() {
	repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
	src="$repo_root/d2-signalloom/apps/fe-signalloom/src"
	suite="$src/tests/test_tenant_isolation.py"
	: "${UV_CACHE_DIR:=/home/andy/src/.worktrees/.uvcache}"
	export UV_CACHE_DIR
}

# Names declared in ATTACK_MANIFEST, read from the source without importing it.
#
# NOTE the indentation: `<<-` strips leading TABS from every line, which is what
# lets the heredoc sit inside this function without breaking bats' style. It
# strips the Python block indentation too if that is also tabs, producing an
# IndentationError that surfaces only as `status != 0`. So the Python below is
# indented with SPACES after the leading tab. Found by running it.
declared_attacks() {
	python3 - "$suite" <<-'PY'
	import ast, sys
	tree = ast.parse(open(sys.argv[1]).read())
	for node in tree.body:
	    if not isinstance(node, ast.AnnAssign):
	        continue
	    if getattr(node.target, "id", None) != "ATTACK_MANIFEST":
	        continue
	    for element in node.value.args[0].elts:   # frozenset({...})
	        print(element.value)
	    break
	else:
	    sys.exit("ATTACK_MANIFEST not found in " + sys.argv[1])
	PY
}

@test "the authorization suite file exists and declares attacks" {
	[ -f "$suite" ]

	run declared_attacks
	[ "$status" -eq 0 ]
	# Assert the mechanism produced something before asserting over it: an ast
	# walk that stopped matching would make every check below vacuous, which is
	# the same defect class this file exists to catch.
	[ -n "$output" ]

	local count
	count="$(wc -l <<< "$output")"
	echo "declared attacks: $count"
	[ "$count" -ge 25 ]
}

@test "pytest actually collects every declared attack" {
	run declared_attacks
	[ "$status" -eq 0 ]
	local declared="$output"

	# --collect-only, and NOT a run: this asks the question that matters
	# (is it selected?) without paying for execution, and it answers it even
	# when a test would fail for an unrelated reason.
	run bash -c "cd '$src' && uv run --python 3.12 --with pytest --with pytest-asyncio \
		--with pytest-xdist --with-requirements requirements.txt \
		python -m pytest tests --collect-only -q -n0 2>&1"
	if [ "$status" -ne 0 ]; then
		echo "pytest --collect-only failed; cannot verify the suite is live:"
		echo "$output"
		false
	fi
	local collected="$output"

	# The file itself must appear at all.
	if ! grep -q 'test_tenant_isolation\.py' <<< "$collected"; then
		echo "tests/test_tenant_isolation.py is NOT COLLECTED by pytest."
		echo ""
		echo "The file is on disk and its tests are green in isolation, but the"
		echo "suite run does not include it — so the authorization boundary is"
		echo "unguarded while CI reports success. Check pytest.ini testpaths,"
		echo "addopts, and any conftest.py collect_ignore, which is where a"
		echo "merge resolves this away."
		false
	fi

	local missing=""
	while read -r attack; do
		[ -z "$attack" ] && continue
		grep -qF "::$attack" <<< "$collected" || missing="${missing}${attack} "
	done <<< "$declared"

	if [ -n "$missing" ]; then
		echo "declared attack case(s) not collected by pytest:"
		for a in $missing; do echo "  $a"; done
		echo ""
		echo "ATTACK_MANIFEST says this suite covers them. pytest disagrees."
		false
	fi
}

@test "the parametrised sweeps have not been hollowed out" {
	# A sweep table emptied by a bad merge leaves the test function present and
	# passing while it attacks nothing. The Python-side check asserts this too;
	# it is repeated here because it is the check most likely to be lost with
	# the file it lives in.
	run bash -c "cd '$src' && python3 -c \"
import ast
tree = ast.parse(open('tests/test_tenant_isolation.py').read())
sizes = {}
for node in tree.body:
    target = None
    if isinstance(node, ast.AnnAssign):
        target = getattr(node.target, 'id', None)
    elif isinstance(node, ast.Assign) and node.targets:
        target = getattr(node.targets[0], 'id', None)
    if target in ('DB_ROUTES', 'SUPERADMIN_ROUTES'):
        sizes[target] = len(node.value.elts)
print(sizes.get('DB_ROUTES', 0), sizes.get('SUPERADMIN_ROUTES', 0))
\""
	[ "$status" -eq 0 ]

	local db_routes superadmin_routes
	db_routes="$(cut -d' ' -f1 <<< "$output")"
	superadmin_routes="$(cut -d' ' -f2 <<< "$output")"
	echo "DB_ROUTES=$db_routes SUPERADMIN_ROUTES=$superadmin_routes"

	[ "$db_routes" -ge 30 ]
	[ "$superadmin_routes" -ge 6 ]
}
