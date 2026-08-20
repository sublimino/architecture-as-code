#!/usr/bin/env bash
#
# Shared helper for test/terraform-tailscale-serve-boot.bats.
#
# ─── test/helpers/, never test/lib/ ─────────────────────────────────────────
#
# `~/.gitignore_global` carries a bare `lib` pattern, which matches `test/lib`
# at any depth. A helper placed there works perfectly on the machine that wrote
# it, is never committed, and `git status` reports nothing to commit — so the
# suite goes green locally and fails for everyone else. Same reason
# test/helpers/ts-node-name.bash lives here.
#
# ─── Extraction, never reimplementation ─────────────────────────────────────
#
# demo-vm.sh is `set -euo pipefail`, declares its paths `readonly`, and calls
# `main` at the bottom, so sourcing it would attempt a real bootstrap. The
# function under test is therefore EXTRACTED verbatim from the real file at test
# time. A hand-copied install_tailscale_serve_unit in this helper would be a
# second implementation that passes its own tests forever while the real one
# rots — "green tests tested the wrong artifact", which this repo has shipped.
#
# The readonly paths are INJECTED rather than extracted, because the real values
# are absolute /etc and /usr/local/sbin paths. A test that wrote there would
# need root and would damage the developer's own machine.

# ts_serve_harness <out-file> <startup-script>
#
# Requires, from the caller's environment:
#   TS_SERVE_UNIT          where the unit should be written
#   TS_SERVE_HELPER        where the helper should be written
#   STUB_SYSTEMCTL_LOG     file the systemctl stub appends its argv to
ts_serve_harness() {
	local out="$1" src="$2"

	: >"$out"
	cat >>"$out" <<-'PREAMBLE'
		LOG_TAG=test-ts-serve
		log() { echo "[${LOG_TAG}] $*"; }
		# metadata_attr is the seam every test drives. STUB_APP_PORT unset means
		# the attribute is ABSENT, which is a distinct case from empty and is
		# tested separately.
		metadata_attr() {
		  case "$1" in
		    signalloom-app-port)
		      [ -n "${STUB_APP_PORT+set}" ] || return 1
		      printf '%s' "${STUB_APP_PORT}"
		      ;;
		    *) return 1 ;;
		  esac
		}
	PREAMBLE

	printf 'TS_SERVE_UNIT=%s\n' "${TS_SERVE_UNIT:?ts_serve_harness needs TS_SERVE_UNIT}" >>"$out"
	printf 'TS_SERVE_HELPER=%s\n' "${TS_SERVE_HELPER:?ts_serve_harness needs TS_SERVE_HELPER}" >>"$out"

	# Taken from the REAL file rather than injected, because unlike the paths
	# these are values the startup script is entitled to decide and a test that
	# hardcoded them would not notice them changing.
	local port wait_s
	port="$(sed -n 's/^readonly TS_SERVE_HTTPS_PORT="\([0-9]*\)".*/\1/p' "$src" | head -n1)"
	wait_s="$(sed -n 's/^readonly TS_SERVE_WAIT_SECONDS="\([0-9]*\)".*/\1/p' "$src" | head -n1)"
	if [ -z "$port" ] || [ -z "$wait_s" ]; then
		echo "EXTRACTION FAILED: TS_SERVE_HTTPS_PORT / TS_SERVE_WAIT_SECONDS not found in ${src}." >&2
		echo "They were renamed or their declaration formatting changed." >&2
		echo "This helper is stale — fix it rather than the tests it breaks." >&2
		return 1
	fi
	printf 'TS_SERVE_HTTPS_PORT=%s\n' "$port" >>"$out"
	printf 'TS_SERVE_WAIT_SECONDS=%s\n' "$wait_s" >>"$out"
	printf 'TS_SERVE_UNIT_NAME=%s\n' \
		"$(sed -n 's/^readonly TS_SERVE_UNIT_NAME="\([^"]*\)".*/\1/p' "$src" | head -n1)" >>"$out"

	# The function itself, verbatim. An awk range that stops matching after a
	# refactor produces an EMPTY harness, and every test then fails with
	# "command not found" — which reads as the function having been deleted
	# rather than as the extractor being stale. Checked, so it says so instead.
	awk '
		$0 == "install_tailscale_serve_unit() {" { inside = 1 }
		inside                                   { print }
		inside && $0 == "}"                      { inside = 0 }
	' "$src" >>"$out.fn"

	if [ ! -s "$out.fn" ]; then
		echo "EXTRACTION FAILED: install_tailscale_serve_unit() not found in ${src}." >&2
		echo "The function was renamed or deleted, or its formatting changed." >&2
		echo "This helper is stale — fix it rather than the tests it breaks." >&2
		rm -f "$out.fn"
		return 1
	fi
	cat "$out.fn" >>"$out"
	rm -f "$out.fn"

	bash -n "$out" || {
		echo "the extracted harness does not parse — extraction produced a partial function" >&2
		return 1
	}
}

# A `systemctl` on PATH that records what it was asked to do and succeeds.
#
# Recording rather than merely succeeding is what lets a test assert that the
# unit was ENABLED as well as started. An enabled-but-never-started oneshot and
# a started-but-never-enabled one are different bugs — the first serves nothing
# until a reboot, the second serves now and never again — and a stub that
# collapsed them could not tell the tests apart.
ts_serve_stub_systemctl() {
	local dir="$1"
	cat >"${dir}/systemctl" <<-STUB
		#!/usr/bin/env bash
		printf '%s\n' "\$*" >>"\${STUB_SYSTEMCTL_LOG:-/dev/null}"
		exit "\${STUB_SYSTEMCTL_RC:-0}"
	STUB
	chmod +x "${dir}/systemctl"
}
