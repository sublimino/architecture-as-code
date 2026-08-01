#!/bin/bats

load 'test_helper/bats-assert/load'

load "lib/detik"

load "lib/utils"
load "lib/linter"

HOST="${HOST:-172.17.0.2:8080}"
UUID="${UUID:-$(uuidgen)}"

# --- Deployment guards ---
#
# Mirrors the SKIP semantics of scripts/acceptance-test.sh:start_port_forward —
# a dependency that was never deployed is a skip, not a failure, so the suite
# stays runnable against any subset of the D2 slices.
#
# The guards check EXISTENCE only. A slice that is deployed but unhealthy still
# runs its assertions and still fails, which is the point: skips must never
# stand in for a passing test.

KUBECTL_GUARD_TIMEOUT="${KUBECTL_GUARD_TIMEOUT:-10s}"

# `version` is served to system:public-info-viewer, so this probes reachability
# without needing cluster-scoped RBAC. `get nodes` would 403 on a namespaced
# kubeconfig and skip the whole suite against a perfectly healthy cluster.
require-cluster() {
	command kubectl --request-timeout="${KUBECTL_GUARD_TIMEOUT}" version -o json >/dev/null 2>&1 \
		|| skip "no reachable Kubernetes cluster"
}

require-k8s() {
	local KIND="$1"
	local NAME="$2"
	local NAMESPACE="${3:-}"
	local ARGS=(--request-timeout="${KUBECTL_GUARD_TIMEOUT}" get "${KIND}" "${NAME}")
	if [[ -n "${NAMESPACE}" ]]; then
		ARGS+=(--namespace "${NAMESPACE}")
	fi
	command kubectl "${ARGS[@]}" >/dev/null 2>&1 \
		|| skip "${KIND}/${NAME}${NAMESPACE:+ in ${NAMESPACE}} not deployed"
}

# Slice-level guard: the shared preconditions every osramp-apps test needs.
#
# Guards name DECLARATIVE objects only — Namespace, Service, Deployment — because
# Flux keeps those reconciled whether or not the workload behind them is healthy.
# Guarding a runtime object (a Pod) would skip exactly when a pod has crashed,
# been evicted, or failed to pull, which is the breakage the suite exists to catch.
# `postgres` in particular is a bare Pod, so it is never recreated after eviction;
# its Service is the correct existence signal.
require-osramp-apps() {
	require-cluster
	require-k8s namespace frontend
	require-k8s namespace backend
	require-k8s service nats backend
}

# ---

try() {
	try-limit 0 "${@}"
}

try-slow-backoff () {
    _TRY_LIMIT_SLEEP=1;
    _TRY_LIMIT_BACKOFF=15;
    try-limit 0 "${@}"
}

try-limit() {
	local LIMIT=$1
	local COUNT=1
	local RETURN_CODE
	shift
	local COMMAND="${@:-}"
	if [[ "${COMMAND}" == "" ]]; then
		echo "At least two arguments required (limit, command)" 1>&2
		return 1
	fi
	function _try-limit-output() {
		printf "\n$(date) (${COUNT}): %s - " "${COMMAND}" 1>&2
	}
	echo "Limit: ${LIMIT}. Trying command: ${COMMAND}"
	COLOUR_RESET=$(tput sgr0 :-"" 2>/dev/null)
	COLOUR_RED=$(tput setaf 1 :-"" 2>/dev/null)
	_try-limit-output
	until echo "${COMMAND}" | source /dev/stdin; do
		RETURN_CODE=$?
		echo "Return code: ${RETURN_CODE}"
		if [[ "${LIMIT}" -gt 0 && "${COUNT}" -ge "${LIMIT}" ]]; then
			printf "\n%sFailed \`%s\` after %s iterations%s\n" "${COLOUR_RED}" "${COMMAND}" "${COUNT}" "${COLOUR_RESET}" 1>&2;
			return 1
		fi
		COUNT=$((COUNT + 1))
		_try-limit-output
		if [[ "${_TRY_LIMIT_BACKOFF:-}" != "" ]]; then
			sleep $(((COUNT * _TRY_LIMIT_BACKOFF) / 10))
		else
			sleep ${_TRY_LIMIT_SLEEP:-0.3}
		fi
	done
	RETURN_CODE=$?
	if [[ "${COUNT}" == 1 ]]; then
		echo
	fi
	echo "${COLOUR_RED}Completed \`${COMMAND}\` after ${COUNT} iterations${COLOUR_RESET}" 1>&2
	unset _TRY_LIMIT_SLEEP _TRY_LIMIT_BACKOFF
	return ${RETURN_CODE}
}

colour-strip() {
  sed "s,\x1B\[[0-9;]*[a-zA-Z],,g"
}
