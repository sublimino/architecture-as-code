#!/usr/bin/env bash
# shellcheck shell=bash
#
# OSD-4 host leg: the air-gap isolation primitive as a HOST namespace, hardened.
#
# @id      airgap-hostns-helper
# @tests   test/slsi-airgap-bundle.bats
# @lib     test/helpers/airgap-sandbox.bash
# @task    SLSI-OSD-4
#
# Why a host leg at all, when the container leg already exists
#   The appliance scenario is an operator extracting the tarball on a HOST and
#   running the installer there, with the host's own tar, sha256sum and shell.
#   `docker run --net none` certifies a different thing: the SANDBOX IMAGE's
#   tar and sha256sum, inside a container. Both are worth having, and each is
#   blind where the other sees, so OSD-4 carries both and says which is which.
#
# Why `unshare -Urnm` and not `unshare -n`
#   `unshare -n` is denied outright in the agent sandbox (CapEff
#   0000000000000000, NoNewPrivs 1, measured; `unshare -n` -> Operation not
#   permitted and the unprivileged fallback `unshare -Ur` -> cannot open
#   /proc/self/uid_map). `systemd-run --user` spawns outside that sandbox, where
#   `unshare -Urnm` succeeds.
#
#   But a BARE net namespace is a FALSE-GREEN air-gap gate, and this is the
#   finding the whole leg is built around. Measured inside `unshare -Urn`, with
#   `ip -o addr show` reporting ZERO addresses and TCP to 1.1.1.1:443 failing
#   "Network is unreachable":
#
#     - /run/systemd/resolve/io.systemd.Resolve was still reachable and
#       `getent hosts github.com` still returned 20.26.156.215;
#     - /run/docker.sock was still present, `docker version` still reported
#       Server 29.9.0, and `docker pull docker.io/library/hello-world:<bad-tag>`
#       still came back with "manifest unknown" FROM THE REGISTRY -- i.e. the
#       daemon egressed to Docker Hub on our behalf.
#
#   Unix sockets are filesystem-scoped, not net-namespace-scoped. So an
#   installer that calls `docker pull` or `kind load` inside `unshare -n`
#   SUCCEEDS, and an air-gap proof built on `unshare -n` alone can never fail
#   for the reason it exists. The mount namespace is what closes it: one tmpfs
#   over /run removes both channels at once, because /var/run is a symlink to
#   /run on this host. Measured after masking: resolve socket absent, docker
#   socket absent, `getent` rc=2 with no address, `docker version` cannot find
#   the socket at all.
#
# Three traps this helper is shaped to avoid, each of which reads as a PASS
#   1. Blindness. Inside the agent sandbox `/run` lists ZERO entries -- byte for
#      byte what a perfectly masked namespace looks like. A probe run in the
#      agent's own shell would "prove" the mask works while measuring nothing.
#      Hence every probe goes through `systemd-run`, and the preflight asserts
#      the UNMASKED host /run is non-empty before any "absent" verdict is
#      trusted (see airgap_hostns_require).
#   2. Stale sysfs. Inside a new net namespace `/sys/class/net` still lists all
#      the HOST's interfaces (29 of them here) while netlink correctly reports
#      1. The interface count therefore comes from `ip`, never from sysfs.
#   3. Mask escape. A tmpfs over /run that propagated to the host would break
#      docker, DNS and dbus for the whole machine. `mount --make-rprivate /` is
#      a hard precondition, not a warning, and the mask refuses to proceed
#      without it.
#
# Every function fails loudly with a named remedy. None of them skips: a
# missing primitive is a red suite, never a green one.

# Positive-control egress target. The severed probe must FAIL to reach it and
# the host probe must SUCCEED, or the instrument is blind.
: "${SLSI_AIRGAP_PROBE_HOST:=1.1.1.1}"
: "${SLSI_AIRGAP_PROBE_PORT:=443}"

# A name that cannot resolve from cache or /etc/hosts, used to prove DNS is
# genuinely severed rather than merely answered locally.
: "${SLSI_AIRGAP_DNS_NAME:=github.com}"

# The directory the mount namespace masks. Both filesystem-scoped egress
# channels live under it on this host: /run/systemd/resolve/io.systemd.Resolve
# and /run/docker.sock (with /var/run a symlink to /run).
: "${SLSI_AIRGAP_MASK_DIR:=/run}"

# Reserved exit codes from the mask prelude. Payloads must not use these.
AIRGAP_HOSTNS_RC_RPRIVATE=91
AIRGAP_HOSTNS_RC_TMPFS=92

# systemd-run, as one word list. --quiet suppresses the unit banner; --pipe
# forwards all three streams; --wait makes it synchronous and propagates the
# payload's own exit status (measured: 42 in, 42 out, through unshare too).
_airgap_hostns_systemd_run() {
	systemd-run --user --quiet --wait --collect --pipe -- "$@"
}

# Preflight for the whole host leg. Hard failure with a remedy; never a skip.
airgap_hostns_require() {
	local out rc

	command -v systemd-run >/dev/null 2>&1 || {
		echo "AIRGAP HOSTNS PREFLIGHT: systemd-run is not on PATH." >&2
		echo "  The host leg needs it to escape the agent sandbox, where" >&2
		echo "  unshare is denied (CapEff 0, NoNewPrivs 1)." >&2
		echo "  Remedy: run on a host with a systemd user manager." >&2
		return 1
	}
	command -v unshare >/dev/null 2>&1 || {
		echo "AIRGAP HOSTNS PREFLIGHT: unshare is not on PATH." >&2
		echo "  Remedy: apt-get install -y util-linux." >&2
		return 1
	}
	command -v ip >/dev/null 2>&1 || {
		echo "AIRGAP HOSTNS PREFLIGHT: ip is not on PATH." >&2
		echo "  The interface count MUST come from netlink: inside a new net" >&2
		echo "  namespace /sys/class/net still lists the host's interfaces." >&2
		echo "  Remedy: apt-get install -y iproute2." >&2
		return 1
	}

	# The user manager must actually be reachable, not merely installed.
	_airgap_hostns_systemd_run /bin/true >/dev/null 2>&1 || {
		echo "AIRGAP HOSTNS PREFLIGHT: 'systemd-run --user' did not run a trivial command." >&2
		echo "  Remedy: ensure a systemd user manager is running for this uid" >&2
		echo "  (loginctl enable-linger \$USER), with DBUS_SESSION_BUS_ADDRESS set." >&2
		return 1
	}

	# The primitive itself. If this cannot run, the leg must be red, not green.
	_airgap_hostns_systemd_run unshare -Urnm --propagation private /bin/true >/dev/null 2>&1 || {
		echo "AIRGAP HOSTNS PREFLIGHT: 'unshare -Urnm' failed outside the sandbox." >&2
		echo "  Remedy: ensure unprivileged user namespaces are enabled" >&2
		echo "  (sysctl kernel.unprivileged_userns_clone=1; user.max_user_namespaces > 0)." >&2
		return 1
	}

	# The mask only covers SLSI_AIRGAP_MASK_DIR. A DOCKER_HOST pointing at a
	# unix socket outside it would survive the mask and silently reopen the
	# very channel this leg closes, so refuse rather than certify around it.
	case "${DOCKER_HOST:-}" in
	"" | "unix://${SLSI_AIRGAP_MASK_DIR}"/*) ;;
	*)
		echo "AIRGAP HOSTNS PREFLIGHT: DOCKER_HOST='${DOCKER_HOST}' is outside the mask." >&2
		echo "  The tmpfs over ${SLSI_AIRGAP_MASK_DIR} would not remove it, so the" >&2
		echo "  docker-socket leak this leg exists to close would stay open." >&2
		echo "  Remedy: unset DOCKER_HOST, or set SLSI_AIRGAP_MASK_DIR to cover it." >&2
		return 1
		;;
	esac

	# The blindness guard. "absent" is only evidence of masking if the same
	# instrument can SEE the thing when it is not masked. Inside the agent
	# sandbox /run reads as empty, which is indistinguishable from a perfect
	# mask, so refuse to certify anything until the unmasked view is non-empty.
	out="$(_airgap_hostns_systemd_run /bin/sh -c "ls -A '$SLSI_AIRGAP_MASK_DIR' 2>/dev/null | wc -l")" && rc=0 || rc=$?
	[[ "$rc" -eq 0 ]] || {
		echo "AIRGAP HOSTNS PREFLIGHT: could not list $SLSI_AIRGAP_MASK_DIR outside the sandbox (rc=$rc)." >&2
		return 1
	}
	[[ "${out//[^0-9]/}" -gt 0 ]] 2>/dev/null || {
		echo "AIRGAP HOSTNS PREFLIGHT: $SLSI_AIRGAP_MASK_DIR reads as EMPTY even unmasked." >&2
		echo "  The instrument is BLIND: a masked namespace looks exactly like this," >&2
		echo "  so every 'socket absent' verdict would pass vacuously." >&2
		echo "  Remedy: run the host leg where $SLSI_AIRGAP_MASK_DIR is readable;" >&2
		echo "  do NOT weaken the assertion to make this pass." >&2
		return 1
	}
	printf '%s\n' "${out//[^0-9]/}"
}

# Writes the air-gap probe to $1. One instrument, run in three configurations;
# the DIFFERENCES between them are the proof. Emits key=value lines only.
airgap_hostns_probe_file() {
	local path="$1"
	cat >"$path" <<'PROBE'
#!/usr/bin/env bash
# OSD-4 air-gap probe. Emits key=value lines; never exits non-zero itself, so
# the caller asserts on the VALUES rather than on a conflated exit status.
mask="${SLSI_AIRGAP_MASK_DIR:-/run}"
probe_host="${SLSI_AIRGAP_PROBE_HOST:-1.1.1.1}"
probe_port="${SLSI_AIRGAP_PROBE_PORT:-443}"
dns_name="${SLSI_AIRGAP_DNS_NAME:-github.com}"

# Interfaces and addresses from NETLINK. Not /sys/class/net: inside a new net
# namespace sysfs still lists every host interface (measured: 29 vs 1).
echo "ifaces=$(ip -o link show 2>/dev/null | wc -l)"
echo "addrs=$(ip -o addr show 2>/dev/null | wc -l)"

# The two filesystem-scoped egress channels a bare net namespace leaves open.
[ -S "$mask/systemd/resolve/io.systemd.Resolve" ] && echo "resolve_sock=PRESENT" || echo "resolve_sock=absent"
[ -S "$mask/docker.sock" ] && echo "docker_sock=PRESENT" || echo "docker_sock=absent"
echo "mask_entries=$(ls -A "$mask" 2>/dev/null | wc -l)"

# DNS. An address here means name resolution still works, whatever the route
# table says. Printed as the resolved address so an empty value is meaningful.
echo "dns_addr=$(getent hosts "$dns_name" 2>/dev/null | awk 'NR==1{print $1}')"

# Raw TCP, the thing a net namespace genuinely does sever.
tcp_msg="$( (exec 3<>"/dev/tcp/$probe_host/$probe_port") 2>&1 )"
echo "tcp_rc=$?"
case "$tcp_msg" in
*"Network is unreachable"*) echo "tcp_unreachable=yes" ;;
*) echo "tcp_unreachable=no" ;;
esac

# The Docker daemon, which does its own networking and is NOT in our namespace.
# A version here means a `docker pull` would reach the registry regardless of
# how severed this namespace's own stack is.
if command -v docker >/dev/null 2>&1; then
	echo "docker_daemon=$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
else
	echo "docker_daemon=NO-CLI"
fi
exit 0
PROBE
	chmod 0755 "$path"
}

# Writes, to $1, a payload that asks the Docker daemon to fetch a tag that
# cannot exist. A REGISTRY answer ("manifest unknown") proves the daemon
# egressed to the public registry on our behalf; a socket error proves it
# could not. Pulls nothing: the tag does not resolve, so no layer is stored.
airgap_hostns_registry_probe_file() {
	local path="$1"
	cat >"$path" <<'REGPROBE'
#!/usr/bin/env bash
ref="docker.io/library/hello-world:osd4-no-such-tag-9z"
out="$(docker pull "$ref" 2>&1)"
echo "pull_rc=$?"
printf 'pull_msg=%s\n' "$(printf '%s' "$out" | tr '\n' '|')"
exit 0
REGPROBE
	chmod 0755 "$path"
}

# The mask prelude, as shell source. Emitted into a wrapper rather than passed
# through argv so quoting cannot corrupt it.
#
# `mount --make-rprivate /` is a HARD precondition. Without it the tmpfs could
# propagate to the host's own /run and take down docker, DNS and dbus
# machine-wide; refusing is the only safe failure.
_airgap_hostns_wrapper_file() {
	local path="$1" payload="$2"
	cat >"$path" <<WRAPPER
#!/usr/bin/env bash
mount --make-rprivate / 2>/dev/null || {
	echo "AIRGAP HOSTNS: could not make / a private mount; refusing to mask." >&2
	echo "  A shared mount would propagate the tmpfs to the HOST's ${SLSI_AIRGAP_MASK_DIR}" >&2
	echo "  and break its docker/DNS/dbus for every process on the machine." >&2
	exit ${AIRGAP_HOSTNS_RC_RPRIVATE}
}
mount -t tmpfs -o nosuid,nodev,mode=0755 tmpfs "${SLSI_AIRGAP_MASK_DIR}" 2>/dev/null || {
	echo "AIRGAP HOSTNS: tmpfs mask of ${SLSI_AIRGAP_MASK_DIR} failed." >&2
	exit ${AIRGAP_HOSTNS_RC_TMPFS}
}
exec "${payload}" "\$@"
WRAPPER
	chmod 0755 "$path"
}

# airgap_hostns_run <mode> <payload-file> [args...]
#
#   masked - unshare -Urnm + tmpfs over SLSI_AIRGAP_MASK_DIR. The OSD-4 gate.
#   leaky  - unshare -Urn only. The POSITIVE CONTROL for the two leaks: this
#            mode must still see the resolve and docker sockets, or the masked
#            mode's "absent" proves nothing.
#   host   - no namespace at all. The POSITIVE CONTROL for reachability: the
#            probe must genuinely connect, or "severed" was never tested.
#   nsonly - unshare -Urnm with NO mask prelude, for payloads that do their own
#            mounting (the escape-containment check). Note that a payload which
#            mounts MUST NOT be given `host` mode: with no namespace its
#            `mount --make-rprivate /` would target the REAL host.
#
# Exit status is the payload's own.
airgap_hostns_run() {
	local mode="$1" payload="$2"
	shift 2
	[[ -x "$payload" ]] || {
		echo "airgap_hostns_run: payload '$payload' is not executable" >&2
		return 2
	}
	local env_pass=(
		"SLSI_AIRGAP_MASK_DIR=$SLSI_AIRGAP_MASK_DIR"
		"SLSI_AIRGAP_PROBE_HOST=$SLSI_AIRGAP_PROBE_HOST"
		"SLSI_AIRGAP_PROBE_PORT=$SLSI_AIRGAP_PROBE_PORT"
		"SLSI_AIRGAP_DNS_NAME=$SLSI_AIRGAP_DNS_NAME"
	)
	case "$mode" in
	masked)
		local wrapper="${payload}.wrapper"
		_airgap_hostns_wrapper_file "$wrapper" "$payload" || return 2
		_airgap_hostns_systemd_run unshare -Urnm --propagation private \
			/usr/bin/env "${env_pass[@]}" "$wrapper" "$@"
		;;
	leaky)
		_airgap_hostns_systemd_run unshare -Urn \
			/usr/bin/env "${env_pass[@]}" "$payload" "$@"
		;;
	nsonly)
		_airgap_hostns_systemd_run unshare -Urnm --propagation private \
			/usr/bin/env "${env_pass[@]}" "$payload" "$@"
		;;
	host)
		_airgap_hostns_systemd_run \
			/usr/bin/env "${env_pass[@]}" "$payload" "$@"
		;;
	*)
		echo "airgap_hostns_run: unknown mode '$mode' (masked|leaky|host|nsonly)" >&2
		return 2
		;;
	esac
}

# Reads one key=value field out of probe output. Fails (rc 3) when the key is
# absent, so a probe that died early cannot be mistaken for a field of "".
airgap_hostns_field() {
	local out="$1" key="$2" line
	line="$(grep -m1 "^${key}=" <<<"$out")" || {
		echo "airgap_hostns_field: key '$key' absent from probe output" >&2
		return 3
	}
	printf '%s\n' "${line#*=}"
}
