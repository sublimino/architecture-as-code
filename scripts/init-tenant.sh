#!/usr/bin/env bash
# ==============================================================================
# init-tenant.sh - SLSI tenant self-initialisation entry point. STUB.
#
# @id        slsi-init-tenant
# @owner     SLSI-P2-1 (cards P2-1..P2-4, P3-1)
# @governed  proposal-slsi-v0.1.1
# @tests     test/slsi-bundle-osd.bats
# @manifest  MANIFEST.json .installer
#
# THIS SCRIPT INITIALISES NOTHING. It is the slot, not the installer.
#
# Why it exists at all. Until now the appliance manifest declared
# `installer.path: scripts/init-tenant.sh` for a file that was absent from the
# working tree, from every local branch, and from every commit reachable from
# any ref. A consumer therefore had to infer the state of the whole
# self-initialisation story from a missing file -- and "the file is not there"
# and "I was not allowed to look" produce byte-identical silence. So the slot
# now exists, says plainly what it is, and MANIFEST.json reports both scopes
# (`installer.present` for the bundle payload, `installer.sourcePresent` and
# `installer.sourceStatus` for this file) as measured values.
#
# Why it refuses instead of no-opping. A stub that exits 0 is worse than no
# stub: `./scripts/init-tenant.sh apply && echo provisioned` would print
# "provisioned", and the first caller to wire it into a pipeline would ship a
# tenant that was never initialised, with a green build to prove it. So every
# operational path exits 69 and names its owning card. Nothing can mistake this
# for working, and nothing can mistake the exit code for a transient failure.
#
# What IS implemented, deliberately, because both are honest and neither
# pretends to initialise anything:
#
#   --help   usage, exit 0
#   slot     the machine-readable slot record, exit 0. It is the same record
#            MANIFEST.json carries, and test/slsi-bundle-osd.bats asserts the
#            two agree -- so the artefact's claim about this file and this
#            file's claim about itself cannot drift apart silently.
#
# Modelled on scripts/p3-tenant-preflight.sh (subcommand dispatch, injectable
# boundaries block, JSON on stdout) and scripts/remote-tenant-lab.sh.
# ==============================================================================
set -Eeuo pipefail

# Injectable boundaries (tests set these):
#   INIT_TENANT_REPO   repository root   (default: this script's parent)
INIT_TENANT_REPO="${INIT_TENANT_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# sysexits(3) EX_UNAVAILABLE. Not 1, which reads as "it ran and said no", and
# not 2, which this repository's scripts use for a usage error: an unimplemented
# path is neither. Asserted by test/slsi-bundle-osd.bats.
readonly EX_NOT_IMPLEMENTED=69

readonly SLOT_PATH="scripts/init-tenant.sh"
readonly SLOT_STATUS="pending-p2-1"
readonly SLOT_OWNED_BY="SLSI-P2-1"
readonly SLOT_GOVERNED_BY="proposal-slsi-v0.1.1"

usage() {
	cat <<EOF
init-tenant.sh - SLSI tenant self-initialisation entry point (STUB: initialises nothing)

Usage:
  init-tenant.sh --help          this message
  init-tenant.sh slot            the machine-readable installer slot record (JSON)

Not implemented (each exits ${EX_NOT_IMPLEMENTED}, owned by ${SLOT_OWNED_BY}):
  init-tenant.sh plan            render what initialisation would do
  init-tenant.sh apply           initialise the tenant
  init-tenant.sh verify          verify an initialised tenant
  init-tenant.sh status          report an initialised tenant's state
  init-tenant.sh <anything else>

Repository root: ${INIT_TENANT_REPO}
EOF
}

not_implemented() {
	local what="$1"
	cat >&2 <<EOF
init-tenant.sh: '${what}' is not yet implemented, owned by ${SLOT_OWNED_BY}.

This file is the installer SLOT, not the installer. It initialises nothing, and
it refuses rather than exiting 0 so that no caller can mistake it for working.

  owner      ${SLOT_OWNED_BY} (cards P2-1..P2-4, P3-1)
  governed   ${SLOT_GOVERNED_BY}
  slot state init-tenant.sh slot
EOF
	return "${EX_NOT_IMPLEMENTED}"
}

# The same five fields MANIFEST.json .installer carries for this slot. One
# source of truth, printed, so the two cannot disagree without a test noticing.
slot() {
	local present=false
	# An `if`, not `[ ... ] && present=true`: under `set -e` the AND list's own
	# non-zero status is a trap this repository has paid for before.
	if [ -e "${INIT_TENANT_REPO}/${SLOT_PATH}" ]; then
		present=true
	fi
	cat <<EOF
{
  "path": "${SLOT_PATH}",
  "sourcePresent": ${present},
  "status": "${SLOT_STATUS}",
  "ownedBy": "${SLOT_OWNED_BY}",
  "governedBy": "${SLOT_GOVERNED_BY}",
  "implemented": false,
  "notImplementedExitCode": ${EX_NOT_IMPLEMENTED}
}
EOF
}

# main "$@" and never main "${@:-}": with no arguments $@ is unset, the default
# fires, and the dispatcher below receives one empty-string argument instead of
# none. The no-argument call is the one a caller makes by accident, so it is
# also the one that must be exercised -- it is a test case, not an edge case.
main() {
	if [ "$#" -eq 0 ]; then
		not_implemented "init-tenant.sh with no subcommand"
		return
	fi

	case "$1" in
	-h | --help | help)
		usage
		;;
	slot)
		slot
		;;
	*)
		not_implemented "$1"
		;;
	esac
}

main "$@"
