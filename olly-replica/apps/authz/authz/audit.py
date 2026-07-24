"""Jarvis audit stand-in. One JSONL record per authorization decision, all
records for a request linked by authz_ctx_id, so 'who authorized this?' is a
single-key lookup. Real ARC forwards this to Splunk over OpenTelemetry; here it
appends to a local file and can be read back by authz_ctx_id for the dashboard."""

import json
import threading

from . import config

_lock = threading.Lock()


def write(record: dict) -> dict:
    """Append one decision record. Never raises into the caller; a broken audit
    sink must not change an authorization outcome."""
    try:
        with _lock, open(config.AUDIT_LOG, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record) + "\n")
    except OSError:
        pass
    return record


def record(authz_ctx_id: str, acme_id: str, agent: str, action: str,
           decision: str, policy_id: str = "", eems_attributes: dict | None = None,
           chain: list | None = None, reason: str = "", ts: str = "") -> dict:
    return write({
        "authz_ctx_id": authz_ctx_id,
        "acme_id": acme_id,
        "agent": agent,
        "action": action,
        "decision": decision,
        "policy_id": policy_id,
        "eems_attributes": eems_attributes or {},
        "agent_chain": chain or [agent],
        "reason": reason,
        "ts": ts,
    })


def read_for(authz_ctx_id: str) -> list:
    """Every record for one authz_ctx_id, the single-query audit answer."""
    out = []
    try:
        with open(config.AUDIT_LOG, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if rec.get("authz_ctx_id") == authz_ctx_id:
                    out.append(rec)
    except OSError:
        pass
    return out
