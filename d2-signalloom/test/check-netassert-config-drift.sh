#!/usr/bin/env bash
set -euo pipefail
# apps/fe-signalloom/base/netassert-signalloom.yaml is a committed copy of
# this directory's netassert-signalloom.yaml, needed because kustomize's
# default load restrictor refuses configMapGenerator `files:` sources outside
# the kustomization root (verified: a `../../../test/...` reference here
# fails `kubectl kustomize` with "is not in or below" even though the
# equivalent cross-directory reference already exists for
# infra/inf-signalloom/controllers/base's discovery-portal-bootstrap.sql
# generator). Same trade-off as check-bootstrap-drift.sh: commit the
# duplicate, catch staleness mechanically rather than by hoping nobody edits
# one copy and forgets the other.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cmp --silent \
  "$root/test/netassert-signalloom.yaml" \
  "$root/apps/fe-signalloom/base/netassert-signalloom.yaml"
printf 'netassert config drift validation passed.\n'
