"""The AgentCard is a contract: skills, auth, and capabilities are the
deterministic categorization surface peers and ARC consume. These
assertions pin the committed JSON; the served-card equivalence is asserted
in test_a2a_app (and again in-cluster by the bats suite)."""

from olly_sentinel import contracts


def committed() -> dict:
    return contracts.load(contracts.AGENT_CARD)


def test_card_identity_and_skills():
    card = committed()
    assert card["name"] == "olly-sentinel"
    assert card["version"]
    assert [s["id"] for s in card["skills"]] == ["triage_enrich_incident"]
    skill = card["skills"][0]
    assert "read-only" in skill["tags"]
    assert skill["examples"], "skill must carry an invocation example"


def test_card_declares_eems_auth_and_capabilities():
    card = committed()
    # Auth declaration: EEMS bearer (the entitlement view), read-only scopes.
    assert card["securitySchemes"]["eems"]["scheme"] == "bearer"
    # COIN M2M is the machine identity Olly presents on every read: an oauth2
    # client-credentials scheme whose token also carries across the A2A hop.
    coin = card["securitySchemes"]["coin_m2m"]
    assert coin["type"] == "oauth2"
    scopes = coin["flows"]["clientCredentials"]["scopes"]
    assert "elk.logs.read" in scopes and "troubleshoot" in scopes
    # A call presents the COIN M2M token and satisfies the EEMS read entitlement.
    assert card["security"] == [
        {"coin_m2m": ["elk.logs.read", "troubleshoot"], "eems": ["elk.logs.read"]}
    ]
    # Capabilities are explicit, not implied.
    assert card["capabilities"]["streaming"] is False
    assert card["capabilities"]["pushNotifications"] is False


def committed_orbit() -> dict:
    return contracts.load(contracts.ORBIT_AGENT_CARD)


def test_orbit_card_identity_and_action_skill():
    card = committed_orbit()
    assert card["name"] == "orbit"
    assert [s["id"] for s in card["skills"]] == ["propose_action"]
    skill = card["skills"][0]
    assert "hitl" in skill["tags"] and "approval" in skill["tags"]
    assert skill["examples"], "skill must carry an invocation example"


def test_orbit_card_declares_approval_scheme():
    card = committed_orbit()
    # Orbit adds a signed-approval scheme alongside the EEMS bearer.
    assert card["securitySchemes"]["approval_jwt"]["scheme"] == "bearer"
    assert "EdDSA" in card["securitySchemes"]["approval_jwt"]["description"]
    # Orbit itself is read-only; the executor holds the write identity.
    assert card["securitySchemes"]["eems"]["scheme"] == "bearer"
    # The AuthZ-CTX Orbit enforces on the A2A hop: a header-carried apiKey the
    # middleware re-validates and narrows (never widens) before proposing.
    authz = card["securitySchemes"]["authz_ctx"]
    assert authz["type"] == "apiKey"
    assert authz["in"] == "header"
    assert authz["name"] == "X-AuthZ-CTX"
