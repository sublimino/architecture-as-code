"""Authenticated import gateway for KubeSec-AFM: POST /api/v1/afm/clusters/import.

Verifies inbound requests using named static Bearer keys (e.g. afm-importer),
enforces required scopes (afm:import) and cluster bindings, audits the mutation
intent, streams and bounds payload size, and forwards the raw payload to upstream
afm-platform without forwarding the inbound Authorization header.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import hashlib
import hmac
import json
import logging
import os
from typing import Any

from fastapi import APIRouter, FastAPI, Request, Response
import httpx

from api_compat import APIError, Principal, _audit_outbound_request, authenticated_principal
from superadmin import is_superadmin

logger = logging.getLogger(__name__)

AFM_IMPORT_KEYS_ENV = "AFM_IMPORT_KEYS"
AFM_IMPORTER_KEY_DIR_ENV = "AFM_IMPORTER_KEY_DIR"
DEFAULT_KEY_DIR = "/etc/fe-signalloom/afm-importer-key"
AFM_IMPORT_MAX_BYTES_DEFAULT = 8388608  # 8 MiB

AFM_BASE_URL_DEFAULT = "http://afm-platform.fe-k8s-afm.svc.cluster.local:8000"
AFM_TIMEOUT_S = 20.0
_MIN_KEY_BYTES = 32
_MAX_EXPIRY_DAYS = 90

_TimeoutException = httpx.TimeoutException
_HTTPStatusError = httpx.HTTPStatusError

router = APIRouter(prefix="/api/v1/afm", tags=["afm"])


def _load_keys() -> list[tuple[dict[str, Any], str]]:
    """Load and validate all configured importer keys from disk.

    Returns a list of (key_spec, key_token) pairs. Raises APIError(503) if
    any key configuration is missing, malformed, short, whitespace, or expired.
    """
    raw_keys_cfg = os.environ.get(AFM_IMPORT_KEYS_ENV)
    if not raw_keys_cfg:
        logger.error("AFM importer keys configuration (%s) is missing", AFM_IMPORT_KEYS_ENV)
        raise APIError(503, "afm_importer_credential_unavailable", "AFM importer keys are not configured")

    try:
        keys_cfg = json.loads(raw_keys_cfg)
    except Exception:
        logger.error("AFM importer keys configuration (%s) is not valid JSON", AFM_IMPORT_KEYS_ENV)
        raise APIError(503, "afm_importer_credential_unavailable", "AFM importer keys configuration is invalid") from None

    if not isinstance(keys_cfg, list) or not keys_cfg:
        logger.error("AFM importer keys configuration must be a non-empty list")
        raise APIError(503, "afm_importer_credential_unavailable", "AFM importer keys configuration is invalid")

    key_dir = os.environ.get(AFM_IMPORTER_KEY_DIR_ENV, DEFAULT_KEY_DIR)
    loaded_keys: list[tuple[dict[str, Any], str]] = []
    now = datetime.now(timezone.utc)
    max_future = now + timedelta(days=_MAX_EXPIRY_DAYS, seconds=300)

    for spec in keys_cfg:
        if not isinstance(spec, dict):
            logger.error("AFM importer key entry is not an object: %s", spec)
            raise APIError(503, "afm_importer_credential_unavailable", "AFM importer key specification is invalid")

        unknown_fields = set(spec.keys()) - {"name", "scopes", "cluster"}
        if unknown_fields:
            logger.error("AFM importer key spec contains unknown fields: %s", sorted(unknown_fields))
            raise APIError(503, "afm_importer_credential_unavailable", "AFM importer key specification has unknown fields")

        name = spec.get("name")
        scopes = spec.get("scopes")
        cluster = spec.get("cluster")

        if not isinstance(name, str) or not name:
            logger.error("AFM importer key spec missing valid string name")
            raise APIError(503, "afm_importer_credential_unavailable", "AFM importer key missing name")
        if not isinstance(scopes, list) or not all(isinstance(s, str) for s in scopes):
            logger.error("AFM importer key %s missing valid scopes list", name)
            raise APIError(503, "afm_importer_credential_unavailable", f"AFM importer key {name} missing valid scopes")
        if not isinstance(cluster, str) or not cluster:
            logger.error("AFM importer key %s missing valid cluster binding", name)
            raise APIError(503, "afm_importer_credential_unavailable", f"AFM importer key {name} missing cluster binding")

        # Read key file
        key_path = os.path.join(key_dir, name)
        try:
            with open(key_path, encoding="utf-8") as fh:
                token = fh.read()
        except OSError:
            logger.error("AFM importer key %s file is missing or unreadable at %s", name, key_path)
            raise APIError(503, "afm_importer_credential_unavailable", f"AFM importer key {name} file is unavailable") from None

        token = token[:-1] if token.endswith("\n") else token
        if len(token) < _MIN_KEY_BYTES or any(c.isspace() for c in token):
            logger.error("AFM importer key %s is too short (<%d bytes) or contains whitespace", name, _MIN_KEY_BYTES)
            raise APIError(503, "afm_importer_credential_unavailable", f"AFM importer key {name} is unusable")

        # Read expires file
        expires_path = os.path.join(key_dir, f"{name}.expires")
        try:
            with open(expires_path, encoding="utf-8") as fh:
                expires_str = fh.read().strip()
        except OSError:
            logger.error("AFM importer key %s expiration file is missing at %s", name, expires_path)
            raise APIError(503, "afm_importer_credential_unavailable", f"AFM importer key {name} expiration is missing") from None

        try:
            expires_dt = datetime.fromisoformat(expires_str.replace("Z", "+00:00"))
        except Exception:
            logger.error("AFM importer key %s expiration timestamp %r is unparseable", name, expires_str)
            raise APIError(503, "afm_importer_credential_unavailable", f"AFM importer key {name} expiration is invalid") from None

        if expires_dt.tzinfo is None:
            expires_dt = expires_dt.replace(tzinfo=timezone.utc)

        if expires_dt < now:
            logger.error("AFM importer key %s expired at %s", name, expires_str)
            raise APIError(503, "afm_importer_credential_unavailable", f"AFM importer key {name} has expired")

        if expires_dt > max_future:
            logger.error("AFM importer key %s expiration %s exceeds maximum 90 days", name, expires_str)
            raise APIError(503, "afm_importer_credential_unavailable", f"AFM importer key {name} expiration exceeds 90 days")

        loaded_keys.append((spec, token))

    return loaded_keys


def _operator_principal(auth_val: str) -> Principal | None:
    """The superadmin behind a Dex bearer, ``None`` when the bearer is not a token we issue.

    Two credentials open this route. A machine presents a named importer key bound to one
    cluster (the rbac-exporter CronJob). An operator in the dashboard presents the Dex token
    the page already holds, and may import any cluster: the same superadmin rule the
    dashboard's nginx gate applies to every other AFM mutation (efa7e8e5). A token that
    validates but is not a superadmin is refused here, never retried as a key.
    """
    try:
        principal = authenticated_principal(auth_val)
    except APIError as exc:
        if exc.status_code == 401:
            return None  # not a JWT we accept: the key path decides
        raise  # a verdict on a real token (host scope, unbound tenant) stands
    if not is_superadmin(principal):
        raise APIError(403, "superadmin_required", "Superadmin access is required to import a cluster")
    return principal


@router.post("/clusters/import")
async def import_cluster(request: Request) -> Response:
    """Authenticated import gateway for AFM cluster models."""
    # 1. Authorization header validation
    auth_headers = request.headers.getlist("authorization")
    if len(auth_headers) != 1:
        raise APIError(401, "authentication_required", "Exactly one Authorization header required")

    auth_val = auth_headers[0]
    if not auth_val.startswith("Bearer "):
        raise APIError(401, "authentication_required", "Bearer authorization scheme required")

    presented_token = auth_val[7:]
    if not presented_token:
        raise APIError(401, "authentication_required", "Bearer token cannot be empty")

    # 2. Operator path: a superadmin's own Dex token. Otherwise key loading and
    #    constant-time digest comparison across ALL keys.
    operator = _operator_principal(auth_val)
    matched_key_spec: dict[str, Any] | None = None
    if operator is None:
        loaded_keys = _load_keys()
        presented_digest = hashlib.sha256(presented_token.encode("utf-8")).digest()

        for spec, loaded_token in loaded_keys:
            expected_digest = hashlib.sha256(loaded_token.encode("utf-8")).digest()
            match = hmac.compare_digest(presented_digest, expected_digest)
            if match and matched_key_spec is None:
                matched_key_spec = spec

        if matched_key_spec is None:
            raise APIError(401, "invalid_token", "Presented Bearer token is invalid")

    key_name = matched_key_spec["name"] if matched_key_spec is not None else f"operator:{operator.subject}"

    # 3. Scope check (keys only; the operator path is the superadmin rule)
    if matched_key_spec is not None and "afm:import" not in matched_key_spec.get("scopes", []):
        logger.warning("AFM importer key %s lacks scope afm:import", key_name)
        raise APIError(403, "scope_required", "Presented key lacks required scope afm:import")

    # 4. Body size limit enforcement (header check and streaming cap)
    max_bytes = int(os.environ.get("AFM_IMPORT_MAX_BYTES", str(AFM_IMPORT_MAX_BYTES_DEFAULT)))
    content_length = request.headers.get("content-length")
    if content_length is not None:
        try:
            cl_int = int(content_length)
            if cl_int > max_bytes:
                raise APIError(413, "payload_too_large", f"Payload size {cl_int} exceeds maximum allowed {max_bytes}")
        except ValueError:
            pass

    chunks: list[bytes] = []
    total_bytes = 0
    async for chunk in request.stream():
        total_bytes += len(chunk)
        if total_bytes > max_bytes:
            raise APIError(413, "payload_too_large", f"Streamed payload exceeded maximum size {max_bytes}")
        chunks.append(chunk)

    body_bytes = b"".join(chunks)

    # 5. JSON schema & cluster ID validation
    try:
        body_json = json.loads(body_bytes)
    except Exception:
        raise APIError(422, "invalid_payload_schema", "Request body is not valid JSON") from None

    if not isinstance(body_json, dict):
        raise APIError(422, "invalid_payload_schema", "Request body must be a JSON object")

    cluster_id = body_json.get("id")
    if not isinstance(cluster_id, str) or not cluster_id:
        raise APIError(422, "invalid_payload_schema", "Request body must contain a non-empty string 'id'")

    # Which cluster the RBAC was READ FROM, as opposed to ``id``, which is the
    # identifier of this import inside AFM.
    #
    # The two are not the same thing and conflating them made every key-bound
    # import impossible. ``id`` is generated per import as
    # ``signalloom-<YYYYMMDDTHHMMSS>-<rand>`` (dashboard ``afmYaml.ts``); the
    # prefix and the sortable stamp are what the AFM embed uses to select the
    # most recent import, so it cannot be repurposed to name a cluster. But the
    # key binding below compared it against ``cluster``, so a key bound to
    # ``kind-osramp`` could never match and only a superadmin (who presents no
    # key) could import at all.
    #
    # ``source_cluster`` carries the selected cluster id instead. It is
    # optional: an older client that omits it falls back to ``id``, which
    # preserves the existing refusal rather than quietly widening the binding.
    source_cluster = body_json.get("source_cluster")
    if source_cluster is not None and (not isinstance(source_cluster, str) or not source_cluster):
        raise APIError(
            422, "invalid_payload_schema", "'source_cluster' must be a non-empty string when present",
        )
    bound_target = source_cluster if isinstance(source_cluster, str) else cluster_id

    # 6. Bound cluster verification (keys are bound to one cluster; an operator is not)
    if matched_key_spec is not None:
        bound_cluster = matched_key_spec.get("cluster")
        if bound_target != bound_cluster:
            logger.warning(
                "Cluster binding mismatch: source cluster %s != bound cluster %s for key %s",
                bound_target, bound_cluster, key_name,
            )
            raise APIError(403, "cluster_not_bound", f"Key {key_name} is not authorized for cluster {bound_target}")

    # 7. Audit logging before upstream mutation
    logger.info("AFM cluster import requested for cluster %s with key %s (%d bytes)", cluster_id, key_name, len(body_bytes))
    principal = operator if operator is not None else Principal(tenant="system", subject=f"key:{key_name}", email=None)
    await _audit_outbound_request(
        principal=principal,
        event_type="afm.cluster_import_requested",
        detail={
            "key": key_name,
            "cluster_id": cluster_id,
            "source_cluster": bound_target,
            "bytes": len(body_bytes),
        },
        what="afm_import",
    )

    # 8. Forward to upstream afm-platform
    afm_base_url = os.environ.get("AFM_BASE_URL", AFM_BASE_URL_DEFAULT)
    target_url = f"{afm_base_url.rstrip('/')}/clusters/import"

    async with httpx.AsyncClient(timeout=AFM_TIMEOUT_S) as client:
        try:
            upstream_resp = await client.post(
                target_url,
                content=body_bytes,
                headers={"Content-Type": "application/json"},
            )
        except _TimeoutException:
            logger.error("Upstream AFM timed out importing cluster %s", cluster_id)
            raise APIError(504, "afm_import_timeout", "Upstream AFM request timed out") from None
        except httpx.HTTPError as exc:
            logger.error("Upstream AFM connection failed for cluster %s: %s", cluster_id, exc)
            raise APIError(502, "afm_import_failed", "Failed to connect to upstream AFM") from None

    if not upstream_resp.is_success:
        logger.warning("Upstream AFM returned status %d for cluster %s", upstream_resp.status_code, cluster_id)
        raise APIError(502, "afm_import_rejected", f"Upstream AFM rejected import with status {upstream_resp.status_code}")

    return Response(
        content=upstream_resp.content,
        status_code=upstream_resp.status_code,
        media_type=upstream_resp.headers.get("content-type", "application/json"),
    )


def install_afm_import_api(app: FastAPI) -> None:
    """Wire the AFM import router into the FastAPI application."""
    app.include_router(router)
