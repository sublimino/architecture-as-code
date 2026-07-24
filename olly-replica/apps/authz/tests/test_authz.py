"""End-to-end checks on the olly-authz control plane. Starts EEMS, PlainID, and
COIN in-process and drives them over HTTP. Runs under pytest or directly:

    python3 tests/test_authz.py

The A2A narrow-only intersection is verified here against Orbit's local grant;
the live hop (Olly -> Orbit re-validation) is covered by the sentinel suite
(olly_sentinel/tests/test_authz_ctx.py).
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from authz import audit, coin, config, eems, httputil, jwtutil, permits, plainid  # noqa: E402

_STARTED = False


def _ensure_started():
    global _STARTED
    if _STARTED:
        return
    try:
        os.remove(config.AUDIT_LOG)
    except OSError:
        pass
    for server in (eems.server(), plainid.server(), coin.server()):
        httputil.serve_in_thread(server)
    time.sleep(0.4)
    _STARTED = True


def _token(obo, actions=None):
    _ensure_started()
    body = {"on_behalf_of": obo, "agent": "olly-sentinel"}
    if actions is not None:
        body["requested_actions"] = actions
    data = json.dumps(body).encode()
    req = urllib.request.Request(f"{config.url(config.COIN_PORT)}/token", data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=6) as resp:
        return json.loads(resp.read())


def test_coin_preserves_username_and_pdp_derives_permissions():
    tok = _token("e12345")
    claims = jwtutil.decode(tok["access_token"], config.JWT_SECRET)
    assert claims["username"] == "e12345"           # human ACME id preserved (OBO)
    assert claims["actor"] == "agent"
    assert tok["decision"] == "PERMIT"
    actions = {p["action"] for p in tok["permitted_actions"]}
    assert "elk.logs.read" in actions               # the MCP read scopes
    assert "restart_service" in actions             # EEMS grants the delegation
    assert "close_incident" not in actions          # EEMS does not


def test_a2a_hop_narrows_only():
    tok = _token("e12345")
    olly = permits.to_map(tok["permitted_actions"])
    narrowed = permits.intersect(tok["permitted_actions"], config.AGENT_LOCAL_GRANTS["orbit"])
    orbit = permits.to_map(narrowed)
    assert olly["restart_service"] == 3             # Olly carries the SRE grant
    assert orbit["restart_service"] == 1            # Orbit narrows it
    assert orbit["restart_service"] <= olly["restart_service"]  # never widens


def test_one_authz_ctx_id_anchors_the_chain():
    tok = _token("e12345")
    records = audit.read_for(tok["authz_ctx_id"])
    assert len(records) >= 1
    assert all(r["authz_ctx_id"] == tok["authz_ctx_id"] for r in records)


def test_deny_when_entitlement_missing():
    tok = _token("e99999", ["restart_service"])     # read-only analyst
    assert tok["decision"] == "DENY"
    assert all(p["action"] != "restart_service" for p in tok["permitted_actions"])


def test_forged_token_rejected():
    forged = jwtutil.encode({"username": "e12345", "authz_ctx_id": "actx-forged",
                             "permitted_actions": [{"action": "restart_service", "limit": 9}]},
                            "wrong-secret")
    try:
        jwtutil.decode(forged, config.JWT_SECRET)
        assert False, "forged token accepted"
    except ValueError:
        pass


def _main():
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in fns:
        fn()
        print(f"ok  {fn.__name__}")
    print(f"\n{len(fns)} passed")


if __name__ == "__main__":
    _main()
