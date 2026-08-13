#!/usr/bin/env bats
#
# Every acceptance spec must declare where it runs, and the declaration must be
# true.
#
# ─── The defect ─────────────────────────────────────────────────────────────
#
# 15 specs sit in test/acceptance. CI stage 8 runs exactly one of them. Two more
# are reachable from a make target. The rest run only if a human types `make
# acceptance-test`, and four of them do not run even then, because they match no
# `testMatch` in playwright.config.ts — Playwright silently reports a smaller
# total rather than complaining that nothing claims them.
#
# That cost real coverage the day this guard was written: d9d1d2f rewrote a test
# in smoke.spec.ts to assert the Collusion & Access page carries no
# page-specific background, and nothing anywhere would ever have run it.
#
# ─── Why a derived guard rather than a list ─────────────────────────────────
#
# TESTING.md already documented this coverage in prose, and had already drifted:
# it describes "68 tests across 9 specs, in four projects" while the config now
# has six projects and Playwright reports 70 tests in 12 files. A hand-kept list
# reproduces the original bug one level up — it goes stale exactly when someone
# adds a spec, which is the moment it needed to be right.
#
# So one side of every check below is derived from the filesystem or from the
# artefact that actually decides (playwright.config.ts, the Makefile,
# vm-pipeline.sh), and both directions are asserted. A spec cannot be added
# without a row; a row cannot outlive its spec; a spec cannot be marked unwired
# once a project claims it; and a spec cannot claim a CI stage that does not run
# it. Same shape as scripts/check-backends.sh, which reads nginx's proxy_pass
# lines rather than a list of backends, and as dashboard-route-collisions.bats,
# which reads the nginx upstreams rather than a list of policy rules.
#
# No cluster, no node_modules, no network: python3 and coreutils only, so this
# runs as CI stage 1c, before the ~25 minutes of cluster work it gates.

setup() {
	repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
	accept_dir="$repo_root/test/acceptance"
	registry="$accept_dir/SPEC-REGISTRY.tsv"
	pw_config="$accept_dir/playwright.config.ts"
	pipeline="$repo_root/scripts/ci/vm-pipeline.sh"
	makefile="$repo_root/Makefile"
}

# LC_ALL=C on every sort and comm in this file is load-bearing, for the reason
# dashboard-route-collisions.bats records: en_GB.UTF-8 collation ignores
# punctuation at the primary level, so it orders "supercred-page.spec.ts" after
# "supercred-two-window.spec.ts" while byte order puts it before. comm then
# aborts with "input is not in sorted order" and the guard reports a test
# failure instead of the drift it exists to catch.

# Every spec file in test/acceptance, basename only.
specs_on_disk() {
	( cd "$accept_dir" && ls -1 -- *.spec.ts 2>/dev/null ) | LC_ALL=C sort
}

# Uncommented, non-blank registry rows.
registry_rows() {
	grep -v '^[[:space:]]*#' "$registry" | grep -v '^[[:space:]]*$'
}

# Column 1 of every registry row.
registry_specs() {
	registry_rows | cut -f1 | LC_ALL=C sort
}

# The runner column for one spec.
registry_runner() {
	registry_rows | awk -F'\t' -v s="$1" '$1 == s { print $2 }'
}

# The reason column for one spec.
registry_reason() {
	registry_rows | awk -F'\t' -v s="$1" '$1 == s { print $3 }'
}

# `<spec>\twired|unwired` for every spec on disk, decided by whether any
# project's testMatch claims it.
#
# The parser refuses to guess. If playwright.config.ts grows a testMatch form it
# cannot read, it aborts rather than reporting that spec as unwired — a guard
# that silently mis-reads its own input is the failure mode this whole file
# exists to prevent.
classify_specs() {
	# NOTE: <<- strips leading TABS, so Python's own indentation must be SPACES.
	python3 - "$pw_config" "$accept_dir" <<-'PY'
	import fnmatch, os, re, sys

	config_path, accept_dir = sys.argv[1], sys.argv[2]
	src = open(config_path).read()

	# Drop // line comments first. playwright.config.ts carries long comment
	# blocks that name spec files in prose ("A spec added to `smoke` gets
	# neither..."), and a commented-out project must not read as coverage.
	src = re.sub(r'(?m)^\s*//.*$', '', src)

	declared = len(re.findall(r'\btestMatch\s*:', src))
	pattern = (r'\btestMatch\s*:\s*'
               r'(?:"([^"]*)"|\'([^\']*)\'|/((?:[^/\\\n]|\\.)*)/[gimsuy]*)')
	found = list(re.finditer(pattern, src))
	if declared != len(found):
	    sys.exit(
	        f"PARSE: playwright.config.ts declares {declared} testMatch keys "
	        f"but only {len(found)} are readable. This guard would report a "
	        f"covered spec as unwired, or miss an orphan entirely. Teach the "
	        f"parser the new form before relying on the result."
	    )

	globs, regexes = [], []
	for m in found:
	    double, single, rx = m.group(1), m.group(2), m.group(3)
	    if rx is not None:
	        try:
	            regexes.append(re.compile(rx))
	        except re.error as err:
	            sys.exit(
	                f"PARSE: testMatch /{rx}/ is not readable as a Python "
	                f"regex ({err}). Rewrite it or extend this parser."
	            )
	    else:
	        globs.append(double if double is not None else single)

	# Playwright matches a string testMatch as a glob and a RegExp against the
	# full path. Every pattern in this config ends in a filename, so matching
	# the basename is equivalent; a pattern anchored with ^ against an absolute
	# path would not be, and would show up as a false "unwired" rather than a
	# false pass.
	def wired(name):
	    if any(fnmatch.fnmatch(name, g) for g in globs):
	        return True
	    return any(r.search(name) for r in regexes)

	# Negative control. A pattern that over-matches — `/spec/` where
	# `/smoke\.spec\.ts/` was meant — would mark every spec wired and turn the
	# orphan check into a no-op that passes forever. No project can legitimately
	# claim this name, so if something does, the patterns are too broad and the
	# result must not be trusted.
	probe = '__spec-coverage-guard-probe__.spec.ts'
	if wired(probe):
	    sys.exit(
	        f"PARSE: a testMatch in playwright.config.ts matches {probe}, which "
	        f"no project can mean. The patterns are too broad, so every spec "
	        f"would read as wired and the orphan check would pass vacuously."
	    )

	specs = sorted(f for f in os.listdir(accept_dir) if f.endswith('.spec.ts'))
	for name in specs:
	    print(f"{name}\t{'wired' if wired(name) else 'unwired'}")
	PY
}

# The command a vm-pipeline.sh run_stage invocation runs, selected by the stage
# id at the front of its report filename.
#
# Keyed on the report FILENAME rather than a stage number in a comment, because
# openreports-convert.sh keys on that same filename. If the guard and the report
# generator ever disagree, they disagree about the same string.
stage_command() {
	# NOTE: <<- strips leading TABS, so Python's own indentation must be SPACES.
	python3 - "$pipeline" "$1" <<-'PY'
	import re, sys

	src = open(sys.argv[1]).read()
	stage_id = sys.argv[2]
	src = re.sub(r'(?m)^\s*#.*$', '', src)
	src = src.replace('\\\n', ' ')

	# run_stage <description> <report-file> <command>
	for block in src.split('run_stage')[1:]:
	    args = re.findall(r'"((?:[^"\\]|\\.)*)"', block)
	    if len(args) >= 3 and args[1].startswith(stage_id + '-'):
	        print(args[2])
	        break
	PY
}

# Every spec filename any run_stage command names. Comments are stripped first:
# vm-pipeline.sh mentions signalloom-test-1.spec.ts in prose near the top, and
# counting a comment as coverage would let a spec be removed from a stage while
# still reading as wired.
pipeline_specs() {
	sed 's/#.*$//' "$pipeline" \
		| grep -oE '[A-Za-z0-9._-]+\.spec\.ts' \
		| LC_ALL=C sort -u
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

@test "the guard can read every project in playwright.config.ts" {
	# A self-test, in the spirit of dashboard-route-collisions.bats asserting
	# both route surfaces parse and are non-empty. Every check below is a set
	# difference, and a parser that returned nothing would make every one of
	# them pass while checking nothing at all.
	run classify_specs
	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}

	local classified on_disk
	classified="$(printf '%s\n' "$output" | wc -l)"
	on_disk="$(specs_on_disk | wc -l)"
	[ "$classified" -eq "$on_disk" ] || {
		echo "classified $classified specs but $on_disk are on disk"
		return 1
	}
	[ "$on_disk" -gt 0 ]

	# Positive control in each direction: the spec CI runs must read as wired,
	# and a name no project mentions must read as unwired. Without these a
	# parser that answered "wired" (or "unwired") to everything would pass.
	[[ "$output" == *"signalloom-test-1.spec.ts	wired"* ]] || {
		echo "the spec CI stage 8 runs classified as unwired — parser is broken"
		return 1
	}
}

@test "every spec on disk has exactly one registry row, and every row has a spec" {
	local orphans stale duplicates
	orphans="$(LC_ALL=C comm -23 <(specs_on_disk) <(registry_specs))"
	[ -z "$orphans" ] || {
		echo "these specs exist but no SPEC-REGISTRY.tsv row covers them:"
		echo "$orphans"
		echo
		echo "a spec nothing declares is a spec nobody notices stops running."
		echo "add a row to $registry naming its runner and, if it is not in a"
		echo "CI stage, the precondition that keeps it out of one."
		return 1
	}

	stale="$(LC_ALL=C comm -13 <(specs_on_disk) <(registry_specs))"
	[ -z "$stale" ] || {
		echo "SPEC-REGISTRY.tsv rows for specs that no longer exist:"
		echo "$stale"
		echo "delete them — a registry that describes deleted files is prose."
		return 1
	}

	duplicates="$(registry_rows | cut -f1 | LC_ALL=C sort | uniq -d)"
	[ -z "$duplicates" ] || {
		echo "duplicate SPEC-REGISTRY.tsv rows: $duplicates"
		return 1
	}
}

@test "every registry runner is a known kind, and every non-CI row gives a reason" {
	local spec runner reason bad=()
	while IFS= read -r spec; do
		runner="$(registry_runner "$spec")"
		reason="$(registry_reason "$spec")"
		case "$runner" in
			ci:*)
				# A CI row needs no reason: the stage IS the reason, and the
				# next two tests prove the stage really runs it.
				;;
			make:*|suite-only|unwired)
				[ -n "${reason// /}" ] || bad+=("$spec: runner '$runner' with no reason")
				;;
			*)
				bad+=("$spec: unknown runner '$runner'")
				;;
		esac
	done < <(registry_specs)

	[ "${#bad[@]}" -eq 0 ] || {
		printf '%s\n' "${bad[@]}"
		echo
		echo "runner must be ci:<stage>, make:<target>, suite-only or unwired."
		echo "everything but ci:* must name the precondition that keeps it out"
		echo "of a lane — that sentence is the work item for wiring it in."
		return 1
	}
}

@test "a spec matches a playwright project if and only if the registry says so" {
	# The check that would have caught all four orphans. Both sides are derived:
	# the left from playwright.config.ts, the right from the registry. Neither
	# can drift without this failing, and marking a spec unwired to silence it
	# fails the other direction the moment a project claims it.

	# Re-establish the classifier's own health here rather than leaning on the
	# first test. classify_specs prints nothing when its parser aborts, and a
	# `while read` over nothing passes every assertion below without making one
	# -- the exact vacuous-pass shape this file exists to stamp out. Observed:
	# feeding the config an unparseable testMatch turned this test green.
	local classified
	classified="$(classify_specs)" || {
		echo "$classified"
		echo "the classifier failed, so nothing below was actually compared."
		return 1
	}
	[ "$(printf '%s\n' "$classified" | wc -l)" -eq "$(specs_on_disk | wc -l)" ] || {
		echo "classifier covered fewer specs than exist on disk; result unusable"
		return 1
	}

	local spec state runner wrong=()
	while IFS=$'\t' read -r spec state; do
		runner="$(registry_runner "$spec")"
		if [ "$state" = "unwired" ] && [ "$runner" != "unwired" ]; then
			wrong+=("$spec: registry says '$runner' but no project testMatch claims it — it runs NOWHERE, not even under \`make acceptance-test\`")
		fi
		if [ "$state" = "wired" ] && [ "$runner" = "unwired" ]; then
			wrong+=("$spec: registry says 'unwired' but a project testMatch claims it — update the row to suite-only, make:<target> or ci:<stage>")
		fi
	done < <(printf '%s\n' "$classified")

	[ "${#wrong[@]}" -eq 0 ] || {
		printf '%s\n' "${wrong[@]}"
		echo
		echo "playwright does not warn when no project claims a spec; it just"
		echo "reports a smaller total. $pw_config decides, this asserts it."
		return 1
	}
}

@test "every ci: row names a stage that really runs that spec" {
	local spec runner stage command missing=()
	while IFS= read -r spec; do
		runner="$(registry_runner "$spec")"
		case "$runner" in ci:*) ;; *) continue ;; esac
		stage="${runner#ci:}"
		command="$(stage_command "$stage")"
		if [ -z "$command" ]; then
			missing+=("$spec: no run_stage in vm-pipeline.sh writes a ${stage}-* report")
		elif [[ "$command" != *"$spec"* ]]; then
			missing+=("$spec: stage ${stage} exists but its command does not run it")
		fi
	done < <(registry_specs)

	[ "${#missing[@]}" -eq 0 ] || {
		printf '%s\n' "${missing[@]}"
		echo
		echo "a registry row claiming CI coverage that CI does not provide is"
		echo "worse than no row: it reads as a guard while guarding nothing."
		return 1
	}
}

@test "every spec a CI stage runs is registered as ci:" {
	# The reverse direction. Without it, wiring a spec into a stage and
	# forgetting the registry leaves the row saying suite-only — and the next
	# reader trusts the registry over the pipeline.
	local spec runner wrong=()
	while IFS= read -r spec; do
		runner="$(registry_runner "$spec")"
		case "$runner" in
			ci:*) ;;
			"") wrong+=("$spec: run by a CI stage but absent from the registry") ;;
			*)  wrong+=("$spec: run by a CI stage but registered as '$runner'") ;;
		esac
	done < <(pipeline_specs)

	[ "${#wrong[@]}" -eq 0 ] || {
		printf '%s\n' "${wrong[@]}"
		return 1
	}
}

@test "every make: row names a target whose recipe runs that spec" {
	local spec runner target recipe wrong=()
	while IFS= read -r spec; do
		runner="$(registry_runner "$spec")"
		case "$runner" in make:*) ;; *) continue ;; esac
		target="${runner#make:}"
		recipe="$(make_recipe "$target")"
		if [ -z "$recipe" ]; then
			wrong+=("$spec: Makefile has no target '$target' (or it has an empty recipe)")
		elif [[ "$recipe" != *"$spec"* ]]; then
			wrong+=("$spec: target '$target' exists but its recipe does not run it")
		fi
	done < <(registry_specs)

	[ "${#wrong[@]}" -eq 0 ] || {
		printf '%s\n' "${wrong[@]}"
		return 1
	}
}
