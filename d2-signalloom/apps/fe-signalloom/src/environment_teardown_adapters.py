"""Fail-closed teardown providers with verified postconditions.

The bounded process runner and HTTPRoute matching are selectively recovered from
EAPR commits b1a0b9c0 and 98a789ca. Lifecycle transitions and orchestration are
deliberately absent: their owner consumes :mod:`environment_teardown_contract`.
"""

from __future__ import annotations

import base64
import http.client
import json
import math
import os
import re
import shutil
import signal
import subprocess
import time
import urllib.parse
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Protocol, Sequence

from environment_teardown_contract import (
    AttributionError,
    DeadlineExceeded,
    StageExecutor,
    StageRequest,
    StageResult,
    TeardownAuthorizationError,
    TeardownError,
    TeardownSecurityError,
    TeardownStage,
)

MAX_CALL_SECONDS = 10.0
_HASH_RE = re.compile(r"^[0-9a-f]{8}$")


def _call_timeout(deadline: float) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise DeadlineExceeded("teardown stage deadline exhausted")
    return min(MAX_CALL_SECONDS, remaining)


def _validate_request(request: StageRequest) -> str:
    if not _HASH_RE.fullmatch(request.customer_hash):
        raise ValueError("customer_hash must be exactly eight lowercase hexadecimal characters")
    if not request.teardown_id.strip():
        raise ValueError("teardown_id must not be empty")
    if not math.isfinite(request.deadline):
        raise ValueError("deadline must be a finite absolute monotonic timestamp")
    _call_timeout(request.deadline)
    return request.customer_hash


@dataclass(frozen=True)
class CommandResult:
    returncode: int | None
    stdout: str
    stderr: str
    timed_out: bool = False


def run_bounded(
    argv: Sequence[str], deadline: float, *, env: Mapping[str, str] | None = None
) -> CommandResult:
    """Run without a shell and kill the complete process group at the deadline."""
    timeout = _call_timeout(deadline)
    process = subprocess.Popen(
        list(argv),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=dict(env) if env is not None else None,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
        return CommandResult(process.returncode, stdout, stderr)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            stdout, stderr = process.communicate(timeout=1.0)
        except subprocess.TimeoutExpired:
            stdout, stderr = "", "process pipes remained open after process-group kill"
        return CommandResult(None, stdout, stderr, timed_out=True)


def _json_command(argv: Sequence[str], deadline: float, *, env: Mapping[str, str] | None = None) -> Any:
    result = run_bounded(argv, deadline, env=env)
    if result.timed_out:
        raise DeadlineExceeded(f"{Path(argv[0]).name} exceeded stage deadline")
    if result.returncode != 0:
        raise RuntimeError(f"{Path(argv[0]).name} failed: {result.stderr.strip()[:300]}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"{Path(argv[0]).name} returned invalid JSON") from error


class BoundedHTTPTransport:
    """Transport that enforces HTTPS, rejects redirects, and bounds timeouts/body sizes."""

    def __init__(self, allow_http_loopback: bool = False, max_body_bytes: int = 1048576) -> None:
        self.allow_http_loopback = allow_http_loopback
        self.max_body_bytes = max_body_bytes

    def request(
        self,
        method: str,
        url: str,
        headers: Mapping[str, str] | None = None,
        body: bytes | str | None = None,
        timeout: float = MAX_CALL_SECONDS,
    ) -> tuple[int, dict[str, str], bytes]:
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme not in ("http", "https"):
            raise ValueError(f"unsupported URL scheme: {parsed.scheme}")
        if parsed.scheme == "http":
            if not self.allow_http_loopback:
                raise ValueError("HTTPS is required for non-loopback connections")
            if parsed.hostname not in ("127.0.0.1", "localhost", "::1"):
                raise ValueError("HTTP only allowed for loopback addresses")

        start_time = time.monotonic()
        call_timeout = min(MAX_CALL_SECONDS, timeout)
        deadline = start_time + call_timeout

        if isinstance(body, str):
            body_bytes = body.encode("utf-8")
        else:
            body_bytes = body

        req_headers = dict(headers) if headers is not None else {}
        host = parsed.hostname or "localhost"
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        path = parsed.path or "/"
        if parsed.query:
            path = f"{path}?{parsed.query}"

        socket_timeout = max(0.01, min(call_timeout, deadline - time.monotonic()))
        conn: http.client.HTTPConnection
        if parsed.scheme == "https":
            conn = http.client.HTTPSConnection(host, port, timeout=socket_timeout)
        else:
            conn = http.client.HTTPConnection(host, port, timeout=socket_timeout)

        try:
            conn.request(method, path, body=body_bytes, headers=req_headers)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise DeadlineExceeded("http_deadline_exceeded")
            if conn.sock:
                conn.sock.settimeout(max(0.01, remaining))

            resp = conn.getresponse()
            status = resp.status
            resp_headers = {k: v for k, v in resp.getheaders()}

            if 300 <= status < 400:
                raise TeardownSecurityError("http_redirect_rejected")

            chunks: list[bytes] = []
            total_read = 0
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise DeadlineExceeded("http_deadline_exceeded")
                if conn.sock:
                    conn.sock.settimeout(max(0.001, remaining))
                try:
                    chunk = resp.read(1)
                except TimeoutError as err:
                    raise DeadlineExceeded("http_deadline_exceeded") from err
                except OSError as err:
                    if "timed out" in str(err).lower():
                        raise DeadlineExceeded("http_deadline_exceeded") from err
                    raise
                if not chunk:
                    break
                total_read += len(chunk)
                if total_read > self.max_body_bytes:
                    raise TeardownSecurityError("http_response_too_large")
                chunks.append(chunk)

            return status, resp_headers, b"".join(chunks)
        except (DeadlineExceeded, TeardownSecurityError):
            raise
        except (http.client.HTTPException, OSError) as err:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise DeadlineExceeded("http_deadline_exceeded") from err
            raise RuntimeError(f"HTTP request failed: {err}") from err
        finally:
            conn.close()


class _StageAdapter(Protocol):
    def execute(self, request: StageRequest) -> StageResult: ...
    def verify(self, request: StageRequest) -> StageResult: ...


class FailClosedExecutor:
    def __init__(self, reason: str = "no teardown providers configured") -> None:
        self.reason = reason

    def execute(self, stage: TeardownStage, request: StageRequest) -> StageResult:
        resolved = stage if isinstance(stage, TeardownStage) else TeardownStage.ROUTE
        return StageResult(resolved, False, self.reason, {"configured": False})

    def verify(self, stage: TeardownStage, request: StageRequest) -> StageResult:
        resolved = stage if isinstance(stage, TeardownStage) else TeardownStage.ROUTE
        return StageResult(resolved, False, self.reason, {"configured": False})


class ConfiguredTeardownExecutor:
    def __init__(self, adapters: Mapping[TeardownStage, _StageAdapter]) -> None:
        self._adapters = dict(adapters)

    def execute(self, stage: TeardownStage, request: StageRequest) -> StageResult:
        if not isinstance(stage, TeardownStage):
            return StageResult(TeardownStage.ROUTE, False, "unknown teardown stage")
        try:
            _validate_request(request)
        except (ValueError, DeadlineExceeded) as error:
            return StageResult(stage, False, str(error))
        adapter = self._adapters.get(stage)
        if adapter is None:
            return StageResult(stage, False, f"provider not configured for {stage.value}", {"configured": False})
        try:
            result = adapter.execute(request)
        except Exception:
            return StageResult(stage, False, "provider_failed")
        if result.stage is not stage:
            return StageResult(stage, False, "provider returned mismatched stage")
        if result.success and time.monotonic() > request.deadline:
            return StageResult(stage, False, "provider returned after stage deadline", result.evidence)
        return result

    def verify(self, stage: TeardownStage, request: StageRequest) -> StageResult:
        if not isinstance(stage, TeardownStage):
            return StageResult(TeardownStage.ROUTE, False, "unknown teardown stage")
        try:
            _validate_request(request)
        except (ValueError, DeadlineExceeded) as error:
            return StageResult(stage, False, str(error))
        adapter = self._adapters.get(stage)
        if adapter is None:
            return StageResult(stage, False, f"provider not configured for {stage.value}", {"configured": False})
        try:
            result = adapter.verify(request)
        except Exception:
            return StageResult(stage, False, "provider_failed")
        if result.stage is not stage:
            return StageResult(stage, False, "provider returned mismatched stage")
        if result.success and time.monotonic() > request.deadline:
            return StageResult(stage, False, "provider returned after stage deadline", result.evidence)
        return result


class RouteAdapter:
    def __init__(self, kubectl: str, namespace: str) -> None:
        self.kubectl = kubectl
        self.namespace = namespace

    def _routes(self, request: StageRequest) -> list[dict[str, Any]]:
        payload = _json_command(
            [self.kubectl, "get", "httproute", "-n", self.namespace, "-o", "json"],
            request.deadline,
        )
        if not isinstance(payload, dict) or not isinstance(payload.get("items"), list):
            raise RuntimeError("invalid_httproute_inventory")
        return list(payload.get("items", []))

    @staticmethod
    def _matches(route: Mapping[str, Any], customer_hash: str) -> bool:
        metadata = route.get("metadata", {})
        if metadata.get("labels", {}).get("signalloom.io/eap-hash") == customer_hash:
            return True
        expected = f"sl-eap-{customer_hash}"
        for hostname in route.get("spec", {}).get("hostnames", []):
            if str(hostname).split(".", 1)[0] == expected:
                return True
        return False

    def execute(self, request: StageRequest) -> StageResult:
        customer_hash = _validate_request(request)
        matches = [route for route in self._routes(request) if self._matches(route, customer_hash)]
        removed: list[str] = []
        for route in matches:
            name = route.get("metadata", {}).get("name")
            if not isinstance(name, str) or not name:
                return StageResult(TeardownStage.ROUTE, False, "matching HTTPRoute has no name")
            result = run_bounded(
                [self.kubectl, "delete", "httproute", name, "-n", self.namespace],
                request.deadline,
            )
            if result.timed_out or result.returncode != 0:
                return StageResult(TeardownStage.ROUTE, False, f"failed deleting HTTPRoute {name}")
            removed.append(name)
        remaining = [
            route.get("metadata", {}).get("name", "<unnamed>")
            for route in self._routes(request)
            if self._matches(route, customer_hash)
        ]
        evidence = {"removed_routes": sorted(removed), "remaining_routes": sorted(remaining)}
        if remaining:
            return StageResult(TeardownStage.ROUTE, False, "tenant HTTPRoutes remain", evidence)
        return StageResult(TeardownStage.ROUTE, True, "tenant HTTPRoutes absent after re-list", evidence)

    def verify(self, request: StageRequest) -> StageResult:
        customer_hash = _validate_request(request)
        remaining = [
            route.get("metadata", {}).get("name", "<unnamed>")
            for route in self._routes(request)
            if self._matches(route, customer_hash)
        ]
        evidence = {"remaining_routes": sorted(remaining)}
        if remaining:
            return StageResult(TeardownStage.ROUTE, False, "tenant HTTPRoutes remain", evidence)
        return StageResult(TeardownStage.ROUTE, True, "tenant HTTPRoutes absent by verification", evidence)


class MeshClient(Protocol):
    def list_nodes(self, timeout: float) -> list[dict[str, Any]]: ...
    def delete_node(self, node_id: str, timeout: float) -> None: ...


class MeshAdapter:
    def __init__(self, client: MeshClient, ownership: Mapping[str, Any] | None = None) -> None:
        self.client = client
        self.ownership = dict(ownership) if ownership is not None else None

    @staticmethod
    def _tenant_nodes(nodes: Sequence[Mapping[str, Any]], customer_hash: str) -> list[Mapping[str, Any]]:
        expected = f"sl-eap-{customer_hash}"
        return [node for node in nodes if str(node.get("hostname", "")).split(".", 1)[0] == expected]

    def _check_ownership_and_filter(
        self, matched: list[Mapping[str, Any]], customer_hash: str
    ) -> tuple[bool, str, list[str]]:
        if self.ownership is None or customer_hash not in self.ownership:
            return False, "ownership_inventory_missing", []

        record = self.ownership[customer_hash]
        if not isinstance(record, dict):
            return False, "ownership_inventory_missing", []

        owned_device_ids = set(record.get("device_ids", []))
        expected_tag = record.get("tag")

        to_delete: list[str] = []
        for node in matched:
            node_id = node.get("id")
            if not isinstance(node_id, str) or not node_id:
                return False, "tenant Tailscale node has no device id", []

            if node_id not in owned_device_ids:
                return False, "mesh_ownership_collision", []

            if expected_tag is not None:
                tags = node.get("tags", [])
                if expected_tag not in tags:
                    return False, "mesh_ownership_collision", []

            to_delete.append(node_id)

        return True, "", to_delete

    def execute(self, request: StageRequest) -> StageResult:
        customer_hash = _validate_request(request)
        matched = self._tenant_nodes(self.client.list_nodes(_call_timeout(request.deadline)), customer_hash)
        deleted: list[str] = []
        if matched:
            valid, reason, to_delete = self._check_ownership_and_filter(matched, customer_hash)
            if not valid:
                return StageResult(TeardownStage.MESH, False, reason)

            for node_id in to_delete:
                self.client.delete_node(node_id, _call_timeout(request.deadline))
                deleted.append(node_id)

        remaining = self._tenant_nodes(self.client.list_nodes(_call_timeout(request.deadline)), customer_hash)
        remaining_ids = [str(node.get("id", "<missing>")) for node in remaining]
        evidence = {"deleted_tenant_nodes": deleted, "remaining_tenant_nodes": remaining_ids}
        if remaining:
            return StageResult(TeardownStage.MESH, False, "tenant Tailscale nodes remain", evidence)
        return StageResult(TeardownStage.MESH, True, "tenant Tailscale nodes absent by API", evidence)

    def verify(self, request: StageRequest) -> StageResult:
        customer_hash = _validate_request(request)
        remaining = self._tenant_nodes(self.client.list_nodes(_call_timeout(request.deadline)), customer_hash)
        remaining_ids = [str(node.get("id", "<missing>")) for node in remaining]
        evidence = {"remaining_tenant_nodes": remaining_ids}
        if remaining:
            return StageResult(TeardownStage.MESH, False, "tenant Tailscale nodes remain", evidence)
        return StageResult(TeardownStage.MESH, True, "tenant Tailscale nodes absent by API", evidence)


class TailscaleAdminAPIClient:
    def __init__(
        self,
        api_base: str,
        tailnet: str,
        api_key: str,
        transport: BoundedHTTPTransport | None = None,
    ) -> None:
        parsed = urllib.parse.urlparse(api_base)
        if parsed.scheme != "https" or not parsed.hostname:
            raise ValueError("Tailscale API base must be an absolute HTTPS URL")
        self.api_base = api_base.rstrip("/")
        self.tailnet = tailnet
        self.authorization = "Basic " + base64.b64encode(f"{api_key}:".encode()).decode()
        self.transport = transport or BoundedHTTPTransport(allow_http_loopback=False)

    def _request(self, method: str, path: str, timeout: float) -> dict[str, Any]:
        status, headers, body = self.transport.request(
            method,
            self.api_base + path,
            headers={"Authorization": self.authorization, "Accept": "application/json"},
            body=None,
            timeout=timeout,
        )
        if status in (401, 403):
            raise TeardownAuthorizationError(f"Tailscale API authorization failed: HTTP {status}")
        if status >= 500:
            raise TeardownSecurityError(f"Tailscale API server error: HTTP {status}")
        if not body:
            return {}
        try:
            data = json.loads(body.decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError) as err:
            raise RuntimeError("invalid_tailscale_response") from err
        if not isinstance(data, dict):
            raise RuntimeError("invalid_tailscale_response")
        return data

    def list_nodes(self, timeout: float) -> list[dict[str, Any]]:
        tailnet = urllib.parse.quote(self.tailnet, safe="")
        data = self._request("GET", f"/api/v2/tailnet/{tailnet}/devices", timeout)
        if not isinstance(data, dict) or "devices" not in data or not isinstance(data["devices"], list):
            raise RuntimeError("invalid_tailscale_inventory")
        return list(data["devices"])

    def delete_node(self, node_id: str, timeout: float) -> None:
        self._request("DELETE", f"/api/v2/device/{urllib.parse.quote(node_id, safe='')}", timeout)


class OpenBaoClient(Protocol):
    def delete_tenant_material(self, customer_hash: str, timeout: float) -> None: ...
    def key_exists(self, customer_hash: str, timeout: float) -> bool: ...
    def secret_exists(self, customer_hash: str, timeout: float) -> bool: ...
    def decrypt_fails(self, customer_hash: str, timeout: float) -> bool: ...


class SpireClient(Protocol):
    def list_entries(self, timeout: float) -> list[dict[str, Any]]: ...
    def delete_entry(self, entry_id: str, timeout: float) -> None: ...


class KeySpireAdapter:
    def __init__(self, openbao: OpenBaoClient, spire: SpireClient) -> None:
        self.openbao = openbao
        self.spire = spire

    @staticmethod
    def _tenant_entries(entries: Sequence[Mapping[str, Any]], customer_hash: str) -> list[Mapping[str, Any]]:
        expected_trust_domain = "signalloom.demo"
        expected_prefix = f"/ns/eap-{customer_hash}/"
        matched = []
        for entry in entries:
            spiffe_id = entry.get("spiffe_id", entry.get("spiffeId"))
            td = None
            path = None
            if isinstance(spiffe_id, dict):
                td = spiffe_id.get("trust_domain")
                path = spiffe_id.get("path")
            elif isinstance(spiffe_id, str):
                if spiffe_id.startswith("spiffe://"):
                    rest = spiffe_id[len("spiffe://"):]
                    parts = rest.split("/", 1)
                    if len(parts) == 2:
                        td, path = parts[0], "/" + parts[1]
            if td == expected_trust_domain and path and path.startswith(expected_prefix):
                matched.append(entry)
        return matched

    def execute(self, request: StageRequest) -> StageResult:
        customer_hash = _validate_request(request)
        try:
            self.openbao.delete_tenant_material(customer_hash, _call_timeout(request.deadline))
        except TeardownAuthorizationError:
            return StageResult(TeardownStage.KEY_SPIRE, False, "openbao_authorization_failed")
        except Exception as err:
            return StageResult(TeardownStage.KEY_SPIRE, False, str(err))

        try:
            key_absent = not self.openbao.key_exists(customer_hash, _call_timeout(request.deadline))
            secret_absent = not self.openbao.secret_exists(customer_hash, _call_timeout(request.deadline))
            decrypt_failed = self.openbao.decrypt_fails(customer_hash, _call_timeout(request.deadline))
        except TeardownAuthorizationError:
            return StageResult(TeardownStage.KEY_SPIRE, False, "openbao_authorization_failed")
        except Exception as err:
            return StageResult(TeardownStage.KEY_SPIRE, False, str(err))

        openbao_evidence = {
            "key_absent": key_absent,
            "secret_absent": secret_absent,
            "decrypt_failed": decrypt_failed,
            "backup_erasure": "unverified",
        }
        if not all(openbao_evidence[key] for key in ("key_absent", "secret_absent", "decrypt_failed")):
            return StageResult(
                TeardownStage.KEY_SPIRE,
                False,
                "OpenBao postconditions unverified",
                {"openbao": openbao_evidence},
            )

        entries = self._tenant_entries(self.spire.list_entries(_call_timeout(request.deadline)), customer_hash)
        deleted_entries: list[str] = []
        for entry in entries:
            entry_id = entry.get("id", entry.get("entry_id"))
            if not isinstance(entry_id, str) or not entry_id:
                return StageResult(TeardownStage.KEY_SPIRE, False, "tenant SPIRE entry has no id")
            self.spire.delete_entry(entry_id, _call_timeout(request.deadline))
            deleted_entries.append(entry_id)

        remaining = self._tenant_entries(self.spire.list_entries(_call_timeout(request.deadline)), customer_hash)
        remaining_ids = [str(entry.get("id", entry.get("entry_id", "<missing>"))) for entry in remaining]
        evidence = {
            "openbao": openbao_evidence,
            "spire_deleted_entries": deleted_entries,
            "spire_remaining_entries": remaining_ids,
        }
        if remaining:
            return StageResult(TeardownStage.KEY_SPIRE, False, "tenant SPIRE entries remain", evidence)
        return StageResult(TeardownStage.KEY_SPIRE, True, "OpenBao and SPIRE postconditions verified", evidence)

    def verify(self, request: StageRequest) -> StageResult:
        customer_hash = _validate_request(request)
        try:
            key_absent = not self.openbao.key_exists(customer_hash, _call_timeout(request.deadline))
            secret_absent = not self.openbao.secret_exists(customer_hash, _call_timeout(request.deadline))
            decrypt_failed = self.openbao.decrypt_fails(customer_hash, _call_timeout(request.deadline))
        except TeardownAuthorizationError:
            return StageResult(TeardownStage.KEY_SPIRE, False, "openbao_authorization_failed")
        except Exception as err:
            return StageResult(TeardownStage.KEY_SPIRE, False, str(err))

        openbao_evidence = {
            "key_absent": key_absent,
            "secret_absent": secret_absent,
            "decrypt_failed": decrypt_failed,
            "backup_erasure": "unverified",
        }
        if not all(openbao_evidence[key] for key in ("key_absent", "secret_absent", "decrypt_failed")):
            return StageResult(
                TeardownStage.KEY_SPIRE,
                False,
                "OpenBao postconditions unverified",
                {"openbao": openbao_evidence},
            )

        remaining = self._tenant_entries(self.spire.list_entries(_call_timeout(request.deadline)), customer_hash)
        remaining_ids = [str(entry.get("id", entry.get("entry_id", "<missing>"))) for entry in remaining]
        evidence = {
            "openbao": openbao_evidence,
            "spire_remaining_entries": remaining_ids,
        }
        if remaining:
            return StageResult(TeardownStage.KEY_SPIRE, False, "tenant SPIRE entries remain", evidence)
        return StageResult(TeardownStage.KEY_SPIRE, True, "OpenBao and SPIRE postconditions verified", evidence)


class OpenBaoHTTPClient:
    def __init__(
        self,
        base_url: str,
        token: str,
        test_ciphertext: str,
        transport: BoundedHTTPTransport | None = None,
    ) -> None:
        parsed = urllib.parse.urlparse(base_url)
        if parsed.scheme != "https":
            if transport and transport.allow_http_loopback and parsed.hostname in ("127.0.0.1", "localhost", "::1"):
                pass
            else:
                raise ValueError("OpenBao base URL must use HTTPS scheme")
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.test_ciphertext = test_ciphertext
        self.transport = transport or BoundedHTTPTransport(allow_http_loopback=False)

    def _request(
        self,
        method: str,
        path: str,
        timeout: float,
        body: dict | None = None,
    ) -> tuple[int, dict]:
        data = json.dumps(body) if body is not None else None
        status, headers, resp_body = self.transport.request(
            method,
            self.base_url + path,
            headers={
                "X-Vault-Token": self.token,
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            body=data,
            timeout=timeout,
        )
        payload: dict = {}
        if resp_body:
            try:
                parsed = json.loads(resp_body.decode("utf-8"))
                if isinstance(parsed, dict):
                    payload = parsed
            except Exception:
                payload = {}
        return status, payload

    def delete_tenant_material(self, customer_hash: str, timeout: float) -> None:
        deadline = time.monotonic() + min(MAX_CALL_SECONDS, timeout)
        key = urllib.parse.quote(f"eap-{customer_hash}", safe="")

        status, _ = self._request(
            "POST",
            f"/v1/transit/keys/{key}/config",
            _call_timeout(deadline),
            {"deletion_allowed": True},
        )
        if status == 403:
            raise TeardownAuthorizationError(f"openbao_authorization_failed: HTTP {status}")
        if status >= 500:
            raise TeardownSecurityError(f"OpenBao server error: HTTP {status}")
        if status not in (200, 204, 404):
            raise TeardownSecurityError(f"OpenBao refused deletion_allowed configuration: HTTP {status}")

        status, _ = self._request("DELETE", f"/v1/transit/keys/{key}", _call_timeout(deadline))
        if status == 403:
            raise TeardownAuthorizationError(f"openbao_authorization_failed: HTTP {status}")
        if status >= 500:
            raise TeardownSecurityError(f"OpenBao server error: HTTP {status}")
        if status not in (200, 204, 404):
            raise TeardownSecurityError(f"OpenBao key deletion failed: HTTP {status}")

        status, _ = self._request("DELETE", f"/v1/secret/metadata/{key}", _call_timeout(deadline))
        if status == 403:
            raise TeardownAuthorizationError(f"openbao_authorization_failed: HTTP {status}")
        if status >= 500:
            raise TeardownSecurityError(f"OpenBao server error: HTTP {status}")
        if status not in (200, 204, 404):
            raise TeardownSecurityError(f"OpenBao secret deletion failed: HTTP {status}")

    def key_exists(self, customer_hash: str, timeout: float) -> bool:
        status, _ = self._request("GET", f"/v1/transit/keys/eap-{customer_hash}", timeout)
        if status == 404:
            return False
        if status == 403:
            raise TeardownAuthorizationError("openbao_authorization_failed")
        if status >= 500:
            raise TeardownSecurityError(f"OpenBao server error: HTTP {status}")
        if status in (200, 204):
            return True
        raise TeardownSecurityError(f"OpenBao unexpected status: HTTP {status}")

    def secret_exists(self, customer_hash: str, timeout: float) -> bool:
        status, _ = self._request("GET", f"/v1/secret/metadata/eap-{customer_hash}", timeout)
        if status == 404:
            return False
        if status == 403:
            raise TeardownAuthorizationError("openbao_authorization_failed")
        if status >= 500:
            raise TeardownSecurityError(f"OpenBao server error: HTTP {status}")
        if status in (200, 204):
            return True
        raise TeardownSecurityError(f"OpenBao unexpected status: HTTP {status}")

    def decrypt_fails(self, customer_hash: str, timeout: float) -> bool:
        status, _ = self._request(
            "POST",
            f"/v1/transit/decrypt/eap-{customer_hash}",
            timeout,
            {"ciphertext": self.test_ciphertext},
        )
        if status in (400, 404):
            return True
        if status == 403:
            raise TeardownAuthorizationError("openbao_authorization_failed")
        if status >= 500:
            raise TeardownSecurityError(f"OpenBao server error: HTTP {status}")
        if status in (200, 204):
            return False
        raise TeardownSecurityError(f"OpenBao unexpected status: HTTP {status}")


class SpireCLIClient:
    def __init__(self, binary: str, socket_path: str) -> None:
        self.binary = binary
        self.socket_path = socket_path

    def list_entries(self, timeout: float) -> list[dict[str, Any]]:
        payload = _json_command(
            [self.binary, "entry", "show", "-output", "json", "-socketPath", self.socket_path],
            time.monotonic() + min(MAX_CALL_SECONDS, timeout),
        )
        if isinstance(payload, dict):
            if "entries" not in payload or not isinstance(payload["entries"], list):
                raise RuntimeError("invalid_spire_inventory")
            return list(payload["entries"])
        if isinstance(payload, list):
            return list(payload)
        raise RuntimeError("invalid_spire_inventory")

    def delete_entry(self, entry_id: str, timeout: float) -> None:
        result = run_bounded(
            [self.binary, "entry", "delete", "-entryID", entry_id, "-socketPath", self.socket_path],
            time.monotonic() + min(MAX_CALL_SECONDS, timeout),
        )
        if result.timed_out or result.returncode != 0:
            raise RuntimeError(f"SPIRE entry deletion failed for {entry_id}")


class NamespaceStorageClient(Protocol):
    def delete_namespace(self, namespace: str, timeout: float) -> None: ...
    def namespace_exists(self, namespace: str, timeout: float) -> bool: ...
    def storage_absence_proof(self, namespace: str, timeout: float) -> dict[str, Any]: ...


class NamespaceStorageAdapter:
    def __init__(self, client: NamespaceStorageClient) -> None:
        self.client = client

    def execute(self, request: StageRequest) -> StageResult:
        customer_hash = _validate_request(request)
        namespace = f"eap-{customer_hash}"
        self.client.delete_namespace(namespace, _call_timeout(request.deadline))
        namespace_absent = not self.client.namespace_exists(namespace, _call_timeout(request.deadline))
        storage = self.client.storage_absence_proof(namespace, _call_timeout(request.deadline))
        evidence = {"namespace_absent": namespace_absent, "storage": storage}
        if not namespace_absent:
            return StageResult(TeardownStage.NAMESPACE_STORAGE, False, "tenant namespace remains", evidence)
        if storage.get("verified") is not True:
            return StageResult(TeardownStage.NAMESPACE_STORAGE, False, "storage absence is unproved", evidence)
        return StageResult(TeardownStage.NAMESPACE_STORAGE, True, "namespace and declared storage scope absent", evidence)

    def verify(self, request: StageRequest) -> StageResult:
        customer_hash = _validate_request(request)
        namespace = f"eap-{customer_hash}"
        namespace_absent = not self.client.namespace_exists(namespace, _call_timeout(request.deadline))
        storage = self.client.storage_absence_proof(namespace, _call_timeout(request.deadline))
        evidence = {"namespace_absent": namespace_absent, "storage": storage}
        if not namespace_absent:
            return StageResult(TeardownStage.NAMESPACE_STORAGE, False, "tenant namespace remains", evidence)
        if storage.get("verified") is not True:
            return StageResult(TeardownStage.NAMESPACE_STORAGE, False, "storage absence is unproved", evidence)
        return StageResult(TeardownStage.NAMESPACE_STORAGE, True, "namespace and declared storage scope absent", evidence)


class KubernetesNamespaceStorageClient:
    def __init__(self, kubectl: str, proof_scope: str) -> None:
        if proof_scope != "kubernetes-pv":
            raise ValueError("storage proof scope must explicitly be kubernetes-pv")
        self.kubectl = kubectl
        self.proof_scope = proof_scope

    def delete_namespace(self, namespace: str, timeout: float) -> None:
        seconds = max(1, int(min(MAX_CALL_SECONDS, timeout)))
        result = run_bounded(
            [self.kubectl, "delete", "namespace", namespace, "--ignore-not-found", "--wait=true", f"--timeout={seconds}s"],
            time.monotonic() + min(MAX_CALL_SECONDS, timeout),
        )
        if result.timed_out:
            raise DeadlineExceeded("namespace deletion exceeded stage deadline")
        if result.returncode != 0:
            err = result.stderr.strip()
            if "forbidden" in err.lower() or "403" in err:
                raise TeardownAuthorizationError(f"namespace_lookup_failed: {err}")
            raise RuntimeError(f"namespace deletion failed for {namespace}: {err}")

    def namespace_exists(self, namespace: str, timeout: float) -> bool:
        result = run_bounded(
            [self.kubectl, "get", "namespace", namespace, "--ignore-not-found", "-o", "name"],
            time.monotonic() + min(MAX_CALL_SECONDS, timeout),
        )
        if result.timed_out:
            raise DeadlineExceeded("namespace verification exceeded stage deadline")
        if result.returncode != 0:
            err = result.stderr.strip()
            if "forbidden" in err.lower() or "403" in err:
                raise TeardownAuthorizationError(f"namespace_lookup_failed: {err}")
            raise RuntimeError(f"namespace_lookup_failed: {err}")

        stdout = result.stdout.strip()
        if not stdout:
            return False
        if stdout == f"namespace/{namespace}" or stdout == namespace:
            return True
        return False

    def storage_absence_proof(self, namespace: str, timeout: float) -> dict[str, Any]:
        payload = _json_command(
            [self.kubectl, "get", "pv", "-o", "json"],
            time.monotonic() + min(MAX_CALL_SECONDS, timeout),
        )
        retained = []
        if isinstance(payload, dict):
            for volume in payload.get("items", []):
                claim = volume.get("spec", {}).get("claimRef", {})
                if claim.get("namespace") == namespace:
                    retained.append(volume.get("metadata", {}).get("name", "<unnamed>"))
        return {
            "verified": False,
            "blocker": "durable_storage_erasure_unproved",
            "proof_scope": self.proof_scope,
            "retained_resources": sorted(retained),
            "external_storage_and_backups": "unverified",
        }


def _require_env(*names: str) -> list[str]:
    values = [os.getenv(name, "").strip() for name in names]
    if not all(values):
        missing = [name for name, value in zip(names, values) if not value]
        raise ValueError(f"missing explicit teardown configuration: {', '.join(missing)}")
    return values


def build_teardown_executor() -> FailClosedExecutor | ConfiguredTeardownExecutor:
    """Build only explicitly selected providers; an unset environment fails closed."""
    adapters: dict[TeardownStage, _StageAdapter] = {}

    if os.getenv("SIGNALLOOM_TEARDOWN_ROUTE_PROVIDER") == "kubectl":
        kubectl, namespace = _require_env("SIGNALLOOM_TEARDOWN_KUBECTL", "SIGNALLOOM_TEARDOWN_ROUTE_NAMESPACE")
        if not shutil.which(kubectl) and not Path(kubectl).is_file():
            raise ValueError("configured kubectl binary does not exist")
        adapters[TeardownStage.ROUTE] = RouteAdapter(kubectl, namespace)

    if os.getenv("SIGNALLOOM_TEARDOWN_MESH_PROVIDER") == "tailscale-api":
        api_base, tailnet, api_key = _require_env(
            "SIGNALLOOM_TEARDOWN_TAILSCALE_API_BASE",
            "SIGNALLOOM_TEARDOWN_TAILSCALE_TAILNET",
            "SIGNALLOOM_TEARDOWN_TAILSCALE_API_KEY",
        )
        ownership_json = os.getenv("SIGNALLOOM_TEARDOWN_MESH_OWNERSHIP", "").strip()
        ownership = json.loads(ownership_json) if ownership_json else None
        adapters[TeardownStage.MESH] = MeshAdapter(
            TailscaleAdminAPIClient(api_base, tailnet, api_key),
            ownership=ownership,
        )

    if os.getenv("SIGNALLOOM_TEARDOWN_KEY_SPIRE_PROVIDER") == "openbao-spire":
        bao_url, bao_token, ciphertext, spire_binary, spire_socket = _require_env(
            "SIGNALLOOM_TEARDOWN_OPENBAO_URL",
            "SIGNALLOOM_TEARDOWN_OPENBAO_TOKEN",
            "SIGNALLOOM_TEARDOWN_OPENBAO_TEST_CIPHERTEXT",
            "SIGNALLOOM_TEARDOWN_SPIRE_BINARY",
            "SIGNALLOOM_TEARDOWN_SPIRE_SOCKET",
        )
        adapters[TeardownStage.KEY_SPIRE] = KeySpireAdapter(
            OpenBaoHTTPClient(bao_url, bao_token, ciphertext),
            SpireCLIClient(spire_binary, spire_socket),
        )

    if os.getenv("SIGNALLOOM_TEARDOWN_NAMESPACE_PROVIDER") == "kubectl":
        kubectl, scope = _require_env("SIGNALLOOM_TEARDOWN_KUBECTL", "SIGNALLOOM_TEARDOWN_STORAGE_PROOF_SCOPE")
        adapters[TeardownStage.NAMESPACE_STORAGE] = NamespaceStorageAdapter(
            KubernetesNamespaceStorageClient(kubectl, scope)
        )

    if not adapters:
        return FailClosedExecutor()
    return ConfiguredTeardownExecutor(adapters)


__all__ = [
    "BoundedHTTPTransport",
    "CommandResult",
    "ConfiguredTeardownExecutor",
    "FailClosedExecutor",
    "KeySpireAdapter",
    "KubernetesNamespaceStorageClient",
    "MAX_CALL_SECONDS",
    "MeshAdapter",
    "MeshClient",
    "NamespaceStorageAdapter",
    "NamespaceStorageClient",
    "OpenBaoClient",
    "OpenBaoHTTPClient",
    "RouteAdapter",
    "SpireCLIClient",
    "SpireClient",
    "TailscaleAdminAPIClient",
    "build_teardown_executor",
    "run_bounded",
]
