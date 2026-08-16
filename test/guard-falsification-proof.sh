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
# ── Three outcomes, never two ───────────────────────────────────────────────
#
# The defect that produced a false "all twelve audit guards are decoration" was
# a two-outcome verdict: the harness could not tell "the guard ran and stayed
# quiet" from "the guard never ran". Those are different answers and they do not
# share an exit path here.
#
#   FIRED      the guard went red, and its output matched the expected signature.
#   NOT FIRED  the guard stayed green with the defect present. THIS IS A FINDING.
#   UNKNOWN    the harness could not run the case. Never counted as either.
#
# UNKNOWN covers: a baseline that was not green; a --filter that selected ZERO
# tests; a mutation that did not change the file; a guard that went red for a
# reason other than the injected defect; a tree that did not recover on restore.
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
NOT_FIRED=0
UNKNOWN=0
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
		sh) n=1 ;;   # a script is one unit; it has no filter to mis-select
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

register() {
	C_ID+=("$1"); C_CAT+=("$2"); C_KIND+=("$3"); C_GUARD+=("$4")
	C_FILTER+=("$5"); C_TARGET+=("$6"); C_SIG+=("$7"); C_MUT+=("$8")
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
register META-EXEC-PROBE meta bats test/no-exec-probes-in-tests.bats \
	'no test file outside the allowlist probes with kubectl exec' \
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
	local id="$1" cat="$2" kind="$3" guard="$4" filter="$5" target="$6" sig="$7" mut="$8"

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
		printf '%s\n' "$GUARD_OUTPUT" | grep -E '^not ok|^# ' | head -5 | sed 's/^/      /'
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
		# The finding. Quote the observed green output — never infer.
		NOT_FIRED=$((NOT_FIRED + 1))
		FINDINGS+=("$id|$guard|$filter|$target")
		printf '  *** GUARD DID NOT FIRE — THIS CHECK IS DECORATION ***\n'
		printf '      the defect was present and the guard exited 0. Observed output:\n'
		printf '%s\n' "$mutated_output" | head -20 | sed 's/^/      | /'
		return 0
	fi

	# Red — but red for the injected defect, or red for something else? A guard
	# that goes red because the mutation broke its parser has not detected
	# anything, and reporting that as success is how a guard keeps its reputation
	# while losing its capability.
	if ! printf '%s\n' "$mutated_output" | grep -qE "$sig"; then
		record_unknown "$id" "guard went red (exit $mutated_status) but its output did not match the expected signature /$sig/ — it may be failing for a reason unrelated to the injected defect"
		printf '%s\n' "$mutated_output" | grep -E '^not ok|^# ' | head -6 | sed 's/^/      | /'
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
	printf '%s\n' "$mutated_output" | grep -E '^not ok' | head -2 | sed 's/^/      | /'
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
	printf 'clean content\n' >"$fix/target.txt"

	SNAP_PATHS=(); SNAP_KEYS=()

	expect() {   # <expected-verdict> <label> ... runs prove() and checks counters
		local want="$1" label="$2"; shift 2
		local f0=$FIRED n0=$NOT_FIRED u0=$UNKNOWN got
		prove "$@" >/dev/null 2>&1 || true
		if   [ "$FIRED"     -gt "$f0" ]; then got=FIRED
		elif [ "$NOT_FIRED" -gt "$n0" ]; then got=NOT_FIRED
		elif [ "$UNKNOWN"   -gt "$u0" ]; then got=UNKNOWN
		else got=NOTHING; fi
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

	printf '=== harness self-test =======================================\n'

	expect FIRED     "a real guard detects its defect" \
		ST-REAL self bats "$fix/real.bats" 'real guard rejects' \
		"$fix/target.txt" 'forbidden token|not ok' st_mut_real

	expect NOT_FIRED "a decoration guard is reported as a finding" \
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

	# Restore proof: every fixture file is byte-identical after all of that.
	if [ "$(cat "$fix/target.txt")" = "clean content" ]; then
		printf '  ok    %-52s -> restored\n' "target file restored after 8 cases"
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
		printf '  ok    %-52s -> restored\n' "EXIT trap restores an ABORTED run"
	else
		printf '  FAIL  %-52s -> %s\n' "EXIT trap did NOT restore an aborted run" "$(cat "$fix/target.txt")"
		rc=1
	fi

	rm -rf "$fix"
	SNAP_PATHS=(); SNAP_KEYS=()
	FIRED=0; NOT_FIRED=0; UNKNOWN=0; FINDINGS=(); UNKNOWNS=()

	printf '=============================================================\n'
	if [ "$rc" -ne 0 ]; then
		printf 'SELF-TEST FAILED: the harness does not classify outcomes correctly.\n'
		printf 'Nothing this tool reports about any guard can be trusted until this passes.\n'
		return 1
	fi
	printf 'self-test passed: all 10 harness behaviours verified.\n'
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
	      "${C_FILTER[$i]}" "${C_TARGET[$i]}" "${C_SIG[$i]}" "${C_MUT[$i]}"
done

restore_all
TREE_AFTER="$(git status --porcelain 2>/dev/null | sort)"

printf '\n=== summary =================================================\n'
printf 'cases run          : %s\n' "$RAN"
printf 'guard FIRED        : %s\n' "$FIRED"
printf 'guard DID NOT FIRE : %s   <-- findings\n' "$NOT_FIRED"
printf 'UNKNOWN            : %s   <-- harness could not run these; neither pass nor fail\n' "$UNKNOWN"

printf '\n--- restore proof ---\n'
if [ "$TREE_BEFORE" = "$TREE_AFTER" ]; then
	printf 'git status is byte-identical before and after. Tree restored.\n'
else
	printf '*** TREE NOT RESTORED — git status changed across the run ***\n'
	diff <(printf '%s\n' "$TREE_BEFORE") <(printf '%s\n' "$TREE_AFTER") | sed 's/^/  /' || true
	NOT_FIRED=$((NOT_FIRED + 1))   # a harness that dirties the tree is a defect
fi

if [ "${#UNKNOWNS[@]}" -gt 0 ]; then
	printf '\n--- UNKNOWN (reported as neither pass nor finding) ---\n'
	printf '%s\n' "${UNKNOWNS[@]}" | sed 's/^/  /'
fi

if [ "${#FINDINGS[@]}" -gt 0 ]; then
	printf '\n--- GUARDS THAT DID NOT FIRE ---\n'
	for f in "${FINDINGS[@]}"; do
		printf '  %s\n' "$f" | tr '|' '\t'
	done
	printf '\nEach of these had its defect injected and exited 0. That guard is\n'
	printf 'decoration: it reads as coverage and provides none.\n'
fi

if [ "$NOT_FIRED" -gt 0 ]; then
	printf '\n%s guard(s) failed to fire.\n' "$NOT_FIRED"
	exit 1
fi
if [ "$UNKNOWN" -gt 0 ]; then
	printf '\n%s case(s) could not be run. That is not a pass — fix them.\n' "$UNKNOWN"
	exit 3
fi
printf '\nAll %s cases red as required, and the tree is clean.\n' "$RAN"
