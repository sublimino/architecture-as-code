"""Decision-event emission: one contract-validated record per gate the
pipeline evaluates, published to ``olly.pipeline.decisions`` keyed by
correlation-ID.

The decision topic makes the causality chain a durable, structured artifact:
records survive a restart, join across the mapping service and the agent, and
drive a UI. The same records render as the Panopticon's decision tree and as the
SIEM audit timeline.

Two properties this module must never violate:

1. **Emission never changes routing.** Every call site emits *after* the gate
   has already decided. A record observes a decision the gate has already made.
2. **Emission never breaks triage.** A broker hiccup or a contract bug here
   must not drop an incident on the floor, so ``emit`` swallows and logs its
   own failures. The decision topic is best-effort observability; the Kafka
   response topic remains the authoritative record of enrichment.
"""

import json
import logging
from datetime import datetime, timezone

from . import config, contracts, redact

log = logging.getLogger("olly-sentinel")

COMPONENT = "olly_sentinel"


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def build(event: dict, gate: str, branch: str, reason: str, **extra) -> dict:
    """Assemble a contract-shaped decision record from the in-flight event.

    Tolerates a partially-parsed event: the schema_validate gate rejects
    before any field can be trusted, so missing identifiers fall back to
    sentinels and the original rejection surfaces.
    """
    clean_reason, _ = redact.scrub(str(reason)[:512])
    record = {
        "schema_version": "v1",
        "correlation_id": str(event.get("correlation_id") or "unknown"),
        "event_id": str(event.get("event_id") or "unknown"),
        "app_id": str(event.get("app_id") or ""),
        "component": COMPONENT,
        "gate": gate,
        "branch": branch,
        "reason": clean_reason,
        "ts": _now(),
    }
    for key, value in extra.items():
        if value is not None:
            record[key] = value
    return record


async def emit(producer, event: dict, gate: str, branch: str, reason: str, **extra) -> None:
    """Validate and publish one decision record. Best-effort by design (see
    the module docstring): failures here are logged and swallowed so that
    observability can never take the pipeline down."""
    if producer is None:
        return
    try:
        record = build(event, gate, branch, reason, **extra)
        contracts.validate(contracts.PIPELINE_DECISION, record)
        await producer.send_and_wait(
            config.DECISIONS_TOPIC,
            json.dumps(record).encode(),
            key=record["correlation_id"].encode(),
        )
    except Exception as exc:  # noqa: BLE001 - observability must not break triage
        log.warning("decision emit failed (gate=%s branch=%s): %s", gate, branch, exc)
