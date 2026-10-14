<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 ControlPlane Security Authors -->

# `APPLIANCE_MODE=attached`: central issuance is a prerequisite

> **The one-sentence version.** `attached` mode cannot self-provision, because
> two Secrets it requires are minted on the vendor's central cluster and are
> never issued locally.

A design partner therefore cannot bring an `attached` appliance up unaided. A
vendor operator must issue the credentials out-of-band first.

**Scope.** This page is the prerequisite statement for Decision 8
(`APPLIANCE_MODE=hub|attached`). `hub` mode needs none of it. A hub runs its
own issuers and mints everything it consumes. Everything below applies to
`attached` mode only.

[`EAP/secondary-cluster.md`](EAP/secondary-cluster.md) is the operational
runbook for the Kusari pilot. This page is the credential contract that runbook
assumes. [`EAP/remote-contract.md`](EAP/remote-contract.md) is the wire
contract.

---

## 1. The asymmetry, stated plainly

| | `APPLIANCE_MODE=hub` | `APPLIANCE_MODE=attached` |
| :--- | :--- | :--- |
| Renders | the hub components | `d2-signalloom/infra/agent-swarm/signalloom-warden-overlays/remote-tenant` |
| Issuers present locally | yes (signal-ingest, fleet-manager, SPIRE, OpenBao) | **no** — none of them run here |
| Can mint its own credentials | yes | **no** |
| Blocked without an out-of-band step | no | **yes** |

Both halves ship in the same appliance. One variable selects between them,
which makes them look interchangeable. They are not. Selecting `attached` is an
assertion that somebody else has already done work on another cluster.

## 2. The two Secrets, precisely

Both live in namespace `inf-signalloom-warden` on the attached cluster. Both are
consumed by the `sentinel` container of the `signalloom-warden` DaemonSet.

In the `remote-tenant` overlay both key refs are `optional: false`. A missing
Secret therefore holds the pod in `ContainerCreating`. It does not let the pod
start and silently do nothing.

| Secret | Key | Consumed as | Consumer | What mints it, centrally |
| :--- | :--- | :--- | :--- | :--- |
| `signalloom-warden-ingest-token` | `token` | `SIGNAL_INGEST_TOKEN` | `signalloom-warden` DaemonSet, container `sentinel` | a signal-ingest **named key** `signalloom-warden`, minted by `scripts/sldc-ingest-bearer.sh` on the central cluster |
| `signalloom-warden-fleet-key` | `token` | `FLEET_MANAGER_STUN_KEY` | `signalloom-warden` DaemonSet, container `sentinel` | a fleet-manager **caller key**, caller `warden`, scope `report`, minted by `scripts/fleet-manager-caller-keys.sh` on the central cluster |

A third Secret is optional by design. It is not part of this prerequisite.

| Secret | Key | Consumed as | Behaviour when absent |
| :--- | :--- | :--- | :--- |
| `signalloom-hub-ca` | `ca.pem` | mounted at `SIGNAL_TLS_CA_FILE` (`/etc/signalloom/hub-ca/ca.pem`) | the warden falls back to the system root pool and keeps running. Needed only when the hub gateway serves a certificate the nodes do not already trust. |

### Why `optional: false` is correct here

On the central cluster both key refs are optional on purpose. The warden
enforces locally, and a missing key must never stop a freeze.

A remote warden is different. It has no local consumer of its observations and
no local fleet-manager. A keyless pod there does nothing except freeze pods
nobody can see or release. It also cannot report its workloads, so the hub
never learns the cluster exists.

`optional: false` converts that silent no-op into a visible wait. This page
exists to make the wait unnecessary. The preflight in §5 exists to make it
legible when it happens anyway.

## 3. The ordered prerequisite

Steps 1 to 3 belong to the vendor operator, on the central cluster. A design
partner cannot perform any of them. The scripts read and write central cluster
state through a central-cluster context, and the key material they derive has
meaning only to central issuers.

1. **Mint the signal-ingest named key** (vendor, central cluster).

   ```bash
   scripts/sldc-ingest-bearer.sh --context "$CENTRAL" --key signalloom-warden
   ```

   This must run first. The emitter in step 2 reads this key rather than
   minting one. It fails with a message naming this command if the key is
   absent.

2. **Emit both Secret manifests** (vendor, central cluster).

   ```bash
   scripts/fleet-manager-caller-keys.sh --context "$CENTRAL" \
     --emit-remote-secrets /secure/transfer
   ```

   It mints the `warden` caller key at scope `report` and reads the ingest key
   from step 1. It writes two files into a directory it creates mode `0700`,
   each file mode `0600`:

   - `/secure/transfer/signalloom-warden-fleet-key.yaml`
   - `/secure/transfer/signalloom-warden-ingest-token.yaml`

   `scripts/sldc-ingest-bearer.sh` accepts the same `--emit-remote-secrets`
   flag for its own consumer Secrets.

3. **Transfer, then delete** (vendor).

   Both files hold key material as clear base64. The manifests are not
   encrypted. They are not safe to mail, to drop in a ticket, or to commit.

   Hand them to the design partner over the agreed secure channel, confirm
   receipt, then delete the staging directory.

Steps 4 and 5 belong to the design partner, on their own cluster.

4. **Create the namespace and apply both Secrets, before anything else.**

   ```bash
   kubectl apply -k d2-signalloom/infra/agent-swarm/signalloom-warden-namespace
   kubectl -n inf-signalloom-warden apply -f signalloom-warden-ingest-token.yaml
   kubectl -n inf-signalloom-warden apply -f signalloom-warden-fleet-key.yaml
   ```

   Order is load-bearing, not hygiene. With `optional: false` key refs, a
   DaemonSet created first sits in `ContainerCreating` until the Secrets
   arrive.

5. **Then, and only then, select `attached`.** That renders the `remote-tenant`
   overlay. Run the preflight in §5 first. It takes one second, and it is the
   difference between a named failure and a buried pod event.

### What the design partner still owns

Three overlay parameters are theirs, and they are not credentials. This
prerequisite does not cover them, but a wrong value is as visible as a missing
Secret.

- `SIGNAL_CLUSTER_ID`, which must be unique across every cluster reporting to
  one hub.
- The two hub URLs.
- `SENTINEL_TENANT_MAP`, the only source of an observation's tenant. Left
  inherited, every pod on the cluster reports `__unattributed__`.

## 4. What the design partner cannot do, and why that is the finding

There is no local path to either credential. Not a harder path. No path.

- `signal-ingest` does not run on an attached cluster. There is nothing local
  to mint an ingest key against. The key's only meaning is as a named key the
  central `signal-ingest` recognises.
- `fleet-manager` does not run on an attached cluster either. The caller key is
  validated centrally, and its scope `report` is a central authorisation
  decision rather than a local one.
- The `remote-tenant` overlay's own header records both as never issued here.

So `attached` mode has a hard dependency on a human on the vendor side. The
appliance's self-initialisation story stops at that boundary.

That is a property to schedule around rather than a bug to fix in the
appliance. The alternative is letting a design partner mint credentials that
authorise writes into another tenant's registry rows.

## 5. The enforceable form

Prose nobody reads is not a prerequisite. `scripts/attached-mode-preflight.sh`
asserts it.

```bash
APPLIANCE_MODE=attached scripts/attached-mode-preflight.sh
```

- **Exit 0** — both required Secrets are present and non-empty. A `WARN` line
  appears if the optional hub CA is absent.
- **Exit 1** — the output names each missing Secret and its key. It names the
  command that mints it, states that the command runs on the central cluster,
  and states that this appliance cannot run it.
- **Exit 2** — usage, or an `APPLIANCE_MODE` it does not recognise. It does not
  guess.

The script is read-only. It issues `get` only, and it never prints a secret
value. It reports only whether a value is present. In `hub` mode it exits 0
without querying a cluster at all.

`scripts/remote-tenant-lab.sh` runs it as step 3b, immediately after applying
the Secrets. The lab therefore proves the gate as well as the path.

The contract is pinned by `test/attached-mode-preflight.bats`.

## 6. Open item for the principal: the escrow bundle

The decision that produced this page carried a hedge. The principal's words
were "they are also stored in a backup encryption file if I remember
correctly".

That was investigated. The recollection points at a real design artefact, but
it is a different artefact. Nothing on this page should be read as saying
otherwise.

**What exists, and where.** Decision 3 of 2026-10-10, and card P2-1 in the SLSI
proposal, specify an encrypted escrow backup bundle named
`<tenant-id>-escrow.tar.enc`. It is emitted to `/opt/tenants/<id>/escrow/` at
bootstrap by a planned tenant-initialisation script. It is encrypted with an
operator-supplied passphrase or public key.

**Why it is not the answer to this page.** Two independent reasons.

1. **Wrong contents.** Decision 3 and P2-1 scope the escrow to the keys the
   appliance mints itself. Those are Cosign, Witness, Orbit approval, the SPIRE
   CA configuration, and the fleet-operator material under `.keys`. Neither
   Secret in §2 is in that set, and neither could be. Both are minted on the
   central cluster and, per the overlay, never issued locally. An escrow of
   locally minted material cannot hold a credential that is never minted
   locally.
2. **Not implemented.** The tenant-initialisation script that would emit the
   bundle does not exist on this tree, and neither does `/opt/tenants`. The
   repository holds exactly two live references to `*-escrow.tar.enc`, and both
   are exclusion patterns. `scripts/package-tenant-bundle.sh` and
   `test/slsi-bundle-manifest.bats` each assert that no such file ships inside
   a tenant bundle. That is the opposite of a delivery channel.

**Channels checked.** An empty search result is not evidence of absence, so
each claim was confirmed through something a sandbox cannot silently blank.

- `rg` and `grep -ril` over the whole tree, for `escrow`, `tar.enc`, `sops`,
  `age-keygen`, `sealed-secret`, `openssl enc`, and backup phrasings.
- `fd` for `.age`, `.gpg`, `.enc`, `.sops` and `.asc` files.
- For each claimed path, both `ls` and `test -r` or `test -d`, with the exit
  status read directly rather than through a pipe.
- A positive control. `test -r /opt` succeeds while `test -d /opt/tenants`
  fails, which distinguishes "absent" from "not permitted to look".

**The ask.** The principal confirms which of these is meant.

- **(a)** The escrow bundle above. Nothing changes here. It is a recovery
  mechanism for locally minted keys, and this prerequisite stands as written.
- **(b)** A separate store, outside this repository, holding copies of the two
  central warden Secrets. A password manager entry or an encrypted archive on
  the vendor side would both qualify. If so, name it. It then becomes the
  documented transfer channel for step 3 of §3, replacing the phrase "the
  agreed secure channel".

Until that is confirmed, step 3 of §3 deliberately says "the agreed secure
channel" and makes no claim about a backup file.
