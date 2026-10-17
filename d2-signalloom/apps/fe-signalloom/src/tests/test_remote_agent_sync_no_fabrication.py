"""Live mode fabricates nothing: a minimal provider payload (no metadata, no
metrics) must map to absent fields, never to a placeholder value.

These exercise the mappers directly -- no HTTP, no database -- because the
defect lives in the mapping functions themselves (``AnthropicAdapter._agent``,
``._session``, ``._environment`` and ``OpenAIAdapter._session``), not in the
request/response plumbing around them.
"""
from __future__ import annotations

from pathlib import Path

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


# --- Regression guard: these literals must never return to production source ---
#
# Scope is deliberately narrower than "every file in the repo": it is the
# backend's own production modules (``src/*.py`` and the packages under it),
# excluding ``tests/`` -- fixture/test files are free to use arbitrary example
# values (including, in a couple of pre-existing unrelated tests, these exact
# strings as mock input data) and that is not the defect this guards against.
# Demo/fixture mode (``_get_pool() is None``) is a backend-wide behavioural
# gate, not a separate source tree, so it cannot be excluded by path; the
# mapper-level tests above are what prove live mode itself never fabricates.
_SRC_ROOT = Path(__file__).resolve().parent.parent
_EXCLUDED_DIRS = {"tests", "__pycache__", ".pytest_cache"}


def _production_python_files() -> list[Path]:
    out = []
    for path in _SRC_ROOT.rglob("*.py"):
        rel = path.relative_to(_SRC_ROOT)
        if _EXCLUDED_DIRS & set(rel.parts[:-1]):
            continue
        out.append(path)
    return out


def test_fabricated_literals_never_return_to_backend_source():
    offenders: list[str] = []
    for path in _production_python_files():
        text = path.read_text(encoding="utf-8", errors="replace")
        for literal in (*FORBIDDEN_LITERALS, "osramp.acme.local"):
            if literal in text:
                offenders.append(f"{path.relative_to(_SRC_ROOT)}: {literal!r}")
    assert not offenders, "fabricated literal(s) found in backend source:\n  " + "\n  ".join(offenders)
