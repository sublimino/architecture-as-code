#!/usr/bin/env bats
#
# SLSI-OSD-5. Guards the boundary between the NETWORK-side dependency install
# and the OFFLINE-side assertion leg.
#
# WHAT THIS PINS, AND WHY IT IS NOT A TIDINESS TEST
# -------------------------------------------------
# `make test-all-offline` was red in every linked git worktree because the leg
# reached `bun install --frozen-lockfile` with no node_modules present (a linked
# worktree does not inherit the main checkout's untracked dependency tree). The
# fix moves that install OUT of the leg and into `make offline-deps`, an ordered
# prerequisite, so the install happens while the network is available and the
# leg that follows asserts offline behaviour.
#
# That fix is trivially reversible by a later well-meaning edit: dropping a
# `bun install` back into the leg's recipe makes the leg pass again on a cold
# tree while silently destroying the only thing the word "offline" was carrying.
# The result LOOKS better than the correct arrangement -- one target instead of
# two, green either way -- which is exactly why a comment is not enough and this
# file exists.
#
# Owned by `make test-offline-install-boundary`, which the offline leg's static
# section runs.

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	MAKEFILE="${REPO_ROOT}/Makefile"
	DEPS_SCRIPT="${REPO_ROOT}/scripts/offline-deps.sh"
	# Any line that resolves or fetches dependencies. yarn and pnpm are listed
	# even though this repo uses neither: the assertion is "no install in the
	# offline leg", not "no bun install in the offline leg", and a future edit
	# that reached for a different package manager must fail here too.
	INSTALL_PATTERN='bun install|bun add|npm install|npm ci|npm i |yarn install|yarn add|pnpm install|pnpm add'
}

# Extract a target's recipe: the TAB-indented lines following its rule line, up
# to the first line that is neither TAB-indented nor empty.
#
# awk rather than sed -n '/a/,/b/p' because the terminator is "a line that does
# not start with TAB", which a sed address range cannot express without also
# consuming the blank lines inside a recipe.
recipe_of() {
	awk -v target="$1" '
		$0 ~ "^" target ":" { inrecipe = 1; next }
		inrecipe && /^\t/   { print; next }
		inrecipe && /^$/    { next }
		inrecipe            { exit }
	' "${MAKEFILE}"
}

# The declared prerequisites on a target's rule line, excluding the comment.
prereqs_of() {
	awk -v target="$1" '
		$0 ~ "^" target ":" {
			sub("^" target ":", "")
			sub(/##.*$/, "")
			print
			exit
		}
	' "${MAKEFILE}"
}

@test "the recipe extractor is not vacuous: it finds the offline leg's own stage markers" {
	# Without this, every assertion below would pass against an empty string --
	# the failure mode that makes a structural guard worthless.
	run recipe_of test-all-offline
	[ "$status" -eq 0 ]
	[ -n "$output" ]
	echo "$output" | grep -qF '[Offline 1/5]'
	echo "$output" | grep -qF '[Offline 5/5]'
	[ "$(echo "$output" | wc -l)" -gt 40 ]
}

@test "offline-deps is a declared prerequisite of test-all-offline" {
	run prereqs_of test-all-offline
	[ "$status" -eq 0 ]
	# Word-boundary match: a prerequisite named offline-deps-something must not
	# satisfy this.
	echo "$output" | grep -qE '(^| )offline-deps( |$)'
}

@test "offline-deps is a declared prerequisite of test-dashboard-weave" {
	# test-dashboard-weave is reached by the offline leg via a sub-make, which
	# re-evaluates prerequisites in a fresh make process, and is also run
	# standalone. It therefore needs the prerequisite in its own right.
	run prereqs_of test-dashboard-weave
	[ "$status" -eq 0 ]
	echo "$output" | grep -qE '(^| )offline-deps( |$)'
}

@test "the test-all-offline recipe contains no dependency install" {
	run recipe_of test-all-offline
	[ -n "$output" ]
	if echo "$output" | grep -nE "${INSTALL_PATTERN}"; then
		echo "An install line is present in the test-all-offline recipe." >&2
		echo "The install belongs in 'make offline-deps', which is an ordered" >&2
		echo "prerequisite of this leg. A leg that installs over the network" >&2
		echo "asserts nothing about offline behaviour." >&2
		false
	fi
}

@test "the test-dashboard-weave recipe contains no dependency install" {
	run recipe_of test-dashboard-weave
	[ -n "$output" ]
	! echo "$output" | grep -qE "${INSTALL_PATTERN}"
}

@test "every bun workspace the offline leg enters is declared in offline-deps.sh" {
	# The leg's coverage must be derived from the leg, not asserted by hand. Any
	# directory the recipe cds into to run bun, which carries a bun.lock, must be
	# on the declared install list -- otherwise a new workspace added to the leg
	# is red on a cold tree and nothing says why.
	local declared dir
	declared="$(bash "${DEPS_SCRIPT}" --list)"
	[ -n "${declared}" ]

	local recipe
	recipe="$(recipe_of test-all-offline)"
	[ -n "${recipe}" ]

	local missing=""
	while read -r dir; do
		[ -n "${dir}" ] || continue
		# No bun.lock means no dependency set to install (tools/harness-dash).
		[ -f "${REPO_ROOT}/${dir}/bun.lock" ] || continue
		grep -qxF "${dir}" <<< "${declared}" || missing="${missing}${dir} "
	done < <(echo "${recipe}" | grep -oE 'cd [^ ]+ && bun' | awk '{print $2}')

	if [ -n "${missing}" ]; then
		echo "Offline-leg bun workspace(s) with a bun.lock that offline-deps.sh does not install:" >&2
		echo "  ${missing}" >&2
		false
	fi
}

@test "the offline-deps recipe uses no recursive make, so make -n cannot build" {
	# A '\$(MAKE)' line inside a recipe is executed even under 'make -n' -- make
	# passes -n down but still runs the sub-make. This repo has already been bitten
	# by exactly that (a dry run that really built). The install target must stay
	# flat so that 'make -n' prints it and nothing more.
	run recipe_of offline-deps
	[ -n "$output" ]
	! echo "$output" | grep -qF '$(MAKE)'
	! echo "$output" | grep -qE '(^|[^a-zA-Z-])make( |$)'
}

@test "make -n offline-deps prints the install without performing it" {
	# Proven by observation, not by reading the recipe: run the dry run against a
	# scratch workspace whose node_modules is absent and assert it is still
	# absent afterwards.
	local scratch
	scratch="$(mktemp -d "${BATS_TMPDIR}/offline-deps-dryrun.XXXXXX")"
	run make -C "${REPO_ROOT}" -n offline-deps
	[ "$status" -eq 0 ]
	echo "$output" | grep -qF 'scripts/offline-deps.sh'
	# A dry run that executed would have printed bun's install summary.
	! echo "$output" | grep -qE 'packages installed|bun install v'
	rmdir "${scratch}"
}

@test "offline-deps.sh with NO arguments installs and reports every workspace satisfied" {
	# The production invocation. 'make offline-deps' passes no flags, so the
	# bare call is the one case that must work; a sweep over --check/--list/--help
	# alone would miss a broken no-argument path entirely.
	run bash "${DEPS_SCRIPT}"
	[ "$status" -eq 0 ]
	echo "$output" | grep -qE 'offline bun workspaces satisfied'
}

@test "offline-deps.sh --check reports satisfied for every declared workspace" {
	run bash "${DEPS_SCRIPT}" --check
	[ "$status" -eq 0 ]
	! echo "$output" | grep -q 'UNSATISFIED'
	[ "$(echo "$output" | grep -c '^satisfied')" -eq "$(bash "${DEPS_SCRIPT}" --list | wc -l)" ]
}

@test "offline-deps.sh rejects an unknown option with a usage message" {
	run bash "${DEPS_SCRIPT}" --reinstall-everything
	[ "$status" -ne 0 ]
	echo "$output" | grep -qF 'unknown option'
	echo "$output" | grep -qF 'usage:'
}

@test "offline-deps.sh installs with bun only and never reaches for npm, npx, yarn or pnpm" {
	# Match an INVOCATION, not a mention. Both this script and this suite name
	# npm and npx in prose precisely in order to forbid them, so a bare
	# whole-word grep would make the prohibition unwritable -- the first
	# implementation did exactly that and failed on its own error message
	# ("never npm or npx"). The shape that matters is a command in command
	# position: start of line, or after a pipeline/list operator, or inside a
	# subshell or an if/then.
	local invocation='(^|[;&|(]|&&|\|\||\bthen\b|\belse\b|\bdo\b)[[:space:]]*(npm|npx|yarn|pnpm)[[:space:]]'
	run bash -c "grep -vE '^[[:space:]]*#' '${DEPS_SCRIPT}' | grep -nE '${invocation}'"
	[ "$status" -ne 0 ]
	grep -vE '^[[:space:]]*#' "${DEPS_SCRIPT}" | grep -qF 'bun install --frozen-lockfile'
}
