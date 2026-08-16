#!/usr/bin/env bash
#
# guard-falsification-proof.sh — prove this repository's guards can actually fail.
#
# ── Why this exists ─────────────────────────────────────────────────────────
#
# A check that cannot fail is worse than no check, because it reads as coverage.
# This repository has shipped that shape repeatedly, and every instance was
# found by accident rather than by a test:
#
#   * a registry guard whose exclusion-list reader shelled out to
#     `make -f - include Makefile`, which re-ran the default target instead of
#     printing the variable. The list parsed empty; two tests passed vacuously.
#   * the same guard's `-not -path '*/.worktrees/*'` filter, which matched the
#     ENTIRE TREE when run from a worktree. Correct in the main checkout,
#     silently examining nothing everywhere agents actually work.
#   * a CI-wiring assertion that grepped the whole pipeline file for a script
#     name. The stage's own COMMENT contained it, so deleting the real
#     invocation left the test green.
#   * scripts/check-flux-substitution.sh, which printed "no unsubstituted
#     tokens" against no cluster at all.
#   * `patch_py` in the audit proof, which asserted its anchors and never
#     checked python's exit code. A stale anchor produced a false
#     "all twelve guards are decoration".
#
# Five, in guards written by people already hunting this exact bug. The
# assumption here is that the rest of the estate is no better.
#
# ── What this proves that the existing suites do not ────────────────────────
#
# Two falsification harnesses already exist and this one is modelled on them:
# d2-signalloom/test/audit-guard-reintroduction-proof.sh (12 cases) and
# d2-signalloom/test/seam-guard-mutation-proof.sh (11 cases).
#
# Many guards in this estate ALREADY falsify themselves — ci-build-parity.bats
# and rbac-subject-resolution.bats build fixture repos, inject drift, and assert
# a non-zero exit. Those fixture tests are real evidence, and they are not what
# this harness re-tests.
#
# The untested half is the REAL-TREE assertion. "RBAC every binding in this
# repository resolves", "no cosign sign call site signs by tag", "no UNDECLARED
# proxy location drops Authorization while accepting mutation" — each of those
# runs the checker against the actual repository and has been green since the
# day it was written. A fixture test proves the CHECKER can go red. It proves
# nothing about whether the real-tree assertion is still WIRED to the real tree.
# That is precisely the check-flux-substitution.sh shape: a correct checker,
# pointed at nothing, reporting success.
#
# So every case below mutates the REAL FILE the real-tree assertion reads, and
# requires that assertion to go red.
#
# ── Verdicts: never two, and as it turned out never three ───────────────────
#
# The defect that produced a false "all twelve audit guards are decoration" was
# a two-outcome verdict: the harness could not tell "the guard ran and stayed
# quiet" from "the guard never ran". Those are different answers and they do not
# share an exit path here.
#
#   FIRED         the guard went red, and its output matched the expected
#                 signature. The check is live for this defect.
#   BLIND SPOT    the guard stayed green on the injected defect, but went RED on
#                 the POSITIVE CONTROL — a blunter form of the same defect. The
#                 guard works and has a specific gap. FINDING. Widen the check.
#   DECORATION    the guard stayed green on the defect AND on the control. It
#                 does not fire. FINDING. Rewrite the check.
#   UNCLASSIFIED  the guard stayed green and no control is registered, so blind
#                 spot and decoration were not told apart. FINDING, but the
#                 finding is "nobody has measured this yet" — never quoted as
#                 evidence that a guard is dead.
#   UNKNOWN       the harness could not run the case. Never counted as either a
#                 pass or a finding.
#
# The third and fourth verdicts were added because the first real run of this
# file got it wrong. It printed "GUARD DID NOT FIRE — THIS CHECK IS DECORATION"
# for two guards. Both statements underneath that headline were true; the
# headline was false. Re-tested with a blunter mutation, both went red. One
# mutation can only ever establish "this guard did not catch THIS ONE THING", and
# the leap from there to "this guard catches nothing" is an inference — the
# identical over-reach that produced the false "all twelve audit guards are
# decoration" this harness was built in response to. The control turns the
# inference back into a measurement.
#
# UNKNOWN covers: a baseline that was not green; a --filter that selected ZERO
# tests; a mutation that did not change the file; a guard that went red for a
# reason other than the injected defect; a tree that did not recover on restore;
# and a positive control that could not be applied, because a finding that cannot
# be classified must not be filed as though it had been.
#
# ── On `bats --filter` selecting nothing ────────────────────────────────────
#
# Measured against bats 1.13.0 in this tree:
#
#     $ bats --tap --filter 'THIS_MATCHES_NOTHING_XYZ' test/kind-config-heredoc.bats
#     1..0
#     run-exit=0
#
# A filter that matches no test exits 0. A typo in this file's registry would
# therefore produce a green baseline, a green mutated run, and a report reading
# "GUARD DID NOT FIRE — this check is decoration" for every affected case, with
# nothing whatever wrong with the guard. Each case asserts `bats --count` is
# non-zero before it believes anything.
#
# ── Restore ─────────────────────────────────────────────────────────────────
#
# Never `git checkout -- <path>`. That reverts the operator's own uncommitted
# work, and it has already happened in this repository: the audit proof's
# restore reverted an in-progress edit to a tracked test file, and the case then
# ran against the OLD guard and reported "did not fire" — a harness bug that
# reads exactly like a guard defect.
#
# Files are snapshotted byte-for-byte before mutation and written back from that
# snapshot. Files that did not exist are recorded as absent and deleted on
# restore. An EXIT trap restores on every path including SIGINT, and
# `--self-test` proves the trap works by killing a run mid-mutation and checking
# the file came back.
#
# ── Usage ───────────────────────────────────────────────────────────────────
#
#   test/guard-falsification-proof.sh              run every registered case
#   test/guard-falsification-proof.sh --list       print the registry and exit
#   test/guard-falsification-proof.sh --only RBAC  run cases whose id matches
#   test/guard-falsification-proof.sh --self-test  prove THIS harness can fail
#
# Requires: bats, python3, git, yq. No cluster, no database, no network.
# The harness performs READS ONLY against Kubernetes — it never mutates a
# cluster, and no registered case invokes kubectl.

set -eo pipefail   # deliberately NOT -u: the shell snapshot's grep wrapper
                   # references $ZSH_VERSION unguarded, and nounset makes every
                   # grep call in this script fatal.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SNAPSHOT_DIR="$(mktemp -d)"
FIRED=0
NOT_FIRED=0        # total findings = BLIND + DECOR + UNCLASSIFIED
BLIND=0
DECOR=0
UNCLASSIFIED=0
UNKNOWN=0
DIRTY_TREE=0
declare -a FINDINGS=()
declare -a UNKNOWNS=()

# ── Snapshot and restore ────────────────────────────────────────────────────
#
# Parallel arrays rather than an associative array keyed on path, because the
# same file may legitimately be mutated by more than one case and the FIRST
# snapshot is the one to keep.
declare -a SNAP_PATHS=()
declare -a SNAP_KEYS=()

snapshot() {
	local path="$1" key
	local p
	for p in "${SNAP_PATHS[@]}"; do
		[ "$p" = "$path" ] && return 0   # already held; keep the earliest bytes
	done
	key="$(printf '%s' "$path" | md5sum | cut -d' ' -f1)"
	SNAP_PATHS+=("$path")
	SNAP_KEYS+=("$key")
	if [ -e "$path" ]; then
		cp -p "$path" "${SNAPSHOT_DIR}/${key}.bytes"
	else
		# Record absence explicitly. A case that CREATES a file (a new spec, a
		# new bats suite) restores by deletion, and conflating that with "no
		# snapshot taken" would leave the file behind.
		: >"${SNAPSHOT_DIR}/${key}.absent"
	fi
}

restore_all() {
	local i key path
	for i in "${!SNAP_PATHS[@]}"; do
		path="${SNAP_PATHS[$i]}"
		key="${SNAP_KEYS[$i]}"
		if [ -f "${SNAPSHOT_DIR}/${key}.absent" ]; then
			rm -f "$path"
		elif [ -f "${SNAPSHOT_DIR}/${key}.bytes" ]; then
			cp -p "${SNAPSHOT_DIR}/${key}.bytes" "$path"
		fi
	done
}

cleanup() {
	local rc=$?
	restore_all
	rm -rf "$SNAPSHOT_DIR"
	# An EXIT trap whose last command fails REPLACES the script's exit status
	# under errexit. That defect has shipped here before: eight green stages
	# still reported failure because a trap's final command returned non-zero.
	# The explicit return preserves whatever the script actually decided.
	return $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ── Mutation helpers ────────────────────────────────────────────────────────
#
# Every one of these ASSERTS ITS ANCHOR and exits non-zero when the anchor is
# absent. A sed or python patch whose pattern misses is a no-op that prints
# success, and the case then reports "guard did not fire" for a reason that has
# nothing to do with the guard. That exact false alarm has already shipped in
# this repository. Content travels through the environment, not through nested
# shell quoting, so an anchor containing quotes, backslashes or newlines cannot
# be silently mangled on the way in.

py_sub() {   # file, old, new  — replace FIRST occurrence, assert old present
	MUT_FILE="$1" MUT_OLD="$2" MUT_NEW="$3" python3 - <<-'PY'
		import os, sys, pathlib
		p = pathlib.Path(os.environ["MUT_FILE"])
		if not p.exists():
		    sys.stderr.write("target does not exist: %s\n" % p); sys.exit(3)
		s = p.read_text()
		old, new = os.environ["MUT_OLD"], os.environ["MUT_NEW"]
		if old not in s:
		    sys.stderr.write("ANCHOR NOT FOUND in %s: %r\n" % (p, old[:160])); sys.exit(3)
		p.write_text(s.replace(old, new, 1))
	PY
}

py_insert_before() {   # file, anchor, text — insert text before FIRST anchor
	MUT_FILE="$1" MUT_OLD="$2" MUT_NEW="$3" python3 - <<-'PY'
		import os, sys, pathlib
		p = pathlib.Path(os.environ["MUT_FILE"])
		if not p.exists():
		    sys.stderr.write("target does not exist: %s\n" % p); sys.exit(3)
		s = p.read_text()
		anchor, text = os.environ["MUT_OLD"], os.environ["MUT_NEW"]
		if anchor not in s:
		    sys.stderr.write("ANCHOR NOT FOUND in %s: %r\n" % (p, anchor[:160])); sys.exit(3)
		p.write_text(s.replace(anchor, text + anchor, 1))
	PY
}

py_append() {   # file, text — append; asserts the file exists
	MUT_FILE="$1" MUT_NEW="$2" python3 - <<-'PY'
		import os, sys, pathlib
		p = pathlib.Path(os.environ["MUT_FILE"])
		if not p.exists():
		    sys.stderr.write("target does not exist: %s\n" % p); sys.exit(3)
		p.write_text(p.read_text() + os.environ["MUT_NEW"])
	PY
}

py_create() {   # file, text — create a NEW file; asserts it did not exist
	MUT_FILE="$1" MUT_NEW="$2" python3 - <<-'PY'
		import os, sys, pathlib
		p = pathlib.Path(os.environ["MUT_FILE"])
		if p.exists():
		    sys.stderr.write("expected %s to be absent, but it exists\n" % p); sys.exit(3)
		p.parent.mkdir(parents=True, exist_ok=True)
		p.write_text(os.environ["MUT_NEW"])
	PY
}

# ── Guard invocation ────────────────────────────────────────────────────────

GUARD_STATUS=0
GUARD_OUTPUT=""

# show <text> <grep-ere or ""> <max-lines> <prefix>
#
# Display-only output, and NEVER fatal. This function exists because the harness
# shipped the exact defect it hunts, and only running it found that out.
#
# `set -o pipefail` makes a pipeline return the first non-zero status in it. A
# `grep` that MATCHES NOTHING returns 1. Under `set -e` that combination kills
# the script. Run 2 of this harness died on
#
#     printf '%s\n' "$ctrl_output" | grep -E '^not ok|^# ' | head -3 | sed ...
#
# because the last registered case was an `sh`-kind guard whose output is prose
# and contains no TAP lines at all, so the grep selected nothing. The script
# exited between the final verdict and the summary block. All 21 verdicts had
# been computed and NOT ONE was printed — and the exit status was 1, which is
# this harness's code for "a guard did not fire". A silent death that renders as
# an ordinary finding is precisely the failure mode being catalogued here, and it
# stayed invisible for four cases in run 1 only because bats output always
# happened to contain a matching line.
#
# `head` is the second trigger: it closes the pipe once it has its lines, and the
# upstream `printf` can then take SIGPIPE and report non-zero for the same
# reason. Both are cosmetic; neither may ever decide a verdict.
# No sed, no grep, no pipeline — bash builtins only.
#
# The first version of this function was `... | grep -E "$pat" | head -n | sed
# "s|^|$prefix|"`, and it printed NOTHING for every finding in the run that
# introduced it:
#
#     *** GUARD DID NOT FIRE ***
#         the defect was present and the guard exited 0. Observed output:
#     sed: -e expression #1, char 13: unknown option to `s'
#
# The prefix for indented evidence is "      | ". It contains the `|` that was
# being used as the s/// delimiter, so sed rejected the expression on every call.
# The `|| true` added to stop pipefail killing the run then swallowed the failure
# status too, leaving four findings filed with their evidence silently missing —
# and the brief for this work says a guard may be reported ONLY with its observed
# output quoted. A cosmetic helper had quietly deleted the evidence while every
# verdict above it stayed correct, so the report still read as complete.
#
# Two lessons, both already in this file's own catalogue: a wrapper that makes
# failures non-fatal must not also make them invisible, and a formatter whose
# argument is interpolated into a mini-language (sed, awk, a regex) breaks on the
# first argument containing that language's metacharacters. Builtins take no
# delimiter and cannot be injected into.
show() {
	local text="$1" pat="$2" n="$3" prefix="$4" line count=0
	while IFS= read -r line; do
		if [ "$count" -ge "$n" ]; then break; fi
		# bash's own ERE engine: no subprocess, so no pipefail interaction and no
		# SIGPIPE. `head` closing a pipe early was the other way this died.
		if [ -n "$pat" ] && ! [[ "$line" =~ $pat ]]; then continue; fi
		printf '%s%s\n' "$prefix" "$line"
		count=$((count + 1))
	done <<< "$text"
	return 0
}

# run_guard <kind> <file> <filter>
#   kind=bats  file is a .bats suite, filter is a --filter regex ("" = whole file)
#   kind=sh    file is a script, filter is ignored
run_guard() {
	local kind="$1" file="$2" filter="$3"
	GUARD_OUTPUT=""
	GUARD_STATUS=0
	case "$kind" in
		bats)
			if [ -n "$filter" ]; then
				GUARD_OUTPUT="$(timeout 300 bats --tap --filter "$filter" "$file" 2>&1)" || GUARD_STATUS=$?
			else
				GUARD_OUTPUT="$(timeout 300 bats --tap "$file" 2>&1)" || GUARD_STATUS=$?
			fi
			;;
		sh)
			GUARD_OUTPUT="$(timeout 300 bash "$file" 2>&1)" || GUARD_STATUS=$?
			;;
		*)
			GUARD_OUTPUT="unknown guard kind: $kind"
			GUARD_STATUS=99
			;;
	esac
	return 0
}

# selected_test_count <kind> <file> <filter>
#
# The mechanism assertion. `bats --filter` matching nothing exits 0 with "1..0",
# so a stale test name in the registry below is indistinguishable from a guard
# that works — until this returns 0 and the case is reported UNKNOWN.
selected_test_count() {
	local kind="$1" file="$2" filter="$3" n
	case "$kind" in
		bats)
			if [ -n "$filter" ]; then
				n="$(timeout 120 bats --count --filter "$filter" "$file" 2>/dev/null)" || n=0
			else
				n="$(timeout 120 bats --count "$file" 2>/dev/null)" || n=0
			fi
			;;
		sh)
			# A script is one unit with no filter, so the bats zero-selection trap
			# cannot apply. State the limitation plainly rather than implying a
			# check that is not happening: there is no general way from out here to
			# assert that a CHECKER'S OWN SCAN found anything. That is exactly the
			# `-not -path '*/.worktrees/*'` defect — a checker examining an empty
			# set and reporting success — and only the checker can assert its own
			# mechanism. What is checkable here is that the file exists and is
			# readable, so a renamed or deleted script is UNKNOWN, never a pass.
			if [ -r "$file" ]; then n=1; else n=0; fi
			;;
		*)  n=0 ;;
	esac
	printf '%s' "${n:-0}"
}

# ── The registry ────────────────────────────────────────────────────────────
#
# Parallel arrays: id, category, guard kind, guard file, test filter, target
# file, expected failure signature (a grep -E pattern), mutation function name.
#
# The mutation is a bash FUNCTION rather than a string passed to eval. A string
# carrying nginx config, YAML and Makefile recipes through two layers of shell
# quoting is a no-op waiting to happen, and a no-op mutation is exactly the
# false alarm this harness exists to avoid.

declare -a C_ID=() C_CAT=() C_KIND=() C_GUARD=() C_FILTER=() C_TARGET=() C_SIG=() C_MUT=()
declare -a C_CTRL=()

register() {
	C_ID+=("$1"); C_CAT+=("$2"); C_KIND+=("$3"); C_GUARD+=("$4")
	C_FILTER+=("$5"); C_TARGET+=("$6"); C_SIG+=("$7"); C_MUT+=("$8")
	C_CTRL+=("")   # no control mutation unless register_control follows
}

# register_control <mutation-fn>
#
# Attaches a POSITIVE CONTROL to the case just registered: a blunt, unambiguous
# version of the same defect that the guard is definitely supposed to catch.
#
# Why this exists — and it is the single most important thing this harness
# learned from its own first real run. That run reported two guards as
# "DECORATION", in those words. Both reports were WRONG, and wrong in the
# direction that does the most damage: a true statement ("the guard stayed green
# with this defect present") printed under a false headline ("this check is
# decoration"). Re-tested with a blunter mutation, both guards went red:
#
#   SIGN-BY-TAG          subtle: sign a tag ALONGSIDE the existing digest -> GREEN
#                        control: sign a tag INSTEAD of the digest        -> RED
#   CI-BUILD-PARITY-REAL subtle: `true # make <step>` (trailing comment)   -> GREEN
#                        control: delete the invocation line entirely      -> RED
#
# Neither guard is decoration. Each is a live guard with a specific blind spot,
# which is a real finding and a completely different repair. Calling a working
# guard decoration gets it rewritten; naming the blind spot gets it fixed.
#
# One mutation can only ever prove "this guard did not catch THIS". Concluding
# "this guard catches NOTHING" from that is an inference, and the brief for this
# work forbids exactly that inference. The control is what turns the inference
# into a measurement.
register_control() {
	if [ "${#C_ID[@]}" -eq 0 ]; then
		printf 'FATAL: register_control called before any register\n' >&2
		exit 2
	fi
	C_CTRL[$(( ${#C_ID[@]} - 1 ))]="$1"
}

# ── RBAC ────────────────────────────────────────────────────────────────────

FLEET_TENANT="d2-osramp-fleet/tenants/local/signalloom.yaml"

mut_rbac_dangling_sa() {
	# A RoleBinding naming a ServiceAccount nobody declares is legal, is stored
	# by the API server, is marked Ready by Flux, and grants NOTHING. In this
	# estate the only symptom is a workload getting fewer results than it should.
	#
	# The SUBJECT is renamed, never the declaration. Renaming both — which a bare
	# `sed s/spire-agent/…/` does, since the declaration and the subject carry the
	# same name — leaves the manifest perfectly consistent and injects no drift at
	# all. rbac-subject-resolution.bats records having made exactly that mistake
	# and reporting its own checker as broken when it was correct.
	py_sub "$FLEET_TENANT" \
		'        - kind: ServiceAccount
          name: spire-agent
          namespace: inf-bao' \
		'        - kind: ServiceAccount
          name: spire-agent-typo
          namespace: inf-bao'
}
register RBAC-DANGLING-SA rbac bats test/rbac-subject-resolution.bats \
	'every binding in this repository resolves' "$FLEET_TENANT" \
	'confers no permissions|not ok' mut_rbac_dangling_sa

mut_rbac_discovery_grant_removed() {
	# Adds a namespace to the proxy's discovery list without the matching
	# Role/RoleBinding. The proxy degrades gracefully on a 403 — it logs, keeps
	# the namespaces that work, and /agents simply returns fewer agents than the
	# cluster holds. Same silent-shortfall shape as a `kind load` that exits 0
	# having transferred nothing.
	py_sub "d2-signalloom/apps/fake-integration-proxy/server.py" \
		'DEFAULT_AGENT_DISCOVERY_NAMESPACES = ("fe-signalloom-agents", "fe-signalloom")' \
		'DEFAULT_AGENT_DISCOVERY_NAMESPACES = ("fe-signalloom-agents", "fe-signalloom", "ns-with-no-grant-at-all")'
}
register RBAC-DISCOVERY-UNGRANTED rbac bats d2-signalloom/test/agent-discovery-rbac.bats \
	'every discovery namespace grants the proxy SA a pod-reading Role' \
	"d2-signalloom/apps/fake-integration-proxy/server.py" \
	'not ok' mut_rbac_discovery_grant_removed

# ── Supply chain and signing ────────────────────────────────────────────────

mut_cosign_referrers_mode() {
	# The no-op flag whose presence in one call site and absence in another sent
	# a whole investigation after the storage format instead of the key.
	py_sub "scripts/push-local.sh" \
		'COSIGN_PASSWORD="" cosign sign --yes' \
		'COSIGN_PASSWORD="" cosign sign --registry-referrers-mode=oci-1-1 --yes'
}
register SIGN-REFERRERS-MODE supplychain bats test/cosign-signing-consistency.bats \
	'no cosign sign call site passes --registry-referrers-mode' \
	"scripts/push-local.sh" 'registry-referrers-mode|not ok' mut_cosign_referrers_mode

mut_cosign_sign_by_tag() {
	# Signing a tag races a concurrent re-push: the tag can move between the push
	# and the sign, leaving the signature on a digest nobody serves. This is the
	# flux-system stall's neighbour — a signature that exists but not where the
	# consumer looks.
	py_sub "scripts/admission-demo.sh" \
		'COSIGN_PASSWORD="" cosign sign --yes --key "${KEYS_DIR}/cosign.key" \' \
		'COSIGN_PASSWORD="" cosign sign --yes --key "${KEYS_DIR}/cosign.key" "${REGISTRY}/demo:latest" \'
}
register SIGN-BY-TAG supplychain bats test/cosign-signing-consistency.bats \
	'every cosign sign call site signs by digest, never by tag' \
	"scripts/admission-demo.sh" 'not a digest reference|not ok' mut_cosign_sign_by_tag

ctl_cosign_pure_tag() {
	# The control: sign a tag INSTEAD of the digest, rather than alongside it.
	# Measured — this goes red, which is what proves the guard above is live and
	# that the green on the subtle mutation is a blind spot rather than decoration.
	py_sub "scripts/admission-demo.sh" \
		'"${REGISTRY_HOST}/acme/images/listener@${SIGNED_DIGEST}"' \
		'"${REGISTRY_HOST}/acme/images/listener:signed"'
}
register_control ctl_cosign_pure_tag

# ── Authorization boundary ──────────────────────────────────────────────────

NGINX_CONF="d2-signalloom/apps/dashboard-signalloom/nginx.conf"

mut_nginx_unauth_mutable_location() {
	# A NEW proxy location that neither forwards Authorization nor restricts
	# methods. This is byte-for-byte the shape of the /supercred-api/ hole: any
	# browser that could load the dashboard could POST through it, borrowing the
	# proxy's ServiceAccount identity with no credential of its own.
	py_insert_before "$NGINX_CONF" \
		'  location /supercred-api/' \
		'  location /new-unguarded-api/ {
    proxy_pass http://afm-platform.fe-k8s-afm.svc.cluster.local:8000/;
  }

'
}
register AUTHZ-NEW-UNGUARDED-LOCATION authz bats \
	d2-signalloom/test/nginx-unauthenticated-locations-are-readonly.bats \
	'no UNDECLARED proxy location drops Authorization while accepting mutation' \
	"$NGINX_CONF" 'unauthenticated proxy location|not ok' mut_nginx_unauth_mutable_location

mut_nginx_remove_limit_except() {
	# Deletes the three lines that closed unauthenticated pod-stun. Before this
	# guard existed, `limit_except` appeared in exactly one file in the whole
	# repository and in no test — so removing it reopened the hole while every
	# suite stayed green.
	py_sub "$NGINX_CONF" 'limit_except GET HEAD' 'limit_except GET HEAD POST PUT DELETE PATCH'
}
register AUTHZ-SUPERCRED-MUTATION-REOPENED authz bats \
	d2-signalloom/test/nginx-unauthenticated-locations-are-readonly.bats \
	'the /supercred-api/ prefix specifically is still mutation-denied' \
	"$NGINX_CONF" 'not ok' mut_nginx_remove_limit_except

mut_route_collision() {
	# An nginx proxy prefix that shadows a client-side SPA route. The server
	# answers first, the route becomes unreachable, and nothing in the SPA knows.
	py_insert_before "$NGINX_CONF" \
		'  location /supercred-api/' \
		'  location /agents {
    proxy_pass http://afm-platform.fe-k8s-afm.svc.cluster.local:8000/;
  }

'
}
register AUTHZ-ROUTE-COLLISION authz bats \
	d2-signalloom/test/dashboard-route-collisions.bats \
	'no proxy prefix shadows a SPA route' \
	"$NGINX_CONF" 'not ok' mut_route_collision

# ── Key-path safety ─────────────────────────────────────────────────────────

mut_keys_dir_concat() {
	# Concatenating a prefix onto an already-absolute KEYS_DIR produces
	# /repo//home/andy/... — the regression audit-anchor-keys-path.bats was
	# written for. It fails as "key not found", which reads as an unsigned
	# artifact rather than as a path bug.
	py_append "Makefile" '
guard-falsification-probe: ## injected by guard-falsification-proof.sh
	@echo $(REPO_ROOT)/$(KEYS_DIR)/cosign.key
'
}
register KEYS-DIR-CONCAT keys bats test/keys-dir-path-safety.bats \
	'no Makefile line concatenates a prefix onto' \
	"Makefile" 'not ok' mut_keys_dir_concat

# ── CI honesty ──────────────────────────────────────────────────────────────

PIPELINE="scripts/ci/vm-pipeline.sh"
CONVERTER="scripts/ci/openreports-convert.sh"

mut_ci_orphan_structured_report() {
	# A structured report the pipeline writes and the converter does not map is
	# silently dropped from the OpenReports artifact. The stage runs, the tests
	# pass, and the results reach nobody.
	py_append "$PIPELINE" '
run_stage \
  "Injected orphan stage" \
  "stage9z-orphan.txt" \
  "cd ${WORK_DIR} && npx playwright test --junit-xml=${REPORT_DIR}/stage9z-orphan.xml"
'
}
register CI-ORPHAN-REPORT ci-honesty bats test/ci-report-integrity.bats \
	'every structured report the pipeline produces is mapped in the converter' \
	"$PIPELINE" 'not in the converter map|not ok' mut_ci_orphan_structured_report

mut_ci_stale_converter_entry() {
	# The mirror image: a converter map entry for a file no stage produces. It
	# reads as a stage that runs and never does, and it would silently "match"
	# if someone reintroduced the filename for something else entirely.
	py_sub "$CONVERTER" \
		"  { file: 'stage1-static.tap'" \
		"  { file: 'stage9z-deleted-long-ago.tap', parser: parseTap, source: 'ghost', category: 'meta' },
  { file: 'stage1-static.tap'"
}
register CI-STALE-CONVERTER-ENTRY ci-honesty bats test/ci-report-integrity.bats \
	'every converter map entry names a file the pipeline actually produces' \
	"$CONVERTER" 'no pipeline stage produces|not ok' mut_ci_stale_converter_entry

mut_ci_parser_format_mismatch() {
	# parseTap on a non-TAP file matches nothing and contributes ZERO rows while
	# the entry reads as configured. Worse than no entry, for exactly that reason.
	py_sub "$CONVERTER" \
		"{ file: 'stage1-static.tap',     parser: parseTap," \
		"{ file: 'stage1-static.tap',     parser: parseJunitXml,"
}
register CI-PARSER-MISMATCH ci-honesty bats test/ci-report-integrity.bats \
	'no converter entry uses parseTap on a non-TAP file' \
	"$CONVERTER" 'mismatched file/parser|not ok' mut_ci_parser_format_mismatch

mut_ci_relative_path_var() {
	# A CI path variable holding a relative value resolves against whatever cwd
	# the stage happens to have. The VM's cwd is not ours.
	py_sub "Makefile" 'GCP_CI_REPORT_DIR=$(abspath ci-reports-2)' 'GCP_CI_REPORT_DIR=ci-reports-2'
}
register CI-RELATIVE-PATH ci-honesty bats test/ci-path-anchoring.bats \
	'no CI path variable is assigned a relative value in the Makefile' \
	"Makefile" 'not ok' mut_ci_relative_path_var

mut_ci_installer_unpinned() {
	# `@latest` in an installer makes the CI toolchain a moving target: the same
	# commit produces different results on different days, and the bisect that
	# chases it finds nothing.
	py_sub "scripts/ci/install-ci-tools.sh" 'COSIGN_VERSION="3.0.6"' 'COSIGN_VERSION="latest"'
}
register CI-UNPINNED-VERSION ci-honesty bats test/ci-installer-privileges.bats \
	'pinned versions are literal, never latest or a branch' \
	"scripts/ci/install-ci-tools.sh" 'not ok' mut_ci_installer_unpinned

# ── Test-suite honesty (the guards that guard the guards) ───────────────────

mut_unregistered_bats_suite() {
	# A .bats suite no runner invokes. Thirty-three of sixty-eight suites and
	# roughly 640 assertions sat in that state in this repository, committed and
	# never executed — among them the suite four documents call "the enforcement
	# mechanism for nginx route collisions".
	py_create "test/zz-injected-orphan-suite.bats" '#!/usr/bin/env bats

@test "injected orphan suite that no runner invokes" {
	[ 1 -eq 1 ]
}
'
}
register META-UNREGISTERED-SUITE meta bats \
	d2-signalloom/test/bats-registry-coverage.bats \
	'every repo-root bats suite is invoked by the CI pipeline' \
	"test/zz-injected-orphan-suite.bats" 'not ok' mut_unregistered_bats_suite

mut_uninvoked_proof_script() {
	# The third shape of the same hole: a proof script under test/ that nothing
	# runs. audit-guard-reintroduction-proof.sh sat in exactly this state — the
	# only thing in the repository proving the audit guards work at all, invoked
	# by nothing, and invisible to the bats registry because it is not a .bats
	# file.
	py_create "test/zz-injected-orphan-proof.sh" '#!/usr/bin/env bash
# Injected by guard-falsification-proof.sh. No runner invokes this.
exit 0
'
}
register META-UNINVOKED-PROOF meta bats \
	d2-signalloom/test/bats-registry-coverage.bats \
	'every proof script under test/ is invoked by something' \
	"test/zz-injected-orphan-proof.sh" 'no runner invokes|not ok' mut_uninvoked_proof_script

COMMENT_ONLY_PROOF="test/zz-injected-comment-only-proof.sh"

mut_proof_mentioned_only_in_a_comment() {
	# The documented defect shape, aimed at the guard that enforces wiring.
	#
	# A CI-wiring assertion that greps a pipeline file for a script NAME has
	# already shipped broken here once: the stage's own comment contained the
	# name, so deleting the real invocation left the test green. This guard's
	# implementation is
	#
	#     grep -rl --include='*.sh' --include='Makefile' --exclude="$base" \
	#          -F "$base" "$root/scripts" "$root/Makefile" "$root/d2-signalloom"
	#
	# and its comment two lines above says "Search every runner, ignoring
	# comments". Nothing in that command ignores comments. The comment describes
	# a filter the code does not have — so this case injects an orphan proof
	# script whose name appears in the pipeline ONLY inside a comment, and asks
	# whether the guard notices that nothing runs it.
	snapshot "$PIPELINE"
	py_create "$COMMENT_ONLY_PROOF" '#!/usr/bin/env bash
# Injected by the falsification harness. Mentioned in a comment, run by nothing.
exit 0
'
	py_append "$PIPELINE" '
# Injected by the falsification harness: zz-injected-comment-only-proof.sh is
# named on this line and invoked on none. If the wiring guard treats this as
# coverage, a commented-out stage counts as a running stage.
'
}
register META-PROOF-COMMENT-ONLY meta bats \
	d2-signalloom/test/bats-registry-coverage.bats \
	'every proof script under test/ is invoked by something' \
	"$COMMENT_ONLY_PROOF" 'no runner invokes|not ok' mut_proof_mentioned_only_in_a_comment

ctl_proof_orphan_no_comment() {
	# Control: the identical orphan script, with no mention anywhere. Must go red.
	py_create "$COMMENT_ONLY_PROOF" '#!/usr/bin/env bash
# Injected by the falsification harness. Mentioned nowhere, run by nothing.
exit 0
'
}
register_control ctl_proof_orphan_no_comment

mut_unregistered_playwright_spec() {
	# A Playwright spec matching no project's testMatch is silently skipped —
	# exit 0, no warning. Four specs hid that way.
	py_create "test/acceptance/zz-injected-orphan.spec.ts" "import { test, expect } from '@playwright/test';

test('injected orphan spec with no registry row', async () => {
  expect(1).toBe(1);
});
"
}
register META-UNREGISTERED-SPEC meta bats test/acceptance-spec-coverage.bats \
	'every spec on disk has exactly one registry row' \
	"test/acceptance/zz-injected-orphan.spec.ts" 'not ok' mut_unregistered_playwright_spec

# The banned verb is ASSEMBLED, never spelled out, for the same reason
# no-exec-probes-in-tests.bats assembles it in its own `exec_verb()`: this file
# is a *.sh inside a test/ directory, so it is IN THAT GUARD'S SCAN SCOPE. A
# literal below makes this harness report itself, which it did on the first real
# run — the guard was red at baseline, the case was correctly recorded UNKNOWN,
# and the culprit was this file. Spelling it out would force this file onto the
# guard's allowlist, and a self-exemption is the one entry nobody would question.
exec_verb() { printf 'e%s' 'xec'; }

mut_exec_probe_reintroduced() {
	# A probe that runs INSIDE the container fails identically whether the
	# property holds or not, the moment the image is hardened. The original
	# instance PASSED while testing nothing — and it was the auth test.
	py_append "test/healthcheck.bats" "
@test \"injected $(exec_verb) probe with no allowlist entry\" {
	run kubectl -n inf-signalloom $(exec_verb) deployment/cardvault -- wget -q -O- http://localhost:8080/
	[ \"\$status\" -ne 0 ]
}
"
}
# The FILTER is assembled too, not just the mutation. The first real run of this
# harness recorded META-EXEC-PROBE as UNKNOWN — "guard was NOT GREEN on an
# unmutated tree" — and the guard's own output named the culprit:
#
#   # kubectl exec used as a probe in test file(s) with no allowlist entry:
#   # test/guard-falsification-proof.sh:567: 'no test file outside the allowlist
#   #                                         probes with kubectl exec' \
#
# The mutation had been carefully assembled via exec_verb() and the filter string
# three lines below it spelled the verb out in full, so this file reported itself
# and lost the case. Every literal in this file is in that guard's scan scope,
# registry strings included.
register META-EXEC-PROBE meta bats test/no-exec-probes-in-tests.bats \
	"no test file outside the allowlist probes with kubectl $(exec_verb)" \
	"test/healthcheck.bats" 'with no allowlist entry|not ok' mut_exec_probe_reintroduced

mut_exec_allowlist_count_drift() {
	# The allowlist pins a COUNT, not a path. Without that, an entry is a blanket
	# exemption and the next probe added to an already-listed file inherits the
	# pass — including one of exactly the shape the guard exists to ban.
	py_append "d2-signalloom/test/supercred-demo.bats" "
@test \"injected extra probe in an already-allowlisted file\" {
	run kubectl -n inf-signalloom $(exec_verb) deployment/openbao -- bao kv get secret/injected
	[ \"\$status\" -eq 0 ]
}
"
}
register META-ALLOWLIST-COUNT-DRIFT meta bats test/no-exec-probes-in-tests.bats \
	'every allowlisted file has exactly its recorded number of occurrences' \
	"d2-signalloom/test/supercred-demo.bats" 'no longer match|not ok' mut_exec_allowlist_count_drift

mut_ci_build_parity_drop() {
	# The real-tree half of ci-build-parity. A build step present in the Makefile
	# recipe and missing from the pipeline is how a workload reached a VM in
	# ImagePullBackOff and failed three stages forty minutes into a lane.
	py_sub "$PIPELINE" 'make demo-signalloom-supercred-images' 'true # make demo-signalloom-supercred-images'
}
register CI-BUILD-PARITY-REAL ci-honesty bats test/ci-build-parity.bats \
	"PARITY the repo's own pipeline builds everything demo-signalloom-up builds" \
	"$PIPELINE" 'MISSING|not ok' mut_ci_build_parity_drop

ctl_ci_build_parity_delete() {
	# The control: delete the invocation line outright, leaving the pipeline's
	# explanatory FULL-LINE comment about the same step in place.
	#
	# Measured — this goes RED. That is the whole point: check-ci-build-parity.sh
	# does strip full-line comments (`grep -vE '^[0-9]+:[[:space:]]*#'`), so a
	# surviving comment does NOT rescue a deleted step. The subtle mutation above
	# stays green only because a TRAILING comment on a live line survives that
	# filter and then `sed -E 's/.*make[[:space:]]+//'` lifts the step name back
	# out of it. Full-line comments handled, trailing comments not: a narrow,
	# specific, fixable gap — and emphatically not "the guard does nothing".
	MUT_FILE="$PIPELINE" python3 - <<-'PY'
		import os, sys, pathlib
		p = pathlib.Path(os.environ["MUT_FILE"])
		lines = p.read_text().splitlines(keepends=True)
		inv = [i for i, l in enumerate(lines)
		       if "demo-signalloom-supercred-images" in l and not l.lstrip().startswith("#")]
		if len(inv) != 1:
		    sys.stderr.write("expected exactly 1 live invocation line, found %d\n" % len(inv))
		    sys.exit(3)
		del lines[inv[0]]
		p.write_text("".join(lines))
	PY
}
register_control ctl_ci_build_parity_delete

# The same defect measured one layer down, through the `sh` guard kind rather
# than through the bats wrapper. This localises the blind spot: if the bats case
# above and this one both stay green on the trailing-comment mutation, the gap is
# in check-ci-build-parity.sh itself and not in how the suite calls it. It also
# exercises the harness's `sh` code path against a real guard — that path had no
# registered case at all until now, which in a tool about untested checks was an
# untested branch of the tool itself.
register CI-BUILD-PARITY-SCRIPT ci-honesty sh scripts/check-ci-build-parity.sh \
	'' "$PIPELINE" 'MISSING' mut_ci_build_parity_drop
register_control ctl_ci_build_parity_delete

# ── Kind cluster config safety ──────────────────────────────────────────────

mut_kind_command_substitution() {
	# The kind config heredoc is UNQUOTED, so its contents are live shell. A
	# command substitution there executes at cluster-create time with whatever
	# privileges the operator has.
	py_sub "scripts/create-kind-cluster.sh" 'kind: Cluster' 'kind: Cluster # $(id -un)'
}
register KIND-COMMAND-SUBSTITUTION supplychain bats test/kind-config-heredoc.bats \
	'no command substitution in the heredoc' \
	"scripts/create-kind-cluster.sh" 'not ok' mut_kind_command_substitution

# ── The engine ──────────────────────────────────────────────────────────────

record_unknown() {
	UNKNOWN=$((UNKNOWN + 1))
	UNKNOWNS+=("$1 — $2")
	printf '  UNKNOWN   %s\n' "$2"
}

prove() {
	local id="$1" cat="$2" kind="$3" guard="$4" filter="$5" target="$6" sig="$7" mut="$8" ctrl="${9:-}"

	printf '\n=== %-32s [%s]\n' "$id" "$cat"
	printf '    guard  : %s\n' "$guard"
	printf '    filter : %s\n' "${filter:-<whole suite>}"
	printf '    target : %s\n' "$target"

	# -- Phase 0: the guard file must exist. ---------------------------------
	if [ ! -f "$guard" ]; then
		record_unknown "$id" "guard file does not exist: $guard"
		return 0
	fi

	# -- Phase 1: the filter must select at least one test. ------------------
	# `bats --filter` matching nothing exits 0. Without this, a stale test name
	# in the registry reports every affected guard as decoration.
	local nsel
	nsel="$(selected_test_count "$kind" "$guard" "$filter")"
	if ! [ "$nsel" -ge 1 ] 2>/dev/null; then
		record_unknown "$id" "filter selected ZERO tests (bats exits 0 on an empty selection, so this would otherwise read as a guard that never fires)"
		return 0
	fi
	printf '    selects: %s test(s)\n' "$nsel"

	# -- Phase 2: green baseline. -------------------------------------------
	# Requiring a clean green baseline collapses every "could not run" cause into
	# one check: if the guard cannot pass on an unmodified tree, nothing below it
	# means anything, whatever the reason.
	run_guard "$kind" "$guard" "$filter"
	if [ "$GUARD_STATUS" -ne 0 ]; then
		record_unknown "$id" "guard was NOT GREEN on an unmutated tree (exit $GUARD_STATUS) — the mutated run below would prove nothing"
		show "$GUARD_OUTPUT" '^not ok|^# ' 5 '      '
		return 0
	fi

	# -- Phase 3: mutate, and prove the mutation landed. ---------------------
	snapshot "$target"
	local pre_sum post_sum
	pre_sum="$( [ -e "$target" ] && sha256sum "$target" | cut -d' ' -f1 || printf 'ABSENT' )"

	if ! "$mut"; then
		record_unknown "$id" "MUTATION FAILED TO APPLY (anchor missing) — this case tested nothing; the message above says which anchor"
		restore_all
		return 0
	fi

	post_sum="$( [ -e "$target" ] && sha256sum "$target" | cut -d' ' -f1 || printf 'ABSENT' )"
	if [ "$pre_sum" = "$post_sum" ]; then
		record_unknown "$id" "mutation exited 0 but did not change $target — nothing was injected"
		restore_all
		return 0
	fi

	# -- Phase 4: the guard must now go red, for the RIGHT reason. -----------
	run_guard "$kind" "$guard" "$filter"
	local mutated_status="$GUARD_STATUS" mutated_output="$GUARD_OUTPUT"

	# -- Phase 5: restore, and require recovery. ----------------------------
	restore_all
	local restored_sum
	restored_sum="$( [ -e "$target" ] && sha256sum "$target" | cut -d' ' -f1 || printf 'ABSENT' )"
	if [ "$restored_sum" != "$pre_sum" ]; then
		record_unknown "$id" "RESTORE FAILED for $target (pre=$pre_sum now=$restored_sum) — the tree is dirty"
		return 0
	fi

	if [ "$mutated_status" -eq 0 ]; then
		# A finding — but WHICH finding is not yet known. Quote the observed green
		# output first, because that is the evidence and it is true regardless of
		# how the case classifies below.
		printf '  *** GUARD DID NOT FIRE ***\n'
		printf '      the defect was present and the guard exited 0. Observed output:\n'
		show "$mutated_output" '' 20 '      | '

		# No control registered: say so, and do NOT claim decoration. "Did not
		# catch this mutation" is all that was measured.
		if [ -z "$ctrl" ]; then
			NOT_FIRED=$((NOT_FIRED + 1))
			UNCLASSIFIED=$((UNCLASSIFIED + 1))
			FINDINGS+=("UNCLASSIFIED|$id|$guard|$filter|$target")
			printf '      verdict: UNCLASSIFIED — no positive control is registered for this\n'
			printf '      case, so this run cannot distinguish a blind spot from decoration.\n'
			return 0
		fi

		# Positive control: the blunt version of the same defect. The tree was
		# restored in Phase 5, so this applies to a clean tree.
		printf '      applying positive control (%s) to classify...\n' "$ctrl"
		local c_pre c_post
		c_pre="$( [ -e "$target" ] && sha256sum "$target" | cut -d' ' -f1 || printf 'ABSENT' )"
		if ! "$ctrl"; then
			record_unknown "$id" "guard stayed green on the subtle mutation, but the POSITIVE CONTROL failed to apply (anchor missing) — blind spot and decoration cannot be told apart, so this is not reported as either"
			restore_all
			return 0
		fi
		c_post="$( [ -e "$target" ] && sha256sum "$target" | cut -d' ' -f1 || printf 'ABSENT' )"
		if [ "$c_pre" = "$c_post" ]; then
			record_unknown "$id" "positive control exited 0 but changed nothing — cannot classify this finding"
			restore_all
			return 0
		fi

		run_guard "$kind" "$guard" "$filter"
		local ctrl_status="$GUARD_STATUS" ctrl_output="$GUARD_OUTPUT"
		restore_all

		NOT_FIRED=$((NOT_FIRED + 1))
		if [ "$ctrl_status" -ne 0 ]; then
			BLIND=$((BLIND + 1))
			FINDINGS+=("BLIND-SPOT|$id|$guard|$filter|$target")
			printf '      verdict: BLIND SPOT — the control went RED (exit %s), so this guard\n' "$ctrl_status"
			printf '      IS live. It has a specific gap, not a missing capability:\n'
			show "$ctrl_output" '^not ok|^# ' 3 '      | '
		else
			DECOR=$((DECOR + 1))
			FINDINGS+=("DECORATION|$id|$guard|$filter|$target")
			printf '      verdict: DECORATION — the control ALSO exited 0. Both the subtle and\n'
			printf '      the blunt form of this defect passed. Observed control output:\n'
			show "$ctrl_output" '' 10 '      | '
		fi
		return 0
	fi

	# Red — but red for the injected defect, or red for something else? A guard
	# that goes red because the mutation broke its parser has not detected
	# anything, and reporting that as success is how a guard keeps its reputation
	# while losing its capability.
	if ! printf '%s\n' "$mutated_output" | grep -qE "$sig"; then
		record_unknown "$id" "guard went red (exit $mutated_status) but its output did not match the expected signature /$sig/ — it may be failing for a reason unrelated to the injected defect"
		show "$mutated_output" '^not ok|^# ' 6 '      | '
		return 0
	fi

	# -- Phase 6: green again, so the red was the mutation and not damage. ---
	run_guard "$kind" "$guard" "$filter"
	if [ "$GUARD_STATUS" -ne 0 ]; then
		record_unknown "$id" "guard did not recover after restore (exit $GUARD_STATUS) — the red above may have been collateral damage rather than detection"
		return 0
	fi

	FIRED=$((FIRED + 1))
	printf '  RED as required (exit %s), recovered green on restore\n' "$mutated_status"
	show "$mutated_output" '^not ok' 2 '      | '
	return 0
}

# ── Self-test: prove THIS harness can fail ──────────────────────────────────
#
# The harness is the thing that catches vacuous passes. A vacuous harness is the
# worst possible outcome here, so its verdict logic is exercised against
# synthetic guards whose correct verdict is known in advance. Each expectation
# below is asserted; a harness whose verdict logic breaks turns this red.

self_test() {
	local fix status out rc=0
	SELFTEST_N=0
	fix="$(mktemp -d)"

	# A guard that is pure decoration: it never looks at its target.
	cat >"$fix/decoration.bats" <<-'BATS'
		@test "decoration guard that never looks at anything" {
			[ 1 -eq 1 ]
		}
	BATS
	# A guard that genuinely reads its target.
	cat >"$fix/real.bats" <<-BATS
		@test "real guard rejects FORBIDDEN" {
			if grep -q FORBIDDEN "$fix/target.txt"; then
				echo "found the forbidden token"
				false
			fi
		}
	BATS
	# A guard that is already failing before anything is injected.
	cat >"$fix/redbase.bats" <<-'BATS'
		@test "guard that is red before any mutation" {
			false
		}
	BATS
	# The same real guard, as a plain script. Until this fixture existed the `sh`
	# branch of run_guard and selected_test_count had no test and no registered
	# case: an unexercised code path inside the tool whose entire purpose is
	# finding unexercised checks.
	cat >"$fix/real-guard.sh" <<-SH
		#!/usr/bin/env bash
		if grep -q FORBIDDEN "$fix/target.txt"; then
		  echo "found the forbidden token"
		  exit 1
		fi
		exit 0
	SH
	printf 'clean content\n' >"$fix/target.txt"

	SNAP_PATHS=(); SNAP_KEYS=()

	expect() {   # <expected-verdict> <label> ... runs prove() and checks counters
		local want="$1" label="$2"; shift 2
		local f0=$FIRED b0=$BLIND d0=$DECOR c0=$UNCLASSIFIED u0=$UNKNOWN got
		prove "$@" >/dev/null 2>&1 || true
		# The specific counters are tested BEFORE NOT_FIRED, because NOT_FIRED is
		# a total that every finding kind also increments. Testing it first would
		# collapse BLIND, DECOR and UNCLASSIFIED into one indistinguishable verdict
		# — a self-test that cannot tell apart the three outcomes it exists to
		# tell apart.
		if   [ "$FIRED"        -gt "$f0" ]; then got=FIRED
		elif [ "$BLIND"        -gt "$b0" ]; then got=BLIND
		elif [ "$DECOR"        -gt "$d0" ]; then got=DECOR
		elif [ "$UNCLASSIFIED" -gt "$c0" ]; then got=UNCLASSIFIED
		elif [ "$UNKNOWN"      -gt "$u0" ]; then got=UNKNOWN
		else got=NOTHING; fi
		SELFTEST_N=$((SELFTEST_N + 1))
		if [ "$got" = "$want" ]; then
			printf '  ok    %-52s -> %s\n' "$label" "$got"
		else
			printf '  FAIL  %-52s -> %s (expected %s)\n' "$label" "$got" "$want"
			rc=1
		fi
	}

	st_mut_real()    { py_sub "$fix/target.txt" 'clean content' 'FORBIDDEN content'; }
	st_mut_badanchor(){ py_sub "$fix/target.txt" 'anchor that is not present' 'x'; }
	st_mut_noop()    { return 0; }
	st_mut_wrongred(){ py_sub "$fix/target.txt" 'clean content' 'FORBIDDEN content'; }
	# A defect the real guard genuinely does not look for. Paired with st_mut_real
	# as the control, this is a guard with a blind spot rather than a dead one.
	st_mut_sneaky()  { py_sub "$fix/target.txt" 'clean content' 'sneaky content'; }

	printf '=== harness self-test =======================================\n'

	# show() must actually EMIT. It once printed nothing whatsoever for every
	# finding in a full run — sed rejected a prefix containing its own delimiter —
	# while every verdict above it stayed correct. Blank evidence under a correct
	# headline is indistinguishable from a guard that produced no output, and this
	# harness is not allowed to report a guard without quoting what it saw.
	local shown sline n_shown=0
	shown="$(show 'not ok 1 example failure
# a detail line
ok 2 should be filtered out' '^not ok|^# ' 5 '      | ')"
	while IFS= read -r sline; do
		case "$sline" in '      | '*) n_shown=$((n_shown + 1)) ;; esac
	done <<< "$shown"
	SELFTEST_N=$((SELFTEST_N + 1))
	if [ "$n_shown" -eq 2 ] && [[ "$shown" == *'not ok 1 example failure'* ]] \
	   && [[ "$shown" != *'should be filtered out'* ]]; then
		printf '  ok    %-52s -> 2 prefixed lines\n' "show() emits filtered, prefixed evidence"
	else
		printf '  FAIL  %-52s -> %s prefixed line(s): %q\n' \
			"show() emitted nothing, or lost the prefix/filter" "$n_shown" "$shown"
		rc=1
	fi

	expect FIRED     "a real guard detects its defect" \
		ST-REAL self bats "$fix/real.bats" 'real guard rejects' \
		"$fix/target.txt" 'forbidden token|not ok' st_mut_real

	expect UNCLASSIFIED "a finding with NO control is UNCLASSIFIED, not decoration" \
		ST-DECOR self bats "$fix/decoration.bats" 'decoration guard' \
		"$fix/target.txt" 'not ok' st_mut_real

	expect UNKNOWN   "a mutation whose anchor is missing is UNKNOWN" \
		ST-BADANCHOR self bats "$fix/real.bats" 'real guard rejects' \
		"$fix/target.txt" 'not ok' st_mut_badanchor

	expect UNKNOWN   "a mutation that changes nothing is UNKNOWN" \
		ST-NOOP self bats "$fix/real.bats" 'real guard rejects' \
		"$fix/target.txt" 'not ok' st_mut_noop

	expect UNKNOWN   "a filter selecting zero tests is UNKNOWN, not green" \
		ST-ZEROSEL self bats "$fix/real.bats" 'NO_SUCH_TEST_NAME_XYZ' \
		"$fix/target.txt" 'not ok' st_mut_real

	expect UNKNOWN   "a guard red at baseline is UNKNOWN" \
		ST-REDBASE self bats "$fix/redbase.bats" 'red before any mutation' \
		"$fix/target.txt" 'not ok' st_mut_real

	expect UNKNOWN   "a missing guard file is UNKNOWN" \
		ST-NOGUARD self bats "$fix/does-not-exist.bats" 'anything' \
		"$fix/target.txt" 'not ok' st_mut_real

	expect UNKNOWN   "red for an unexpected reason is UNKNOWN, not FIRED" \
		ST-WRONGRED self bats "$fix/real.bats" 'real guard rejects' \
		"$fix/target.txt" 'a signature that will never appear' st_mut_wrongred

	# ── The classification the first real run got wrong ─────────────────────
	#
	# These four are the reason this self-test grew. A run that cannot tell a
	# blind spot from decoration will confidently call a working guard dead, and
	# it did: two guards were reported as "DECORATION" in exactly those words,
	# and both went red under a blunter control.

	expect BLIND     "guard missed the subtle defect but caught the control" \
		ST-BLIND self bats "$fix/real.bats" 'real guard rejects' \
		"$fix/target.txt" 'not ok' st_mut_sneaky st_mut_real

	expect DECOR     "guard missed the control too — decoration, now measured" \
		ST-DECOR-CTRL self bats "$fix/decoration.bats" 'decoration guard' \
		"$fix/target.txt" 'not ok' st_mut_sneaky st_mut_real

	expect UNKNOWN   "a control whose anchor is missing cannot classify -> UNKNOWN" \
		ST-CTRLBAD self bats "$fix/decoration.bats" 'decoration guard' \
		"$fix/target.txt" 'not ok' st_mut_sneaky st_mut_badanchor

	expect FIRED     "the sh guard kind runs and detects its defect" \
		ST-SH self sh "$fix/real-guard.sh" '' \
		"$fix/target.txt" 'forbidden token' st_mut_real

	expect UNKNOWN   "an unreadable sh guard is UNKNOWN, never a pass" \
		ST-SH-MISSING self sh "$fix/no-such-guard.sh" '' \
		"$fix/target.txt" 'forbidden token' st_mut_real

	# Restore proof: every fixture file is byte-identical after all of that.
	if [ "$(cat "$fix/target.txt")" = "clean content" ]; then
		SELFTEST_N=$((SELFTEST_N + 1))
		printf '  ok    %-52s -> restored\n' "target file restored after every verdict case"
	else
		printf '  FAIL  %-52s -> %s\n' "target file NOT restored" "$(cat "$fix/target.txt")"
		rc=1
	fi

	# Trap proof: kill a run mid-mutation and require the file to come back.
	#
	# $BASHPID, not $$. Inside a subshell `$$` still holds the PARENT's pid, so
	# `kill -TERM $$` here terminates the harness itself rather than the subshell
	# under test — which it did on the first run of this very case, taking the
	# whole self-test down with exit 130 and printing no verdict at all. A
	# self-test that kills its own runner reports nothing and looks like a hang.
	printf 'clean content\n' >"$fix/target.txt"
	(
		trap 'cp "$fix/snap.bytes" "$fix/target.txt"; exit 130' EXIT
		cp "$fix/target.txt" "$fix/snap.bytes"
		printf 'MUTATED AND ABANDONED\n' >"$fix/target.txt"
		kill -TERM "$BASHPID" 2>/dev/null
		sleep 5
	) >/dev/null 2>&1 || true
	if [ "$(cat "$fix/target.txt")" = "clean content" ]; then
		SELFTEST_N=$((SELFTEST_N + 1))
		printf '  ok    %-52s -> restored\n' "EXIT trap restores an ABORTED run"
	else
		printf '  FAIL  %-52s -> %s\n' "EXIT trap did NOT restore an aborted run" "$(cat "$fix/target.txt")"
		rc=1
	fi

	rm -rf "$fix"
	SNAP_PATHS=(); SNAP_KEYS=()
	FIRED=0; NOT_FIRED=0; UNKNOWN=0; FINDINGS=(); UNKNOWNS=()
	BLIND=0; DECOR=0; UNCLASSIFIED=0

	printf '=============================================================\n'
	if [ "$rc" -ne 0 ]; then
		printf 'SELF-TEST FAILED: the harness does not classify outcomes correctly.\n'
		printf 'Nothing this tool reports about any guard can be trusted until this passes.\n'
		return 1
	fi
	# The count is COMPUTED, not typed. A hardcoded "all 10 behaviours verified"
	# stays at 10 while cases are added or silently skipped — a claim about
	# coverage that stops tracking the coverage, which is this repository's
	# signature defect written in a status line.
	if [ "$SELFTEST_N" -lt 10 ]; then
		printf 'SELF-TEST DEGENERATE: only %s behaviour(s) ran; expected at least 10.\n' "$SELFTEST_N"
		return 1
	fi
	printf 'self-test passed: %s harness behaviours verified.\n' "$SELFTEST_N"
	return 0
}

# ── Main ────────────────────────────────────────────────────────────────────

ONLY=""
MODE=run
while [ $# -gt 0 ]; do
	case "$1" in
		--list)      MODE=list ;;
		--self-test) MODE=selftest ;;
		--only)      ONLY="$2"; shift ;;
		-h|--help)   sed -n '2,60p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*)           printf 'unknown argument: %s\n' "$1"; exit 2 ;;
	esac
	shift
done

# Assert the harness's OWN mechanism. A registry that discovered zero cases must
# be a failure, not a pass — this is the tool that catches vacuous passes, and
# writing one would be the joke telling itself.
if [ "${#C_ID[@]}" -eq 0 ]; then
	printf 'FATAL: the case registry is EMPTY. A falsification harness with no cases\n'
	printf 'passes vacuously, which is the precise defect it exists to detect.\n'
	exit 2
fi

if [ "$MODE" = list ]; then
	printf '%-34s %-12s %s\n' ID CATEGORY GUARD
	for i in "${!C_ID[@]}"; do
		printf '%-34s %-12s %s :: %s\n' "${C_ID[$i]}" "${C_CAT[$i]}" "${C_GUARD[$i]}" "${C_FILTER[$i]}"
	done
	printf '\n%s case(s) registered.\n' "${#C_ID[@]}"
	exit 0
fi

if [ "$MODE" = selftest ]; then
	self_test
	exit $?
fi

printf '=== guard falsification proof ================================\n'
printf 'repo   : %s\n' "$REPO_ROOT"
printf 'HEAD   : %s\n' "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
printf 'cases  : %s registered\n' "${#C_ID[@]}"

# The self-test runs FIRST, every time. A harness whose verdict logic is broken
# reports confident nonsense about twenty guards, and the most alarming message
# it can produce is the one a broken harness produces most easily.
if ! self_test; then
	printf '\nAborting: the harness failed its own self-test.\n'
	exit 2
fi

# Record the working-tree state so the restore claim is evidence, not assertion.
TREE_BEFORE="$(git status --porcelain 2>/dev/null | sort)"

RAN=0
for i in "${!C_ID[@]}"; do
	if [ -n "$ONLY" ] && ! printf '%s' "${C_ID[$i]}" | grep -qE "$ONLY"; then
		continue
	fi
	RAN=$((RAN + 1))
	prove "${C_ID[$i]}" "${C_CAT[$i]}" "${C_KIND[$i]}" "${C_GUARD[$i]}" \
	      "${C_FILTER[$i]}" "${C_TARGET[$i]}" "${C_SIG[$i]}" "${C_MUT[$i]}" \
	      "${C_CTRL[$i]}"
done

restore_all
TREE_AFTER="$(git status --porcelain 2>/dev/null | sort)"

printf '\n=== summary =================================================\n'
printf 'cases run          : %s\n' "$RAN"
printf 'guard FIRED        : %s\n' "$FIRED"
printf 'guard DID NOT FIRE : %s   <-- findings\n' "$NOT_FIRED"
printf '  of which BLIND SPOT   : %s   guard IS live; control went red, this shape slipped through\n' "$BLIND"
printf '  of which DECORATION   : %s   guard stayed green even for the blunt control\n' "$DECOR"
printf '  of which UNCLASSIFIED : %s   no control registered; blind spot vs decoration not measured\n' "$UNCLASSIFIED"
printf 'UNKNOWN            : %s   <-- harness could not run these; neither pass nor fail\n' "$UNKNOWN"

printf '\n--- restore proof ---\n'
if [ "$TREE_BEFORE" = "$TREE_AFTER" ]; then
	printf 'git status is byte-identical before and after. Tree restored.\n'
else
	printf '*** TREE NOT RESTORED — git status changed across the run ***\n'
	diff <(printf '%s\n' "$TREE_BEFORE") <(printf '%s\n' "$TREE_AFTER") | sed 's/^/  /' || true
	# A harness that dirties the tree is a HARNESS defect, and it gets its own
	# flag rather than being added to NOT_FIRED. Folding it into the guard-finding
	# counter would report a harness bug as though a guard had failed to fire —
	# the same category error this whole round exists to stamp out.
	DIRTY_TREE=1
fi

if [ "${#UNKNOWNS[@]}" -gt 0 ]; then
	printf '\n--- UNKNOWN (reported as neither pass nor finding) ---\n'
	printf '%s\n' "${UNKNOWNS[@]}" | sed 's/^/  /'
fi

if [ "${#FINDINGS[@]}" -gt 0 ]; then
	printf '\n--- GUARDS THAT DID NOT FIRE ---\n'
	printf '  %-13s %-28s %s\n' VERDICT ID 'GUARD :: FILTER :: TARGET'
	for f in "${FINDINGS[@]}"; do
		printf '  %s\n' "$f" | tr '|' '\t'
	done
	printf '\nEach had its defect injected and the guard exited 0. Read the verdict\n'
	printf 'column — the three are different defects with different repairs:\n'
	printf '  BLIND SPOT   the guard works; this shape slips past it. Widen the check.\n'
	printf '  DECORATION   the guard did not fire even for the blunt control. Rewrite it.\n'
	printf '  UNCLASSIFIED not measured. Register a positive control and re-run before\n'
	printf '               drawing any conclusion about this guard at all.\n'
fi

if [ "$DIRTY_TREE" -ne 0 ]; then
	printf '\nThe harness did not restore the tree. Nothing it reported can be trusted\n'
	printf 'until that is fixed, and the working tree needs inspecting by hand.\n'
	exit 4
fi
if [ "$NOT_FIRED" -gt 0 ]; then
	printf '\n%s guard(s) failed to fire (%s blind spot, %s decoration, %s unclassified).\n' \
		"$NOT_FIRED" "$BLIND" "$DECOR" "$UNCLASSIFIED"
	exit 1
fi
if [ "$UNKNOWN" -gt 0 ]; then
	printf '\n%s case(s) could not be run. That is not a pass — fix them.\n' "$UNKNOWN"
	exit 3
fi
printf '\nAll %s cases red as required, and the tree is clean.\n' "$RAN"
