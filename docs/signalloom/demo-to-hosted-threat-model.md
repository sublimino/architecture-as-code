# Signal Loom demo-to-hosted threat model and release gate

**Scope:** the repository-local Signal Loom D2 demo and a future hosted
deployment. This is a design and verification record only: it neither changes
runtime configuration nor authorizes deployment, cloud provisioning, or use of
production data or credentials.

**Evidence boundary:** observations cite the checked-in D2 implementation.
Controls marked **required** are promotion gates, not claims that a hosted
environment currently implements them.

## System and trust boundaries

| Boundary | Demo evidence | Hosted decision |
| --- | --- | --- |
| Browser/client to portal | The workload exposes HTTP on `8000`; the local profile uses fake integrations. (`d2-signalloom/apps/fe-signalloom/base/deployment.yaml:47-84`) | Terminate TLS at the approved gateway, expose no direct Service endpoint, and authenticate callers before session reads or report downloads. |
| Portal process to PostgreSQL/Redis | A dedicated service account, non-root pod security, a database secret, cluster-local PostgreSQL/Redis names, and `/readyz` PostgreSQL checking are present. (`d2-signalloom/apps/fe-signalloom/base/deployment.yaml:19-45`, `:53-60`; `d2-signalloom/apps/fe-signalloom/src/main.py:39-57`) | Use per-environment Secret/ExternalSecret delivery, least-privilege database role, TLS/private connectivity where supported, and a default-deny NetworkPolicy with explicit allows. |
| Portal to report storage | Demo selects S3-compatible MinIO and injects separate storage credentials. (`d2-signalloom/apps/fe-signalloom/base/deployment.yaml:61-76`; `d2-signalloom/apps/fe-signalloom/src/integrations/report_store.py:86-131`) | Use a private bucket/container, workload identity or narrowly scoped credentials, encrypted storage, short-lived authorized download paths, and lifecycle deletion. |
| Portal to discovery and notification providers | Demo selects `fake-openai`, `fake-hubspot`, `fake-slack`, and `fake-email`. (`d2-signalloom/apps/fe-signalloom/base/deployment.yaml:77-84`) | Enable each real integration only after owner approval, allowlisted egress, minimum scopes, rate limits, audit logging, and a tested disable switch. |
| Session and discovered-agent records | Session rows include email/company metadata, report URL, errors, and discovered-agent details; records are linked only by `session_id`. (`d2-signalloom/apps/fe-signalloom/src/db/migrations/001_discovery_tables.sql:8-44`) | Bind each row to an authenticated tenant/principal, enforce authorization on every read, and add database-enforced tenant isolation or an equivalently tested access-control boundary. |

## Assets and threat model

Risk scale: **Critical/High** risks block hosted promotion until the stated
exit criterion passes. Demo-only fake integrations are not evidence that an
equivalent hosted control exists.

| ID | Asset / threat | Evidence and attack path | Risk | Required mitigation and owner | Verification / exit criterion |
| --- | --- | --- | --- | --- | --- |
| TM-01 | Discovery-session and report disclosure | The schema persists customer/contact metadata, report URL, errors, and discovered-agent data; it has no tenant column. (`d2-signalloom/apps/fe-signalloom/src/db/migrations/001_discovery_tables.sql:8-44`) | Critical | **App owner:** authenticated principal and tenant binding on create/read; **data owner:** DB RLS or tested equivalent; **security owner:** authorization review. | `VM-01` proves cross-tenant/status/report reads receive denial; migration and policy tests pass. |
| TM-02 | Report-object overwrite or unauthorised retrieval | `report_key` rejects path traversal, but writes overwrite a deterministic session key and the local S3 path returns a direct endpoint URL. (`d2-signalloom/apps/fe-signalloom/src/integrations/report_store.py:24-27`, `:96-108`) | High | **App owner:** retain path validation and authorize object access; **platform owner:** private storage, scoped identity, versioning/lifecycle policy; **security owner:** download-token review. | `VM-02` rejects traversal/cross-tenant reads and proves report URLs/tokens expire and cannot list the bucket. |
| TM-03 | Secret disclosure or credential replay | Database and storage keys come from Kubernetes Secrets; fake provider selection avoids real integrations in the demo. (`d2-signalloom/apps/fe-signalloom/base/deployment.yaml:53-84`) | High | **Platform owner:** external secret delivery, rotation and no plaintext Git/env dumps; **app owner:** never log credentials; **security owner:** secret-scan/review. | `VM-03` renders hosted manifests without values, confirms only secret references, and exercises rotation in a disposable environment. |
| TM-04 | Ingress bypass or unauthenticated API use | The D2 Deployment defines a Service-facing HTTP port but no hosted gateway/auth policy. (`d2-signalloom/apps/fe-signalloom/base/deployment.yaml:47-52`) | High | **Platform owner:** gateway-only ingress, TLS and network isolation; **app owner:** authenticated authorization middleware; **security owner:** route review. | `VM-04` proves direct pod/Service access is denied and unauthenticated requests fail while approved gateway requests succeed. |
| TM-05 | Dependency outage accepted as ready | `/readyz` tests PostgreSQL and reports Redis as diagnostic/degraded; readiness is wired to it. (`d2-signalloom/apps/fe-signalloom/src/main.py:39-57`; `d2-signalloom/apps/fe-signalloom/base/deployment.yaml:95-98`) | Medium | **App owner:** retain dependency-aware readiness and define Redis fail-open/fail-closed policy; **SRE owner:** alerts and rollback thresholds. | `VM-05` unit tests PostgreSQL failure as `503`, Redis degradation visibility, and probe manifest paths. |
| TM-06 | Privilege escalation or mutable runtime | The pod runs non-root with RuntimeDefault seccomp, no privilege escalation, dropped capabilities, and read-only root filesystem. (`d2-signalloom/apps/fe-signalloom/base/deployment.yaml:19-23`, `:42-45`, `:99-103`) | Medium | **Platform owner:** enforce these as admission policy; **app owner:** document writable-volume exceptions rather than weakening defaults. | `VM-06` policy/render test rejects privileged, capability-added, or writable-root variants. |
| TM-07 | Unsafe external egress / real-provider blast radius | Local deployment explicitly chooses fake discovery, CRM, notification, and email backends. (`d2-signalloom/apps/fe-signalloom/base/deployment.yaml:77-84`) | High | **Integration owner:** approve each provider and minimum scope; **platform owner:** default-deny egress with destination allowlist; **app owner:** feature flags default disabled. | `VM-07` network-policy test denies arbitrary egress and contract tests show disabled providers make no calls. |
| TM-08 | Resource exhaustion or database connection abuse | Startup waits indefinitely for PostgreSQL; the app creates its pool at lifespan start. (`d2-signalloom/apps/fe-signalloom/base/deployment.yaml:24-45`; `d2-signalloom/apps/fe-signalloom/src/main.py:16-21`) | Medium | **App/SRE owners:** bounded startup/retry budget, request limits, resource sizing, and saturation alerting. | `VM-08` demonstrates timeout/backoff behaviour and load test stays inside approved concurrency/resource limits in a disposable environment. |
| TM-09 | Supply-chain or configuration drift | Image references use registry/tag placeholders and `IfNotPresent`; config is kustomized. (`d2-signalloom/apps/fe-signalloom/base/deployment.yaml:47-49`; `d2-signalloom/apps/fe-signalloom/base/kustomization.yaml:1-10`) | High | **Release owner:** immutable digest promotion with provenance/SBOM policy; **platform owner:** GitOps reconciliation and signed review. | `VM-09` rejects mutable/unapproved images and records provenance/SBOM verification for the promoted digest. |
| TM-10 | Deployment misconfiguration breaks availability | D2 static checks validate topology, dependencies, portal package, bootstrap and Bao/SPIRE configuration. (`d2-signalloom/Makefile:5-13`) | Medium | **Release owner:** require static checks before every promotion; **SRE owner:** staged rollout and rollback ownership. | `VM-10` requires `make -C d2-signalloom test`, `make -C d2-signalloom bao-test-config`, and manifest render success. |

## Ownership and promotion gates

| Gate | Accountable owner | Must be true before hosted promotion |
| --- | --- | --- |
| G-1 Identity and isolation | Signal Loom application owner | TM-01/VM-01 closes: named tenant/principal model, authenticated session/report access, and tested isolation. |
| G-2 Secrets and storage | Platform security owner | TM-02/TM-03 close: private report storage, scoped workload identity, rotation, retention/deletion and redaction evidence. |
| G-3 Network and integration safety | Platform networking owner with integration owners | TM-04/TM-07 close: gateway-only ingress, TLS, default-deny/allowlisted egress, approved minimum provider scopes, and kill switches. |
| G-4 Runtime resilience | Signal Loom SRE owner | TM-05/TM-08 close: readiness semantics, bounded startup, alerts, resource budget, rollout and rollback runbook. |
| G-5 Release integrity | Release manager | TM-06/TM-09/TM-10 close: admission controls, immutable attested image, manifest/test evidence, and change approval. |

No gate may be self-approved by the person making a provider credential,
network-policy, or authorization change. A failed or unexecuted verification
is a promotion blocker, not an assumed pass.

## Verification matrix

| Verification | Threats | Method | Current repository evidence | Hosted acceptance evidence |
| --- | --- | --- | --- | --- |
| VM-01 Authorization isolation | TM-01 | API + DB integration tests | Schema and D2 tests are available, but no tenant field/policy is present. | Two tenants and two principals; every cross-tenant session, agent and report read is denied. |
| VM-02 Report boundary | TM-02 | Unit/integration tests | `report_key` validates path-safe IDs; report-store tests cover local behavior. (`d2-signalloom/apps/fe-signalloom/src/integrations/report_store.py:24-27`; `d2-signalloom/apps/fe-signalloom/src/tests/test_report_store.py`) | Private storage cannot list/read without scoped authorization; expiry/retention tests pass. |
| VM-03 Secret hygiene | TM-03 | Render + secret/reference scan | Deployment uses `secretKeyRef` for database and S3 keys. (`d2-signalloom/apps/fe-signalloom/base/deployment.yaml:53-76`) | No values in rendered GitOps artifacts; rotation and log-redaction test pass. |
| VM-04 Ingress enforcement | TM-04 | Disposable-cluster negative/positive route tests | No hosted ingress/auth implementation is claimed by this demo. | Direct Service/pod route denied; gateway TLS/auth route is the only successful path. |
| VM-05 Readiness degradation | TM-05 | Python unit tests | `/readyz` returns `503` on PostgreSQL failure and diagnoses Redis. (`d2-signalloom/apps/fe-signalloom/src/main.py:39-57`) | Dependency failure causes removal from endpoints and alert; recovery is observed. |
| VM-06 Pod hardening | TM-06 | Manifest/policy tests | D2 pod security controls are checked in. (`d2-signalloom/apps/fe-signalloom/base/deployment.yaml:19-23`, `:99-103`) | Admission rejects a violating deployment in a disposable cluster. |
| VM-07 Egress/provider controls | TM-07 | Network-policy and provider contract tests | Fake backends bound in local manifest. (`d2-signalloom/apps/fe-signalloom/base/deployment.yaml:77-84`) | Denied arbitrary egress; only approved enabled provider destinations work with minimum-scope identities. |
| VM-08 Failure/retry budget | TM-08 | Controlled failure/load test | Init container blocks until DB is ready. (`d2-signalloom/apps/fe-signalloom/base/deployment.yaml:24-45`) | Bounded failure and rollback meet the approved SLO; no duplicate externally visible effects. |
| VM-09 Artifact integrity | TM-09 | CI/GitOps policy verification | Image coordinates are parameterized. (`d2-signalloom/apps/fe-signalloom/base/deployment.yaml:47-49`) | Digest, signature/provenance, SBOM and approval match the release record. |
| VM-10 D2 regression checks | TM-10 | Local commands | `d2-signalloom/Makefile:5-13` defines static package/config checks. | CI records successful commands and rendered-manifest validation for the candidate. |

## Non-production validation performed for this document

The document is source-backed by the checked-in D2 files cited above. Its
creation does not make a hosted-security claim. The local verification record
for this change is limited to static/document checks and the affected D2 test
targets recorded in the accompanying errata.
