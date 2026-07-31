#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
controllers="$root/d2-signalloom/infra/inf-signalloom/controllers/base/dependencies.yaml"
controller_kustomization="$root/d2-signalloom/infra/inf-signalloom/controllers/base/kustomization.yaml"
config_kustomization="$root/d2-signalloom/infra/inf-signalloom/configs/base/kustomization.yaml"
test -f "$controllers"
grep -Fq 'image: postgres:16-alpine' "$controllers"
grep -Fq 'image: redis:7-alpine' "$controllers"
grep -Fq 'image: minio/minio:latest' "$controllers"
grep -Fq 'name: discovery-portal-bootstrap' "$controller_kustomization"
grep -Fq 'discovery-portal-bootstrap.sql' "$controller_kustomization"
if grep -Eq 'kind: (OCIRepository|HelmRelease)|registry-1\.docker\.io' "$controllers"; then
  printf 'local dependency controller must not add external tenant sources\n' >&2
  exit 1
fi
if grep -Fq 'discovery-portal-bootstrap' "$config_kustomization"; then
  printf 'PostgreSQL bootstrap must be available before controller health checks\n' >&2
  exit 1
fi
bash "$root/d2-signalloom/test/check-bootstrap-drift.sh"
if command -v kustomize >/dev/null 2>&1; then
  kustomize build --load-restrictor=LoadRestrictionsNone "$root/d2-signalloom/infra/inf-signalloom/controllers/local" >/dev/null
  kustomize build --load-restrictor=LoadRestrictionsNone "$root/d2-signalloom/infra/inf-signalloom/configs/local" >/dev/null
fi
printf 'Signalloom dependency validation passed.\n'
