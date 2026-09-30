#!/usr/bin/env bats
#
# cluster-clean-teardown.sh and cluster-scratch-standup.sh are destructive, so
# they are only ever run here against stubs: PATH holds stub kind/docker/pkill/
# ip/iptables/make/kubectl plus plain coreutils, and no real cluster tool. The
# first test proves that by construction before any other test runs a script.
#
# @target scripts/cluster-clean-teardown.sh scripts/cluster-scratch-standup.sh

bats_require_minimum_version 1.5.0

setup() {
	root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	teardown_sh="$root/scripts/cluster-clean-teardown.sh"
	standup_sh="$root/scripts/cluster-scratch-standup.sh"
	t="$BATS_TEST_TMPDIR"
	stub="$t/stub" tools="$t/tools"
	mkdir -p "$stub" "$tools"
	for b in bash sh env grep awk sed cut wc cat rm mkdir dirname basename tr head tail sort git date touch chmod find mktemp cp mv ls cmp stat xargs tee ln; do
		p="$(command -v "$b")" && ln -s "$p" "$tools/$b"
	done
	export PATH="$stub:$tools" STUB_LOG="$t/calls.log"
	: >"$STUB_LOG"
	export SLDC_SAVED_CONTAINERS_FILE="$t/saved.txt"
	export KIND_CLUSTERS=$'osramp\nsignalloom-hub\nother'
	mkstub kind 'case "$*" in "get clusters") printf "%s\n" "$KIND_CLUSTERS" ;; "delete cluster"*) exit "${KIND_DELETE_RC:-0}" ;; esac'
	# docker ps: lists STUB_LINGERING before any stop, STUB_REMAINING after.
	mkstub docker 'case "$*" in
  "ps --filter"*) [ -f "$STUB_LOG.stopped" ] || printf "%s" "${STUB_LINGERING:-}" ;;
  "ps -q"*) printf "%s" "${STUB_REMAINING:-}" ;;
  stop*) touch "$STUB_LOG.stopped" ;;
  "network inspect"*) exit 0 ;;
esac'
	mkstub pkill ''
	mkstub ip 'case "$*" in *"link show"*) echo "9: veth1@if2: <UP> mtu 1500 master docker0 state UP" ;; esac'
	mkstub iptables ''
	mkstub kubectl 'exit 99'
	mkstub make 'case "$*" in *"${MAKE_FAIL:-none}"*) exit 2 ;; esac'
	# Standup runs $REPO_ROOT/scripts/dual-cluster-up.sh: point it at a stub repo.
	export REPO_ROOT="$t/repo"
	mkdir -p "$REPO_ROOT/scripts"
	printf '#!/usr/bin/env bash\necho "dual-cluster-up" >>"$STUB_LOG"\n' >"$REPO_ROOT/scripts/dual-cluster-up.sh"
}

mkstub() { printf '#!/usr/bin/env bash\necho "%s $*" >>"$STUB_LOG"\n%s\n' "$1" "$2" >"$stub/$1"; chmod +x "$stub/$1"; }

@test "only stubs are reachable: no real kind, docker, pkill, ip, make or kubectl" {
	for b in kind docker pkill ip iptables make kubectl; do [ "$(command -v "$b")" = "$stub/$b" ]; done
}

@test "teardown deletes exactly the two SLDC clusters, via the stub, and passes" {
	run bash "$teardown_sh"
	[ "$status" -eq 0 ]
	[ "$(grep -c '^kind delete' "$STUB_LOG")" -eq 2 ]
	grep -qx 'kind delete cluster --name osramp' "$STUB_LOG"
	grep -qx 'kind delete cluster --name signalloom-hub' "$STUB_LOG"
	! grep -q 'name other' "$STUB_LOG"
}

@test "teardown fails when a cluster delete fails" {
	KIND_DELETE_RC=1 run --separate-stderr bash "$teardown_sh"
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"kind delete cluster --name osramp failed"* ]]
	[[ "$output" != *"VERDICT: PASS"* ]]
}

@test "teardown fails while matching containers still run" {
	STUB_LINGERING=osramp-worker STUB_REMAINING=$'abc\n' run --separate-stderr bash "$teardown_sh"
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"VERDICT: FAIL (1 lingering containers, 0 failed deletes)"* ]]
	grep -qx 'docker stop osramp-worker' "$STUB_LOG"
	[ "$(cat "$SLDC_SAVED_CONTAINERS_FILE")" = osramp-worker ]
}

@test "teardown writes saved containers only to SLDC_SAVED_CONTAINERS_FILE" {
	touch "$t/marker"
	STUB_LINGERING=signalloom-aux run bash "$teardown_sh"
	[ "$(cat "$SLDC_SAVED_CONTAINERS_FILE")" = signalloom-aux ]
	[ -z "$(find /tmp -maxdepth 1 -name sldc-saved-containers.txt -newer "$t/marker" 2>/dev/null)" ]
}

@test "teardown never deletes a bridge-attached veth" {
	run bash "$teardown_sh"
	! grep -q 'link delete' "$STUB_LOG"
}

@test "standup: a failing platform target fails the standup" {
	MAKE_FAIL=demo-signalloom-up run --separate-stderr bash "$standup_sh"
	[ "$status" -ne 0 ]
	[[ "$output" != *"VERDICT: PASS"* ]]
	! grep -q 'healthcheck' "$STUB_LOG"
}

@test "standup: healthy targets run in order and pass" {
	run bash "$standup_sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *"VERDICT: PASS"* ]]
	grep -qx dual-cluster-up "$STUB_LOG"
	[ "$(grep '^make' "$STUB_LOG" | sed 's/^make -C [^ ]* //' | tr '\n' ' ')" = "up demo-signalloom-up demo-agent-trust-up healthcheck " ]
}

@test "standup restores saved auxiliary containers but never a kind control plane" {
	printf 'signalloom-aux\nosramp-control-plane\n' >"$SLDC_SAVED_CONTAINERS_FILE"
	run bash "$standup_sh"
	[ "$status" -eq 0 ]
	grep -qx 'docker start signalloom-aux' "$STUB_LOG"
	! grep -q 'docker start osramp-control-plane' "$STUB_LOG"
	[ ! -e "$SLDC_SAVED_CONTAINERS_FILE" ]
}
