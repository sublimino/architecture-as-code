# Proposal — Cardvault Secret Decoupling, CPAI Project Externalization, and Jev SPA Desync Hardening (2026-Q4)

## Context
Signal Loom coordinates agent authorization, identity attestation, and containment across deployment slices.
The Cardvault service stores encrypted card records for SuperCred credential verification journeys.
The CPAI runtime acts as an OpenAI-compatible translation proxy connecting platform agents to Vertex AI models.
Additionally, the Jev test bot and the user surface gate run HTTP servers to validate surface contracts.

## Problem Statement
The Cardvault deployment specification embeds plaintext service account credentials directly in pod environment variables.
This pattern risks credential leakage through pod specs and kubectl inspect commands.
Similarly, the CPAI deployment hardcodes a test Google Cloud project name directly in container environment variables.
Operators deploying CPAI cannot override the project dynamically without editing manifests.
Furthermore, the Jev SPA server drains request bodies without validating hexadecimal chunk lengths or CRLF delimiters.
The user surface gate stub server ignores chunked transfer encodings entirely and fails to close connections on malformed payloads.

## Objectives
1. Decouple Cardvault credentials into a dedicated Kubernetes Secret and support file-mounted credential loading.
2. Externalize CPAI project configuration into a ConfigMap with dynamic environment override support in lifecycle scripts.
3. Harden the Jev SPA server against chunk stream desynchronization and premature EOF conditions.
4. Implement chunked transfer encoding decoding and connection closure guards in the user surface gate stub server.

## Proposed Changes

### 1. Cardvault Credential Decoupling and File-Mounted Secret Support
We create `d2-signalloom/apps/cardvault/base/secret.yaml` defining Secret `cardvault-credentials`.
We update `d2-signalloom/apps/cardvault/base/kustomization.yaml` to include the secret manifest.
We update `d2-signalloom/apps/cardvault/base/deployment.yaml` to resolve username and password from the Secret via `secretKeyRef`.
We enhance `d2-signalloom/apps/cardvault/main.go` to load credentials from `CARDVAULT_USERNAME_FILE` and `CARDVAULT_PASSWORD_FILE`.

### 2. CPAI Project Externalization and Deployment Script Dynamic Overrides
We create `d2-cpai/apps/cpai-runtime/base/configmap.yaml` defining ConfigMap `cpai-runtime-config`.
We register the ConfigMap in `d2-cpai/apps/cpai-runtime/base/kustomization.yaml`.
We update `d2-cpai/apps/cpai-runtime/base/deployment.yaml` to ingest `cpai-runtime-config` via `envFrom`.
We update `scripts/cpai-up.sh` to apply dynamic project configuration from `GOOGLE_CLOUD_PROJECT` if provided by the operator.
We update `d2-cpai/README.md` to reference the ConfigMap architecture.

### 3. Jev SPA Server Chunk Stream Desynchronization Hardening
We update `scripts/jev-test-bot/spa-server.py` to validate chunk length hexadecimal strings with a regular expression.
We reject negative chunk sizes and ensure malformed CRLF delimiters mark the connection for closure.
We detect premature EOF conditions and invalid Content-Length headers, ensuring `Connection: close` headers are emitted.
We add contract tests in `scripts/jev-test-bot/test_spa_server.py`.

### 4. User Surface Gate Stub Server Chunk Decoding and Desync Defenses
We update `test/fixtures/user-surface-gate/stub-surface-server.py` to handle chunked POST requests.
We validate chunk sizes, verify CRLF delimiters, and enforce connection closure on malformed bodies.
We add unit tests in `test/fixtures/user-surface-gate/test_stub_surface_server.py`.

## Verification Plan
We run Go unit and adversarial tests for the Cardvault service.
We verify manifest rendering with `kubectl kustomize` for Cardvault and CPAI.
We execute Python unit and contract tests for the Jev SPA server and the user surface gate stub server.
We verify documentation index synchronization with `bats test/docs-index-sync.bats`.
We run `./scripts/docs-lint.sh` to ensure compliance with documentation style.
