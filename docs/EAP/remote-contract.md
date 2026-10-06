# Remote cluster contract: warden, fleet-manager, portal

Describes the tree at the commit named in the git log entry that added this
file. Derives from ADR-11 to ADR-14 in
[the Spireless proposal](../Proposal%20—%20Signal%20Loom%20Spireless%20Token-Based%20Agent%20Identity%20Migration%20%282026-Q4%29.md).
Every builder of the remote path implements exactly this contract. The
pages under `docs/EAP/` describe it to the pilot.

## Roles

- The hub (central cluster) runs signal-ingest, fleet-manager, the portal
  and the dashboard behind the gateway.
- A remote cluster runs only the warden DaemonSet from the `remote-tenant`
  overlay. It holds two keys: a signal-ingest key and a fleet-manager caller
  key. It reaches the hub only through the gateway prefixes `/warden-ingest`
  and `/warden-fleet`.

## TLS

The warden's two HTTP clients read `SIGNAL_TLS_CA_FILE` (a PEM bundle
mounted from a Secret) and `SIGNAL_TLS_INSECURE_SKIP_VERIFY` (`true` only
for development). With neither set the system roots apply. The warden logs
one line at start naming which of the three applies and refuses to start
with `SIGNAL_TLS_INSECURE_SKIP_VERIFY=true` unless `SIGNAL_DEV_MODE=true`.

## Workload report (warden to fleet-manager)

`POST /api/v1/fleet/workloads/report`, caller key scope `report`, body:

```json
{"cluster_id": "kusari-prod", "node": "ip-10-0-1-7", "reported_at": "RFC3339",
 "pods": [{"namespace": "payments", "name": "agent-x-7d6-abc", "uid": "…",
           "owner": {"kind": "Deployment", "name": "agent-x"},
           "tenant": "kusari", "labels": {"signalloom.ai/agent": "true"},
           "frozen": false}]}
```

Sent at start and every `FLEET_REPORT_INTERVAL` (default 60s). fleet-manager
keeps the registry keyed `cluster_id/namespace/name`, drops entries not
reported for three intervals, and serves it at
`GET /api/v1/fleet/workloads?cluster_id=` (scope `read`).

## Stun of a remote workload

`POST /api/v1/fleet/stun/{agent}` resolves `{agent}` first as before, then
against the registry by pod name, `cluster_id/namespace/name`, or owner name.
For a registry hit fleet-manager writes a stun record
`{id, cluster_id, namespace, name, reason, requested_by, requested_at,
state: "stun_requested"}`, audits `agent.stunned` with `remote: true`, and
answers 202 with the record. It takes no local Kubernetes action.

## Stun state and resume

`GET /api/v1/fleet/stun-state?cluster_id=` (scope `report`) returns every
record for that cluster whose state is `stun_requested` or
`resume_requested`. The warden polls it every `FLEET_POLL_INTERVAL`
(default 10s). It freezes the named pod if it is on its node and not frozen,
and it releases the hold for `resume_requested`. It then calls
`POST /api/v1/fleet/stun-state/ack`. The body is:

```json
{"id": "...", "state": "stunned", "node": "ip-10-0-1-7", "at": "RFC3339"}
```

`state` is `stunned` or `resumed`.

`POST /api/v1/fleet/resume/{agent}` on a registry target sets
`resume_requested`. The caller needs the `resume` scope. That scope says who
may ask. It does not say who approved. A remote resume therefore carries a
dual-signed resume token in the body, under the same governance as a local
resume. The token has the same schema as the local one,
`sler.signalloom.io/v1alpha1`. Its `audience` and `trust_root_id` are
fleet-manager's `FLEET_AUDIENCE` and `OPERATOR_TRUST_ROOT_ID`. Its `agent_id`
is the registry pod name and its `namespace` is the pod's namespace, even when
the caller named the owner. fleet-manager verifies the token, consumes it once
in the replay ledger, writes an attested record naming the cluster, and only
then sets `resume_requested`. A request with no token answers `403`. A replayed
token with a different `idempotency_key` answers `409`. A retry with the same
`idempotency_key` answers `202` with the current record and writes nothing.

The operator tool is
[`fleet-manager/cmd/resume-token`](../../d2-signalloom/apps/fleet-manager/cmd/resume-token/main.go).
Run it with `go run ./cmd/resume-token` from
`d2-signalloom/apps/fleet-manager`. The flow is `keygen`, `mint`, `sign`
twice, `request`, then the POST. [`enforcement.md`](enforcement.md#how-to-resume)
walks through it. The existing local path is unchanged.

## Discovery and tenancy

The portal merges `GET /api/v1/fleet/workloads` into `/api/agents` as
discovered remote workloads with `origin: "remote"` and the reported
tenant. A non-superadmin sees only agents whose tenant is their own. The
remote-tenant overlay takes the tenant map and cluster id as parameters,
so a remote pod is attributed to the pilot tenant, never `__unattributed__`.
