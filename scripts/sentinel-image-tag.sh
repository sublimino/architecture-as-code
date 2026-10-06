#!/usr/bin/env bash
#
# sentinel-image-tag.sh - print the signalloom-warden image tag.
#
# @id     sentinel-image-tag
# @lib    scripts/lib/source-id.sh
# @tests  test/sentinel-image-provenance.bats, test/source-id-tracked.bats, test/demo-lifecycle.bats
# @doc    docs/signalloom/sltm-governor-log.md
#
# The tag is src-<12 hex> of the files the sentinel Dockerfile COPYs. With no
# flag it refuses (exit 1) when any of the image's inputs is not the committed
# source; --no-dirty-check prints the fingerprint regardless.
#
# Why a script and not `$(MAKE) -s sentinel-image-tag` inside the recipes that
# need the tag: GNU make executes any recipe line containing $(MAKE) even under
# -n, and the sub-make inherits -n through MAKEFLAGS, so it printed its recipe
# text instead of the tag and the docker build, kind load and zot push on the
# same line then ran for real against a mangled tag (2026-10-04,
# test/demo-lifecycle.bats "foundation health before activation"). A plain
# shell call carries no such rule: `make -n` prints it and runs nothing.
set -o pipefail

usage() { echo "usage: sentinel-image-tag.sh [--no-dirty-check]" >&2; exit 2; }

main() {
  local dirty_check=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-dirty-check) dirty_check=0; shift ;;
      -h|--help) usage ;;
      *) echo "sentinel-image-tag.sh: unknown option $1" >&2; usage ;;
    esac
  done

  local here root
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root="$(cd "${here}/.." && pwd)"
  cd "${root}/d2-signalloom" || exit 2
  # shellcheck source=lib/source-id.sh
  source "${root}/scripts/lib/source-id.sh" || exit 2

  # Same values as d2-signalloom/Makefile; the Makefile exports its own so the
  # two cannot drift when it calls this script.
  local dockerfile="${SENTINEL_DOCKERFILE:-signalloom-stun-sentinel/Dockerfile}"
  local inputs="${SENTINEL_IMAGE_INPUTS:-apps/stun-sentinel apps/signalloom-stun-sentinel}"

  if [ "${dirty_check}" -eq 1 ]; then
    local dirty
    # shellcheck disable=SC2086  # inputs is a space-separated list by contract
    dirty=$(source_id_dirty_inputs . ${inputs}) || { echo "sentinel-image-tag: git status failed; refusing" >&2; exit 2; }
    if [ -n "${dirty}" ]; then
      echo "sentinel-image-tag: refusing a -dirty build; inputs that are not the committed source (modified, untracked or ignored -- an ignored file still enters the docker build context):" >&2
      printf '%s\n' "${dirty}" >&2
      exit 1
    fi
  fi

  local -a paths
  mapfile -t paths < <(source_id_copied_paths "apps/${dockerfile}" "${dockerfile}")
  [ "${#paths[@]}" -gt 0 ] || { echo "sentinel-image-source-id: no COPY sources in apps/${dockerfile}" >&2; exit 2; }
  local p
  for p in "${paths[@]}"; do
    [ -e "apps/${p}" ] || { echo "sentinel-image-source-id: the Dockerfile COPYs ${p}, which does not exist" >&2; exit 2; }
  done
  local id
  id=$(source_id_hash_paths apps "${paths[@]}") && [ -n "${id}" ] || { echo "sentinel-image-source-id: empty fingerprint" >&2; exit 2; }
  printf 'src-%s\n' "${id:0:12}"
}

main "$@"
