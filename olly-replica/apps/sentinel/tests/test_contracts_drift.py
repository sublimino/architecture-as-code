"""The drift gate: the shapes this agent consumes and produces must match
the committed schemas. Runs during the image build, so an image with drifted
contracts cannot exist."""

import jsonschema
import pytest

from olly_sentinel import contracts, pipeline


def sample_event() -> dict:
    return {
        "schema_version": "v1",
        "event_id": "evt-0001",
        "correlation_id": "corr-0001",
        "app_id": "inventory-service",
        "source": "replay",
        "alert_type": "app_failure_burst",
        "severity": 2,
        "occurred_at": "2026-07-17T00:00:00Z",
        "payload": {"raw": "db connection pool exhausted"},
    }


def test_event_validates():
    contracts.validate(contracts.ELIGIBLE_EVENT, sample_event())


def test_event_without_join_key_rejected():
    ev = sample_event()
    del ev["correlation_id"]
    with pytest.raises(jsonschema.ValidationError):
        contracts.validate(contracts.ELIGIBLE_EVENT, ev)


def test_assembled_enrichment_validates_and_redacts():
    c = pipeline.Correlation(
        error_count=12,
        total_docs=23,
        fault_domain="dependency",
        top_error="db connection pool exhausted: timeout acquiring connection",
        sample_lines=["[ERROR inventory-service] db connection pool exhausted"],
        secrets_scrubbed=1,
    )
    evidence = [{
        "source": "elk", "scope": "elk.logs.read",
        "query": "app-logs-* app_id:inventory-service", "doc_count": 23,
        "observed_at": "2026-07-17T00:00:00Z",
    }]
    summary = (
        "pool exhaustion; found dsn=postgres://svc:Sup3rSecretPlantedPw!@db/x in logs"
    )
    payload = pipeline.assemble(sample_event(), c, evidence, summary,
                                "deterministic-fallback", enrichment_pass=1)
    # assemble() already contract-validated; assert the safety properties.
    assert "Sup3rSecretPlantedPw" not in str(payload)
    assert payload["redaction"]["secrets_found"] >= 2
    assert payload["agent"]["name"] == "olly-sentinel"
    assert "incident_sys_id" not in payload  # correlation-ID is the join key
