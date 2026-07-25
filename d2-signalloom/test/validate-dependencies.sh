#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
controllers="$root/d2-signalloom/infra/inf-signalloom/controllers/base/dependencies.yaml"
test -f "$controllers"
grep -Fq 'tag: "18.8.0"' "$controllers"
grep -Fq 'tag: "27.0.17"' "$controllers"
grep -Fq 'tag: "8.0.10"' "$controllers"
grep -Fq 'storageClass: "standard"' "$controllers"
grep -Fq 'enabled: false' "$controllers"
bash "$root/d2-signalloom/test/check-bootstrap-drift.sh"
if command -v kustomize >/dev/null 2>&1; then
  kustomize build "$root/d2-signalloom/infra/inf-signalloom/controllers/local" >/dev/null
  kustomize build "$root/d2-signalloom/infra/inf-signalloom/configs/local" >/dev/null
fi
printf 'Signalloom dependency validation passed.\n'
