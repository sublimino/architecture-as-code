"""The Federated Services screen must show measured federation state in live mode.

Before this file, GET /v1/federation/* was answered by the reverse proxy, which
forwarded to signal-ingest; signal-ingest registers no /api/v1/federation
handler, so api/auth.go default-denied with 403 {"error":"unregistered_route"}
and the proxy translated that to 502 upstream_route_not_served. That is honest
but empty: the screen had nothing to show in live mode, which is what Andy's
"we should have a REAL federation screen, ensure it's live when we click live"
is about.

The invariant these tests pin, in both directions:

  * a field that CAN be derived from an input must move when that input moves
    (so it cannot be a constant), and
  * a field that CANNOT be derived must be absent and named in a refusal, never
    replaced by a better-chosen constant.

The refusal vocabulary is the existing non-money one (``evidence_state`` /
``assurance`` / ``freshness`` / ``reason``, as used by ``_derived_topology``);
no third vocabulary is introduced.
"""
from __future__ import annotations

import httpx
import pytest
import respx
from httpx import ASGITransport, AsyncClient

from conftest import EAP_ALICE, EAP_BOB, eap_bearer
from main import app

EAP_AUTHENTICATED = True

READ_SUBPATHS = (
    "summary",
    "zones",
    "federations",
    "services",
    "policies",
    "identities",
    "events",
)

#: Two collector payloads that differ only in the observed workloads. Any field
#: derived from the collector must differ between the two; a field that does not
#: is not a function of its input.
def _topology(nodes: list[dict]) -> dict:
    return {
        "generated_at": "2026-10-12T00:00:00Z",
        "version": "v1",
        "collectors": {
            "kubernetes": {
                "status": "ok",
                "observed_at": "2026-10-12T00:00:00Z",
                "reason": "",
            }
        },
        "nodes": nodes,
        "edges": [],
        "modeled_gaps": [],
    }


def _node(node_id: str, spiffe_id: str, *, tenant: str, ns: str, sa: str) -> dict:
    return {
        "id": node_id,
        "kind": "agent",
        "label": node_id,
        "tenant": tenant,
        "namespace": ns,
        "service_account": sa,
        "spiffe_id": spiffe_id,
        "location": "in-cluster",
        "evidence_state": "observed",
        "evidence_source": "kubernetes collector",
        "observed_at": "2026-10-12T00:00:00Z",
        "freshness": "fresh",
        "assurance": "observed",
        "reason": "pod observed in-cluster",
    }


TOPOLOGY_URL = "http://fake-integration-proxy.inf-signalloom.svc.cluster.local:8080/trust-topology"


async def _get(subpath: str, actor, *, topology: dict | None = None) -> httpx.Response:
    with respx.mock(assert_all_called=False) as mock:
        # signal-ingest serves no federation route; that is the production shape.
        mock.get(url__startswith="http://signal-ingest:8082/api/v1/federation").mock(
            return_value=httpx.Response(403, json={"error": "unregistered_route"})
        )
        if topology is None:
            mock.get(TOPOLOGY_URL).mock(side_effect=httpx.ConnectError("collector down"))
        else:
            mock.get(TOPOLOGY_URL).mock(return_value=httpx.Response(200, json=topology))
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            return await client.get(f"/v1/federation/{subpath}", headers=eap_bearer(actor))


@pytest.mark.asyncio
@pytest.mark.parametrize("subpath", READ_SUBPATHS)
async def test_federation_read_routes_are_served_locally_not_refused(subpath):
    """Live mode must get an answer, not 502 upstream_route_not_served."""
    resp = await _get(subpath, EAP_ALICE, topology=_topology([]))
    assert resp.status_code == 200, (
        f"/{subpath} answered {resp.status_code}: {resp.text[:300]}. The federation "
        "read routes are derived locally; forwarding them to an upstream that does "
        "not serve them leaves the live screen with nothing at all."
    )


@pytest.mark.asyncio
async def test_federation_zones_and_identities_track_the_collector_input():
    """Measured panels are a function of what the collector observed."""
    one = _topology([
        _node("alpha", "spiffe://osramp.local/ns/tenant-a/sa/alpha",
              tenant="tenant-a", ns="tenant-a", sa="alpha"),
    ])
    two = _topology([
        _node("alpha", "spiffe://osramp.local/ns/tenant-a/sa/alpha",
              tenant="tenant-a", ns="tenant-a", sa="alpha"),
        _node("beta", "spiffe://signalloom.hub/ns/tenant-a/sa/beta",
              tenant="tenant-a", ns="tenant-a", sa="beta"),
    ])

    a = (await _get("summary", EAP_ALICE, topology=one)).json()
    b = (await _get("summary", EAP_ALICE, topology=two)).json()

    a_domains = sorted(z["domain"] for z in a["zones"]["items"])
    b_domains = sorted(z["domain"] for z in b["zones"]["items"])
    assert a_domains == ["osramp.local"], a_domains
    assert b_domains == ["osramp.local", "signalloom.hub"], b_domains
    assert a["counts"]["trust_zones"] == 1
    assert b["counts"]["trust_zones"] == 2
    assert a["counts"]["spiffe_identities"] == 1
    assert b["counts"]["spiffe_identities"] == 2


@pytest.mark.asyncio
async def test_federation_zone_unmeasurable_fields_are_refused_per_field():
    """clusters / servers / status are not collected: absent, and named with a reason."""
    payload = (await _get(
        "zones",
        EAP_ALICE,
        topology=_topology([
            _node("alpha", "spiffe://osramp.local/ns/tenant-a/sa/alpha",
                  tenant="tenant-a", ns="tenant-a", sa="alpha"),
        ]),
    )).json()
    assert payload["available"] is True
    zone = payload["items"][0]
    for field in ("clusters", "servers", "status"):
        assert zone.get(field) is None, (
            f"zones[].{field} is not derivable from any source this service reads; "
            f"emitting {zone.get(field)!r} would be a fabrication"
        )
    refused = {r["field"]: r["reason"] for r in payload["unmeasured_fields"]}
    for field in ("clusters", "servers", "status"):
        assert field in refused, f"zones[].{field} absent but not refused: {refused}"
        assert len(refused[field]) > 20, f"refusal for {field} names no cause"


@pytest.mark.asyncio
@pytest.mark.parametrize("subpath", ["federations", "services", "policies", "events"])
async def test_federation_wholly_unmeasurable_panels_refuse_rather_than_fill(subpath):
    """No source exists for these panels: available=false with a reason, never rows."""
    payload = (await _get(subpath, EAP_ALICE, topology=_topology([]))).json()
    assert payload["available"] is False, f"/{subpath} claims availability it has no source for"
    assert payload["items"] == [], f"/{subpath} emitted rows with no source: {payload['items'][:2]}"
    assert payload["evidence_state"] == "unavailable"
    assert payload["freshness"] == "unavailable"
    assert len(payload["reason"]) > 40, f"/{subpath} refuses without naming the missing source"


@pytest.mark.asyncio
async def test_federation_identity_svid_and_expiry_are_refused():
    """The portal never handles a workload SVID, so its type and expiry are unknown."""
    payload = (await _get(
        "identities",
        EAP_ALICE,
        topology=_topology([
            _node("alpha", "spiffe://osramp.local/ns/tenant-a/sa/alpha",
                  tenant="tenant-a", ns="tenant-a", sa="alpha"),
        ]),
    )).json()
    item = payload["items"][0]
    assert item["uri"] == "spiffe://osramp.local/ns/tenant-a/sa/alpha"
    assert item["ns"] == "tenant-a"
    assert item["sa"] == "alpha"
    assert item.get("svid") is None
    assert item.get("expiry") is None
    refused = {r["field"] for r in payload["unmeasured_fields"]}
    assert {"svid", "expiry"} <= refused, refused


@pytest.mark.asyncio
async def test_federation_summary_emits_no_attestation_rate_and_no_alert_count():
    """The two headline figures of the deleted dataset had no source and still have none."""
    payload = (await _get("summary", EAP_ALICE, topology=_topology([]))).json()
    body = (await _get("summary", EAP_ALICE, topology=_topology([]))).text
    assert "99.8" not in body
    assert payload["counts"].get("attestation_success_rate") is None
    assert payload["counts"].get("active_alerts") is None
    refused = {r["field"] for r in payload["unmeasured_fields"]}
    assert {"attestation_success_rate", "active_alerts"} <= refused, refused


@pytest.mark.asyncio
async def test_federation_collector_down_is_labelled_modeled_not_observed():
    """Unreachable collector: still an answer, every item modeled, reason carried."""
    payload = (await _get("summary", EAP_ALICE, topology=None)).json()
    assert payload["collectors"]["kubernetes"]["status"] == "unavailable"
    assert payload["collectors"]["kubernetes"]["reason"]
    for panel in ("zones", "identities"):
        section = payload[panel]
        if section["items"]:
            assert section["evidence_state"] == "modeled", (
                f"{panel} claims observed evidence while the collector is unreachable"
            )
            assert section["freshness"] == "unavailable"


@pytest.mark.asyncio
async def test_federation_measured_rows_move_with_the_authenticated_tenant():
    """W9's perturbation, kept: identical 200 bodies across tenants means a literal."""
    topology = _topology([
        _node("alpha", "spiffe://osramp.local/ns/tenant-a/sa/alpha",
              tenant="tenant-a", ns="tenant-a", sa="alpha"),
        _node("beta", "spiffe://signalloom.hub/ns/tenant-b/sa/beta",
              tenant="tenant-b", ns="tenant-b", sa="beta"),
    ])
    alice = (await _get("identities", EAP_ALICE, topology=topology)).json()
    bob = (await _get("identities", EAP_BOB, topology=topology)).json()
    alice_uris = {i["uri"] for i in alice["items"]}
    bob_uris = {i["uri"] for i in bob["items"]}
    assert "spiffe://osramp.local/ns/tenant-a/sa/alpha" in alice_uris
    assert "spiffe://signalloom.hub/ns/tenant-b/sa/beta" not in alice_uris, (
        "tenant-a sees tenant-b's SPIFFE identity"
    )
    assert alice_uris != bob_uris, "identity rows do not move with the tenant"


@pytest.mark.asyncio
async def test_federation_write_methods_still_proxy_upstream():
    """Only the seven read subpaths are local. Everything else keeps the proxy's answer."""
    with respx.mock(assert_all_called=False) as mock:
        route = mock.post("http://signal-ingest:8082/api/v1/federation/zones").mock(
            return_value=httpx.Response(201, json={"created": True})
        )
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.post(
                "/v1/federation/zones",
                headers={**eap_bearer(EAP_ALICE), "Content-Type": "application/json"},
                content=b"{}",
            )
    assert route.called, "a federation write must still reach signal-ingest"
    assert resp.status_code == 201


@pytest.mark.asyncio
async def test_federation_unknown_read_subpath_still_refuses_upstream_route():
    """A subpath with no local derivation keeps the honest upstream refusal."""
    resp = await _get("bundles", EAP_ALICE, topology=_topology([]))
    assert resp.status_code == 502
    assert resp.json()["code"] == "upstream_route_not_served"
