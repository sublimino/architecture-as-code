"""Deterministic vs LLM: the model narrates, it never decides.

Wiring an LlmAgent narrator must change ONLY the RCA summary text and the
reported model_id. The fault domain, confidence, probable cause, evidence
trajectory, redaction, and suggested actions stay identical to the deterministic
run. This is design invariant #8 as an executable check, run in the image build
against the hermetic golden evidence (no real model call, no network).
"""

import asyncio
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # tests/ -> elk_stub
import elk_stub  # noqa: E402

from olly_sentinel import config, pipeline  # noqa: E402
from olly_sentinel.agent import SentinelRuntime  # noqa: E402

CANNED_LLM_SUMMARY = (
    "LLM narrative: inventory-service is failing because its connection pool to "
    "positions-ledger-db is exhausted; raise the pool or add a read replica."
)

EVENT = {
    "schema_version": "v1",
    "event_id": "evt-detllm",
    "correlation_id": "corr-detllm",
    "app_id": "inventory-service",
    "source": "replay",
    "alert_type": "app_failure_burst",
    "severity": 2,
    "occurred_at": "2026-07-18T00:00:00Z",
    "payload": {"raw": "det-vs-llm"},
}


class _FakeNarrator:
    """Stands in for the ADK LlmAgent narrator without a real model call: it
    yields one final response carrying a canned summary, the same shape the real
    narrator's final event has."""

    async def run_async(self, ctx):
        from google.adk.events import Event
        from google.genai import types

        yield Event(
            author="rca_narrator",
            invocation_id=ctx.invocation_id,
            content=types.Content(role="model", parts=[types.Part(text=CANNED_LLM_SUMMARY)]),
        )


def _evidence_no_ts(enr):
    # observed_at is a wall-clock stamp; drop it so two runs are comparable.
    return [{k: v for k, v in e.items() if k != "observed_at"} for e in enr["evidence"]]


def _triage(monkeypatch, with_narrator):
    elk_stub.install(monkeypatch, pipeline)
    runtime = SentinelRuntime()
    if with_narrator:
        monkeypatch.setattr(config, "LLM_MODEL", "fake-llm-narrator", raising=False)
        object.__setattr__(runtime.agent, "narrator", _FakeNarrator())
    return asyncio.run(runtime.triage(dict(EVENT)))


def test_llm_narrates_but_does_not_decide(monkeypatch):
    det = _triage(monkeypatch, with_narrator=False)
    llm = _triage(monkeypatch, with_narrator=True)

    # The model changed the narrative and the reported model id.
    assert llm["rca"]["summary"] == CANNED_LLM_SUMMARY
    assert det["rca"]["summary"] != llm["rca"]["summary"]
    assert det["agent"]["model_id"] == "deterministic-fallback"
    assert llm["agent"]["model_id"] == "fake-llm-narrator"

    # It did NOT change any decision: every other field is identical.
    for field in ("fault_domain", "probable_cause", "confidence_score", "suggested_actions"):
        assert det["rca"][field] == llm["rca"][field], f"narrator changed rca.{field}"
    assert _evidence_no_ts(det) == _evidence_no_ts(llm)
    assert det["redaction"] == llm["redaction"]
    assert det["idempotency_key"] == llm["idempotency_key"]
    assert det["correlation_id"] == llm["correlation_id"]

    # The classification is the seeded dependency incident, unaffected by the model.
    assert det["rca"]["fault_domain"] == "dependency"
    assert det["rca"]["confidence_score"] >= 0.5
