# Signal Loom discovery-portal runtime contract

**Card:** SLDPB-P1-1
**Evidence boundary:** Source inspection only; paths and line numbers below are relative to `/home/andy/src/cp/platform`.
**Assessment date:** 2026-07-25

This is a reviewable runtime contract, not a claim about deployed Azure state. “Observed” records what the source says. “Recommendation” records the proposed D2 landing decision.

## 1. Service purpose and ownership

### Observed

- The service is a FastAPI application titled **Signal Loom Discovery Portal**, version `0.1.0`, with discovery and frontend routers. (`services/discovery-portal/main.py:45-53`, `services/discovery-portal/main.py:103-105`)
- Its discovery flow accepts a business email, company, industry, selected platforms, and platform credentials; it creates a scan session and starts discovery of OpenAI, Bedrock, or Foundry agents. (`services/discovery-portal/routers/discovery.py:30-46`, `services/discovery-portal/routers/discovery.py:187-261`)
- The infrastructure description calls it the “Enterprise Discovery (edisc v0) backend” and identifies `discovery.signal-loom.ai` as the intended public Front Door hostname. (`infrastructure/terraform/discovery-portal-app.tf:1-5`)
- No application-level owner or on-call team is declared in the service source. Terraform applies the generic tag `owner = "security-program-owner"`; that is an ownership signal, not a named operational owner. (`infrastructure/terraform/main.tf:48-59`)

### Owner decision

- **Proposed owner:** Signal Loom platform/application team, with security-program-owner as accountable business owner pending confirmation.
- **Unknown owner:** The named service owner, on-call rotation, escalation path, and SLA/SLO are not present in the inspected source. Gate A must assign these before production exposure.

## 2. Container, process, health, and readiness

### Observed

- The image is `python:3.12-slim`, runs as non-root `appuser`, exposes TCP port `8000`, and starts two Uvicorn workers with `main:app` on `0.0.0.0:8000`. (`services/discovery-portal/Dockerfile:1-15`)
- The Docker healthcheck performs an HTTP `GET`-equivalent probe of `http://localhost:8000/health` every 30 seconds, with a 5-second timeout and three retries. (`services/discovery-portal/Dockerfile:12-14`)
- The application exposes `GET /health` returning `{"status": "ok"}`. (`services/discovery-portal/main.py:107-109`)
- Application startup initializes an async PostgreSQL pool and creates a Redis client when `REDIS_URL` is configured; shutdown closes both resources. (`services/discovery-portal/main.py:22-43`)
- The current `/health` handler does not check PostgreSQL or Redis, so it is a process/HTTP health signal rather than a dependency-readiness signal. (`services/discovery-portal/main.py:22-43`, `services/discovery-portal/main.py:107-109`)
- The current Container App liveness and readiness probes both call `/health` on port 8000; liveness waits 15 seconds, then probes every 30 seconds with a 5-second timeout and threshold 3, while readiness probes every 10 seconds with threshold 3. (`infrastructure/terraform/discovery-portal-app.tf:113-130`)

### Kubernetes contract recommendation

- Use a `Deployment` with a single container listening on `8000`, initially one replica, and a `Service` targeting that port. Preserve non-root execution and the Uvicorn command, but validate whether two workers per pod is appropriate before scaling replicas. The one-replica starting point and current `min_replicas = 1` are source-backed baseline choices. (`infrastructure/terraform/discovery-portal-app.tf:78-86`)
- Implement a distinct readiness endpoint before pilot: it should fail until the database pool is initialized and should report Redis degradation explicitly if Redis remains optional. Keep `/health` cheap for liveness. This is a recommendation because the source currently has only one dependency-agnostic endpoint. (`services/discovery-portal/main.py:22-43`, `services/discovery-portal/main.py:107-109`)
- Suggested probe starting values: startup probe for the slowest cold start; liveness on `/health`; readiness on the new dependency-aware endpoint. Calibrate timeout and failure thresholds from test evidence rather than treating the current Container App values as Kubernetes defaults. (`infrastructure/terraform/discovery-portal-app.tf:113-130`)

## 3. Configuration and secret names

The following are names only. No values, tokens, connection strings, or `.env` content are reproduced.

### Observed non-secret configuration

| Name | Source | Classification |
| --- | --- | --- |
| `ENVIRONMENT` / `environment` | Pydantic settings; Terraform injects `ENVIRONMENT` | Non-secret runtime mode; controls docs/OpenAPI exposure. (`services/discovery-portal/config.py:3-10`, `infrastructure/terraform/discovery-portal-app.tf:103-106`, `services/discovery-portal/main.py:45-53`) |
| `LOG_LEVEL` / `log_level` | Pydantic settings; Terraform injects `LOG_LEVEL` | Non-secret operational setting. (`services/discovery-portal/config.py:7-10`, `infrastructure/terraform/discovery-portal-app.tf:108-111`) |
| `CORS_ALLOWED_ORIGINS` / `cors_allowed_origins` | Pydantic settings | Non-secret browser policy; defaults are source-defined and must be reviewed for the target hostname. (`services/discovery-portal/config.py:4-10`, `services/discovery-portal/main.py:74-81`) |
| `FRONTDOOR_ID` | Process environment | Sensitive configuration: origin-lock identifier; not a credential, but must be protected from accidental disclosure and injected from deployment configuration. (`services/discovery-portal/main.py:20-20`, `services/discovery-portal/main.py:57-72`) |
| `BOOKING_URL` | Process environment | Non-secret external-link configuration. (`services/discovery-portal/routers/frontend.py:16-27`, `services/discovery-portal/routers/discovery.py:213-221`) |
| `CONSENT_VERSION` | Process environment | Non-secret consent/version configuration. (`services/discovery-portal/routers/frontend.py:11-13`, `services/discovery-portal/routers/frontend.py:16-27`) |
| `CONSENT_MODAL_ENABLED` | Process environment | Non-secret feature flag with a production-default-off behaviour. (`services/discovery-portal/routers/frontend.py:11-13`) |
| `FREE_SCAN_INTERVAL_MONTHS` | Process environment | Non-secret rate-policy configuration, parsed with a minimum of one month. (`services/discovery-portal/constants.py:1-8`) |
| `AZURE_STORAGE_ACCOUNT` | Process environment | Non-secret resource identifier; required to construct the Blob endpoint, but its absence prevents report upload. (`services/discovery-portal/integrations/blob_storage.py:20-32`) |
| `GMAIL_SENDER` | Process environment / Container App secret-backed env in the current Terraform | Identity/address configuration; source comments say it is the Workspace user impersonated by Gmail DWD. (`services/discovery-portal/integrations/email.py:14-20`, `services/discovery-portal/integrations/email.py:116-130`, `infrastructure/terraform/discovery-portal-app.tf:48-51`) |
| `GMAIL_FROM` | Process environment | Non-secret visible sender address, subject to mail-provider policy. (`services/discovery-portal/integrations/email.py:41-43`, `services/discovery-portal/integrations/email.py:80-84`) |
| `TEAM_REPORT_RECIPIENTS` | Process environment | Non-secret routing configuration, though it contains personal/work addresses and should be treated as restricted configuration. (`services/discovery-portal/integrations/email.py:35-38`) |
| `HUBSPOT_DISCOVERY_SEQUENCE_ID` | Process environment | Non-secret external workflow identifier. (`services/discovery-portal/integrations/hubspot.py:130-145`) |

### Observed secret or credential material

| Name | Source | Classification and delivery requirement |
| --- | --- | --- |
| `DATABASE_URL` / `database_url` | Settings and Terraform secret reference `postgresql-connection-string` | **Secret:** PostgreSQL DSN/credential material; deliver from a Kubernetes Secret or external secret store, never ConfigMap. (`services/discovery-portal/config.py:3-6`, `services/discovery-portal/db/connection.py:29-39`, `infrastructure/terraform/discovery-portal-app.tf:36-40`, `infrastructure/terraform/discovery-portal-app.tf:88-91`) |
| `REDIS_URL` / `redis_url` | Settings and Terraform secret reference `redis-url` | **Secret:** Redis connection URL; deliver from a Kubernetes Secret or external secret store. (`services/discovery-portal/config.py:3-6`, `services/discovery-portal/main.py:27-36`, `infrastructure/terraform/discovery-portal-app.tf:42-46`, `infrastructure/terraform/discovery-portal-app.tf:93-96`) |
| `GMAIL_SA_KEY_JSON` | Gmail integration | **High-sensitivity secret:** service-account JSON key used for domain-wide delegation; external-secret delivery and rotation are mandatory. (`services/discovery-portal/integrations/email.py:14-20`, `services/discovery-portal/integrations/email.py:116-130`) |
| `GMAIL_SENDER` | Gmail integration | **Sensitive identity configuration:** impersonated Workspace principal; source treats it as required for sending. (`services/discovery-portal/integrations/email.py:116-130`) |
| `HUBSPOT_API_KEY` | HubSpot integration | **High-sensitivity secret:** bearer credential for HubSpot API calls. (`services/discovery-portal/integrations/hubspot.py:27-38`, `services/discovery-portal/integrations/hubspot.py:74-100`) |
| `SLACK_DISCOVERY_WEBHOOK` | HubSpot/notification integration | **Secret:** webhook URL, optional but capable of receiving scan metadata and report links. (`services/discovery-portal/integrations/hubspot.py:148-171`) |
| Request credential fields: `openai_api_key`, `aws_access_key_id`, `aws_secret_access_key`, `azure_client_secret` | Scan request and connector extraction | **Customer-provided secrets:** accepted in request memory, passed to a background task, and documented as not written to the database; this is a high-risk design boundary requiring TLS, log redaction, memory-lifetime review, and a retention policy. (`services/discovery-portal/routers/discovery.py:30-35`, `services/discovery-portal/routers/discovery.py:63-81`, `services/discovery-portal/routers/discovery.py:250-259`, `services/discovery-portal/orchestrator.py:24-37`, `services/discovery-portal/orchestrator.py:287-307`) |

The current Terraform explicitly says additional live environment variables and secrets for HubSpot, booking, Blob Storage, and `FRONTDOOR_ID` are configured out of band and ignored by Terraform. The Kubernetes contract must eliminate that undocumented drift by declaring names and delivery ownership in the deployment manifest or external-secret source, without placing values in Git. (`infrastructure/terraform/discovery-portal-app.tf:54-57`, `infrastructure/terraform/discovery-portal-app.tf:134-141`)

## 4. Managed-service dependencies and network needs

### Observed dependencies

- **PostgreSQL:** startup creates an asyncpg pool with 2–10 connections and a 30-second command timeout; scan sessions and discovered agents are persisted in PostgreSQL. (`services/discovery-portal/db/connection.py:29-39`, `services/discovery-portal/db/migrations/001_discovery_tables.sql:8-44`)
- **Redis:** used for per-domain and per-IP rate limiting; the code fails open when Redis is absent or errors, so Redis is operationally important but not currently correctness-enforcing. (`services/discovery-portal/main.py:27-36`, `services/discovery-portal/routers/discovery.py:141-184`)
- **Azure Blob Storage:** completed PDF reports are uploaded to the `discovery-reports` container using `DefaultAzureCredential`, overwrite semantics, and a seven-day user-delegation SAS URL. (`services/discovery-portal/integrations/blob_storage.py:1-5`, `services/discovery-portal/integrations/blob_storage.py:20-73`)
- **Microsoft Azure identity and management APIs:** the Foundry connector uses a client-secret credential, resource-group listing, Azure Machine Learning workspace/deployment APIs, and online endpoint/deployment enumeration. (`services/discovery-portal/connectors/foundry_connector.py:6-10`, `services/discovery-portal/connectors/foundry_connector.py:17-63`, `services/discovery-portal/connectors/foundry_connector.py:65-102`)
- **AWS Bedrock:** the Bedrock connector uses AWS access-key credentials, scans four fixed regions concurrently, and calls Bedrock Agent list/get/action-group APIs. (`services/discovery-portal/connectors/bedrock_connector.py:13-31`, `services/discovery-portal/connectors/bedrock_connector.py:48-101`)
- **OpenAI:** the OpenAI connector calls the Assistants API over HTTPS with a bearer key and paginates up to ten pages of 100 assistants. (`services/discovery-portal/connectors/openai_connector.py:8-8`, `services/discovery-portal/connectors/openai_connector.py:17-35`, `services/discovery-portal/connectors/openai_connector.py:70-92`)
- **HubSpot:** successful scans optionally upsert a contact, attach a report note, enroll a sequence, and notify via Slack webhook; each side effect is non-fatal. (`services/discovery-portal/orchestrator.py:198-216`, `services/discovery-portal/integrations/hubspot.py:174-227`)
- **Gmail/Google Workspace:** successful scans optionally send an internal PDF copy via Gmail API using service-account domain-wide delegation, in a worker thread. (`services/discovery-portal/orchestrator.py:207-216`, `services/discovery-portal/integrations/email.py:1-20`, `services/discovery-portal/integrations/email.py:145-165`)

### Inbound and outbound contract

- Inbound routes are `GET /`, `GET /legal/terms`, `GET /legal/privacy`, `GET /legal/eula`, `GET /health`, `POST /api/discovery/scan`, `GET /api/discovery/scan/{session_id}`, and `GET /api/discovery/scan/{session_id}/agents`; static assets are mounted below `/static`. (`services/discovery-portal/routers/frontend.py:8-52`, `services/discovery-portal/main.py:55-55`, `services/discovery-portal/main.py:103-109`, `services/discovery-portal/routers/discovery.py:20-20`, `services/discovery-portal/routers/discovery.py:187-333`)
- Terraform enables external HTTPS ingress to target port 8000 and relies on an application-layer `X-Azure-FDID` origin lock; `/health` is explicitly exempt from that lock. (`infrastructure/terraform/discovery-portal-app.tf:59-70`, `services/discovery-portal/main.py:57-72`)
- The application allows configured CORS origins, credentials, GET/POST/OPTIONS, and all headers. (`services/discovery-portal/main.py:74-81`)
- Outbound access is required to PostgreSQL, Redis, Azure Blob, Microsoft identity/management endpoints, AWS APIs in four regions, OpenAI, HubSpot, Slack when configured, and Google Gmail APIs. These destinations are inferred directly from the connector and integration URLs/client usage; live firewall reachability is not established by this document. (`services/discovery-portal/connectors/openai_connector.py:8-35`, `services/discovery-portal/connectors/bedrock_connector.py:48-76`, `services/discovery-portal/connectors/foundry_connector.py:41-80`, `services/discovery-portal/integrations/blob_storage.py:31-36`, `services/discovery-portal/integrations/hubspot.py:21-22`, `services/discovery-portal/integrations/email.py:123-130`)
- The portal does not invoke shared Entra/Auth0 bearer-token validation in the inspected `main.py` or discovery router. Its explicit inbound trust assumption is Front Door FDID matching when `FRONTDOOR_ID` is set; customer cloud credentials are submitted in the scan request. (`services/discovery-portal/main.py:57-72`, `services/discovery-portal/routers/discovery.py:187-224`)

## 5. Tenant context and data isolation

### Observed

- The discovery schema stores `email_domain`, company, industry, platforms, scan status, report URL, and discovered agents; agent rows are linked to sessions by `session_id` with cascade deletion. (`services/discovery-portal/db/migrations/001_discovery_tables.sql:8-44`)
- Discovery status and agent reads query by `session_id` only; the endpoints do not require a tenant identifier or authenticated principal, and there is no tenant column or PostgreSQL RLS policy in this service migration. (`services/discovery-portal/routers/discovery.py:264-333`, `services/discovery-portal/db/migrations/001_discovery_tables.sql:8-44`)
- The session UUID is returned to the caller and is the only lookup key used by the status and agents endpoints. (`services/discovery-portal/routers/discovery.py:240-261`, `services/discovery-portal/routers/discovery.py:264-333`)

### Gate A isolation decision

- **Current assumption:** this is a prospect/free-scan workflow keyed by an unguessable UUID, not a tenant-aware authenticated product service.
- **Risk:** possession of a session UUID appears sufficient to read status, errors, report URL, and discovered agent data; UUID secrecy is not a substitute for authorization. (`services/discovery-portal/routers/discovery.py:264-333`)
- **Required before a multi-tenant Kubernetes pilot:** define the tenant/customer principal, bind every session and agent row to that tenant, authorize reads and report downloads, and add database-level isolation or an equivalent tested access-control boundary. Do not import the shared platform tenant-context model without adapting this schema: the inspected discovery service does not currently use it. This is a recommendation based on the observed schema and routes. (`services/discovery-portal/db/migrations/001_discovery_tables.sql:8-44`, `services/discovery-portal/routers/discovery.py:264-333`)

## 6. Background behaviour, restart, idempotency, and scaling

### Observed

- `POST /scan` inserts a `pending` row, then schedules `run_scan` through FastAPI `BackgroundTasks` while immediately returning a session ID and `scanning` status. (`services/discovery-portal/routers/discovery.py:224-261`)
- The scan runs connectors concurrently; Bedrock also scans its four regions concurrently, while report PDF generation is offloaded to a thread. (`services/discovery-portal/orchestrator.py:88-110`, `services/discovery-portal/orchestrator.py:170-183`, `services/discovery-portal/connectors/bedrock_connector.py:24-31`)
- An outer exception handler marks a failed session and clears the domain rate-limit key where possible; connector failures can be partial, while Blob, HubSpot, and email failures are recorded as non-fatal side effects except that missing report upload makes the overall scan failed. (`services/discovery-portal/orchestrator.py:24-65`, `services/discovery-portal/orchestrator.py:136-219`)
- Database migration creation is idempotent, and report upload overwrites the deterministic `{session_id}/report.pdf` blob path. (`services/discovery-portal/db/migrations/001_discovery_tables.sql:1-6`, `services/discovery-portal/integrations/blob_storage.py:31-46`)
- The current infrastructure requests one to three replicas in Single revision mode. (`infrastructure/terraform/discovery-portal-app.tf:18-24`, `infrastructure/terraform/discovery-portal-app.tf:78-86`)

### Constraints and recommendations

- FastAPI `BackgroundTasks` is process-local and has no durable queue or lease in the inspected code. A pod restart, revision replacement, or worker failure can therefore interrupt work after the session is created; a retry may duplicate external side effects. This is an inference from the scheduling mechanism and absence of a durable worker/queue in the inspected service. (`services/discovery-portal/routers/discovery.py:187-261`, `services/discovery-portal/orchestrator.py:24-307`)
- Do not scale this workload horizontally for reliability until scans are moved to a durable queue/worker model or the session state machine has explicit claim, lease, retry, and idempotency keys. At minimum, make report upload, HubSpot updates, email, and final database writes safe to retry. Recommendation based on the observed non-transactional fan-out. (`services/discovery-portal/orchestrator.py:139-219`, `services/discovery-portal/integrations/blob_storage.py:42-46`)
- Bound concurrency and request duration at the ingress and worker layers: the source has connector-specific limits, but no global scan timeout or admission control beyond IP/domain rate limits. (`services/discovery-portal/connectors/openai_connector.py:20-26`, `services/discovery-portal/routers/discovery.py:141-184`)

## 7. Proposed Kubernetes landing shape

This section is **recommendation**, not observed deployed state.

- **Namespace:** a dedicated `signalloom-discovery` namespace, separated from platform control-plane workloads and with a default-deny NetworkPolicy baseline.
- **Workload:** `Deployment` plus `Service`, initially one replica and one Uvicorn process container contract on port 8000; add a separate durable scan worker deployment only after queue semantics are designed. The current source already separates HTTP submission/status from `run_scan`, but does not provide a separate worker process. (`services/discovery-portal/routers/discovery.py:187-261`, `services/discovery-portal/orchestrator.py:24-75`)
- **Service account:** a dedicated service account with only the permissions needed for external-secret retrieval and Azure Blob user-delegation access; no broad namespace or cluster administration. The current Azure shape uses a dedicated user-assigned identity for registry pull and Key Vault secret reads, which is the boundary to preserve conceptually. (`infrastructure/terraform/discovery-portal-app.tf:7-15`, `infrastructure/terraform/discovery-portal-app.tf:26-45`, `infrastructure/terraform/discovery-portal-app.tf:154-167`)
- **Config delivery:** ConfigMap for non-sensitive mode/feature/routing settings; Secret or ExternalSecret for `DATABASE_URL`, `REDIS_URL`, `GMAIL_SA_KEY_JSON`, `HUBSPOT_API_KEY`, `SLACK_DISCOVERY_WEBHOOK`, and the customer-credential handling boundary. Never put customer request credentials in pod environment variables. Names and current secret references are source-backed. (`services/discovery-portal/config.py:3-10`, `infrastructure/terraform/discovery-portal-app.tf:36-57`)
- **Probes:** liveness `/health`; readiness must be dependency-aware; add startup protection for image/import/pool initialization. The current probes are both `/health`, so copying them unchanged would mask dependency failure. (`services/discovery-portal/main.py:22-43`, `services/discovery-portal/main.py:107-109`, `infrastructure/terraform/discovery-portal-app.tf:113-130`)
- **Network policy:** allow ingress only from the selected gateway/Front Door integration, allow egress only to PostgreSQL, Redis, DNS, the identity/secret path, Blob, OpenAI, AWS, Azure ML/resource management, HubSpot, Slack, and Gmail destinations required by enabled features. Exact IPs and private endpoints require environment-specific validation; this document makes no live-network claim. Existing Terraform defines database and private-DNS network primitives but the Container Apps environment has documented dev/private-egress limitations. (`infrastructure/terraform/modules/networking/main.tf:9-38`, `infrastructure/terraform/modules/networking/main.tf:134-194`, `infrastructure/terraform/modules/container-apps/main.tf:53-56`)
- **Resources:** start from the current `0.5 CPU` and `1Gi` memory request/limit intent, then measure PDF generation and concurrent connector scans before setting Kubernetes requests/limits. (`infrastructure/terraform/discovery-portal-app.tf:82-86`)
- **Exposure:** keep the public route behind a gateway that supplies an authenticated, non-spoofable origin signal; do not expose the Service directly. The current design depends on Front Door plus an app-layer FDID check, and health is intentionally public. (`infrastructure/terraform/discovery-portal-app.tf:59-70`, `services/discovery-portal/main.py:57-72`)

## 8. Gate A questions and risks

1. Who is the named service owner and on-call? The source only provides a generic owner tag. (`infrastructure/terraform/main.tf:48-59`)
2. Is this intentionally anonymous/prospect-facing, or must it become tenant-authenticated? The inspected discovery routes have no bearer-token or tenant authorization. (`services/discovery-portal/routers/discovery.py:187-333`)
3. What is the required data-retention and deletion policy for email, company data, discovered agents, PDF reports, SAS URLs, logs, and customer-supplied credentials? The migration has no retention/deletion workflow, and the Blob URL lasts seven days. (`services/discovery-portal/db/migrations/001_discovery_tables.sql:8-44`, `services/discovery-portal/integrations/blob_storage.py:52-72`)
4. Is `GMAIL_SA_KEY_JSON` permitted in the target platform, or must Gmail DWD be replaced with workload identity/federated credentials? The source currently requires a full service-account JSON key. (`services/discovery-portal/integrations/email.py:14-20`, `services/discovery-portal/integrations/email.py:116-130`)
5. Which external APIs are enabled in the pilot, and what egress/RBAC scopes and rate limits are approved for each connector? The code scans four Bedrock regions and enumerates broad Foundry resource groups/workspaces. (`services/discovery-portal/connectors/bedrock_connector.py:13-46`, `services/discovery-portal/connectors/foundry_connector.py:51-102`)
6. What is the durable job/retry design? `BackgroundTasks` is not a durable queue, and the current orchestration has retry/duplication risks on restart. (`services/discovery-portal/routers/discovery.py:250-259`, `services/discovery-portal/orchestrator.py:24-65`)
7. Should Redis fail closed for abuse controls? Current tests and code explicitly fail open when Redis is missing or unavailable. (`services/discovery-portal/tests/test_rate_limit.py:24-27`, `services/discovery-portal/routers/discovery.py:141-184`)
8. What is the contract for report URL access? The status endpoint returns a signed Blob URL to any caller holding the session UUID. (`services/discovery-portal/routers/discovery.py:264-291`, `services/discovery-portal/integrations/blob_storage.py:61-72`)
9. How will migrations run, and who owns rollback? The repository contains idempotent SQL but the service startup only initializes a connection pool; it does not run migrations. (`services/discovery-portal/db/migrations/001_discovery_tables.sql:1-6`, `services/discovery-portal/db/connection.py:29-39`)
10. What alerting and operational dashboards are required for scan failures, dependency failures, and silent dead-air? The source has P1/P2 alert definitions for scan and HubSpot logs, but the dead-man switch is explicitly left disabled pending input. (`infrastructure/terraform/discovery-portal-alerts.tf:25-35`, `infrastructure/terraform/discovery-portal-alerts.tf:98-121`, `infrastructure/terraform/discovery-portal-alerts.tf:177-199`)

## 9. Pilot-suitability recommendation

### Recommendation: **Conditionally suitable** as the first stateless pilot

The service has a bounded HTTP surface, a clear container entry point, a non-root image, explicit port/probe configuration, and source-level tests for the scan flow, Front Door lock, Blob managed identity path, and rate limiting. (`services/discovery-portal/Dockerfile:5-15`, `services/discovery-portal/tests/test_scan_flow.py:83-231`, `services/discovery-portal/tests/test_frontdoor_lock.py:31-70`, `services/discovery-portal/tests/test_blob_storage_mi.py:17-73`, `services/discovery-portal/tests/test_rate_limit.py:12-149`)

It is **not suitable without conditions** for a multi-tenant or production-like first pilot because authorization/tenant isolation is absent from the discovery data path, scans are process-local background work, customer credentials arrive in a public request body, Redis rate limiting fails open, and several secret/config dependencies are currently out-of-band in Terraform. (`services/discovery-portal/routers/discovery.py:30-35`, `services/discovery-portal/routers/discovery.py:250-259`, `services/discovery-portal/routers/discovery.py:173-184`, `infrastructure/terraform/discovery-portal-app.tf:54-57`)

**Gate A conditions:** assign the owner/on-call; decide anonymous versus authenticated tenant scope; add session/report authorization and tenant binding; define secret delivery and rotation; validate approved egress/RBAC; add a dependency-aware readiness probe; document migration ownership; and either constrain the pilot to one replica with explicit restart-loss acceptance or implement durable scan jobs with idempotent side effects. Until those conditions are accepted and tested, classify the service as unsuitable for a production first pilot, while retaining conditional suitability for a tightly scoped, non-sensitive development pilot.
