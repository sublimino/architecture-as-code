#!/bin/bats

load 'test_helper/bats-assert/load'

load "lib/detik"

load "lib/utils"
load "lib/linter"

HOST="${HOST:-172.17.0.2:8080}"
UUID="${UUID:-$(uuidgen)}"

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
