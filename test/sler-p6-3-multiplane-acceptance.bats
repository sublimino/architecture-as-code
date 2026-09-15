#!/usr/bin/env bats
#
# SLER-P6-3 — the multi-plane acceptance suite must cover every plane the schema
# declares, and must actually be reachable from something that runs.
#
# ─── Why this file exists beside the Go suite ───────────────────────────────
#
# multiplane_acceptance_test.go already derives its coverage from
# AllEnforcementPlanes(). That closes the drift class *inside* Go. It cannot
# close two others:
#
#   1. A Go test that nothing runs is green by never executing. That is the
#      exact defect test/acceptance-spec-coverage.bats was written for after
#      d9d1d2f left a rewritten Playwright test unclaimed by any project —
#      Playwright reported a smaller total rather than complaining. `go test`
#      has the same hole in a different shape: a package nothing invokes simply
#      never runs, and no tool says so.
#
#   2. A derivation written in the same language as the thing it derives from
#      can be wrong in the same direction twice. The plane list here is parsed
#      out of schema.go by an independent reader, so the Go suite and this guard
#      would have to be wrong in the same way, in two languages, to agree.
#
# So one side of every check below is derived from the artefact that decides —
# schema.go for the enum, the Makefile recipe for the make wiring,
# scripts/ci/vm-pipeline.sh for the CI wiring, the P5-2 JSON for the bounds —
# and never from a list kept in this file.
#
# ─── The parsers refuse to guess ────────────────────────────────────────────
#
# Every parser below aborts rather than returning a partial answer. A guard that
# silently mis-reads its own input reports drift it cannot see as "no drift",
# and the whole point is lost. Same discipline as classify_specs() in
# acceptance-spec-coverage.bats.
#
# No cluster, no network, no Go toolchain: python3 and coreutils only, so this
# runs in the cheap static lane alongside acceptance-spec-coverage.bats.

setup() {
	repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
	schema="$repo_root/d2-signalloom/apps/fleet-manager/schema.go"
	suite="$repo_root/d2-signalloom/apps/fleet-manager/multiplane_acceptance_test.go"
	matrix="$repo_root/docs/signalloom/sler-p5-2-denial-matrix.json"
	proof="$repo_root/docs/signalloom/sler-p6-3-proof.md"
	pipeline="$repo_root/scripts/ci/vm-pipeline.sh"
	makefile="$repo_root/Makefile"
	redteam="$repo_root/scripts/run-redteam-suite.sh"

	# The make target and CI stage this suite claims. Both are asserted against
	# the real recipe / real run_stage command below, never taken on trust.
	make_target="test-sler-multiplane-acceptance"
	ci_stage="stage1c3"
}

# LC_ALL=C on every sort and comm, for the reason acceptance-spec-coverage.bats
# records: en_GB.UTF-8 collation ignores punctuation at the primary level, so
# comm aborts with "input is not in sorted order" and the guard reports a test
# failure instead of the drift it exists to catch.

# ── Derivation 1: the plane enum, read out of schema.go ─────────────────────
#
# Reads BOTH the const block (identifier -> wire value) and the
# AllEnforcementPlanes() return list, then resolves one through the other. It
# does not read the const block alone, because a constant that exists but is
# absent from AllEnforcementPlanes() is not a plane the cascade dispatches, and
# counting it would make this guard demand coverage for a plane nothing runs.
enum_planes() {
	# NOTE: <<- strips leading TABS, so Python's own indentation must be SPACES.
	python3 - "$schema" <<-'PY'
	import re, sys

	src = open(sys.argv[1]).read()

	# identifier -> wire value, e.g. PlaneMesh -> mesh
	consts = dict(re.findall(
	    r'^\s*(Plane[A-Za-z0-9_]*)\s+EnforcementPlane\s*=\s*"([^"]+)"\s*$',
	    src, re.M))
	if not consts:
	    sys.exit(
	        "PARSE: no `PlaneX EnforcementPlane = \"...\"` constants found in "
	        "schema.go. Returning an empty enum would make every coverage check "
	        "below a set difference against nothing, which passes while checking "
	        "nothing at all."
	    )

	body = re.search(
	    r'func\s+AllEnforcementPlanes\(\)\s*\[\]EnforcementPlane\s*\{(.*?)\n\}',
	    src, re.S)
	if not body:
	    sys.exit(
	        "PARSE: AllEnforcementPlanes() not found in schema.go, or its "
	        "signature changed. This guard derives the expected plane set from "
	        "that function; teach the parser the new form before relying on it."
	    )

	listed = re.findall(r'\b(Plane[A-Za-z0-9_]*)\b', body.group(1))
	if not listed:
	    sys.exit("PARSE: AllEnforcementPlanes() returned no plane identifiers.")

	out = []
	for ident in listed:
	    if ident not in consts:
	        sys.exit(
	            f"PARSE: AllEnforcementPlanes() returns {ident}, which has no "
	            f"`EnforcementPlane = \"...\"` constant. The wire value cannot be "
	            f"resolved, so this guard would compare an identifier against a "
	            f"wire string and report false drift."
	        )
	    out.append(consts[ident])

	for v in sorted(set(out)):
	    print(v)
	PY
}

# ── Derivation 2: the planes the Go acceptance registry claims ──────────────
#
# Parses acceptanceScenarios() in the Go suite and resolves each claimed
# identifier through schema.go's const block — the same resolution the enum
# derivation uses, so a rename shows up as drift rather than as two matching
# mistakes.
registry_planes() {
	# NOTE: <<- strips leading TABS, so Python's own indentation must be SPACES.
	python3 - "$schema" "$suite" <<-'PY'
	import re, sys

	schema_src = open(sys.argv[1]).read()
	suite_src = open(sys.argv[2]).read()

	consts = dict(re.findall(
	    r'^\s*(Plane[A-Za-z0-9_]*)\s+EnforcementPlane\s*=\s*"([^"]+)"\s*$',
	    schema_src, re.M))

	# Strip // comments first. The suite's prose names planes at length
	# ("Resume touches the credential planes..."), and counting a comment as a
	# coverage claim would let a scenario drop a plane while still reading as
	# covering it -- the same reason pipeline_specs() in
	# acceptance-spec-coverage.bats strips comments before counting.
	suite_src = re.sub(r'(?m)^\s*//.*$', '', suite_src)

	body = re.search(
	    r'func\s+acceptanceScenarios\(\)\s*\[\]acceptanceScenario\s*\{(.*?)\n\}\n',
	    suite_src, re.S)
	if not body:
	    sys.exit(
	        "PARSE: acceptanceScenarios() not found in the Go suite, or its "
	        "signature changed. Without it this guard cannot read what the suite "
	        "claims to cover, and would report full coverage over an empty set."
	    )

	claims = re.findall(r'Planes:\s*\[\]EnforcementPlane\{([^}]*)\}', body.group(1))
	if not claims:
	    sys.exit(
	        "PARSE: no `Planes: []EnforcementPlane{...}` claims in "
	        "acceptanceScenarios(). An empty claim set would make the coverage "
	        "comparison pass vacuously in one direction."
	    )

	values = set()
	for group in claims:
	    for ident in re.findall(r'\b(Plane[A-Za-z0-9_]*)\b', group):
	        if ident not in consts:
	            sys.exit(
	                f"PARSE: a scenario claims {ident}, which schema.go declares "
	                f"no constant for. Either the plane was renamed or the claim "
	                f"is a typo; both make the coverage it reports fiction."
	            )
	        values.add(consts[ident])

	for v in sorted(values):
	    print(v)
	PY
}

# The planes P5-2's export publishes, keyed on each entry's .plane FIELD.
#
# Deliberately not the JSON object key: the export keys OpenBao as "openbao"
# while its plane value is "bao". Reading the key would leave the bao plane
# unbound, and an unbound plane has its timing assertion skipped rather than
# failed -- a gap that reads as coverage.
matrix_planes() {
	# NOTE: <<- strips leading TABS, so Python's own indentation must be SPACES.
	python3 - "$matrix" <<-'PY'
	import json, sys

	try:
	    doc = json.load(open(sys.argv[1]))
	except FileNotFoundError:
	    sys.exit(f"PARSE: SLER-P5-2 denial-matrix export missing at {sys.argv[1]}")
	except json.JSONDecodeError as err:
	    sys.exit(f"PARSE: {sys.argv[1]} is not valid JSON: {err}")

	planes = doc.get("planes") or {}
	if not planes:
	    sys.exit(f"PARSE: {sys.argv[1]} declares no planes")

	out = []
	for key, entry in planes.items():
	    value = entry.get("plane")
	    if not value:
	        sys.exit(
	            f"PARSE: denial-matrix entry {key!r} has no \"plane\" field. The "
	            f"export keys OpenBao as 'openbao' while its plane value is 'bao', "
	            f"so this index reads the field; an entry without one cannot be "
	            f"bound to a plane at all."
	        )
	    out.append(value)

	for v in sorted(set(out)):
	    print(v)
	PY
}

# The recipe lines of one Makefile target. index()==1 is a literal prefix match,
# not a regex, so a target name containing regex metacharacters cannot silently
# match the wrong rule.
make_recipe() {
	awk -v t="$1:" '
		index($0, t) == 1 { inrecipe = 1; next }
		inrecipe && /^\t/ { print; next }
		inrecipe { exit }
	' "$makefile"
}

# The command a vm-pipeline.sh run_stage invocation runs, selected by the stage
# id at the front of its report filename. Keyed on the report FILENAME because
# openreports-convert.sh keys on that same string.
stage_command() {
	# NOTE: <<- strips leading TABS, so Python's own indentation must be SPACES.
	python3 - "$pipeline" "$1" <<-'PY'
	import re, sys

	src = open(sys.argv[1]).read()
	stage_id = sys.argv[2]
	src = re.sub(r'(?m)^\s*#.*$', '', src)
	src = src.replace('\\\n', ' ')

	for block in src.split('run_stage')[1:]:
	    args = re.findall(r'"((?:[^"\\]|\\.)*)"', block)
	    if len(args) >= 3 and args[1].startswith(stage_id + '-'):
	        print(args[2])
	        break
	PY
}

@test "both plane derivations parse, and neither returns an empty set" {
	# The self-test. Every check below is a set difference, and a parser that
	# returned nothing would make all of them pass while comparing nothing --
	# the vacuous-pass shape this whole file exists to stamp out. Observed in
	# acceptance-spec-coverage.bats's own history: an unparseable testMatch
	# turned its central test green.
	run enum_planes
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	local enum_count
	enum_count="$(printf '%s\n' "$output" | grep -c .)"
	[ "$enum_count" -gt 0 ] || { echo "schema.go yielded no planes"; return 1; }

	run registry_planes
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ "$(printf '%s\n' "$output" | grep -c .)" -gt 0 ] || {
		echo "the Go acceptance registry yielded no plane claims"
		return 1
	}

	# Positive control. mesh is declared in schema.go's const block and returned
	# by AllEnforcementPlanes(); a parser that answered nothing useful would
	# still have passed the count check above with one junk line.
	enum_planes | grep -qx 'mesh' || {
		echo "the enum parser did not find the mesh plane; its output is not the plane set"
		enum_planes
		return 1
	}

	# Negative control. schema.go declares no such plane, so if the parser
	# reports it the matching is too broad and every result here is worthless.
	if enum_planes | grep -qx '__acceptance-coverage-probe__'; then
		echo "the enum parser reported a plane schema.go does not declare"
		return 1
	fi
}

@test "every plane schema.go declares is claimed by an acceptance scenario" {
	# The check that closes the drift class. Left side derived from schema.go,
	# right side derived from the Go suite. A sixth plane added to
	# AllEnforcementPlanes() fails here until a scenario claims it.
	local uncovered
	uncovered="$(LC_ALL=C comm -23 <(enum_planes | LC_ALL=C sort) <(registry_planes | LC_ALL=C sort))"
	[ -z "$uncovered" ] || {
		echo "planes AllEnforcementPlanes() declares that NO acceptance scenario claims:"
		echo "$uncovered"
		echo
		echo "a plane the cascade dispatches but the acceptance suite never exercises"
		echo "produces a green multi-plane acceptance run that in fact covered fewer"
		echo "planes than it published. add a scenario to acceptanceScenarios() in"
		echo "$suite, and a test that actually drives it."
		return 1
	}
}

@test "no acceptance scenario claims a plane schema.go does not declare" {
	# The reverse direction, which a one-way check misses. A RENAMED plane
	# leaves the old value claimed and the new one orphaned; without this, the
	# forward check still passes because the new name is simply absent.
	local unknown
	unknown="$(LC_ALL=C comm -13 <(enum_planes | LC_ALL=C sort) <(registry_planes | LC_ALL=C sort))"
	[ -z "$unknown" ] || {
		echo "acceptance scenarios claim planes the schema does not declare:"
		echo "$unknown"
		echo "either a plane was renamed in schema.go and the registry still names"
		echo "the old value, or the claim is a typo. the coverage it reports is fiction."
		return 1
	}
}

@test "the derived coverage check fails when a plane has no scenario" {
	# Falsification. The three tests above are set differences over real inputs
	# that currently agree, so they would pass identically if comm were replaced
	# by `true`. This injects a synthetic sixth plane into one side only and
	# proves the comparison actually reports it -- the same drift control the Go
	# suite runs as TestAcceptanceCoverage_FailsOnSyntheticSixthPlane, repeated
	# here because this guard's comparison is a different implementation.
	#
	# The probe name is deliberately one schema.go could never declare. An
	# earlier version used "quarantine", which is a perfectly plausible future
	# plane name — and when a mutation run added exactly that plane to the enum
	# to falsify test 2, this control started comparing 'quarantine' against
	# 'quarantine\nquarantine' and failed for a reason that had nothing to do
	# with what it tests. A control that collides with the thing it controls for
	# reports noise at precisely the moment its signal matters.
	local probe='__coverage-drift-probe__'
	local uncovered
	uncovered="$(LC_ALL=C comm -23 \
		<( { enum_planes; echo "$probe"; } | LC_ALL=C sort -u) \
		<(registry_planes | LC_ALL=C sort -u))"

	[ "$uncovered" = "$probe" ] || {
		echo "a synthetic sixth plane ($probe) was NOT reported as uncovered; got: '$uncovered'"
		echo "this guard cannot detect a new plane, which is the entire drift class"
		echo "it exists to close."
		return 1
	}
}

@test "P5-2 publishes a bound for every plane the schema declares" {
	# The suite sources every timing assertion from the JSON export. A plane
	# missing from the export has its assertion skipped rather than failed.
	local missing
	missing="$(LC_ALL=C comm -23 <(enum_planes | LC_ALL=C sort) <(matrix_planes | LC_ALL=C sort))"
	[ -z "$missing" ] || {
		echo "planes with no entry in docs/signalloom/sler-p5-2-denial-matrix.json:"
		echo "$missing"
		echo
		echo "note this resolves entries by their .plane FIELD, not the JSON key:"
		echo "the OpenBao entry is keyed \"openbao\" and carries \"plane\": \"bao\"."
		echo "keying on the object key leaves bao unbound and its timing assertion"
		echo "silently skipped."
		return 1
	}

	# Positive control on exactly that trap.
	matrix_planes | grep -qx 'bao' || {
		echo "the bao plane did not resolve from the export; the index is reading the JSON key"
		return 1
	}
}

@test "the acceptance suite asserts against the JSON export, not the prose matrix" {
	# Hard-coding today's figures from the prose document is the failure mode
	# the card names: a later re-benchmark in P5-2 would leave this suite
	# asserting stale numbers with no test catching the drift.
	grep -q 'sler-p5-2-denial-matrix\.json' "$suite" || {
		echo "the Go acceptance suite does not reference the machine-readable export."
		echo "timing assertions sourced from anywhere else go stale on the next re-benchmark."
		return 1
	}

	# And it must read the published threshold rather than a literal.
	grep -q 'RegressionThresholdMs' "$suite" || {
		echo "the suite does not read regression_threshold_ms from the export"
		return 1
	}
}

@test "a make target really runs the acceptance suite" {
	# Derived from the recipe, not from a claim. A target that exists but whose
	# recipe does not run the suite reads as wiring while wiring nothing.
	local recipe
	recipe="$(make_recipe "$make_target")"
	[ -n "$recipe" ] || {
		echo "Makefile has no target '$make_target' (or it has an empty recipe)"
		return 1
	}
	[[ "$recipe" == *"go test"* ]] || {
		echo "target '$make_target' exists but its recipe does not run go test:"
		echo "$recipe"
		return 1
	}
	[[ "$recipe" == *"TestAcceptance"* ]] || {
		echo "target '$make_target' runs go test but does not select the acceptance tests:"
		echo "$recipe"
		return 1
	}
	[[ "$recipe" == *"fleet-manager"* ]] || {
		echo "target '$make_target' does not run in the fleet-manager module:"
		echo "$recipe"
		return 1
	}
}

@test "a CI stage really runs the acceptance suite" {
	# The check that separates "reachable if a human types make" from "runs on
	# every change". acceptance-spec-coverage.bats exists because 12 of 15
	# Playwright specs were in the first category while documented as the second.
	local command
	command="$(stage_command "$ci_stage")"
	[ -n "$command" ] || {
		echo "no run_stage in scripts/ci/vm-pipeline.sh writes a ${ci_stage}-* report."
		echo
		echo "a suite reachable only from a manual make invocation is a suite that"
		echo "stops running the first time someone forgets. that is the silent"
		echo "non-coverage failure mode this guard's sibling exists to catch."
		return 1
	}
	[[ "$command" == *"$make_target"* ]] || {
		echo "CI stage ${ci_stage} exists but its command does not run '$make_target':"
		echo "$command"
		return 1
	}
}

@test "this guard has its own CI stage and therefore its own report" {
	# run_stage writes ONE report per stage. Folded into the acceptance stage, a
	# coverage-drift failure and a Go acceptance failure land in the same blob
	# and openreports-convert.sh cannot tell a maintainer which contract broke.
	#
	# The deeper reason is the one d2-signalloom/test/bats-registry-coverage.bats
	# enforces, and it caught this file's omission when it was first wired: a
	# repo-root suite that no run_stage NAMES is invisible to the registry guard,
	# so it can quietly stop running with nothing to notice. "Reachable via a
	# make target" is exactly the category acceptance-spec-coverage.bats exists
	# to distinguish from real CI coverage.
	local self_stage command
	self_stage="stage1c4"
	command="$(stage_command "$self_stage")"

	[ -n "$command" ] || {
		echo "no run_stage writes a ${self_stage}-* report, so this guard has no report of its own"
		return 1
	}
	[[ "$command" == *"sler-p6-3-multiplane-acceptance.bats"* ]] || {
		echo "CI stage ${self_stage} does not name this suite:"
		echo "$command"
		return 1
	}
}

@test "the offline test lane claims the acceptance suite" {
	# Third wiring surface. `make test-all-offline` is what a developer runs
	# before pushing; a suite absent from it is one they will not see fail.
	local recipe
	recipe="$(make_recipe "test-all-offline")"
	[ -n "$recipe" ] || {
		echo "Makefile has no test-all-offline target"
		return 1
	}
	[[ "$recipe" == *"$make_target"* ]] || {
		echo "test-all-offline does not invoke '$make_target'"
		return 1
	}
	[[ "$recipe" == *"sler-p6-3-multiplane-acceptance.bats"* ]] || {
		echo "test-all-offline does not run this guard itself."
		echo "a coverage guard nothing runs is the defect it was written to prevent,"
		echo "one level up."
		return 1
	}
}

@test "the red-team runner gates on the acceptance suite" {
	# P6-1 asserts an adversary cannot escape the cascade. That claim is only
	# meaningful if the cascade works on the ordinary path, so the happy-path
	# suite runs first and a failure there stops the adversarial run rather than
	# letting it publish zero escapes against a cascade that never contained.
	grep -q "$make_target" "$redteam" || {
		echo "scripts/run-redteam-suite.sh does not run '$make_target'."
		echo "an adversarial suite reporting zero escapes against a broken cascade"
		echo "is the most expensive kind of false assurance, because it is published."
		return 1
	}
}

@test "the acceptance suite fails loudly and never skips" {
	# A skip on a missing dependency turns a build failure into a silent pass.
	# The Go suite asserts this about itself; this asserts it from outside, so
	# deleting the Go guard does not also delete the check.
	local hits
	hits="$(grep -cE '\bt\.Skip(f|Now)?\(' "$suite" || true)"
	[ "$hits" -eq 0 ] || {
		echo "the acceptance suite contains $hits skip call(s):"
		grep -nE '\bt\.Skip(f|Now)?\(' "$suite"
		echo
		echo "a misconfigured CI run must fail, not report coverage it did not obtain."
		return 1
	}

	# The guard must be capable of finding one. Without this, a typo in the
	# pattern above makes the check pass over a file full of skips.
	local probe
	probe="$(printf 'func TestX(t *testing.T) {\n\tt.Sk%s("x")\n}\n' 'ip')"
	printf '%s' "$probe" | grep -qE '\bt\.Skip(f|Now)?\(' || {
		echo "the skip pattern does not match a real call site; this check is inert"
		return 1
	}
}

@test "the proof document exists and names its derivation source" {
	[ -f "$proof" ] || {
		echo "docs/signalloom/sler-p6-3-proof.md is missing"
		return 1
	}
	grep -q 'AllEnforcementPlanes' "$proof" || {
		echo "the proof document does not name the artefact coverage is derived from."
		echo "a proof that describes a derived guard without naming the source it"
		echo "derives from is prose."
		return 1
	}
	grep -q 'sler-p5-2-denial-matrix.json' "$proof" || {
		echo "the proof document does not name the timing source"
		return 1
	}
}
