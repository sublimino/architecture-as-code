#!/usr/bin/env bash
#
# policy-engine-image-tag.sh - print the policy-engine image tag.
#
# @id     policy-engine-image-tag
# @lib    scripts/lib/source-id.sh
# @tests  test/policy-engine-image-provenance.bats, test/image-provenance-coverage.bats
# @doc    docs/flux-coverage.md
#
# The tag is src-<12 hex> of the files the policy-engine Dockerfile COPYs --
# pkg/obscel/ and apps/policy-engine/, plus the Dockerfile itself. With no flag
# it refuses (exit 1) when any of those inputs is not the committed source;
# --no-dirty-check prints the fingerprint regardless.
#
# ─── Why this exists ────────────────────────────────────────────────────────
#
# policy-engine imports d2-signalloom/pkg/obscel, the shared package named in
# this repository's standing re-pin rule, and its Deployment is reconciled by
# Flux. Until 2026-10-12 it ran `policy-engine:local`. A change to pkg/obscel
# therefore moved the signal-ingest tag and turned
# TestReconciledManifestRunsTheImageBuiltFromThisSource red if you forgot to
# re-pin -- while shipping a stale policy-engine in complete silence, because
# the sibling that shares the dependency had no equivalent. One of the two
# consumers of the same package was guarded and the other was not.
#
# ─── Why the sentinel was the template, and not signal-ingest ───────────────
#
# Both existing tag scripts were read first. signal-ingest derives its input set
# from a Go program (cmd/image-tag, internal/imagetag.TrackedInputs) that walks
# `go list -deps`. That is the right answer for signal-ingest, whose Dockerfile
# COPYs the whole module tree and whose tag must not move on a test-only edit.
# It costs a second declaration of "what goes into this image" -- a Go
# identifier list that is not the Dockerfile -- which its own script then has to
# cross-check against git, and it needs a Go toolchain to print a tag.
#
# sentinel-image-tag.sh reads the input set OUT OF the Dockerfile. There is no
# second list, so there is nothing to drift, which is the same argument
# scripts/lib/source-id.sh makes for parsing nginx.conf rather than maintaining a
# backend list. policy-engine's Dockerfile COPYs whole directories, exactly the
# shape source_id_copied_paths handles, so the derived set is complete by
# construction. A test-only edit does move this tag; for a demo image rebuilt by
# `make demo-signalloom-supercred-images` that is a rebuild, not a problem, and
# the alternative is a blind spot.
#
# The seven steps both scripts need now live in source_id_src_tag() in
# scripts/lib/source-id.sh, so the dirty refusal, the missing-COPY refusal and
# the empty-fingerprint refusal cannot be present in one script and absent from
# the other.
#
# Why a script and not `$(MAKE) -s policy-engine-image-tag`: GNU make executes
# any recipe line containing $(MAKE) even under -n, and the sub-make inherits -n
# through MAKEFLAGS, so the line printed its recipe text instead of a tag and
# the docker build on the same line then ran for real against it (2026-10-04,
# recorded in scripts/sentinel-image-tag.sh).
set -o pipefail

usage() { echo "usage: policy-engine-image-tag.sh [--no-dirty-check]" >&2; exit 2; }

main() {
  local dirty_check=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-dirty-check) dirty_check=0; shift ;;
      -h|--help) usage ;;
      *) echo "policy-engine-image-tag.sh: unknown option $1" >&2; usage ;;
    esac
  done

  local here root
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root="$(cd "${here}/.." && pwd)"
  # shellcheck source=lib/source-id.sh
  source "${root}/scripts/lib/source-id.sh" || exit 2

  # Same values as the POLICY_ENGINE_* variables in Makefile; exported there so
  # the two cannot drift. The context is d2-signalloom, NOT apps/policy-engine:
  # go.mod carries `replace .../pkg/obscel => ../../pkg/obscel`, so a context
  # rooted at the app directory cannot see the module at all.
  local context="${POLICY_ENGINE_CONTEXT:-d2-signalloom}"
  local dockerfile="${POLICY_ENGINE_DOCKERFILE:-apps/policy-engine/Dockerfile}"

  source_id_src_tag policy-engine-image-tag "${context}" "${dockerfile}" "${dirty_check}"
}

main "$@"
