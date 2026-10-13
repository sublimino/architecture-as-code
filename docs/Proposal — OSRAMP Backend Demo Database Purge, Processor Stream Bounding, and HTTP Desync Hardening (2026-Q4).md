# Proposal — OSRAMP Backend Demo Database Purge, Processor Stream Bounding, and HTTP Desync Hardening (2026-Q4)

## Context
OSRAMP ingestion components process tasks across NATS streaming subjects and persist records into PostgreSQL.
The user surface gate and Jev test bot validate service availability through lightweight HTTP servers.
These services must remain resilient against socket exhaustion, malformed HTTP payloads, and stream desynchronization.

## Problem Statement
The backend base and staging manifests embed an accidental demo database name `testify`.
This default conflicts with production configuration `osramp_archivista` and the archiver schema `task_archive`.
In `d2-osramp-apps/apps/processor/processor.go`, `consumeTasksWithLimit` reads lines without upper bounds.
An oversized stream without a newline can cause memory exhaustion.
`processTask` executes task commands without a deadline, risking worker slot exhaustion if tasks hang.
In `d2-osramp-apps/apps/listener/publish.sh`, requesting usage assistance requires `nats` and `jq` binaries.
In `test/fixtures/user-surface-gate/stub-surface-server.py` and `scripts/jev-test-bot/spa-server.py`, premature EOF in chunked requests treats truncated payloads as valid.
Additionally, these servers accept conflicting `Transfer-Encoding` and `Content-Length` headers simultaneously.

## Objectives
1. Purge accidental demo database `testify` from backend base and staging secrets, aligning with `osramp_archivista`.
2. Implement bounded line reading and command execution timeouts in the OSRAMP processor service.
3. Allow `publish.sh` help options to execute without external binary prerequisites.
4. Harden the user surface stub and Jev SPA servers against chunked stream premature EOF, trailer flooding, and desynchronization.

## Proposed Changes

### 1. Purge Accidental Demo Database testify
Update `d2-osramp-apps/components/backend/base/postgres.yaml` to set `POSTGRES_DB: osramp_archivista`.
Update `init.sql.sh` to guard `CREATE DATABASE task_archive` against executing when `POSTGRES_DB` matches `task_archive`.
Update `d2-osramp-apps/components/backend/base/archivista-secret.yaml` connection string to reference `osramp_archivista`.
Update `d2-osramp-apps/components/backend/staging/postgres-secret.yaml` and `archivista-secret.yaml` to match.

### 2. Bound Processor Stream Memory and Execution Timeouts
Implement `readBoundedLine` in `d2-osramp-apps/apps/processor/processor.go` capped at 4 MiB per line.
Add `TASK_TIMEOUT_SECONDS` support defaulting to 300 seconds using `exec.CommandContext`.
Add unit tests verifying bounded line draining and timeout configuration parsing.

### 3. Order publish.sh Help Before Dependency Verification
Move `help`, `--help`, and `-h` command dispatch before `command -v` assertions in `publish.sh`.

### 4. Harden Stub Surface and Jev SPA Servers Against Chunk Stream Desync
Enforce mutual exclusivity between `Transfer-Encoding: chunked` and `Content-Length`.
Detect premature EOF during chunk length, chunk data, and trailer parsing.
Close connections immediately and return `400 Bad Request` upon detecting truncated streams.
Cap trailer parsing to 32 lines and reject unterminated chunk size strings.
Add contract tests in `test_stub_surface_server.py` and `test_spa_server.py`.

## Verification Plan
1. Run Go unit tests in `d2-osramp-apps/apps/processor`.
2. Run Python contract tests in `test_stub_surface_server.py` and `test_spa_server.py`.
3. Synthesize Kubernetes manifests with `kubectl kustomize` for backend base and staging overlays.
4. Execute `bats test/user-surface-gate.bats`.
5. Execute `bats test/docs-index-sync.bats` and `./scripts/docs-lint.sh`.
