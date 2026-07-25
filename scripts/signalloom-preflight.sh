#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
	printf 'Usage: %s check PLATFORM_ROOT OSRAMP_ROOT DEMO_ROOT D2_BAO_ROOT\n' "$0"
	printf '       %s help PLATFORM_ROOT OSRAMP_ROOT DEMO_ROOT D2_BAO_ROOT INTEGRATION_BRANCH\n' "$0"
}

die() {
	printf 'signalloom-check: %s\n' "$1" >&2
	exit 1
}

check_root() {
	local name="$1"
	local root="$2"

	[[ -d "$root" ]] || die "missing git root: ${name}=${root}"
	git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1 || die "not a git root: ${name}=${root}"
}

check_path() {
	local name="$1"
	local path="$2"

	[[ -e "$path" ]] || die "missing required path: ${name}=${path}"
}

check() {
	[[ "$#" -eq 4 ]] || { usage >&2; exit 2; }

	local platform_root="$1"
	local osramp_root="$2"
	local demo_root="$3"
	local d2_bao_root="$4"

	check_root SIGNALLOOM_PLATFORM_ROOT "$platform_root"
	check_root OSRAMP_PRODUCT_ROOT "$osramp_root"
	check_root OSRAMP_DEMO_ROOT "$demo_root"
	check_root D2_BAO_ROOT "$d2_bao_root"

	check_path discovery-portal "${platform_root}/services/discovery-portal"
	check_path platform-terraform "${platform_root}/infrastructure/terraform"
	check_path demo-apps "${demo_root}/d2-osramp-apps"
	check_path demo-fleet "${demo_root}/d2-osramp-fleet"
	check_path demo-infra "${demo_root}/d2-infra"
	check_path d2-bao-infra "${d2_bao_root}/d2-bao-infra"

	printf 'Signal Loom preflight passed: four git roots and six required paths are present.\n'
}

show_help() {
	[[ "$#" -eq 5 ]] || { usage >&2; exit 2; }

	printf 'Signal Loom demo command surface\n\n'
	printf 'Resolved source roots:\n'
	printf '  SIGNALLOOM_PLATFORM_ROOT=%s\n' "$1"
	printf '  OSRAMP_PRODUCT_ROOT=%s\n' "$2"
	printf '  OSRAMP_DEMO_ROOT=%s\n' "$3"
	printf '  D2_BAO_ROOT=%s\n' "$4"
	printf '\nIntegration branch expectation: %s\n' "$5"
	printf '\nSafe staged sequence (no deployment):\n'
	printf '  1. make signalloom-check\n'
	printf '  2. make signalloom-help\n'
	printf '  3. Review the deployment profiles before adding any up/down commands.\n'
}

[[ "$#" -ge 1 ]] || { usage >&2; exit 2; }
case "$1" in
	check) check "${@:2}" ;;
	help) show_help "${@:2}" ;;
	*) usage >&2; exit 2 ;;
esac
