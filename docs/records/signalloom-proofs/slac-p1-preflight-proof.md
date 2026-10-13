# SLAC Phase 1 Preflight Verification Proof

- Proposal: [Proposal — Signal Loom In-Cluster Agent Discovery and Auto-Claim (2026-Q3)](file:///home/andy/Documents/Obsidian/v1/2.%20Areas/CEO/Enhancement%20Proposals/Proposal%20%E2%80%94%20Signal%20Loom%20In-Cluster%20Agent%20Discovery%20and%20Auto-Claim%20(2026-Q3).md)
- Shortcode: `SLAC`
- Phase: Phase 1 (Backend & Data Layer)
- Date: 2026-09-08T19:38:00Z
- Integration Branch: `integration/slac-v0.1.0`

---

## 1. Backend Service Readiness

Probe executed from `deploy/dashboard-signalloom` in `fe-signalloom`:
```bash
kubectl -n fe-signalloom exec deploy/dashboard-signalloom -- curl -sS http://fe-signalloom:8000/readyz
```
Output:
```json
{"status":"ready","postgresql":"ready","redis":"disabled"}
```
Result: **PASS (HTTP 200 OK)**

---

## 2. Cluster Workload Status

Pods in `fe-signalloom` and `inf-signalloom`:
```bash
kubectl get pods -n fe-signalloom
```
```
NAME                                     READY   STATUS      RESTARTS       AGE
bao-spire-negative-proof-j9jbn           0/1     Completed   0              6d7h
bao-spire-positive-proof-jfbbh           0/1     Completed   0              6d7h
dashboard-signalloom-788b85c4c5-ft2xx    1/1     Running     0              8h
fe-signalloom-654869cccf-kb6mm           1/1     Running     0              12h
fleet-manager-558784db49-pnx5s           1/1     Running     1 (4d1h ago)   8d
signal-ingest-7fc5f4c6b5-5x8h4           1/1     Running     1 (4d1h ago)   5d16h
supercred-demo-runner-5fdb77fbfc-n6ht2   1/1     Running     0              12h
```

```bash
kubectl get pods -n inf-signalloom
```
```
NAME                                      READY   STATUS    RESTARTS       AGE
cardvault-79f88dc795-4vtbr                1/1     Running   0              30h
dex-77bb7f86cc-n72tx                      1/1     Running   0              3d1h
fake-integration-proxy-5bc6df5554-4z5xh   1/1     Running   0              12h
minio-7f9d759dc8-cnx9z                    1/1     Running   1 (4d1h ago)   8d
netassert-controller-789ff645b9-rs8pp     1/1     Running   0              12h
policy-engine-b6d6d86f4-dqgwd             1/1     Running   0              30h
postgresql-74f986bf-l2zsg                 1/1     Running   1 (4d1h ago)   8d
redis-757fc8df8c-x5r2m                    1/1     Running   1 (4d1h ago)   8d
```
Result: **PASS (All pods Running)**

---

## 3. Database Schema & Governance Baseline

Query executed against `deploy/postgresql` in `inf-signalloom`:
```bash
kubectl exec -n inf-signalloom deploy/postgresql -- psql -U signalloom -d signalloom -c "SELECT count(*) FROM governance_controls;"
```
Output:
```
 count 
-------
     6
(1 row)
```

Baseline governance controls verified:
```
                  id                  |               name               | control_order 
--------------------------------------+----------------------------------+---------------
 c0000000-0000-0000-0000-000000000001 | Traceability                     |             1
 c0000000-0000-0000-0000-000000000004 | CC6.1 -- Logical Access Security |             1
 c0000000-0000-0000-0000-000000000002 | Human Oversight                  |             2
 c0000000-0000-0000-0000-000000000005 | CC6.2 -- System Access Controls  |             2
 c0000000-0000-0000-0000-000000000003 | Incident Attribution             |             3
 c0000000-0000-0000-0000-000000000006 | CC7.2 -- System Monitoring       |             3
(6 rows)
```
Target tables inspected and schemas confirmed:
- `public.agent_registry` (primary agent metadata, status, compliance_posture)
- `public.agent_origin_verifications` (workload pod SVID attestation)
- `public.agent_compliance_results` (control results with foreign keys to governance_controls and agent_registry)
- `public.audit_events` (append-only governance audit log)

Result: **PASS (Database tables and baseline controls verified)**

---

## 4. Git Lineage & Branch Status

```bash
git -C /home/andy/src/cp/osramp-demo status --short
```
Integration branch `integration/slac-v0.1.0` created from HEAD `cd9c89b2` at dedicated Governor worktree `/home/andy/src/.worktrees/osramp-demo/slac-v0.1.0/governor`.

Result: **PASS (Clean base ref and governor worktree)**
