"""W11 perturbation probes for the four previously-unassessed telemetry routes.

Doctrine: a figure is real iff it is a function of its inputs. A figure that cannot
be derived must be REFUSED, never replaced by a better-chosen constant.

Routes under probe:
  GET  /api/agents/{agent_id}/telemetry          (api_compat.py:6810)
  GET  /v1/telemetry/coding-agents               (coding_agent_telemetry.py)
  GET  /v1/telemetry/coding-agents/aggregate     (coding_agent_telemetry.py)
  POST /v1/telemetry/coding-agents/ordering      (coding_agent_telemetry.py)

Each probe holds the request constant and varies exactly ONE axis, so that a still
field can be attributed: fabricated, correctly constant, or unreached. The axis
varied is named in every test docstring.
"""
from __future__ import annotations

from typing import Any

import pytest

import api_compat
from test_api_compat import bearer, client, token_for  # noqa: F401  (client is a fixture)


@pytest.fixture
def fixture_mode(monkeypatch):
    """Drive the in-memory (pool is None) path: no SQL telemetry plane exists."""

    async def _no_pool():
        return None

    monkeypatch.setattr(api_compat, "_get_pool", _no_pool)
    return _no_pool


def _register(tenant: str, agent_id: str, name: str) -> None:
    api_compat._ensure_seeded(tenant)
    with api_compat._STORE_LOCK:
        api_compat._AGENTS.setdefault(tenant, {})[agent_id] = {"id": agent_id, "name": name}


def _telemetry(client, agent_id: str, query: str = "") -> dict[str, Any]:
    res = client.get(
        f"/api/agents/{agent_id}/telemetry{query}", headers=bearer(token_for("alice"))
    )
    assert res.status_code in (200, 502, 503), res.status_code
    return {"status": res.status_code, "body": res.json()}


# ---------------------------------------------------------------------------
# P4-A  AXIS: agent identity string (real state held constant at zero)
# ---------------------------------------------------------------------------
def test_p4a_observations_are_not_decided_by_agent_id_substring(client, fixture_mode):
    """AXIS=agent-id string. Three agents, identical (empty) real telemetry state.

    Their IDs differ only in a substring the handler branches on. A field that is a
    function of its inputs cannot change here, because no input changed -- only a name.
    """
    _register("tenant-a", "probe-nono-1", "probe-nono-1")
    _register("tenant-a", "probe-standard-1", "probe-standard-1")
    _register("tenant-a", "probe-plain-1", "probe-plain-1")

    sets = {}
    for aid in ("probe-nono-1", "probe-standard-1", "probe-plain-1"):
        body = _telemetry(client, aid)["body"]
        sets[aid] = sorted(
            (o["source"], o["layer"], o["action"], o["confidence"])
            for o in body.get("observations", [])
        )

    distinct = {tuple(v) for v in sets.values()}
    assert len(distinct) == 1, (
        "FABRICATION: the observation set is selected by agent-ID substring, not by "
        f"observed state. Three agents with identical empty state returned "
        f"{len(distinct)} different observation sets: { {k: len(v) for k, v in sets.items()} }"
    )


# ---------------------------------------------------------------------------
# P4-C  AXIS: upstream payload shape, mocked to PRODUCTION TRUTH (no source wired)
# ---------------------------------------------------------------------------
def test_p4c_no_telemetry_plane_must_refuse_not_invent(client, fixture_mode):
    """AXIS=upstream availability. No telemetry store is consulted by this route at all.

    Production truth: there is no telemetry data plane behind this handler -- it reads
    neither signal-ingest observations nor the cAdvisor sampler. The honest responses are
    an empty set or a typed refusal. Returning populated observations is fabrication.
    """
    _register("tenant-a", "probe-plain-2", "probe-plain-2")
    out = _telemetry(client, "probe-plain-2")
    body = out["body"]

    if out["status"] == 200:
        assert body.get("observations") == [], (
            "FABRICATION: 200 OK carrying "
            f"{len(body.get('observations', []))} observations while no telemetry "
            "source was queried. Sources cited: "
            f"{sorted({o['source'] for o in body['observations']})}"
        )
        assert body.get("source_health") != "healthy", (
            "FABRICATION: source_health='healthy' is asserted without probing any source."
        )


def test_p4c2_cited_sources_must_not_be_undeployed_sensors(client, fixture_mode):
    """AXIS=upstream availability. Attribution must name a sensor that actually reported.

    Tetragon was never deployed in this estate (dropped 2026-10-06, warden in-sentinel
    eBPF used instead), so an observation attributed to 'tetragon-*' cannot be real.
    """
    _register("tenant-a", "probe-standard-2", "probe-standard-2")
    body = _telemetry(client, "probe-standard-2")["body"]
    cited = sorted({o["source"] for o in body.get("observations", [])})
    assert not [s for s in cited if "tetragon" in s], (
        f"FABRICATION: observations attributed to an undeployed sensor: {cited}"
    )


# ---------------------------------------------------------------------------
# P4-B  AXIS: wall-clock time (no new telemetry between the two calls)
# ---------------------------------------------------------------------------
def test_p4b_observed_at_must_not_be_request_time(client, fixture_mode, monkeypatch):
    """AXIS=time, as a POSITIVE provenance proof rather than a two-call diff.

    observed_at is the time an observation was MADE. A two-call diff cannot detect
    request-time stamping because _now_iso() has one-second granularity and both calls
    land in the same second. So instead: replace the request-time clock with a sentinel
    and see whether it surfaces on the wire. If it does, observed_at provably carries
    request time, not observation time -- every poll restamps invented events as fresh.
    """
    _register("tenant-a", "probe-plain-3", "probe-plain-3")
    sentinel = "1999-12-31T23:59:58Z"
    monkeypatch.setattr(api_compat, "_now_iso", lambda: sentinel)

    body = _telemetry(client, "probe-plain-3")["body"]
    observations = body.get("observations", [])
    if not observations:
        pytest.skip("route refused or returned empty: nothing to compare (honest)")

    stamped = [o["id"] for o in observations if o["observed_at"] == sentinel]
    assert not stamped, (
        "FABRICATION: observed_at is the request clock, not an observation time -- "
        f"the request-time sentinel {sentinel} surfaced on {len(stamped)} of "
        f"{len(observations)} observations: {stamped}"
    )


# ---------------------------------------------------------------------------
# P4-D  AXIS: agent count / per-agent real state
# ---------------------------------------------------------------------------
def test_p4d_confidence_must_vary_with_evidence_not_be_a_constant(client, fixture_mode):
    """AXIS=agent count. Many agents, none with any real evidence behind them.

    A confidence is a property of evidence. With no evidence, every agent receiving the
    same hardcoded float is a constant masquerading as a measurement.
    """
    ids = [f"probe-fleet-{n}" for n in range(6)]
    for aid in ids:
        _register("tenant-a", aid, aid)

    per_agent = {}
    for aid in ids:
        body = _telemetry(client, aid)["body"]
        per_agent[aid] = sorted(o["confidence"] for o in body.get("observations", []))

    populated = {k: v for k, v in per_agent.items() if v}
    if not populated:
        pytest.skip("route refused or returned empty for all agents (honest)")

    distinct = {tuple(v) for v in populated.values()}
    assert len(distinct) > 1, (
        "FABRICATION: every one of "
        f"{len(populated)} agents with no evidence returned the identical confidence "
        f"vector {next(iter(distinct))} -- a hardcoded constant, not a measurement."
    )


# ---------------------------------------------------------------------------
# P4-E  AXIS: limit parameter (pushdown claim vs what was actually pushed down)
# ---------------------------------------------------------------------------
def test_p4e_pushdown_filters_must_not_claim_a_pushdown_that_did_not_happen(
    client, fixture_mode
):
    """AXIS=limit. pushdown_filters is the route's own claim about where filtering ran.

    Filtering applied in the handler over an in-process literal list is not a pushdown.
    Reporting it as one misrepresents where the work happened and what total_count counts.
    """
    _register("tenant-a", "probe-plain-4", "probe-plain-4")
    unlimited = _telemetry(client, "probe-plain-4")["body"]
    limited = _telemetry(client, "probe-plain-4", "?limit=1")["body"]

    if not unlimited.get("observations"):
        pytest.skip("route refused or returned empty: nothing to compare (honest)")

    assert limited["total_count"] >= unlimited["total_count"], (
        "total_count must describe the matching population, not the truncated page"
    )
    assert "limit" not in limited.get("pushdown_filters", {}), (
        "MISREPRESENTATION: pushdown_filters advertises limit="
        f"{limited['pushdown_filters'].get('limit')} but the limit was applied by this "
        "handler to an in-process list; no store received it."
    )
