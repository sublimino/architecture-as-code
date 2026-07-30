# SPIFFE/OpenBao Attestation Architecture

Signal Loom workloads are identified by SPIFFE SVIDs issued by a SPIRE server
in the `inf-bao` namespace. OpenBao (the open-source Vault fork) provides
secrets management and serves as the JWT auth endpoint for SPIFFE-identified
workloads.

## Current architecture (demo)

```
┌─────────────────────────────────────────────────────────┐
│  SPIRE Server (inf-bao)                                 │
│  ├ Trust domain: signalloom.demo                        │
│  ├ Key manager: disk (/run/spire/data/keys.json)        │
│  ├ Node attestor: join_token                            │
│  └ DataStore: SQLite (in-pod ephemeral)                 │
└────────────────────┬────────────────────────────────────┘
                     │ SVID issuance
┌────────────────────▼────────────────────────────────────┐
│  SPIRE Agent (DaemonSet, inf-bao)                       │
│  ├ Workload attestor: k8s (ServiceAccount-based)        │
│  └ Socket: /run/spire/sockets/agent.sock                │
└────────────────────┬────────────────────────────────────┘
                     │ JWT-SVID
┌────────────────────▼────────────────────────────────────┐
│  Workload (fe-signalloom/fe-signalloom)                  │
│  ├ SPIFFE ID: spiffe://signalloom.demo/ns/fe-signalloom │
│  │            /sa/fe-signalloom                         │
│  └ Fetches JWT-SVID with audience "openbao"             │
└────────────────────┬────────────────────────────────────┘
                     │ JWT exchange
┌────────────────────▼────────────────────────────────────┐
│  OpenBao (inf-bao)                                      │
│  ├ Mode: dev (unsealed, signalloom-demo-root-token)     │
│  ├ JWT auth: validates SPIFFE JWT, issues Bao token     │
│  ├ Role: signalloom-fe-signalloom                       │
│  │   Bound subject: spiffe://signalloom.demo/ns/...     │
│  │   Bound audience: openbao                            │
│  ├ KV v2: kv/signalloom/fe-signalloom                   │
│  ├ PKI: pki/cluster-root, pki/spire                     │
│  └ Transit: transit/envelope                            │
└─────────────────────────────────────────────────────────┘
```

### Proof jobs

Two Jobs in `fe-signalloom` validate the attestation chain:

- **bao-spire-positive-proof**: ServiceAccount `fe-signalloom` → fetches JWT-SVID
  → exchanges for OpenBao token → reads `kv/signalloom/fe-signalloom`. **Must succeed.**

- **bao-spire-negative-proof**: ServiceAccount `fe-signalloom-negative` → attempts
  JWT-SVID fetch → OpenBao rejects (wrong identity). **Must be denied.**

Run: `make demo-bao-test`

## Production hardening path

### Phase 1: OpenBao as Upstream Authority (blog post pattern)

Per the [Securing Agent Identity](https://control-plane.io/posts/securing-agent-identity-openbao-spire/)
blog post, SPIRE should delegate CA signing to OpenBao's PKI engine:

```hcl
# SPIRE server configuration
UpstreamAuthority "vault" {
    plugin_data {
        vault_addr = "https://openbao.inf-bao.svc:8200"
        ca_cert_path = "/etc/ca/openbao-ca.pem"
        pki_mount_point = "pki/spire"
        k8s_auth {
            k8s_auth_mount_point = "kubernetes"
            k8s_auth_role_name = "spire"
            token_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
        }
    }
}
```

**Gap:** currently not implemented. SPIRE is standalone root CA.

### Phase 2: OpenBao Transit as Key Manager

SPIRE should use OpenBao's Transit engine for signing operations — private keys
never leave the OpenBao boundary:

```hcl
KeyManager "hashicorp_vault" {
    plugin_data {
        vault_addr = "https://openbao.inf-bao.svc:8200"
        ca_cert_path = "/etc/ca/openbao-ca.pem"
        transit_engine_path = "transit/envelope"
        key_identifier_value = "spire"
        k8s_auth {
            k8s_auth_mount_point = "kubernetes"
            k8s_auth_role_name = "spire"
            token_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
        }
    }
}
```

**Gap:** currently not implemented. SPIRE uses disk key manager.

### Phase 3: Production-ready deployment

| Current (demo) | Target (production) |
| :---- | :---- |
| `join_token` node attestor | `k8s_psat` (projected SA token) |
| Disk key manager | Transit key manager (OpenBao) |
| Self-signed root CA | OpenBao PKI upstream authority |
| Dev mode OpenBao | HA Raft cluster, auto-unseal |
| SQLite data store | PostgreSQL (shared infra) |
| `insecure_bootstrap = true` | mTLS bootstrap with CA bundle |
| Skip kubelet verification | Full kubelet verification |

## Security posture for AFM and RBAC Explorer

### AFM platform (fe-k8s-afm)

| Control | Status |
| :---- | :---- |
| Network isolation | NetworkPolicy allows dashboard→AFM (port 8000 only) |
| Resource limits | 500m CPU / 512Mi memory / 1 Z3 worker |
| RBAC access | Read-only ClusterRole for RBAC resources (CronJob SA) |
| No secrets access | AFM does not access secrets or service account tokens |
| CORS | Open (demo); restrict to dashboard origin in production |
| Image source | Built from source, kind-loaded; production → signed via Zot |

### RBAC Explorer (dashboard component)

| Control | Status |
| :---- | :---- |
| Auth required | Dex OIDC (same as all dashboard pages) |
| Data source | AFM API via nginx proxy (no direct k8s access from browser) |
| Data sensitivity | RBAC metadata (role names, verbs, bindings) — not secrets |
| Write access | None — read-only views; analysis triggered server-side |

## Remote connector extensibility

The RBAC Explorer's cluster selector is designed for multi-cluster support.
Remote clusters are added by importing their RBAC data into AFM:

```bash
# Import from a remote cluster
kubectl --context remote-cluster get clusterroles,clusterrolebindings,\
  roles,rolebindings -A -o json | python3 scripts/rbac-to-afm.py \
  --id remote-prod --name "Production (EU)" | \
  curl -X POST http://afm:8000/clusters/import \
    -H "Content-Type: application/json" -d @-
```

Future connectors:
- **Azure**: Azure RBAC role assignments via Graph API
- **AWS**: IAM roles/policies via STS
- **GCP**: IAM bindings via Resource Manager API

Each connector follows the same pattern: read RBAC data from the remote source,
transform to AFM's `{rbac: {subjects, roles, bindings}}` format, POST to
`/clusters/import`. The RBAC Explorer UI requires no changes — new clusters
appear in the selector automatically.
