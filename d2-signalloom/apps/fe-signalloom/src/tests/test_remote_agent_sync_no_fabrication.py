"""Live mode fabricates nothing: a minimal provider payload (no metadata, no
metrics) must map to absent fields, never to a placeholder value.

These exercise the mappers directly -- no HTTP, no database -- because the
defect lives in the mapping functions themselves (``AnthropicAdapter._agent``,
``._session``, ``._environment`` and ``OpenAIAdapter._session``), not in the
request/response plumbing around them.
"""
from __future__ import annotations

import remote_agent_sync as ras

# These exact strings were hardcoded into live output by 163b1b60c. None of
# them may ever appear in a mapped RemoteItem again, from any payload shape.
FORBIDDEN_LITERALS = (
    "1f9b3065-9e10-42e5-b2ac-e8f37a186b88",  # fabricated org_id
    "wrkspc_01PFJfZsJrq5bUVWA2wWnyvm",        # fabricated workspace_id fallback
    "Andrew Martin (User)",                    # fabricated owner
)


def _assert_no_forbidden(value: object) -> None:
    blob = repr(value)
    for literal in FORBIDDEN_LITERALS:
        assert literal not in blob, f"fabricated literal {literal!r} leaked into {value!r}"


def test_anthropic_agent_minimal_payload_invents_nothing():
    item = ras.AnthropicAdapter()._agent({"id": "agent_1", "type": "agent"}, creds={})
    assert item.user_metadata == {}
    assert item.metrics == {}
    _assert_no_forbidden(item.user_metadata)


def test_anthropic_session_minimal_payload_invents_nothing():
    item = ras.AnthropicAdapter()._session({"id": "sess_1", "type": "session"}, creds={})
    assert item.user_metadata == {}
    assert item.metrics == {}
    _assert_no_forbidden(item.user_metadata)
    _assert_no_forbidden(item.metrics)


def test_anthropic_environment_minimal_payload_invents_no_name_or_network():
    item = ras.AnthropicAdapter()._environment({"id": "env_1", "type": "environment"}, creds={})
    assert item.name is None
    assert item.environment_config.get("network") == "unknown"
    _assert_no_forbidden(item.user_metadata)
    _assert_no_forbidden(item.environment_config)


def test_anthropic_workspace_id_comes_only_from_creds_or_payload():
    adapter = ras.AnthropicAdapter()

    neither = adapter._agent({"id": "agent_1"}, creds={})
    assert "workspace_id" not in neither.user_metadata

    from_creds = adapter._agent({"id": "agent_1"}, creds={"workspace_id": "wrkspc_real_from_creds"})
    assert from_creds.user_metadata["workspace_id"] == "wrkspc_real_from_creds"

    from_payload = adapter._agent({"id": "agent_1", "workspace_id": "wrkspc_real_from_payload"}, creds={})
    assert from_payload.user_metadata["workspace_id"] == "wrkspc_real_from_payload"


def test_openai_session_minimal_payload_invents_nothing():
    item = ras.OpenAIAdapter()._session({"id": "sess_1"})
    assert item.user_metadata == {}
    assert item.metrics == {}


def test_anthropic_environment_reads_network_from_config_networking():
    adapter = ras.AnthropicAdapter()
    payload = {
        "id": "env_1",
        "config": {
            "networking": {
                "type": "limited",
                "allowed_hosts": ["pypi.org"],
                "allow_mcp_servers": False,
                "allow_package_managers": True,
            },
            "packages": {"apt": ["gcc"], "pip": ["requests"]},
        },
    }
    item = adapter._environment(payload, creds={})
    assert item.environment_config["network"] == "limited"
    assert item.environment_config["allowed_hosts"] == ["pypi.org"]
    assert item.environment_config["allow_mcp_servers"] is False
    assert item.environment_config["allow_package_managers"] is True
    assert item.environment_config["packages"] == {"apt": ["gcc"], "pip": ["requests"]}
