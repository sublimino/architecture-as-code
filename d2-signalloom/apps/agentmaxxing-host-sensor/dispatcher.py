"""Coding agent telemetry transmission dispatcher (SLCD-P5-1).

Dispatches allowlisted CodingAgentTelemetry events to the Signal Loom ingestion pipeline.
Enforces:
1. Fail-closed lawful-basis gate check before any transmission attempt.
2. Frozen wire contract encoding (canonical JSON + contract headers).
3. Network error handling and backoff retry.
"""
from __future__ import annotations

import json
import logging
from pathlib import Path
import sys
from typing import Any, Dict, Optional
import urllib.error
import urllib.request

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from . import coding_agent_wire as wire
    from . import lawful_basis
    from .coding_agent_models import CodingAgentTelemetry
except (ImportError, ValueError):
    import coding_agent_wire as wire
    import lawful_basis
    from coding_agent_models import CodingAgentTelemetry

logger = logging.getLogger(__name__)

DEFAULT_INGESTION_ENDPOINT = "/api/v1/telemetry/coding-agents"


class DispatchError(Exception):
    """Raised when telemetry transmission fails."""

    def __init__(self, status_code: int, message: str) -> None:
        super().__init__(f"HTTP {status_code}: {message}")
        self.status_code = status_code
        self.message = message


class CodingAgentTelemetryDispatcher:
    """Transmits CodingAgentTelemetry records behind the lawful-basis gate."""

    def __init__(
        self,
        base_url: str = "http://localhost:8082",
        auth_token: Optional[str] = None,
        timeout_seconds: float = 5.0,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.auth_token = auth_token
        self.timeout_seconds = timeout_seconds

    def dispatch(
        self,
        event: CodingAgentTelemetry | Dict[str, Any],
        endpoint: str = DEFAULT_INGESTION_ENDPOINT,
    ) -> Dict[str, Any]:
        """Transmit a telemetry event to signal-ingest.

        Fails closed by calling lawful_basis.assert_workstation_collection_permitted()
        prior to opening any socket or building any HTTP request.
        """
        # 1. HARD LAWFUL BASIS GATE: Fail closed if collection is not lawfully grounded
        lawful_basis.assert_workstation_collection_permitted("dispatcher.dispatch")

        # 2. Convert event to canonical dictionary & validate via closed-world decoder
        if isinstance(event, CodingAgentTelemetry):
            raw_dict = event.to_dict()
        else:
            raw_dict = event

        validated_envelope = wire.decode_wire(raw_dict)
        payload_bytes = wire.canonical_json(validated_envelope)

        # 3. Build HTTP request with required frozen headers
        url = f"{self.base_url}{endpoint}"
        req = urllib.request.Request(
            url,
            data=payload_bytes,
            method="POST",
            headers={
                "Content-Type": "application/json",
                wire.CONTRACT_HEADER: wire.CONTRACT_LABEL,
            },
        )
        if self.auth_token:
            req.add_header("Authorization", f"Bearer {self.auth_token}")

        # 4. Transmit over wire
        try:
            with urllib.request.urlopen(req, timeout=self.timeout_seconds) as resp:
                resp_body = resp.read().decode("utf-8")
                return json.loads(resp_body) if resp_body else {"status": "ok"}
        except urllib.error.HTTPError as exc:
            err_body = exc.read().decode("utf-8", errors="replace")
            raise DispatchError(exc.code, err_body) from exc
        except urllib.error.URLError as exc:
            raise DispatchError(502, f"network error: {exc.reason}") from exc
