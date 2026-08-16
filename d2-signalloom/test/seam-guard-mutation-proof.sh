#!/usr/bin/env bash
#
# Proves the vocabulary seam guards actually fail when their defect is present.
#
# A guard is only worth its runtime if it goes red on the thing it claims to
# catch. Two of the assertions in these files were red against live code when
# they were written -- that is real evidence for those two. The rest were green
# from the first run, which is exactly the state in which a guard that can never
# fail is indistinguishable from one that works. This repository has already
# shipped both shapes: a scanner that silently scanned nothing, and a bats
# helper that returned build output so the tests depending on it passed
# vacuously through a mutation designed to break them.
#
# So each assertion gets its defect injected, the specific test is run, and a
# NON-ZERO exit is required. Then the file is restored from a byte-for-byte
# backup and the test must pass again.
#
# Restoration is by `cp` from a backup taken at start, never by `git checkout --`
# on a path: these files are new and uncommitted for most of their life, so a
# checkout would delete the work rather than restore it.
#
# Usage:  bash d2-signalloom/test/seam-guard-mutation-proof.sh
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TESTS_DIR="${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/src/tests"
DASH_SRC="${REPO_ROOT}/d2-signalloom/apps/dashboard-signalloom/src"
API_COMPAT="${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/src/api_compat.py"

AUDIT_TRAIL="${DASH_SRC}/views/AuditTrail.tsx"
AGENTS_PAGE="${DASH_SRC}/pages/AgentsPage.tsx"
AGENT_DETAIL="${DASH_SRC}/pages/AgentDetailPage.tsx"
AUDIT_GUARD="${TESTS_DIR}/test_dashboard_audit_vocabulary.py"
LIFECYCLE_GUARD="${TESTS_DIR}/test_dashboard_lifecycle_vocabulary.py"

BACKUP_DIR="$(mktemp -d)"
FAILURES=0
CHECKS=0

# PYTEST_DISABLE_PLUGIN_AUTOLOAD: a broken third-party libtmux plugin in this
# environment aborts collection before any test runs. addopts is cleared because
# pytest.ini requests xdist, which is not always installed for an ad-hoc run.
run_test() {
	(cd "$TESTS_DIR" && PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 \
		python3 -m pytest "$1" -p no:cacheprovider -o addopts="" -q -k "$2" 2>&1)
}

backup() { cp "$1" "${BACKUP_DIR}/$(basename "$1").bak"; }
restore() { cp "${BACKUP_DIR}/$(basename "$1").bak" "$1"; }

cleanup() {
	# Restore everything unconditionally, including on an interrupted run. An
	# aborted proof that leaves an injected defect behind is worse than no proof.
	for f in "$AUDIT_TRAIL" "$AGENTS_PAGE" "$AGENT_DETAIL" "$AUDIT_GUARD" \
	         "$LIFECYCLE_GUARD" "$API_COMPAT"; do
		[ -f "${BACKUP_DIR}/$(basename "$f").bak" ] && cp "${BACKUP_DIR}/$(basename "$f").bak" "$f"
	done
	rm -rf "$BACKUP_DIR"
}
trap cleanup EXIT

# prove <label> <file> <guard> <-k filter> <sed-or-python mutation command>
prove() {
	local label="$1" target="$2" guard="$3" filter="$4" mutation="$5"
	CHECKS=$((CHECKS + 1))

	# Green before.
	if ! run_test "$guard" "$filter" >/dev/null 2>&1; then
		echo "FAIL  ${label}"
		echo "      test was not green BEFORE the mutation -- nothing was proved"
		FAILURES=$((FAILURES + 1))
		return
	fi

	backup "$target"
	eval "$mutation"

	# The mutation must actually change the file. A sed that matches nothing
	# exits 0 and prints success while injecting no defect at all -- the test
	# then "passes" and would be recorded here as a guard that failed to fire.
	if cmp -s "$target" "${BACKUP_DIR}/$(basename "$target").bak"; then
		echo "FAIL  ${label}"
		echo "      mutation did not modify $(basename "$target") -- nothing was injected"
		FAILURES=$((FAILURES + 1))
		restore "$target"
		return
	fi

	local output status
	output="$(run_test "$guard" "$filter" 2>&1)" && status=0 || status=$?
	restore "$target"

	if [ "$status" -eq 0 ]; then
		echo "FAIL  ${label}"
		echo "      guard stayed GREEN with the defect injected"
		FAILURES=$((FAILURES + 1))
		return
	fi

	# Green again after restore, so the red was the mutation and not damage.
	if ! run_test "$guard" "$filter" >/dev/null 2>&1; then
		echo "FAIL  ${label}"
		echo "      test did not recover after restore"
		FAILURES=$((FAILURES + 1))
		return
	fi

	echo "ok    ${label}"
	echo "      red: $(echo "$output" | grep -oE 'AssertionError: [^\\]{0,110}' | head -1)"
}

echo "=== seam guard mutation proof ==============================="

# ── audit vocabulary guard ─────────────────────────────────────────────
prove "emitted type with no filter option is caught" \
	"$AUDIT_TRAIL" "$AUDIT_GUARD" "test_every_emitted_event_type_is_filterable" \
	"sed -i \"s/^  'agent.created', 'agent.transitioned', 'agent.stunned',\$/  'agent.transitioned', 'agent.stunned',/\" '$AUDIT_TRAIL'"

prove "filter option matching nothing emitted is caught" \
	"$AUDIT_TRAIL" "$AUDIT_GUARD" "test_every_filter_option_matches_something_the_api_emits" \
	"sed -i \"s/^  'demo.phase_run', 'demo.reset_requested',\$/  'demo.phase_run', 'demo.reset_requested', 'agent.teleported',/\" '$AUDIT_TRAIL'"

prove "filter option with no colour is caught" \
	"$AUDIT_TRAIL" "$AUDIT_GUARD" "test_every_filter_option_has_a_colour" \
	"sed -i \"/^  'support.requested': 'var(--amber)',\$/d\" '$AUDIT_TRAIL'"

prove "stale legacy allowlist entry is caught" \
	"$AUDIT_GUARD" "$AUDIT_GUARD" "test_no_stale_legacy_filter_options" \
	"sed -i \"s/^    \\\"discovery_enroll_requested\\\",\$/    \\\"discovery_enroll_requested\\\",\\n    \\\"dropped_by_a_later_migration\\\",/\" '$AUDIT_GUARD'"

prove "unreadable EVENT_TYPES fails instead of reporting agreement" \
	"$AUDIT_TRAIL" "$AUDIT_GUARD" "test_the_dashboard_declares_filter_options_at_all" \
	"sed -i 's/^const EVENT_TYPES = \\[\$/const EVENT_TYPE_LIST = [/' '$AUDIT_TRAIL'"

prove "agent-scoped type missing from the timeline is caught" \
	"$AGENT_DETAIL" "$AUDIT_GUARD" "test_agent_detail_timeline_filters_match_emitted_types" \
	"sed -i \"s/^  'agent.created', 'agent.transitioned', 'agent.stunned',\$/  'agent.transitioned', 'agent.stunned',/\" '$AGENT_DETAIL'"

# ── lifecycle vocabulary guard ─────────────────────────────────────────
prove "written state the constraint forbids is caught" \
	"$API_COMPAT" "$LIFECYCLE_GUARD" "test_every_state_the_api_writes_is_permitted" \
	"sed -i \"s/^STUNNED_LIFECYCLE_STATE = \\\"suspended\\\"\$/STUNNED_LIFECYCLE_STATE = \\\"quarantined\\\"/\" '$API_COMPAT'"

prove "written state with no filter option is caught" \
	"$AGENTS_PAGE" "$LIFECYCLE_GUARD" "test_every_state_the_api_writes_is_filterable" \
	"sed -i \"s/^const LIFECYCLE_OPTIONS = \\['all', 'registered', /const LIFECYCLE_OPTIONS = ['all', /\" '$AGENTS_PAGE'"

prove "transition target the constraint forbids is caught" \
	"$AGENT_DETAIL" "$LIFECYCLE_GUARD" "test_every_offered_transition_target_is_permitted" \
	"sed -i \"0,/{ state: 'suspended', label:/s//{ state: 'quarantined', label:/\" '$AGENT_DETAIL'"

prove "dead lifecycle filter option is caught" \
	"$AGENTS_PAGE" "$LIFECYCLE_GUARD" "test_no_dead_lifecycle_filter_options" \
	"sed -i \"s/^const LIFECYCLE_OPTIONS = \\['all', /const LIFECYCLE_OPTIONS = ['all', 'mothballed', /\" '$AGENTS_PAGE'"

prove "stale unfiltered-state allowlist entry is caught" \
	"$LIFECYCLE_GUARD" "$LIFECYCLE_GUARD" "test_no_stale_unfiltered_state" \
	"sed -i 's/^UNFILTERED_PERMITTED_STATES = {\"decommissioned\"}\$/UNFILTERED_PERMITTED_STATES = {\"decommissioned\", \"gone\"}/' '$LIFECYCLE_GUARD'"

echo "============================================================="
if [ "$FAILURES" -ne 0 ]; then
	echo "${FAILURES} of ${CHECKS} mutation(s) did not produce a red test."
	exit 1
fi
echo "all ${CHECKS} mutations produced a red test and recovered on restore."
