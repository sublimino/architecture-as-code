# SLDC-P2-GOV: Phase 2 Governor Report: cross-cluster federation

> Status: see `ci-evidence/phase2-governance-certification.json` (`status`, `gates[]`).
> **Human sign-off required before Phase 3 starts.** This report certifies the evidence; it does not approve itself.

| Field | Value |
| :---- | :---- |
| Card | SLDC-P2-GOV (Phase 2 Governor) |
| Integration branch | `integration/sldc-v0.1.0` |
| Merged | SLDC-P2-1 `3598eab5df94a9f93e4cc7b85e1410d2b7fad2a0` (merge `8b55a594`), SLDC-P2-2 `16ed92d1f80ee07947df9562788a21cef461cf39` (merge `8adb1c99`) |
| Runner | `scripts/test-phase2-governor.sh` |
| Suite | `test/phase2-governor-verification.bats` (20 hermetic tests + 1 live) |
| Evidence | `ci-evidence/phase2-governance-certification.json`, `ci-evidence/phase2-token-exchange-audit.txt` |

## What was certified

The runner drives the live dual-Kind topology. `kind-osramp` (`spiffe://osramp.local`) sits on 172.19.0.10 and `kind-signalloom-hub` (`spiffe://signalloom.hub`) on 172.19.0.20, both on `signalloom-bridge`. Every request in G4 to G6 starts in a pod on kind-osramp and crosses the bridge.

| Gate | Assertion | Result on the certified run |
| :--- | :-------- | :-------------------------- |
| G1 merge | P2-1 and P2-2 commits are ancestors of HEAD. A `--no-ff --no-commit` re-merge is a no-op. There are no conflict markers. | Already up to date, 0 markers |
| G2 bringup | `dual-cluster-up.sh`, then `bootstrap-spire-federation.sh apply seed federate entries`. `federation refresh` must succeed in both directions (5 tries, 2s backoff). | Both directions OK |
| G3 tls | `openssl s_client` to `172.19.0.20:31443`, SNI `sl-eap-4b53ab6b.ts.net`. A `-tls1_2` handshake must be refused. | TLSv1.3, `TLS_AES_256_GCM_SHA384`, X25519; TLS 1.2 refused |
| G4 mtls | The osramp pod verifies the hub's `signalloom.hub` X.509-SVID (DNS SAN `sl-eap-4b53ab6b.ts.net`) through the **federated** bundle and presents its own `osramp.local` SVID, which the hub verifies. | `Verification: OK`, `client_verify=SUCCESS` |
| G5 ingest | A JWT-SVID (aud `signal-ingest`, `spiffe://osramp.local/ns/fe-signalloom-agents/sa/kusari-agent`) posts to `/api/v1/observations`. | 201, then 10/10 consecutive 201 with 0 trust errors |
| G6 negative | Anonymous GET/POST; a valid token without read permission (route-existence control); a tampered signature; a rogue.local JWT; a forged osramp.local JWT (unknown key); the wrong audience; an unbound subject; a rogue.local client certificate. signal-ingest must not restart. | 401 / 401 / 403 / 401 / 401 / 401 / 401 / 403 / TLS 400; restarts 0 |
| G7 openbao | `auth/jwt-osramp/login`, role `agent-cardvault`, with the glob subject `…/sa/agent-cardvault-worker-1`; `…/sa/unauthorized-agent`; an expired SVID (entry TTL 10s + 5s leeway). | 200 + client token (`agent-cardvault-policy`) / 400 / 400 |
| G8 mutation | `bound_claims_type` is removed from the role derived from `openbao-supercred-bootstrap.yaml`, then restored. Separately, the client verifies the hub with the wrong (osramp.local) trust bundle. | 400 → 200 restored; TLS verify error, handshake aborted |

The negative gate is built to prevent the "false-pass 404" failure mode. The anonymous 401 counts only because the same route returns 403 to a valid token that lacks `observations:read`, so the router matched the route before it rejected the request.

## Defects found and fixed during the gate

1. **Hub → workload federation was refused (hard-blocker class).** Cilium KPR on kind-osramp attaches BPF NodePort to `eth0` only, so `https://172.19.0.10:31843` refused connections. P2-1 deviation (b) and P2-2 note (1) both predicted this. **Fix:** `d2-agent-trust/spire-federation-bridge-relay.yaml`, a hostNetwork nginx `stream` TCP pass-through bound to `172.19.0.10:31843`, added as bootstrap step `relay` inside `apply`. It never terminates TLS, so the hub still authenticates the SPIRE server end to end. It was chosen over P2-2's suggestion (`hostNetwork` on the spire-server StatefulSet) because it leaves the server's pod networking, Service and PSAT path unchanged and can be removed with one `kubectl delete`.
2. **Node alias in a reserved path.** SPIRE 1.11 rejects `spiffe://osramp.local/spire/node/osramp` ("path is in the reserved namespace"), so `entries` failed on the live server. The P2-2 lab did not catch this. It is now `spiffe://osramp.local/k8s-cluster/osramp`.
3. **Script-name collision.** `scripts/test-phase2-governor.sh` already held the finished CRKC project's Phase 2 runner. That file moved verbatim to `scripts/test-crkc-phase2-governor.sh` and remains reachable as `scripts/test-phase2-governor.sh --crkc`.

## How the hub side was exercised (and why it is a fixture)

Phase 2 delivers the trust plumbing: SPIRE federation, the OpenBao JWT role, and the signal-ingest JWKS config. Nothing on the hub serves it yet, because the Envoy Gateway listener and HTTPRoutes belong to Phase 3 (SLDC-P3-2 and out of scope here). The runner therefore creates a disposable namespace `sldc-p2-gov` on the hub and deletes it on exit, so NodePort 31443 is free for Phase 3:

- **openbao**: OpenBao 2.1.1 in dev mode on NodePort 30820. The root token is generated per run and delivered through a Secret. The CLI runs inside that pod (`scripts/lib/p2gov-bao.sh`), so the token is never on an argv. The host `bao` (v2.7.0, provenance unverified) segfaulted in the bootstrap and is not used.
- **signal-ingest**: image `signal-ingest:sldc-p2-gov-<sha8>`, built from the integration tree, because the cached `signal-ingest:local` predates P2-2's `SIGNAL_AUTH_JWKS_FILE`. It uses the shipped `signal-ingest-jwt-auth` ConfigMap and the federated JWKS written by the bootstrap `signal-ingest` step.
- **audit-db**: Postgres with the `signal_audit_trail` column shape. The protected router refuses to start without a healthy fail-closed audit writer, and the fixture keeps that posture instead of opting into discard.
- **sl-eap-front**: nginx, TLS 1.3 only, NodePort 31443. The server certificate is a `signalloom.hub` X.509-SVID fetched from the hub SPIRE agent. Client certificates are verified against the federated `osramp.local` bundle (`optional`, so anonymous callers reach signal-ingest and get its 401).

Workload identities under test are ephemeral probe pods on kind-osramp (`test/fixtures/phase2-governor/workload-probe.yaml`), one per subject. The namespace `agent-trust` and the entries for `unauthorized-agent` and `agent-cardvault-worker-expiry` exist only for the duration of the run. The entries created by P2-2's bootstrap are left in place.

## Evidence handling

The token-exchange audit records each JWT as its decoded header and claims only. Signatures, OpenBao client tokens and accessors are never written, and BATS enforces this with a paired mutation. Bearer tokens travel to the TLS client and to OpenBao on stdin, never on argv.

## Run history (honest record)

- The first live iterations failed on fixture issues, each fixed before certification: `/healthz` sits behind auth, signal-ingest requires an audit DB, the host `bao` segfaulted, and two harness bugs (a jq redaction filter, and side results lost in `$(...)` subshells).
- One bound run (`4e144983`) returned 502/504 for two G6 probes, which means the front could not reach signal-ingest for a short window. 60 of 60 repeats of those probes returned 401/403 with 0 restarts. The runner now retries only no-response/502/503/504 (5 × 2s, audited), never an auth decision, and fails G6 if signal-ingest restarted.
- A later run aborted in fixture setup because a namespace was still Terminating from a manual teardown. Setup now waits for leftovers, and an aborted run writes a `status=fail` certificate.

## Open items for the principal and Phase 3

1. **Audience replay (from P2-2, still open):** the role's `bound_audiences` is `[signal-ingest, openbao]`, so a cardvault SVID minted for signal-ingest is also accepted by OpenBao. The recommendation is `["openbao"]` only.
2. **Federated key rotation** reaches OpenBao and signal-ingest only when the `openbao` and `signal-ingest` bootstrap steps are re-run. A CronJob or controller is a follow-up.
3. **Phase 3** must supply the real hub listener on 31443 (Envoy Gateway + HTTPRoute) and should reuse this runner's G3 to G6 against it. The fixture front is a stand-in, not a design.
4. The relay pins a hostNetwork port on the shared kind-osramp node. Tear it down with `kubectl --context kind-osramp -n spire-system delete deploy/spire-federation-bridge-relay cm/spire-federation-bridge-relay`.
