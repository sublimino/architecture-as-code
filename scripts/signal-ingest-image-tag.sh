#!/usr/bin/env bash
# Print signal-ingest's immutable image tag (src-<digest of its compiled inputs>),
# refusing when any input has uncommitted changes. A script, not a recursive
# $(MAKE), so `make -n demo-signalloom-up` stays a dry run: make executes any
# recipe line that names $(MAKE) even under -n, which ran a real docker build.
set -euo pipefail
cd "$(dirname "$0")/../d2-signalloom/apps/signal-ingest"
inputs="$(go run ./cmd/image-tag -inputs)"
# shellcheck disable=SC2086
dirty="$(cd .. && git status --porcelain --untracked-files=all -- $inputs)"
if [ -n "$dirty" ]; then
    echo "signal-ingest-image-tag: refusing a -dirty build; uncommitted changes in the image inputs:" >&2
    printf '%s\n' "$dirty" >&2
    exit 1
fi
go run ./cmd/image-tag
