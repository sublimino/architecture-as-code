#!/usr/bin/env bats
#
# scripts/teardown.sh decides a destructive action from `kind get clusters`. It
# used to read that list through `| grep -qx` under pipefail, where grep exits at
# the first match, kind is SIGPIPEd if still writing, and the pipeline's 141
# reads as "cluster not present": the delete is skipped and the run reports a
# clean teardown. Same defect as cluster-clean-teardown.sh (p6-teardown-safety).
#
# The script `rm -rf`s repo-relative paths, so it only ever runs here from a
# scratch copy, with stub kind/docker/kubectl and plain coreutils on PATH.
#
# @target scripts/teardown.sh

bats_require_minimum_version 1.5.0

setup() {
	root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	t="$BATS_TEST_TMPDIR"
	scratch="$t/repo" stub="$t/stub" tools="$t/tools"
	mkdir -p "$scratch/scripts" "$stub" "$tools"
	cp "$root/scripts/teardown.sh" "$scratch/scripts/teardown.sh"
	for b in bash sh env grep awk sed cat rm mkdir dirname basename tr head sort chmod; do
		p="$(command -v "$b")" && ln -s "$p" "$tools/$b"
	done
	export PATH="$stub:$tools" STUB_LOG="$t/calls.log"
	: >"$STUB_LOG"
	# Cluster names, then (KIND_FILLER) ~1 MiB more than a pipe buffer holds, so
	# kind is provably still writing when a first-match reader goes away.
	# `exec` keeps the writer the kind process itself.
	mkstub kind 'case "$*" in
  "get clusters") printf "%s\n" osramp signalloom-hub; [ -z "${KIND_FILLER:-}" ] || exec awk "BEGIN { for (i = 0; i < 70000; i++) print \"filler-cluster-\" i }" ;;
esac'
	mkstub docker ''
	mkstub kubectl ''
}

mkstub() { printf '#!/usr/bin/env bash\necho "%s $*" >>"$STUB_LOG"\n%s\n' "$1" "$2" >"$stub/$1"; chmod +x "$stub/$1"; }

@test "teardown deletes the osramp cluster even while kind is still writing after the match" {
	KIND_FILLER=1 run bash "$scratch/scripts/teardown.sh"
	[ "$status" -eq 0 ]
	grep -qx 'kind delete cluster --name osramp' "$STUB_LOG"
	[[ "$output" == *"deleting kind cluster 'osramp'"* ]]
	[[ "$output" != *"not present"* ]]
}

@test "teardown does not delete a cluster kind does not list" {
	CLUSTER_NAME=absent run bash "$scratch/scripts/teardown.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *"kind cluster 'absent' not present"* ]]
	run ! grep -q '^kind delete' "$STUB_LOG"
}
