#!/usr/bin/env bash
# Print signal-ingest's immutable image tag (src-<digest of its compiled inputs>),
# refusing when any input has uncommitted changes. A script, not a recursive
# $(MAKE), so `make -n demo-signalloom-up` stays a dry run: make executes any
# recipe line that names $(MAKE) even under -n, which ran a real docker build.
set -euo pipefail
cd "$(dirname "$0")/../d2-signalloom/apps/signal-ingest"
inputs="$(go run ./cmd/image-tag -inputs)"
# The tag hashes only the TRACKED inputs (internal/imagetag.TrackedInputs), so anything else
# go build would compile -- an untracked or a gitignored .go file in a package directory, which
# go list reports from disk -- is refused here, with the same guard as the sentinel's tag
# (scripts/lib/source-id.sh: modified, untracked and ignored, failing closed).
# shellcheck source=lib/source-id.sh
source ../../../scripts/lib/source-id.sh # from the module dir (cd above)
# ../.. is the Docker build context (d2-signalloom; internal/imagetag.ContextDir), which is what
# the -inputs paths are relative to. It was .. while the context was d2-signalloom/apps; passing
# the wrong root here makes `git status -- <paths>` match nothing, so every input reads as clean
# and the guard silently stops refusing dirty builds.
# shellcheck disable=SC2086
dirty="$(source_id_dirty_inputs ../.. $inputs)" || {
    echo "signal-ingest-image-tag: git status failed; refusing" >&2
    exit 2
}
if [ -n "$dirty" ]; then
    echo "signal-ingest-image-tag: refusing a -dirty build; inputs that are not the committed source (modified, untracked or ignored):" >&2
    printf '%s\n' "$dirty" >&2
    exit 1
fi
go run ./cmd/image-tag
