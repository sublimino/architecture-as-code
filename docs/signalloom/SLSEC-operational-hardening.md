# SLSEC — Operational Hardening (out-of-repo findings)

Companion to `SLSEC-security-remediation-proposal.md`. These pentest findings are
**not fixable by a change in this repository** — they concern how the local
dev-machine Archivista/datastore containers are launched, which lives outside
`osramp-demo` source control. They are recorded here as operational steps with
exact remediation commands so the private deployment matches the posture the
in-repo fixes enforce.

## F3 — Datastores bound to `0.0.0.0` (Medium)

The blackbox pentest and the infra scout found four stateful backends bound to
every interface on the host (and therefore reachable from the tailnet):

| Container | Port(s) | Finding |
| :-- | :-- | :-- |
| `archivista-db-1` (MySQL) | `0.0.0.0:3306` | reachable off-host; auth enforced, no anonymous access |
| `archivista-minio-1` (MinIO) | `0.0.0.0:9000-9001` | S3 API + console; `403 AccessDenied` unsigned, login form on console |
| `archivista-archivista-1` | `0.0.0.0:8081-8082` | see F4 |
| `sldp-p41-pg` (Postgres) | `0.0.0.0:55439` | SASL/SCRAM required, no anonymous access |

**Not a breach** (auth held on all four) but a blast-radius/segmentation gap: the
`kind` API (`127.0.0.1:34777`) and `docs-signalloom-readonly` (`127.0.0.1:18081`)
are correctly loopback-only, proving the pattern is known — just not applied to
the Archivista dev stack.

**Remediation** — rebind these containers to loopback (or a docker-internal
network) unless off-host access is a deliberate requirement. In the compose/run
definition that starts the Archivista stack (external to this repo), change the
host port mappings from implicit `0.0.0.0` to `127.0.0.1`:

```yaml
# docker-compose (Archivista dev stack) — bind to loopback
services:
  db:        { ports: ["127.0.0.1:3306:3306"] }
  minio:     { ports: ["127.0.0.1:9000:9000", "127.0.0.1:9001:9001"] }
  archivista:{ ports: ["127.0.0.1:8082:8082"] }   # see F4 before exposing at all
  # postgres (sldp): ["127.0.0.1:55439:5432"]
```

Or for ad-hoc `docker run`: `-p 127.0.0.1:3306:3306` (not `-p 3306:3306`).
If the host is tailnet-joined and off-host access IS required, gate it behind
tailnet ACLs rather than binding `0.0.0.0`.

## F4 — Archivista GraphQL executes unauthenticated (Medium) + GraphiQL exposed (Info)

`POST http://<host>:8082/query` executes GraphQL with no authentication (returns
`200`; empty result only because the local DB is empty). `GET :8082/` serves the
GraphiQL playground unauthenticated. Introspection is disabled, but that does not
disable query execution, and malformed queries still leak schema names.

This matches Archivista's own documented trust model (it expects to sit behind an
authenticating gateway) — the local deployment simply exposes it directly.

**Remediation** — either:
1. Put Archivista behind the same OIDC/SPIRE-gated proxy as the rest of the
   stack (preferred if it must be reachable), or
2. Bind it loopback/internal-only per F3 if it is consumed solely by other local
   services, and disable the GraphiQL playground (`ARCHIVISTA_GRAPHQL_WEBCLIENT=false`
   or equivalent in the Archivista config).

## Verification

After rebinding, confirm from another host / the tailnet:

```bash
ss -lnt | grep -E ':(3306|9000|9001|8081|8082|55439)\b'   # expect 127.0.0.1 only
curl -s -o /dev/null -w '%{http_code}\n' http://<host>:8082/query -d '{"query":"{__typename}"}'  # expect no route / connection refused off-host
```

## Status

Owner: platform/operations (Andy's dev host). These are the residual findings the
in-repo SLSEC work (EAPR router auth, nginx headers, Dex rate-limit) does not and
cannot cover. Tracked so the private deployment is fully hardened, not just the
source tree.
