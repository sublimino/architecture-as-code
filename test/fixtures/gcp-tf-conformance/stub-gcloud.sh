#!/usr/bin/env bash
#
# stub-gcloud.sh -- a gcloud that answers from disk.
#
# Copied onto PATH as `gcloud` by test/terraform-conformance-harness.bats. It
# never touches a network, never reads a credential, and records every
# invocation so the suite can assert that the scripts under test made only
# read-only calls -- an assertion about what actually ran, not about what the
# source appears to do.
#
# Environment:
#   STUB_FIXTURE_OVERLAY  searched first; holds only a scenario's differences
#   STUB_FIXTURE_BASE     searched second; the compliant estate
#   STUB_GCLOUD_LOG       append the full argv of every call here
#   STUB_GCLOUD_FAIL      when 1, every call fails -- the "could not look" case
set -uo pipefail

if [ -n "${STUB_GCLOUD_LOG:-}" ]; then
  printf '%s\n' "$*" >>"${STUB_GCLOUD_LOG}"
fi

if [ "${STUB_GCLOUD_FAIL:-0}" = "1" ]; then
  printf 'ERROR: (gcloud) PERMISSION_DENIED: stub is in fail mode\n' >&2
  exit 1
fi

# Slug the call: every non-flag token up to and including the first read verb.
# Stopping at the verb keeps the slug stable when a resource name or a --project
# changes, which is what lets one fixture serve a check that iterates.
slug=""
for arg in "$@"; do
  case "$arg" in
    -*) continue ;;
  esac
  if [ -z "$slug" ]; then slug="$arg"; else slug="${slug}-${arg}"; fi
  case "$arg" in
    describe | list | version | get-iam-policy) break ;;
  esac
done

if [ -z "$slug" ]; then
  printf 'ERROR: (gcloud) stub could not slug: %s\n' "$*" >&2
  exit 1
fi

for dir in "${STUB_FIXTURE_OVERLAY:-}" "${STUB_FIXTURE_BASE:-}"; do
  [ -n "$dir" ] || continue
  file="${dir}/${slug}.json"
  [ -f "$file" ] || continue
  # A fixture that is only the sentinel means "this call fails" -- how a deleted
  # state bucket and a denied API are expressed without deleting a file.
  if [ "$(head -c 15 "$file")" = "__STUB_ERROR__" ]; then
    printf 'ERROR: (gcloud) NOT_FOUND: stub error fixture for %s\n' "$slug" >&2
    exit 1
  fi
  cat "$file"
  exit 0
done

printf 'ERROR: (gcloud) no stub fixture for slug: %s\n' "$slug" >&2
exit 1
