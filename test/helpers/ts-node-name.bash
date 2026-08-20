#!/usr/bin/env bash
#
# Shared helper for test/terraform-ts-stable-node-name.bats.
#
# ─── test/helpers/, never test/lib/ ─────────────────────────────────────────
#
# `~/.gitignore_global` carries a bare `lib` pattern, which matches `test/lib`
# at any depth. A helper placed there works perfectly on the machine that wrote
# it, is never committed, and `git status` reports nothing to commit — so the
# suite goes green locally and fails for everyone else with a missing-file
# error that names a path the author can see on disk. This directory is the
# repo's established home for shared bats helpers for that reason.
#
# ─── What this does, and why it is not a copy ───────────────────────────────
#
# demo-vm.sh runs as a GCE startup script: it is `set -euo pipefail`, it calls
# `main` at the bottom, and sourcing it would attempt an actual bootstrap. So
# the functions under test are EXTRACTED from the real file at test time and
# sourced into a harness with a stub `tailscale` on PATH.
#
# Extraction, not reimplementation, is the point. A hand-copied version of
# assert_tailscale_node_name in this file would be a second implementation that
# passes its own tests forever while the real one rots — the exact shape of
# "green tests tested the wrong artifact". Every byte under test here comes out
# of terraform/modules/compute/startup/demo-vm.sh.

# Build a sourceable harness containing the three name-assertion functions,
# verbatim, from the real startup script.
#
# Writes the harness to $1. Fails loudly if any function did not extract: an
# awk range that stops matching after a refactor produces an EMPTY harness, and
# an empty harness makes every test below fail with "command not found" — which
# reads as the function being deleted rather than as the extractor being stale.
# Checking here turns that into one clear message.
ts_name_harness() {
	local out="$1" src="$2" fn

	: >"$out"
	cat >>"$out" <<-'PREAMBLE'
		LOG_TAG=test-ts-name
		log() { echo "[${LOG_TAG}] $*"; }
	PREAMBLE

	# TS_NAME_MARKER is injected by the caller rather than taken from the real
	# file, because the real value is an absolute /var/lib path. A test that
	# wrote there would need root and would corrupt the developer's own machine.
	printf 'TS_NAME_MARKER=%s\n' "${TS_NAME_MARKER:?ts_name_harness needs TS_NAME_MARKER}" >>"$out"

	for fn in tailscale_self_dnsname assert_tailscale_node_name write_ts_name_marker; do
		awk -v f="$fn" '
			$0 == f "() {" { inside = 1 }
			inside        { print }
			inside && $0 == "}" { inside = 0 }
		' "$src" >>"$out.fn"

		if [ ! -s "$out.fn" ]; then
			echo "EXTRACTION FAILED: ${fn}() not found in ${src}." >&2
			echo "The function was renamed or deleted, or its formatting changed." >&2
			echo "This helper is stale — fix it rather than the tests it breaks." >&2
			return 1
		fi
		cat "$out.fn" >>"$out"
		: >"$out.fn"
	done
	rm -f "$out.fn"

	# Belt and braces: the harness must actually parse. Without this a partial
	# extraction surfaces as a confusing failure inside whichever test happens
	# to source it first.
	bash -n "$out" || {
		echo "EXTRACTION FAILED: the assembled harness at ${out} is not valid bash." >&2
		return 1
	}
}

# A stub `tailscale` whose `status --json --peers=false` output the test owns.
#
# Emits a file the test wrote rather than generating anything, so each test
# states the exact tailnet shape it is about and there is no shared default for
# a test to accidentally depend on. Mirrors the convention in
# test/fixtures/gcp-tf-tailscale/stub-tailscale.
#
#   STUB_TS_JSON   file emitted for `status --json --peers=false`
#   STUB_TS_DOWN   1 => the command fails and prints nothing, which is what a
#                  stopped or logged-out tailscaled does
ts_name_stub_tailscale() {
	local dir="$1"
	mkdir -p "$dir"
	cat >"${dir}/tailscale" <<-'STUB'
		#!/usr/bin/env bash
		if [ "${STUB_TS_DOWN:-0}" = "1" ]; then exit 1; fi
		case "$*" in
		  "status --json --peers=false")
		    [ -f "${STUB_TS_JSON:-}" ] || exit 1
		    cat "${STUB_TS_JSON}"
		    exit 0
		    ;;
		esac
		exit 0
	STUB
	chmod +x "${dir}/tailscale"
}

# A `tailscale status` document with one Self node carrying $1 as its DNSName.
#
# Written as a literal rather than through jq: the thing under test is a
# grep/sed extraction over this exact text shape, so generating it with a JSON
# tool would test the two against each other rather than against the format the
# daemon actually emits.
ts_name_status_json() {
	printf '{"Version":"1.80.0","BackendState":"Running","Self":{"ID":"n1","HostName":"%s","DNSName":"%s","TailscaleIPs":["100.64.0.1"],"Online":true}}\n' \
		"${2:-node}" "$1"
}
