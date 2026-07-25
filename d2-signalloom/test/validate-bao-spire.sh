#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
controllers="$root/d2-signalloom/infra/inf-bao/controllers/base/openbao-spire.yaml"
configs="$root/d2-signalloom/infra/inf-bao/configs/base"
proof="$root/d2-signalloom/apps/fe-signalloom/base/bao-spire-proof.yaml"

for file in "$controllers" "$configs/openbao-bootstrap.yaml" "$configs/spire-openbao-config.yaml" "$proof"; do test -f "$file"; done
grep -Fq 'spiffe://signalloom.demo/ns/fe-signalloom/sa/fe-signalloom' "$configs/openbao-bootstrap.yaml"
grep -Fq 'bound_audiences=openbao' "$configs/openbao-bootstrap.yaml"
grep -Fq 'auth/jwt/role/signalloom-fe-signalloom' "$configs/openbao-bootstrap.yaml"
grep -Fq 'kv/data/signalloom/fe-signalloom' "$configs/openbao-bootstrap.yaml"
grep -Fq 'serviceAccountName: fe-signalloom' "$proof"
grep -Fq 'serviceAccountName: fe-signalloom-negative' "$proof"
grep -Fq '/run/spire/sockets/agent.sock' "$proof"
grep -Fq 'auth/jwt/login role=signalloom-fe-signalloom' "$proof"
grep -Fq 'bao kv get kv/signalloom/fe-signalloom' "$proof"
grep -Fq 'bao.controlplane.io/consumer: fe-signalloom' "$proof"
printf 'bounded Bao/SPIRE identity and proof configuration validates\n'
