#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# scripts/attached-mode-preflight.sh : refuse APPLIANCE_MODE=attached until the
# two centrally issued Secrets are present, and say who issues them.
#
# @id     attached-mode-preflight
# @doc    docs/attached-mode-central-issuance.md
# @spec   docs/EAP/remote-contract.md
# @tests  test/attached-mode-preflight.bats
#
# Usage:
#   APPLIANCE_MODE=hub|attached scripts/attached-mode-preflight.sh
#                                [--namespace NS] [--context CTX] [--kubectl BIN]
#
#   --namespace   where the warden Secrets live. Default inf-signalloom-warden,
#                 the namespace the remote-tenant overlay puts the warden in.
#   --context     kube context of THIS cluster (the appliance's own). Default:
#                 whatever the current kubeconfig selects.
#   --kubectl     the binary to use. Default kubectl, or $KUBECTL.
#
# Exit: 0 nothing required, or every requirement met
#       1 a requirement is missing (the message names which, and who issues it)
#       2 usage, or an APPLIANCE_MODE this script does not know
#
# ── Why this gate exists (OSD-8) ─────────────────────────────────────────────
#
# Decision 8 ships one appliance that selects between two halves. The halves
# are NOT symmetric, and that asymmetry is the whole reason for this file:
#
#   APPLIANCE_MODE=hub       self-provisions. It runs the issuers, so every
#                            credential it needs it can mint.
#   APPLIANCE_MODE=attached  renders signalloom-warden-overlays/remote-tenant,
#                            whose two key refs are `optional: false`. BOTH
#                            Secrets are minted on the VENDOR's CENTRAL cluster
#                            and the overlay's own header records that they are
#                            "never issued here". A design partner therefore
#                            CANNOT generate them, with or without this script.
#
# Without the gate, selecting `attached` without them produces a DaemonSet
# whose pods sit in ContainerCreating with `secret "…" not found` buried in a
# pod event — a reconcile-depth failure that reads as a broken appliance rather
# than as a missing out-of-band step. With it, the selection fails in a second
# and names the two objects, the two minting commands, and the fact that the
# commands belong to somebody else.
#
# This script is READ-ONLY. It never mints, applies, patches or deletes, and it
# never prints a secret value — only whether one is present and non-empty.
set -eo pipefail

NAMESPACE="inf-signalloom-warden"
CONTEXT=""
KUBECTL="${KUBECTL:-kubectl}"
PREREQ_DOC="docs/attached-mode-central-issuance.md"

# The two required Secrets, as the remote-tenant overlay reads them. Each row is
#   <secret name>|<key inside it>|<what mints it, centrally>
REQUIRED=(
	"signalloom-warden-ingest-token|token|scripts/sldc-ingest-bearer.sh --context \$CENTRAL --key signalloom-warden --emit-remote-secrets DIR"
	"signalloom-warden-fleet-key|token|scripts/fleet-manager-caller-keys.sh --context \$CENTRAL --emit-remote-secrets DIR"
)
# Optional, by deliberate design: a hub serving a publicly trusted certificate
# needs no bundle, and the warden must fall back to the system roots rather than
# refuse to start. A warning, never a failure.
OPTIONAL_SECRET="signalloom-hub-ca"
OPTIONAL_KEY="ca.pem"

say() { printf '%s\n' "$*"; }
usage() { sed -n '/^# Usage:/,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() {
	printf 'attached-mode-preflight: %s\n' "$1" >&2
	exit "${2:-1}"
}

# secret_value NAME KEY — base64 value of one key, or empty. Never echoed to the
# operator; only its emptiness is reported.
secret_value() {
	local args=(get secret "$1" -o "jsonpath={.data.$2}")
	[ -n "${CONTEXT}" ] && args=(--context "${CONTEXT}" "${args[@]}")
	"${KUBECTL}" "${args[@]}" -n "${NAMESPACE}" 2>/dev/null || true
}

check_attached() {
	local missing=0 row name key minter value

	say "attached-mode-preflight: APPLIANCE_MODE=attached, namespace ${NAMESPACE}"
	for row in "${REQUIRED[@]}"; do
		IFS='|' read -r name key minter <<<"${row}"
		value="$(secret_value "${name}" "${key}")"
		if [ -n "${value}" ]; then
			say "  OK      ${name} (key ${key}) is present"
			continue
		fi
		missing=$((missing + 1))
		say "  MISSING ${name} (key ${key})"
		say "          minted centrally by: ${minter}"
	done

	value="$(secret_value "${OPTIONAL_SECRET}" "${OPTIONAL_KEY}")"
	if [ -n "${value}" ]; then
		say "  OK      ${OPTIONAL_SECRET} (key ${OPTIONAL_KEY}) is present"
	else
		say "  WARN    ${OPTIONAL_SECRET} (key ${OPTIONAL_KEY}) is absent; the warden will"
		say "          fall back to the system root pool. Required only when the hub"
		say "          gateway serves a certificate no node already trusts."
	fi

	if [ "${missing}" -eq 0 ]; then
		say "attached-mode-preflight: both required Secrets are in place"
		return 0
	fi

	say ""
	say "attached-mode-preflight: ${missing} required Secret(s) missing."
	say "  This appliance CANNOT mint them. Both are issued on the vendor's"
	say "  central cluster and are never issued locally: the ingest token is a"
	say "  signal-ingest named key, the fleet key is a fleet-manager caller key"
	say "  (caller warden, scope report). Ask the vendor operator to run the"
	say "  command(s) above on the central cluster and to hand you the two"
	say "  Secret manifests over the agreed secure channel, then apply them to"
	say "  ${NAMESPACE} BEFORE selecting attached mode."
	say "  Full prerequisite: ${PREREQ_DOC}"
	return 1
}

main() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--namespace)
			NAMESPACE="${2:?--namespace needs a value}"
			shift 2
			;;
		--context)
			CONTEXT="${2:?--context needs a value}"
			shift 2
			;;
		--kubectl)
			KUBECTL="${2:?--kubectl needs a value}"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*) die "unknown option: $1
$(usage)" 2 ;;
		esac
	done

	case "${APPLIANCE_MODE:-hub}" in
	hub)
		say "attached-mode-preflight: APPLIANCE_MODE=hub; no central issuance required (hub mode self-provisions)"
		exit 0
		;;
	attached)
		check_attached || exit 1
		exit 0
		;;
	*) die "unrecognised APPLIANCE_MODE: ${APPLIANCE_MODE}; expected hub or attached" 2 ;;
	esac
}

main "$@"
