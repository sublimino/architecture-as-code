# Long-term fix: switch OpenBao JWT auth from static keys to live JWKS

## Status

**Design validated on kind-osramp (2026-08-23). Not shipped to GCP.**

## Problem

OpenBao's `jwt_validation_pubkeys` holds a static snapshot of SPIRE's JWT-SVID
signing keys. SPIRE rotates its CA on `ca_ttl` (default 24h):

- **t+12h** (ca_ttl/2): PREPARE — successor key published to the bundle; both
  old and new keys validate JWTs. Logins work.
- **t+20h** (ca_ttl×5/6): ACTIVATE — successor key starts signing JWTs. The old
  key still validates existing tokens but the new key is now active. If OpenBao
  only holds the old key set, **every new SPIFFE login fails** with "no known key
  successfully validated the token signature".

The CronJob at `d2-signalloom/infra/inf-bao/controllers/base/spire-openbao-sync-cronjob.yaml`
mitigates this by re-syncing every 8h, but it is a bridge — not a permanent fix.

## Solution: `jwks_url`

OpenBao supports three mutually exclusive key sources for JWT auth:

| Setting | Behaviour |
|---------|-----------|
| `jwt_validation_pubkeys` | Static PEM list — current approach |
| `jwks_url` | Live JWKS endpoint — OpenBao fetches on unknown kid |
| `oidc_discovery_url` | OIDC .well-known — derives JWKS URL from discovery |

**Writing any one of these clears the other two.** There is no overlay.

### Validated findings (kind-osramp, 2026-08-23)

1. **ES256 works with `jwt_supported_algs` unset.** SPIRE signs JWT-SVIDs with
   ES256 (P-256). OpenBao's default alg list includes ES256, so no explicit
   config is needed.

2. **OpenBao refetches JWKS on unknown kid.** When a JWT arrives signed by a kid
   OpenBao hasn't seen, it re-fetches the JWKS endpoint before rejecting.
   This means live-JWKS follows SPIRE's rotation with zero re-sync needed.

3. **Dead JWKS endpoint costs zero downtime for known kids.** If the endpoint
   goes down, OpenBao continues validating JWTs signed by cached keys. Only
   new kids trigger a fetch — and only that fetch fails.

### Why `jwks_url` and not `oidc_discovery_url`

SPIRE's built-in OIDC discovery provider requires a sidecar container and an
Ingress/Service to expose the `.well-known/openid-configuration` endpoint.
Using `jwks_url` directly is simpler: it points to the JWKS endpoint
(e.g. `https://spire-oidc.inf-bao.svc.cluster.local/keys`) without needing
the full OIDC discovery flow.

Both achieve the same result — live key rotation without snapshots. Choose
`oidc_discovery_url` only if other consumers also need the discovery document.

## Prerequisites

1. **OIDC discovery provider sidecar** added to the spire-server Deployment in
   `d2-signalloom/infra/inf-bao/controllers/base/openbao-spire.yaml`. This is
   the container that serves the JWKS endpoint.

2. **Service** exposing the OIDC provider's JWKS port (default 8008) as
   `spire-oidc.inf-bao.svc.cluster.local`.

3. **SPIRE server config** updated with `oidc_discovery` block pointing to the
   provider's listen address.

⚠️ **Socket path trap:** the OIDC provider reads SPIRE's admin socket. The
default is `/tmp/spire-server/private/api.sock`. If `socket_path` is set in
`server.conf`, the OIDC provider must match. Our current config uses the
default (no explicit `socket_path`), so the provider's default also works.

## Migration sequence

```bash
# 1. Deploy the OIDC provider sidecar and Service (prerequisite above)

# 2. Verify the JWKS endpoint serves the current keys
kubectl -n inf-bao exec deployment/spire-server -c oidc-provider -- \
  wget -qO- http://localhost:8008/keys | jq '.keys | length'

# 3. Switch OpenBao from static keys to live JWKS
# WARNING: this clears jwt_validation_pubkeys — the switch is atomic
kubectl -n inf-bao exec deployment/openbao -- env \
  BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$BAO_ROOT_TOKEN" \
  bao write auth/jwt/config \
    jwks_url="http://spire-oidc.inf-bao.svc.cluster.local:8008/keys"

# 4. Verify a SPIFFE login still works
kubectl -n fe-signalloom exec deployment/fe-signalloom -- \
  /opt/spire/bin/spire-agent api fetch jwt \
    -audience openbao \
    -socketPath /run/spire/sockets/agent.sock

# 5. Remove the CronJob (no longer needed)
kubectl -n inf-bao delete cronjob spire-openbao-sync

# 6. Remove sync_openbao_jwt_validation calls from demo-lifecycle.sh and
#    agent-trust-local.sh (the functions remain for fallback)
```

## Rollback

If the OIDC provider fails, revert to static keys:

```bash
# Re-sync static keys from SPIRE → OpenBao
source scripts/lib/spire-trust-anchor.sh
sync_openbao_jwt_validation inf-bao signalloom-demo-root-token
```

This writes `jwt_validation_pubkeys`, which clears `jwks_url` atomically.

## Why not ship now

The OIDC discovery provider sidecar touches the identity plane — it adds a
container to the spire-server Deployment, which currently runs a single
container. Adding it changes the pod's resource profile, restart behaviour,
and failure modes. This is a separate design decision from the key sync fix.

The CronJob is the correct bridge: it eliminates the outage window (8h interval
vs 20h deadline), is self-contained (no new containers), and its removal is
the last step of the `jwks_url` migration.
