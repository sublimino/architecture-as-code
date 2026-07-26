#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
controllers="$root/d2-signalloom/infra/inf-bao/controllers/base/openbao-spire.yaml"
controller_configs="$root/d2-signalloom/infra/inf-bao/controllers/base/spire-openbao-config.yaml"
configs="$root/d2-signalloom/infra/inf-bao/configs/base"
agent="$configs/spire-agent.yaml"
proof="$root/d2-signalloom/apps/fe-signalloom/base/bao-spire-proof.yaml"

for file in "$controllers" "$controller_configs" "$agent" "$configs/openbao-bootstrap.yaml" "$proof"; do test -f "$file"; done
# OpenBao's stock entrypoint transitions from root through su-exec, which
# invokes setgroups(2).  The demo deliberately runs the packaged binary
# directly as the image's unprivileged account so it remains compatible with
# the dropped-capability/no-new-privileges security context.
grep -Fq 'command: ["/bin/bao"]' "$controllers"
grep -Fq 'runAsNonRoot: true' "$controllers"
grep -Fq 'runAsUser: 100' "$controllers"
grep -Fq 'runAsGroup: 1000' "$controllers"
grep -Fq 'allowPrivilegeEscalation: false' "$controllers"
grep -Fq 'capabilities: {drop: ["ALL"]}' "$controllers"
grep -Fq 'args: ["-config", "/run/spire/config/server.conf"]' "$controllers"
grep -Fq 'args: ["-config", "/run/spire/config/server.conf"]' "$controllers"
grep -Fq 'args: ["-config", "/run/spire/config/agent.conf", "-expandEnv"]' "$agent"
if grep -Fq 'args: ["spire-server", "run"' "$controllers" || grep -Fq 'args: ["spire-agent", "run"' "$agent"; then
  printf 'SPIRE image entrypoint is duplicated in controller args\n' >&2
  exit 1
fi
grep -Fq 'spire-openbao-config.yaml' "$root/d2-signalloom/infra/inf-bao/controllers/base/kustomization.yaml"
grep -Fq 'keys_path = "/run/spire/data/keys.json"' "$controller_configs"
grep -Fq 'insecure_bootstrap = true' "$controller_configs"
grep -Fq 'name: JOIN_TOKEN' "$agent"
grep -Fq 'name: spire-agent-join-token' "$agent"
grep -Fq 'join_token = "$${JOIN_TOKEN}"' "$controller_configs"
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
