#!/usr/bin/env bash
#
# stub-curl.sh -- a curl that returns a status code from the environment.
#
# The script under test calls curl exactly once, with -o /dev/null and
# -w '%{http_code}', so the whole contract is "print a status code on stdout".
#
# Environment:
#   STUB_CURL_CODE  the code to print. Default 200. The literal value 000 is
#                   what real curl prints when it could not connect at all.
#   STUB_CURL_LOG   append the full argv of every call here
set -uo pipefail

if [ -n "${STUB_CURL_LOG:-}" ]; then
  printf '%s\n' "$*" >>"${STUB_CURL_LOG}"
fi

printf '%s' "${STUB_CURL_CODE:-200}"
