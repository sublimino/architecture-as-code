# Proposal — HTTP-1.1 Keep-Alive Persistence, Stream Desync Defenses, and Grafana Secret Decoupling (2026-Q4)

## Context
Signal Loom coordinates agent trust boundaries and agentic SRE services across Kubernetes clusters.
The `d2-agent-trust` slice provides SPIFFE identity validation, OpenBao JWT role verification, and Agent-to-Agent (A2A) protocol communication.
The `olly-replica` slice provides autonomous agent monitoring, authorization policy evaluation (`olly-authz`), and sentinel analysis (`olly-sentinel`).
Both services expose HTTP endpoints that parse incoming payloads, manage socket streams, and support persistent connections.

## Problem Statement
In `http.server.BaseHTTPRequestHandler`, `protocol_version` defaults to `"HTTP/1.0"`.
Unless explicitly overridden to `"HTTP/1.1"`, every response includes `Connection: close` and sets `self.close_connection = 1`.
This disabled HTTP/1.1 persistent connections (Keep-Alive) in both `d2-agent-trust/a2a/service.py` and `olly-replica/apps/authz/authz/httputil.py`.
Disabling keep-alive masked request stream desynchronization bugs where unconsumed bodies on pipelined GET or HEAD requests poisoned subsequent requests.
Additionally:
1. `do_GET` and `do_HEAD` in `d2-agent-trust/a2a/service.py` omitted body draining, leaving pipelined bytes on the socket stream.
2. `_drain_body` and `drain_body` returned void (`None`) and swallowed framing errors (invalid hex chunk sizes, negative lengths, truncated reads, and TE.CL conflicts). Consequently, dispatchers returned `204 No Content` or `200 OK` on corrupted streams instead of RFC 9112 Section 6.3/7.1 mandated `400 Bad Request`.
3. In `httputil.py`, `read_json` flagged `close_connection = True` on valid `Content-Length: 0` payloads.
4. Chunk length lines were limited to 128 bytes via `readline(128)`, truncating valid chunk extensions.
5. In `olly-replica/components/configs/base/grafana.yaml`, Eye-in-the-Sky Grafana admin credentials (`adminUser: admin`, `adminPassword: olly-replica-demo`) were hardcoded without Secret decoupling for staging and production overlays.

## Objectives
1. Configure `protocol_version = "HTTP/1.1"` in `d2-agent-trust/a2a/service.py` and `olly-replica/apps/authz/authz/httputil.py`.
2. Drain request bodies on `GET` and `HEAD` endpoints across both services to support persistent pipelined connections.
3. Update `_drain_body` and `drain_body` to return a boolean indicating framing validity, and reject corrupted streams with `400 Bad Request` and `Connection: close`.
4. Fix `read_json` handling of `Content-Length: 0` and expand chunk line reading to 1024 bytes.
5. Decouple Eye-in-the-Sky Grafana admin credentials in `olly-replica/components/configs` into Secret `olly-grafana-admin` with staging and production overlay patches.

## Proposed Changes

### 1. HTTP/1.1 Protocol and Body Draining in Agent Trust
We set `protocol_version = "HTTP/1.1"` on `A2AHandler` in `d2-agent-trust/a2a/service.py`.
We invoke `self._drain_body()` in `do_GET` and `do_HEAD`.
We update `_drain_body()` to return `bool`, returning `False` on framing syntax errors, invalid hex lengths, negative lengths, oversized chunk extensions, and TE.CL conflicts.
When `_drain_body()` returns `False`, we return `400 Bad Request` and close the connection.
We guard socket writes with `OSError` exception handling to safely mark `close_connection = True`.
In `d2-agent-trust/test/test_contracts.py`, we add tests verifying HTTP/1.1 keep-alive persistence across pipelined requests and 400 Bad Request on framing errors.

### 2. HTTP/1.1 Protocol and Framing Validation in Olly AuthZ
We set `protocol_version = "HTTP/1.1"` on `Handler` in `olly-replica/apps/authz/authz/httputil.py`.
We update `drain_body()` to return `bool` and expand `readline()` buffer to 1024 bytes.
We update `_dispatch` and `send_error` to return `400 Bad Request` when `drain_body()` fails.
We fix `read_json()` to return `{}` without closing connections on `Content-Length: 0`.
We update `olly-replica/apps/authz/tests/test_authz.py` to assert `400 Bad Request` on malformed chunk lines and negative content lengths, and add keep-alive verification across pipelined requests.

### 3. Grafana Admin Secret Decoupling
We add Secret `olly-grafana-admin` to `olly-replica/components/configs/base/grafana.yaml` and configure `admin.existingSecret: olly-grafana-admin`.
We create `staging/olly-grafana-admin-secret.yaml` and `production/olly-grafana-admin-secret.yaml`.
We patch `olly-grafana-admin` in `staging/kustomization.yaml` and `production/kustomization.yaml`.

## Verification Plan
1. Run `python3 -m unittest discover -s d2-agent-trust/test`.
2. Run `python3 -m pytest olly-replica/apps/authz/tests -v`.
3. Run `cd olly-replica/apps/sentinel && uv run --python 3.12 --with-requirements requirements.txt python -m pytest tests -q`.
4. Run `go test ./...` in `olly-replica/apps`.
5. Run `kubectl kustomize` across base, local, staging, and production overlays.
6. Run `./scripts/lint-pipefail-grep-q.sh` and `./scripts/check-vacuous-assertions.sh`.
7. Run `bats test/vacuous-assertions.bats` and `bats test/docs-index-sync.bats`.
8. Run `./scripts/docs-lint.sh`.
