#!/usr/bin/env bash
# shellcheck shell=bash
#
# Air-gap sandbox helper: the isolation primitive, the egress probe, the
# strace absence-of-attempt instrument and the static egress-site scanner,
# each built so that a caller can pair it with a positive control.
#
# @id      airgap-sandbox-helper
# @tests   test/slsi-airgap-bundle.bats
# @task    SLSI-P1-4 (reusable by SLSI-P2-5)
#
# Why `docker run --pull=never --net none` and not `unshare -n`:
#   `unshare -n true` is denied in this environment (`unshare failed:
#   Operation not permitted`, measured by SLSI-P1-PRE and again by P1-4), so a
#   suite built on it can never run. `--pull=never` is not decoration: without
#   it `docker run --net none <absent-image>` PULLS over the network and then
#   severs it (OSD-4), so an air-gap proof could never fail for the reason it
#   exists. With it, an absent image exits 125 `No such image`.
#
# Every function here fails loudly with a named remedy. None of them skip:
# a missing primitive is a red suite, never a green one.

# The sandbox image. It must already be in the local daemon; this helper will
# not fetch it. GNU coreutils/tar are needed for `sha256sum --strict`.
: "${SLSI_AIRGAP_IMAGE:=debian:trixie-slim}"
# Positive-control egress target (host/port). The severed probe must FAIL to
# reach it and the connected probe must SUCCEED, or the instrument is blind.
: "${SLSI_AIRGAP_PROBE_HOST:=1.1.1.1}"
: "${SLSI_AIRGAP_PROBE_PORT:=443}"

# Container names created by this process, one per line, so teardown removes
# exactly these and nothing else (never `pkill -f`, which matches the harness).
AIRGAP_NAMES_FILE="${AIRGAP_NAMES_FILE:-${BATS_SUITE_TMPDIR:-${TMPDIR:-/tmp}}/airgap-container-names}"
AIRGAP_SEQ=0

airgap_require_docker() {
	command -v docker >/dev/null 2>&1 || {
		echo "AIRGAP PREFLIGHT: docker is not on PATH. The air-gap suite needs" >&2
		echo "  docker as its isolation primitive (unshare -n is denied here)." >&2
		echo "  Remedy: install Docker Engine, or run where it is available." >&2
		return 1
	}
	docker info >/dev/null 2>&1 || {
		echo "AIRGAP PREFLIGHT: docker is on PATH but the daemon is unreachable." >&2
		echo "  Remedy: start the daemon / grant access to its socket." >&2
		return 1
	}
}

# Resolves SLSI_AIRGAP_IMAGE to its local image ID and prints it. Fails, rather
# than pulls, when the image is absent.
airgap_resolve_image() {
	local id
	id="$(docker image inspect --format '{{.Id}}' "$SLSI_AIRGAP_IMAGE" 2>/dev/null)" || id=""
	[[ "$id" =~ ^sha256:[0-9a-f]{64}$ ]] || {
		echo "AIRGAP PREFLIGHT: sandbox image '$SLSI_AIRGAP_IMAGE' is not in the local daemon." >&2
		echo "  This suite never pulls. Remedy (with network, once):" >&2
		echo "    docker pull $SLSI_AIRGAP_IMAGE" >&2
		echo "  or point SLSI_AIRGAP_IMAGE at a local image with GNU tar + coreutils." >&2
		return 1
	}
	printf '%s\n' "$id"
}

_airgap_next_name() {
	AIRGAP_SEQ=$((AIRGAP_SEQ + 1))
	local name="slsi-airgap-$$-${BATS_TEST_NUMBER:-0}-${AIRGAP_SEQ}"
	printf '%s\n' "$name" >>"$AIRGAP_NAMES_FILE"
	printf '%s\n' "$name"
}

# airgap_run <net-mode> <image> [docker-args...] -- <sh -c script>
#   net-mode: "severed" adds --net none; "connected" uses the default network.
# Runs as the calling uid/gid so bind-mounted output stays removable.
airgap_run() {
	local mode="$1" image="$2"
	shift 2
	local args=() name
	while [[ $# -gt 0 && "$1" != "--" ]]; do
		args+=("$1")
		shift
	done
	[[ "${1:-}" == "--" ]] || { echo "airgap_run: missing -- before the script" >&2; return 2; }
	shift
	name="$(_airgap_next_name)"
	case "$mode" in
	severed) args+=(--net none) ;;
	connected) ;;
	*) echo "airgap_run: unknown mode '$mode'" >&2; return 2 ;;
	esac
	docker run --rm --pull=never --name "$name" --user "$(id -u):$(id -g)" \
		"${args[@]}" "$image" sh -c "$1"
}

# The egress probe: a TCP connect via bash's /dev/tcp. Exit 0 = connected.
airgap_probe_script() {
	printf 'exec 3<>/dev/tcp/%s/%s && echo PROBE-CONNECTED' \
		"$SLSI_AIRGAP_PROBE_HOST" "$SLSI_AIRGAP_PROBE_PORT"
}

# Removes every container this process named. Idempotent.
airgap_cleanup_containers() {
	[[ -f "$AIRGAP_NAMES_FILE" ]] || return 0
	local n
	while IFS= read -r n; do
		[[ -n "$n" ]] && docker rm -f "$n" >/dev/null 2>&1 || true
	done <"$AIRGAP_NAMES_FILE"
	: >"$AIRGAP_NAMES_FILE"
}

# airgap_strace <logfile> <cmd...>
# Runs cmd under strace, following forks, recording every socket-address-taking
# syscall. Returns cmd's own exit status.
airgap_strace() {
	local log="$1"
	shift
	command -v strace >/dev/null 2>&1 || {
		echo "AIRGAP PREFLIGHT: strace is not installed; the absence-of-attempt leg cannot run." >&2
		echo "  Remedy: apt-get install -y strace (host package; never fetched by this suite)." >&2
		return 127
	}
	# --seccomp-bpf stops the tracee only on the traced syscalls; without it
	# every read() of a multi-GB archive is a ptrace round trip.
	strace -f --seccomp-bpf -qq -e trace=connect,sendto,sendmsg,sendmmsg \
		-e signal=none -o "$log" "$@"
}

# Prints every recorded AF_INET/AF_INET6 address that is not loopback.
# One line per attempt; empty output = zero non-loopback attempts.
airgap_nonloopback_attempts() {
	local log="$1"
	[[ -f "$log" ]] || { echo "airgap_nonloopback_attempts: no strace log at $log" >&2; return 2; }
	grep -E 'sa_family=AF_INET6?' "$log" |
		grep -vE 'inet_addr\("127\.|inet_pton\(AF_INET6, "::1"|"::ffff:127\.' || true
}

# Prints file:line:match for every egress-capable command in the scripts under
# a directory. Scripts are *.sh, *.bash and any file whose first line is a
# shell shebang; large binary payloads are never read.
AIRGAP_EGRESS_PATTERN='(^|[^A-Za-z0-9_-])(curl|wget|crane|skopeo|apt-get|apt|dnf|yum|apk add|brew|pip3? install|go install|go get|npm install|bun install|git (clone|fetch|pull)|docker (pull|login)|nc|ncat|socat)([^A-Za-z0-9_-]|$)'

# Prints every shell script under a directory, one path per line.
airgap_script_files() {
	local dir="$1" f first
	while IFS= read -r -d '' f; do
		case "$f" in
		*.sh | *.bash) ;;
		*)
			first="$(head -c 64 "$f" 2>/dev/null | head -n 1 | tr -d '\0')" || first=""
			[[ "$first" =~ ^#!.*(ba)?sh ]] || continue
			;;
		esac
		printf '%s\n' "$f"
	# -size -1048576c, NOT -size -1M: GNU find rounds sizes UP to whole units, so
	# -1M matches only empty files and the scanner would read nothing at all.
	done < <(find "$dir" -type f -size -1048576c ! -path '*/blobs/*' -print0)
}

airgap_egress_sites() {
	local f
	while IFS= read -r f; do
		# Comment lines and echo/printf remedy text name tools without running them.
		grep -HnE "$AIRGAP_EGRESS_PATTERN" "$f" |
			grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|echo[[:space:]]|printf[[:space:]])' || true
	done < <(airgap_script_files "$1")
}

# Prints every image reference in the tree that carries no @sha256 digest:
# YAML `image:` fields under fleet/ and infra/, and the default image a
# Decision 10 wrapper falls back to. Sorted, unique.
airgap_digestless_refs() {
	local root="$1"
	{
		grep -rhoE '^[[:space:]]*(-[[:space:]]+)?image:[[:space:]]*["'"'"']?[^"'"'"'[:space:]]+' \
			"$root/fleet" "$root/infra" 2>/dev/null |
			sed -E 's/^[[:space:]]*(-[[:space:]]+)?image:[[:space:]]*["'"'"']?//' || true
		grep -rhoE 'SLSI_UTILITY_IMAGE:-[^}"]+' "$root/bin" 2>/dev/null |
			sed 's/^SLSI_UTILITY_IMAGE:-//' || true
	} | grep -vE '@sha256:[0-9a-f]{64}$' | LC_ALL=C sort -u || true
}

# The entry-count gate. `sha256sum -c` silently skips a `#` line even under
# --strict (coreutils 9.7, measured), so "rc=0" alone does not mean every line
# was checked. This passes only when the number of OK lines equals the number
# of non-blank manifest lines. Run it from the directory the paths are
# relative to. Prints a reason on failure.
airgap_seal_gate() {
	local manifest="$1" out rc entries oks
	entries="$(grep -cvE '^[[:space:]]*$' "$manifest")" || entries=0
	out="$(sha256sum -c --strict "$manifest" 2>&1)" && rc=0 || rc=$?
	oks="$(grep -c ': OK$' <<<"$out")" || oks=0
	if [[ "$rc" -ne 0 ]]; then
		printf 'SEAL: sha256sum rc=%s\n%s\n' "$rc" "$(grep -v ': OK$' <<<"$out" | head -n 5)"
		return 1
	fi
	if [[ "$entries" -eq 0 || "$oks" -ne "$entries" ]]; then
		printf 'SEAL: entry count mismatch: %s verified OK of %s manifest lines\n' "$oks" "$entries"
		return 1
	fi
	printf 'SEAL: %s of %s entries OK\n' "$oks" "$entries"
}
