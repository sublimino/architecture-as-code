# Anonymous EAP surface, EAPR-P2-1 (scripts/eap/anon_sweep.py, in-process TestClient, bare app)

## Before — merged base 769090c5 (integration/eapr-v0.1.0 95b68f10 + EAPR-P1-4 4621df93), scratch worktree

```text
Rejected GitHub webhook: signature verification failed
Rejected generic webhook: signature verification or timestamp validation failed
Memory watchdog alert: RSS 115613696 bytes exceeds bound 52428800
ReaperDaemon background reconciliation PAUSED by administrative command.
Memory watchdog alert: RSS 116203520 bytes exceeds bound 52428800
POST   /api/v1/environments/provision                                422  REACHABLE
POST   /api/v1/environments/resolve-domain                           400  REACHABLE
GET    /api/v1/environments/                                         200  REACHABLE
GET    /api/v1/environments/{environment_id}                         404  REACHABLE
POST   /api/v1/environments/{environment_id}/extend                  422  REACHABLE
POST   /api/v1/environments/{environment_id}/teardown                404  REACHABLE
GET    /api/v1/environments/{environment_id}/probe                   404  REACHABLE
POST   /api/v1/webhooks/github                                       401  auth
POST   /api/v1/webhooks/generic                                      401  auth
POST   /api/v1/eap/tenants                                           422  REACHABLE
GET    /api/v1/eap/tenants                                           200  REACHABLE
GET    /api/v1/eap/tenants/{customer_hash}                           404  REACHABLE
DELETE /api/v1/eap/tenants/{customer_hash}                           404  REACHABLE
POST   /api/v1/eap/tenants/{customer_hash}/transit/encrypt           422  REACHABLE
POST   /api/v1/eap/tenants/{customer_hash}/transit/decrypt           422  REACHABLE
GET    /api/v1/eap/tenants/{customer_hash}/manifests                 404  REACHABLE
GET    /api/v1/eap/tenants/{customer_hash}/spire-entry               200  REACHABLE
POST   /api/v1/eap/lifecycle/register                                422  REACHABLE
POST   /api/v1/eap/lifecycle/environments/{customer_hash}/heartbeat  404  REACHABLE
POST   /api/v1/eap/lifecycle/environments/{customer_hash}/activity   404  REACHABLE
GET    /api/v1/eap/lifecycle/environments/{customer_hash}            404  REACHABLE
GET    /api/v1/eap/lifecycle/active                                  200  REACHABLE
POST   /api/v1/eap/lifecycle/reap-now                                200  REACHABLE
POST   /api/v1/eap/lifecycle/reaper/pause                            200  REACHABLE
POST   /api/v1/eap/lifecycle/reaper/resume                           200  REACHABLE
GET    /api/v1/eap/lifecycle/reaper/status                           200  REACHABLE
GET    /api/v1/eap/lifecycle/reaper/dlq                              200  REACHABLE
POST   /api/v1/eap/lifecycle/reaper/dlq/clear                        200  REACHABLE
GET    /api/v1/eap/lifecycle/audit-events                            200  REACHABLE
GET    /api/v1/eap/lifecycle/metrics                                 200  REACHABLE
POST   /api/v1/eap/scenarios/execute                                 201  REACHABLE
GET    /api/v1/eap/scenarios/events/{customer_hash}                  200  REACHABLE
GET    /api/v1/eap/scenarios/events/{customer_hash}/stream           open REACHABLE
GET    /api/v1/eap/scenarios/history                                 200  REACHABLE
WS     /api/v1/environments/{environment_id}/telemetry               -    UNPROBED
positive control GET /health without token: 200
REACHABLE 32 of 34 EAP routes anonymously (non-401/403); 1 websocket route(s) unprobed
```

## After — EAPR-P2-1 206fc5f5 (--expect-zero, rc 0)

```text
POST   /api/v1/environments/provision                                401  auth
POST   /api/v1/environments/resolve-domain                           401  auth
GET    /api/v1/environments/                                         401  auth
GET    /api/v1/environments/{environment_id}                         401  auth
POST   /api/v1/environments/{environment_id}/extend                  401  auth
POST   /api/v1/environments/{environment_id}/teardown                401  auth
GET    /api/v1/environments/{environment_id}/probe                   401  auth
POST   /api/v1/webhooks/github                                       401  auth
POST   /api/v1/webhooks/generic                                      401  auth
POST   /api/v1/eap/tenants                                           401  auth
GET    /api/v1/eap/tenants                                           401  auth
GET    /api/v1/eap/tenants/{customer_hash}                           401  auth
DELETE /api/v1/eap/tenants/{customer_hash}                           401  auth
POST   /api/v1/eap/tenants/{customer_hash}/transit/encrypt           401  auth
POST   /api/v1/eap/tenants/{customer_hash}/transit/decrypt           401  auth
GET    /api/v1/eap/tenants/{customer_hash}/manifests                 401  auth
GET    /api/v1/eap/tenants/{customer_hash}/spire-entry               401  auth
POST   /api/v1/eap/lifecycle/register                                401  auth
POST   /api/v1/eap/lifecycle/environments/{customer_hash}/heartbeat  401  auth
POST   /api/v1/eap/lifecycle/environments/{customer_hash}/activity   401  auth
GET    /api/v1/eap/lifecycle/environments/{customer_hash}            401  auth
GET    /api/v1/eap/lifecycle/active                                  401  auth
POST   /api/v1/eap/lifecycle/reap-now                                401  auth
POST   /api/v1/eap/lifecycle/reaper/pause                            401  auth
POST   /api/v1/eap/lifecycle/reaper/resume                           401  auth
GET    /api/v1/eap/lifecycle/reaper/status                           401  auth
GET    /api/v1/eap/lifecycle/reaper/dlq                              401  auth
POST   /api/v1/eap/lifecycle/reaper/dlq/clear                        401  auth
GET    /api/v1/eap/lifecycle/audit-events                            401  auth
GET    /api/v1/eap/lifecycle/metrics                                 401  auth
POST   /api/v1/eap/scenarios/execute                                 401  auth
GET    /api/v1/eap/scenarios/events/{customer_hash}                  401  auth
GET    /api/v1/eap/scenarios/events/{customer_hash}/stream           401  auth
GET    /api/v1/eap/scenarios/history                                 401  auth
WS     /api/v1/environments/{environment_id}/telemetry               401  auth
positive control GET /health without token: 200
REACHABLE 0 of 34 EAP routes anonymously (non-401/403); 0 of 1 websocket route(s) reachable
```
