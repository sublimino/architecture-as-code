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
  # shellcheck source=lib/source-id.sh
  source "${root}/scripts/lib/source-id.sh" || exit 2

  # Same values as d2-signalloom/Makefile; the Makefile exports its own so the
  # two cannot drift when it calls this script.
  local dockerfile="${SENTINEL_DOCKERFILE:-signalloom-stun-sentinel/Dockerfile}"

  # The seven steps below this line used to be written out here, and again in
  # scripts/policy-engine-image-tag.sh once that workload needed the same
  # guarantee. They are now source_id_src_tag() in scripts/lib/source-id.sh,
  # which is where the fingerprint itself already lives, so a defence cannot be
  # present in one of the two scripts and absent from the other. The fingerprint
  # is unchanged: it is still source_id_hash_paths over source_id_copied_paths of
  # this Dockerfile, rooted at the build context.
  #
  # SENTINEL_IMAGE_INPUTS is gone. It named the dirty-check set by hand
  # ("apps/stun-sentinel apps/signalloom-stun-sentinel") alongside the
  # Dockerfile-derived set used for the hash -- two declarations of the same
  # thing, and they had already diverged: the hand-written one omitted the
  # Dockerfile, so an uncommitted Dockerfile edit moved the tag without the
  # dirty guard refusing. The set is now derived once, from the Dockerfile.
  source_id_src_tag sentinel-image-tag "d2-signalloom/apps" "${dockerfile}" "${dirty_check}"
}

main "$@"
