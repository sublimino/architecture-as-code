#!/usr/bin/env bats
#
# SLDC-P6-1 cold-start replay, offline: teardown hands the auxiliary
# containers it stopped to standup through a saved-container list, and standup
# rebuilds in order and restarts exactly those. Run against stubs only (see
# test/p6-teardown-safety.bats for the per-script refusal paths); the live
# replay is the operator running the two scripts back to back.
#
# The previous version of this suite re-ran other suites and grepped their
# counts, packaged with the repo's real signing key into .evidence/, and
# checksummed files it had just written; each of those is covered directly by
# eap-evidence-supertest, eap-evidence-mutation-gate, eap-evidence-adversarial
# and `bash test/e2e-mutation-proof.sh`.
#
# @target scripts/cluster-clean-teardown.sh scripts/cluster-scratch-standup.sh

setup() {
	root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	t="$BATS_TEST_TMPDIR"
	stub="$t/stub" tools="$t/tools"
	mkdir -p "$stub" "$tools" "$t/run" "$t/repo/scripts"
	for b in bash env grep awk sed cut wc cat rm mkdir dirname basename tr touch chmod; do
		p="$(command -v "$b")" && ln -s "$p" "$tools/$b"
	done
	export PATH="$stub:$tools" STUB_LOG="$t/calls.log" XDG_RUNTIME_DIR="$t/run" REPO_ROOT="$t/repo"
	unset SLDC_SAVED_CONTAINERS_FILE
	: >"$STUB_LOG"
	mkstub kind 'case "$*" in "get clusters") printf "osramp\nsignalloom-hub\n" ;; esac'
	mkstub docker 'case "$*" in "ps --filter"*) [ -f "$STUB_LOG.stopped" ] || printf "signalloom-aux\nosramp-control-plane\n" ;; stop*) touch "$STUB_LOG.stopped" ;; esac'
	for b in pkill ip iptables make kubectl; do mkstub "$b" ''; done
	printf '#!/usr/bin/env bash\necho "dual-cluster-up" >>"$STUB_LOG"\n' >"$REPO_ROOT/scripts/dual-cluster-up.sh"
}

mkstub() { printf '#!/usr/bin/env bash\necho "%s $*" >>"$STUB_LOG"\n%s\n' "$1" "$2" >"$stub/$1"; chmod +x "$stub/$1"; }

@test "teardown then standup: clusters deleted, rebuilt in order, auxiliary container restored" {
	run bash "$root/scripts/cluster-clean-teardown.sh"
	[ "$status" -eq 0 ]
	[ -s "$XDG_RUNTIME_DIR/sldc-saved-containers.txt" ]
	run bash "$root/scripts/cluster-scratch-standup.sh"
	[ "$status" -eq 0 ]
	[ ! -e "$XDG_RUNTIME_DIR/sldc-saved-containers.txt" ]
	sequence="$(sed -E 's/^make -C [^ ]+ /make /' "$STUB_LOG" | grep -E '^(kind delete|docker (stop|start)|make|dual-cluster-up)' | tr '\n' '|')"
	[ "$sequence" = "kind delete cluster --name signalloom-hub|kind delete cluster --name osramp|docker stop signalloom-aux|docker stop osramp-control-plane|docker start signalloom-aux|make up|dual-cluster-up|make demo-signalloom-up|make demo-agent-trust-up|make healthcheck|" ]
}
