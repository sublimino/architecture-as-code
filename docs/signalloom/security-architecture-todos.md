# Security architecture to-dos

This register records each security control that the platform relaxed or did
not yet build, until the enterprise security architecture documentation is
complete. Each entry has an id, the decision, the blast radius, the
compensating controls, the candidate replacements, and an exit criterion.

An entry stays open until its exit criterion is met. Close an entry with a
dated line that names the commit that met the criterion. Do not delete it.

| Id | Title | Status | Opened |
| :--- | :--- | :--- | :--- |
| [SA-TODO-001](#sa-todo-001-public-https-egress-for-the-portal-pod) | Public HTTPS egress for the portal pod | Open, exemption in force | 2026-10-16 |
| [SA-TODO-002](#sa-todo-002-unbounded-api-transport-egress-on-two-runner-pods) | Unbounded API transport egress on two runner pods | Open, finding | 2026-10-16 |
| [SA-TODO-003](#sa-todo-003-connector-credentials-are-not-in-openbao) | Connector credentials are not in OpenBao | Open, fix built, waiting for the live cutover | 2026-10-17 |
| [SA-TODO-004](#sa-todo-004-openbao-static-seal-key-in-a-kubernetes-secret) | OpenBao static seal key in a Kubernetes Secret | Open, exemption in force (kind only) | 2026-10-17 |
| [SA-TODO-005](#sa-todo-005-start-up-credentials-in-kubernetes-secrets) | Start-up credentials in Kubernetes Secrets | Open, exemption in force | 2026-10-17 |
| [SA-TODO-006](#sa-todo-006-openbao-listens-on-plain-http) | OpenBao listens on plain HTTP | Open, exemption in force (kind only) | 2026-10-17 |
| [SA-TODO-007](#sa-todo-007-plaintext-secrets-left-in-the-portals-committed-secrets) | Plaintext secrets left in the portal's committed Secrets | Open, finding | 2026-10-17 |

## SA-TODO-001: public HTTPS egress for the portal pod

**Decision.** The principal accepted this exemption on 2026-10-16. The
decision, in the principal's words, is quoted as given. The style check is
off for the quote only.

<!-- docs-lint: off -->
> Seeing as our enterprise architecture documentation is not yet complete, we
> need to leave a security exemption for this behaviour and for now allow
> public internet egress. This is not something we'll do in future.
<!-- docs-lint: on -->

**What was relaxed.** The `fe-signalloom` namespace is default-deny for
ingress and egress. The NetworkPolicy `allow-portal-public-https-egress` now
lets the portal pod open TCP 443 to public IPv4 addresses. The policy is in
`d2-signalloom/apps/fe-signalloom/base/networkpolicy.yaml`. Its annotations
carry the id `SA-TODO-001`, the decision date, the reason, and the
replacement.

**Why.** The live AI provider connectors run in the portal. They must reach
`api.anthropic.com` and `api.openai.com`. Before the exemption, a connection
from the pod to `160.79.104.10:443` timed out. The cluster CNI is kindnet. It
applies plain Kubernetes NetworkPolicy, which has no rule for a host name. The
provider IP addresses are not stable, so an IP allow-list would break without
warning.

**Blast radius.**

- One workload: the `fe-signalloom` Deployment. The selector needs both
  `app.kubernetes.io/name: fe-signalloom` and `bao.controlplane.io/consumer:
  fe-signalloom`. The bao-spire proof Jobs carry only the second label, so
  they do not get the grant.
- Every container in that pod gets the grant, because NetworkPolicy applies
  to the pod. These are `discovery-portal`, the `kubectl-proxy` sidecar, and
  since SA-TODO-003 the `jwt-svid` and `openbao-agent` sidecars.
- Any public IPv4 host on TCP 443, not only the AI providers. A compromised
  portal process can send data to any HTTPS endpoint on the internet. This is
  the residual risk that the principal accepted.
- No new in-cluster path. The `except` list removes 10.0.0.0/8,
  172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 and
  127.0.0.0/8. It also names the kind pod range 10.244.0.0/16 and the service
  range 10.96.0.0/12, so that a later edit to 10.0.0.0/8 cannot open them.
- No IPv6. The pods have no IPv6 route.

**Compensating controls.**

- Only the portal pod, and only TCP 443.
- Connector credentials are sealed at rest with AES-256-GCM, bound to the
  tenant and the connector. The code is
  `d2-signalloom/apps/fe-signalloom/src/connector_credentials.py`. The key is
  in a mounted Secret, not in the manifest.
- The portal opens provider connections only for connectors that a tenant
  configured.
- `d2-signalloom/test/portal-public-egress.bats` pins the policy shape. It
  fails if the selector, the port, the peer, or the `except` list widens. It
  also fails if another policy in the namespace grants public egress.
- `scripts/portal-egress-probe.sh` proves the result on a live cluster. It
  checks provider reach, and it checks that an unlisted private address still
  times out.

**Candidate replacements.** The principal named three. The security
architecture documentation will select one.

1. An L7 egress proxy with an FQDN allow-list. The portal sends provider
   traffic through the proxy, and the NetworkPolicy allows only the proxy.
2. A service mesh egress gateway. The mesh controls egress by host name and
   adds mTLS and per-request audit.
3. An eBPF or Cilium FQDN policy. A `CiliumNetworkPolicy` with `toFQDNs`
   allows only the provider host names. This needs Cilium as the CNI in place
   of kindnet.

**Exit criterion.** Close this entry when all of these are true:

- The security architecture documentation selects a replacement.
- The portal reaches the providers through that replacement, and the
  replacement allows only the configured provider host names.
- `allow-portal-public-https-egress` is deleted from the manifests.
- `scripts/portal-egress-probe.sh` passes against the replacement, and a host
  that is not on the allow-list fails.

**Verification.**

```bash
bats d2-signalloom/test/portal-public-egress.bats
bats d2-signalloom/test/portal-egress-probe.bats
scripts/portal-egress-probe.sh --context kind-osramp
```

## SA-TODO-002: unbounded API transport egress on two runner pods

**Status.** This is a finding. No decision authorised it. It was found while
the SA-TODO-001 tests were written.

**What it is.** Two policies in `fe-signalloom` have an egress rule with no
`to` field. Such a rule allows every destination on its ports.

| Policy | Pods | Ports |
| :--- | :--- | :--- |
| `allow-netassert-runner-egress` | The `netassert-run` Job (`signalloom.ai/purpose: network-test-run`) | TCP 443, TCP 6443 |
| `allow-supercred-demo-runner-egress` | `supercred-demo-runner` | TCP 443, TCP 6443 |

Both rules exist so that the pod can reach the kube-apiserver. Because they
have no `to` field, both pods can also reach any public host on 443. This was
true before SA-TODO-001.

**Blast radius.** The supercred demo runner executes privileged demo scripts
against the cluster. Public 443 egress from it is a data-exfiltration path.

**Candidate fix.** Bound each rule to the cluster service range and the node
network, as `allow-portal-dependencies` does for its kube-apiserver rule. The
three SA-TODO-001 replacements also cover this case.

**Exit criterion.** Close this entry when neither policy has an egress rule
without a `to` field. The test "the set of policies with an unbounded egress
rule does not grow" in `d2-signalloom/test/portal-public-egress.bats` pins the
two current names. Update it in the same commit.

## SA-TODO-003: connector credentials are not in OpenBao

**Status.** This is a finding against the platform secrets standard: every
platform secret is stored in OpenBao. The principal set the standard on
2026-10-17, after this store shipped.

**What it is.** Connector credentials (provider API keys, admin keys and
workspace identifiers held with them) are sealed with AES-256-GCM in
`public.tenant_connectors.credentials_ciphertext`. The sealing key is read
from the `fe-signalloom/fe-signalloom-connector-credential-key` Kubernetes
Secret, minted by `make connector-credential-key`. The code is
`d2-signalloom/apps/fe-signalloom/src/connector_credentials.py`.

**Blast radius.** Anyone who can read both the database and that Secret can
decrypt every tenant's provider credentials. OpenBao's per-path policy,
leases and audit log do not cover these reads.

**Compensating controls.** The ciphertext is bound to tenant and connector as
associated data, so a row moved to another tenant does not decrypt. Without
the key, credential writes fail with 503. The portal pod is the only reader.

**Candidate fix.** Store each credential in OpenBao KV v2 under a per-tenant
path, for example `signalloom/tenants/<tenant>/connectors/<connector_id>`.
Keep only that path in Postgres. The portal authenticates to OpenBao with its
workload identity, under a policy that grants each tenant path read and write.
The portal already has egress to `inf-bao:8200`. Migrate existing rows, then
delete the sealing key Secret.

**History.** On 2026-10-17 the OpenBao server in `inf-bao` ran `bao server
-dev` from image `quay.io/openbao/openbao:2.1.1`. Storage was `inmem`, and
the root token was a static value in the manifest. A pod restart lost every
secret. Thus the credential move waited for phase 1, a persistent OpenBao.

**Decisions (principal, 2026-10-17).**

1. Unseal: a static seal key in a Kubernetes Secret, on kind only. This is
   [SA-TODO-004](#sa-todo-004-openbao-static-seal-key-in-a-kubernetes-secret).
   Cloud KMS auto-unseal on the GCP lane is a follow-up, not built.
2. Administration: a one-shot init Job holds the root token in memory only.
   It creates the SPIFFE-bound JWT role `inf-bao-admin`, then revokes the root
   token. Every setup Job, the `spire-openbao-sync` CronJob and every host
   script log in through that role.
3. Storage credential: a Kubernetes Secret, recorded as
   [SA-TODO-005](#sa-todo-005-start-up-credentials-in-kubernetes-secrets). The
   Postgres superuser password moves out of plain text into a minted Secret.
4. Cutover: export, then import, then a key-by-key comparison of hashes.
5. Topology: one replica and HTTP on kind. TLS is
   [SA-TODO-006](#sa-todo-006-openbao-listens-on-plain-http).
6. The recovery key from `bao operator init` is discarded with the root
   token. The lead accepted this for kind on 2026-10-17. It needs a principal
   decision before any use outside kind.

**Phase 1, built on branch `feat/connector-creds-openbao-w17`.**

- [`openbao-spire.yaml`](../../d2-signalloom/infra/inf-bao/controllers/base/openbao-spire.yaml)
  runs OpenBao 2.7.1 from `config.hcl`. Storage is `postgresql`, database and
  role `openbao` on the `inf-signalloom` server. The seal is `static`, keyed
  from Secret `inf-bao/openbao-seal-key`. There is one replica with the
  `Recreate` strategy.
- [`openbao-init.yaml`](../../d2-signalloom/infra/inf-bao/controllers/base/openbao-init.yaml)
  initialises the server once. It enables the audit log on the server's
  stdout, the `kv/` and `secret/` KV v2 mounts and `auth/jwt`. It writes the
  `inf-bao-admin` policy and role, then revokes the root token. An exit trap
  revokes the root token on a failure too.
- `inf-bao-admin` is bound to
  `spiffe://signalloom.demo/ns/inf-bao/sa/openbao-admin` and gives 15-minute
  tokens. Its policy denies raw storage, root token creation, rekey, key
  rotation, seal controls and changes to the audit log. It can read its own
  role and policy, but it cannot change them.
- [`openbao-admin.yaml`](../../d2-signalloom/infra/inf-bao/controllers/base/openbao-admin.yaml)
  runs a bao agent as `inf-bao-admin`, with the `fleet-manager` sidecar
  pattern. Host scripts use it through
  [`bao-admin.sh`](../../scripts/lib/bao-admin.sh). The token stays in that
  pod. The one exception is `bao_admin_token`. It copies the current
  15-minute token out for a tool that calls OpenBao over HTTP from the host.
  The users are `run_slet_p4_2_acceptance.sh`, `e2e_teardown_certifier.py`,
  `swarm-seed-secrets.sh` and `kagent-credentials.sh`.
- [`openbao-secrets.sh`](../../scripts/openbao-secrets.sh) mints the seal
  key and the storage credential, and creates the role and database.
  [`postgres-superuser-secret.sh`](../../scripts/postgres-superuser-secret.sh)
  mints the Postgres superuser password. `make demo-signalloom-up` runs both.
- [`openbao-migrate.sh`](../../scripts/openbao-migrate.sh) exports, imports
  and compares the state. Logs carry hashes of values, never the values.
- [`openbao-no-static-root-token.bats`](../../test/openbao-no-static-root-token.bats)
  fails if the old token, a literal `BAO_TOKEN` value, dev mode or a reader of
  a dev token comes back.

The changes from 2.1.1 to 2.7.1 that touch this estate:

- The `file` storage backend is removed. This estate uses `postgresql`.
- Since 2.6.0 the image runs as user `openbao`. The manifests run
  `/bin/bao` as uid 100 with `fsGroup` 1000.
- Since 2.6.0 `operator generate-root` calls authenticated endpoints. In
  2.7.1 the unauthenticated root token endpoints are off by default. Thus no
  host script can use them, and all use `inf-bao-admin`.
- The LDAP, Kerberos and RADIUS plugins are removed. This estate uses none of
  them.
- Dev mode made `secret/` implicitly. The init Job now enables it.

**What the export does not move.** Tokens and leases expire, so restart the
agents after the import. The `openbao-agent-generic-role-setup` Job makes the
named identity entities again, and logins make the others.

**Cutover runbook, phase 1.** The lead runs these commands. Run each block
only when the block before it is complete.

```bash
CTX=kind-osramp
DIR=/dev/shm/openbao-cutover && mkdir -m 700 -p "$DIR"

# 1. Start-up secrets. The ALTER ROLE drops new connections that use the old
#    password until the consumers restart in step 3.
make postgres-superuser-secret CONTEXT=$CTX
make openbao-secrets CONTEXT=$CTX

# 2. Export from the dev server BEFORE Flux replaces it.
flux --context $CTX -n inf-bao suspend kustomization infra-controllers
flux --context $CTX -n inf-bao suspend kustomization infra-configs
scripts/openbao-migrate.sh export --context $CTX --file "$DIR/export.json"

# 3. Deploy the branch, then resume. A Deployment that moves from RollingUpdate
#    to Recreate keeps its old rollingUpdate block under server-side apply, and
#    Flux then fails the dry run. Patch the strategy first.
kubectl --context $CTX -n inf-bao patch deploy openbao --type=json \
  -p '[{"op":"remove","path":"/spec/strategy/rollingUpdate"},{"op":"replace","path":"/spec/strategy/type","value":"Recreate"}]'
flux --context $CTX -n inf-bao resume kustomization infra-controllers
kubectl --context $CTX -n inf-bao wait --for=condition=complete job/openbao-init --timeout=10m
kubectl --context $CTX -n inf-bao logs job/openbao-init | tail -1   # "... root token revoked"
kubectl --context $CTX -n inf-bao rollout status deploy/openbao-admin --timeout=5m
kubectl --context $CTX -n inf-bao exec deploy/openbao-admin -c bao -- bao-admin token lookup -format=json | jq -r '.data.policies[]'
flux --context $CTX -n inf-bao resume kustomization infra-configs
kubectl --context $CTX -n inf-bao wait --for=condition=complete --timeout=10m \
  job/openbao-agent-generic-role-setup job/openbao-spire-bootstrap \
  job/openbao-supercred-bootstrap job/openbao-fleet-manager-bootstrap
kubectl --context $CTX -n fe-signalloom rollout restart deploy/fe-signalloom deploy/signal-ingest deploy/fleet-manager

# 4. Import and compare. Expect "mismatched=0 missing=0".
scripts/openbao-migrate.sh import --context $CTX --file "$DIR/export.json"
scripts/openbao-migrate.sh verify --context $CTX --file "$DIR/export.json"
# The import writes the dev server's policies back, which overwrites any policy
# the new setup Jobs changed (the portal's tenant connector grant among them).
# Re-run the setup Jobs so the manifests own their policies again. Verify then
# reports those policies as changed; that is expected.
kubectl --context $CTX -n inf-bao delete job openbao-agent-generic-role-setup \
  openbao-spire-bootstrap openbao-supercred-bootstrap openbao-fleet-manager-bootstrap
flux --context $CTX -n inf-bao reconcile kustomization infra-configs
kubectl --context $CTX -n inf-bao wait --for=condition=complete --timeout=10m \
  job/openbao-agent-generic-role-setup job/openbao-spire-bootstrap \
  job/openbao-supercred-bootstrap job/openbao-fleet-manager-bootstrap
kubectl --context $CTX -n fe-signalloom-agents rollout restart deploy

# 5. Restart survival. Expect the same "verified" line as step 4.
kubectl --context $CTX -n inf-bao rollout restart deploy/openbao
kubectl --context $CTX -n inf-bao rollout status deploy/openbao --timeout=5m
kubectl --context $CTX -n inf-bao exec deploy/openbao-admin -c bao -- bao-admin status
scripts/openbao-migrate.sh verify --context $CTX --file "$DIR/export.json"

# 6. Keep the export: phase 2 step 10 destroys it.
```

**Applied on kind-osramp, 2026-10-17.** The lead ran phases 1 and 2. Four
defects surfaced and were fixed on the way: the server ran `/bin/bao`, which
2.7.1 ships at `/usr/bin/bao`; `openbao-init` called `bao audit enable`, which
2.7 refuses (the audit device is now declared in `config.hcl`); the
`openbao-admin` SVID writer ran as root and its 0600 file was unreadable to the
uid-100 agent; and `verify` counted 11 roles as drift when 2.7.1 only reported
null lists as `[]`. The import also overwrote the portal policy, which step 4
now handles. Result: verify matched 39, mismatched 0, missing 0, before and
after a server restart. One connector credential moved; `--verify` reports ok,
sealed 0, before and after a restart. The export was shredded. The exit steps
below are still open.

**Rollback, phase 1.** Before step 3, resume both Kustomizations and stop.
Nothing changed except the minted Secrets. After step 3, revert the branch.
Flux makes the dev server again, and its setup Jobs run again. Then restore
the data into it:

```bash
scripts/openbao-migrate.sh import --context $CTX --file "$DIR/export.json" --to dev
scripts/openbao-migrate.sh verify --context $CTX --file "$DIR/export.json" --to dev
```

**Break-glass.** No root token exists after the init Job. If `inf-bao-admin`
cannot log in, scale the `openbao` Deployment to zero and drop database `openbao`.
Then let the init Job run again, and import the export. This loses anything
written after the export.

**Phase 2, built on the same branch.**

- [`connector_secret_store.py`](../../d2-signalloom/apps/fe-signalloom/src/connector_secret_store.py)
  writes each credential to
  `kv/data/signalloom/tenants/<tenant_id>/connectors/<connector_id>`.
  Postgres keeps only `credentials_ref` and `credentials_version` (migration
  078). A CHECK stops a row from holding a reference and a ciphertext
  together.
- The portal logs in as `signalloom-fe-signalloom` through a `jwt-svid`
  sidecar and an `openbao-agent` sidecar, the `fleet-manager` pattern. It
  reads `BAO_TOKEN_FILE` again for each request.
- The policy grants `create`, `read` and `update` on
  `kv/data/signalloom/tenants/+/connectors/+` and `delete` on the matching
  metadata path. It grants nothing broader.
- Per-tenant OpenBao policies are not used. The portal is one identity for all
  tenants, and a per-tenant policy needs one identity for each tenant. The
  portal builds every path from the tenant of the checked principal. It
  refuses an id that is not a safe path segment. It refuses a stored
  reference that is not the path of the row's own tenant and connector.
- If OpenBao cannot be reached, a credential read or write answers 503
  `credential_store_unavailable`. A row that still has only the old
  ciphertext also answers 503. The portal never decrypts it.
- Disconnect deletes the KV metadata, which removes all versions, before it
  marks the row. If OpenBao does not confirm, the answer is 503 and the row
  stays as it was.
- [`migrate_connector_credentials.py`](../../d2-signalloom/apps/fe-signalloom/src/migrate_connector_credentials.py)
  moves the old rows. It is a dry run by default. With `--apply` it opens
  each row with the old key, writes the value to OpenBao, and reads it back.
  Then it changes the row only if the ciphertext did not change. A second run
  changes nothing. `--verify` reads every reference and requires zero sealed
  rows. Its output is counts, never values.

**Cutover runbook, phase 2.** Run this after phase 1 step 5, and after Flux
rolls out the new portal image and manifests. Keep the export from phase 1
until step 10.

```bash
# 7. The portal has a token, and migration 078 ran at start-up.
kubectl --context $CTX -n fe-signalloom rollout status deploy/fe-signalloom --timeout=5m
kubectl --context $CTX -n fe-signalloom exec deploy/fe-signalloom -c discovery-portal -- \
  test -s /var/run/secrets/openbao/token && echo token-present

# 8. Dry run, apply, verify. Each prints one JSON line of counts.
P="kubectl --context $CTX -n fe-signalloom exec deploy/fe-signalloom -c discovery-portal -- python -m migrate_connector_credentials"
$P                 # expect "failed": 0, "would_migrate": N
$P --apply         # expect "failed": 0, "migrated": N
$P --apply         # expect "sealed": 0, "migrated": 0 (idempotent)
$P --verify        # expect "ok": true, "sealed": 0, "unreadable": 0

# 9. Restart survival for the credentials. Expect the same --verify line.
kubectl --context $CTX -n inf-bao rollout restart deploy/openbao
kubectl --context $CTX -n inf-bao rollout status deploy/openbao --timeout=5m
$P --verify

# 10. Destroy the phase 1 export.
shred -u "$DIR/export.json"
```

**Exit steps.** Do these in one commit, only after step 8 `--verify` passes on
the live cluster. Until then keep the sealing key, because a rollback needs
it.

1. Remove `CONNECTOR_CREDENTIAL_KEY_FILE`, the `connector-credential-key`
   volume and its mount from the portal Deployment.
2. Remove `make connector-credential-key`, `scripts/connector-credential-key.sh`
   and its test, and the call in `make demo-signalloom-up`.
3. Remove `connector_credentials.py` and the migration module once no
   environment has a sealed row.
4. Delete the Secret:
   `kubectl --context $CTX -n fe-signalloom delete secret fe-signalloom-connector-credential-key`.
5. Close this entry with the date and that commit.

**Rollback, phase 2.** Before step 8 `--apply`, revert the portal change. The
old code still reads the sealed rows. After `--apply`, the old code cannot
read the moved rows, because their ciphertext is null. Then the rollback is
forward: fix the new code, or ask the tenants to enter their credentials
again.

**Exit criterion.** Close this entry when no connector secret is stored
outside OpenBao and the sealing key Secret no longer exists.

## SA-TODO-004: OpenBao static seal key in a Kubernetes Secret

**Decision.** The principal chose this unseal model on 2026-10-17, for kind
only.

**What it is.** OpenBao 2.7.1 unseals itself with `seal "static"`. The key is
32 random bytes in Secret `inf-bao/openbao-seal-key`, minted once by
[`openbao-secrets.sh`](../../scripts/openbao-secrets.sh) and never replaced.
The server reads it as a file.

**Blast radius.** Anyone who can read this Secret and the `openbao` database
can decrypt all OpenBao storage offline. The OpenBao policies and the audit
log do not see such a read.

**Compensating controls.** The Secret is in `inf-bao` only. The `openbao`
database accepts connections only from the OpenBao pod
(`allow-openbao-storage-ingress`). The key rotates by `previous_key` and a
new `current_key`.

**Candidate replacements.** Cloud KMS auto-unseal on the GCP lane. A Transit
seal from a separate OpenBao. A hardware security module plugin.

**Exit criterion.** Close this entry when no environment outside kind uses
the static seal, and kind is either retired or uses a KMS seal.

## SA-TODO-005: start-up credentials in Kubernetes Secrets

**Decision.** The principal accepted this on 2026-10-17. OpenBao needs these
credentials before it can start, so OpenBao cannot hold them.

**What it is.**

| Secret | Holds | Minted by |
| :--- | :--- | :--- |
| `inf-bao/openbao-storage` | Password and connection URL of Postgres role `openbao` | `make openbao-secrets` |
| `inf-signalloom/postgresql-superuser` | Postgres superuser password | `make postgres-superuser-secret` |
| `fe-signalloom/discovery-portal-database-credentials` | Portal DSN with the superuser password | `make postgres-superuser-secret` |

**Blast radius.** The superuser credential opens every database on the
server, including the `openbao` storage table. The portal and
`signal-ingest` still connect as the superuser.

**Compensating controls.** No manifest carries a value. The scripts send
values on stdin, never on argv. NetworkPolicy limits who can reach port 5432.

**Candidate fix.** Give the portal and `signal-ingest` their own Postgres
roles, with dynamic credentials from the OpenBao database secrets engine.
Keep only the OpenBao storage credential outside OpenBao.

**Exit criterion.** Close this entry when the only start-up credential
outside OpenBao is the OpenBao storage credential.

## SA-TODO-006: OpenBao listens on plain HTTP

**Decision.** The principal accepted HTTP on kind on 2026-10-17.

**What it is.** `listener "tcp"` on port 8200 has `tls_disable = true`. Tokens,
JWT-SVIDs and secret values cross the pod network in clear.

**Blast radius.** A workload that can see pod traffic on the node can read
OpenBao requests and answers.

**Compensating controls.** NetworkPolicy admits port 8200 only from listed
consumers. Tokens last 5 or 15 minutes.

**Candidate fix.** Serve TLS from a certificate that the SPIRE or PKI chain
issues. Give every client the CA bundle.

**Exit criterion.** Close this entry when OpenBao refuses plain HTTP.

## SA-TODO-007: plaintext secrets left in the portal's committed Secrets

**Status.** This is a finding. It was found on 2026-10-17 while the Postgres
password moved out of
[`secrets.yaml`](../../d2-signalloom/apps/fe-signalloom/base/secrets.yaml).

**What it is.** `discovery-portal-database` still holds
`IDENTITY_ENCRYPTION_KEY` as a fixed value. `discovery-portal-storage` holds
the MinIO access key and secret key. Both are in Git.

**Blast radius.** Anyone with read access to the repository can decrypt the
identity data that the key protects, and can use the MinIO credentials.

**Candidate fix.** Keep the identity key in OpenBao, as Transit or KV, and
mint the MinIO credentials per cluster. A key change needs a re-encryption
plan for the stored identity data.

**Exit criterion.** Close this entry when neither Secret carries a value in
Git.
