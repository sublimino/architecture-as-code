#!/usr/bin/env bash
#
# stub-gcloud.sh -- a gcloud that answers from disk, for preserve-check.sh.
#
# Copied onto PATH as `gcloud` by test/terraform-preserve-guards.bats. It never
# touches a network, never reads a credential, and records every invocation so
# the suite can assert on what actually ran rather than on what the source
# appears to do.
#
# WHY THIS IS NOT test/fixtures/gcp-tf-conformance/stub-gcloud.sh. That stub
# slugs a call on the verb and stops, which is right for conformance.sh: one
# `compute instances list` per project, one answer. preserve-check.sh reads TWO
# buckets in the same run and has to be able to say "the state bucket is gone
# and the audit bucket is fine". A verb-only slug maps both to
# `storage-buckets-describe.json`, so every scenario would have to break both
# buckets at once and the per-bucket verdicts would never be exercised
# separately. This slug therefore carries the resource identity as well.
#
# Environment:
#   STUB_FIXTURE_OVERLAY  searched first; holds only a scenario's differences
#   STUB_FIXTURE_BASE     searched second; the intact estate
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

# Slug: every non-flag token up to and including the first read verb, then the
# single positional that follows it -- the resource name. Flag VALUES are
# skipped along with their flags, so `--project X` never lands in the slug and
# one fixture keeps serving a call whose project changes.
slug=""
verb_seen=0
resource=""
skip_next=0
for arg in "$@"; do
  if [ "$skip_next" = "1" ]; then
    skip_next=0
    continue
  fi
  case "$arg" in
    --*=*) continue ;;
    --project | --format | --filter | --limit)
      skip_next=1
      continue
      ;;
    -*) continue ;;
  esac

  if [ "$verb_seen" = "1" ]; then
    resource="$arg"
    break
  fi

  if [ -z "$slug" ]; then slug="$arg"; else slug="${slug}-${arg}"; fi
  case "$arg" in
    describe | list | version | get-iam-policy) verb_seen=1 ;;
  esac
done

if [ -z "$slug" ]; then
  printf 'ERROR: (gcloud) stub could not slug: %s\n' "$*" >&2
  exit 1
fi

if [ -n "$resource" ]; then
  # gs:// scheme dropped and every filesystem-hostile character folded to '_',
  # so a service account email becomes a legal, readable filename.
  clean="${resource#gs://}"
  # A trailing '/**' is the recursion wildcard `gcloud storage objects list`
  # requires -- without it the real API returns an empty list for a bucket full
  # of objects. It names the same bucket, so it is dropped here rather than
  # folded into three underscores in every fixture filename.
  clean="${clean%/\*\*}"
  clean="$(printf '%s' "$clean" | tr -c 'A-Za-z0-9._-' '_')"
  slug="${slug}-${clean}"
fi

for dir in "${STUB_FIXTURE_OVERLAY:-}" "${STUB_FIXTURE_BASE:-}"; do
  [ -n "$dir" ] || continue
  file="${dir}/${slug}.json"
  [ -f "$file" ] || continue
  # Two distinct error sentinels, because preserve-check.sh MUST tell them
  # apart: "the state bucket was deleted" and "your token expired" are the same
  # non-zero gcloud exit and must never produce the same verdict.
  head="$(head -c 24 "$file")"
  case "$head" in
    __STUB_NOT_FOUND__*)
      printf 'ERROR: (gcloud) NOT_FOUND: stub says %s does not exist\n' "$slug" >&2
      exit 1
      ;;
    __STUB_DENIED__*)
      printf 'ERROR: (gcloud) PERMISSION_DENIED: stub refuses to answer %s\n' "$slug" >&2
      exit 1
      ;;
  esac
  cat "$file"
  exit 0
done

printf 'ERROR: (gcloud) no stub fixture for slug: %s\n' "$slug" >&2
exit 1
