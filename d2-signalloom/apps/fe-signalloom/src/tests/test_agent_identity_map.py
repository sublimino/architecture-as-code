"""agent_identity_map mirrors d2-signalloom/apps/fleet-manager/identity_map.go:
both read one identity.<agent-name> (ServiceAccount) and
identity-ns.<agent-name> (namespace) file pair per registered agent from a
ConfigMap volume mount, and the contract -- missing directory is "no
mapping", an unregistered name always matches, a half-authored pair is
dropped, namespace AND ServiceAccount must both match -- must stay
identical on both sides, since the Go and Python readers consume the same
fleet-config ConfigMap.
"""
from __future__ import annotations

from pathlib import Path

import agent_identity_map
from agent_identity_map import AgentIdentity


def _write(directory: Path, name: str, content: str) -> None:
    (directory / name).write_text(content)


def test_load_reads_identity_prefixed_file_pairs(tmp_path: Path) -> None:
    _write(tmp_path, "fleet.yaml", "agents: []\n")  # must be ignored
    _write(tmp_path, "identity.kusari-agent", "kusari-agent\n")
    _write(tmp_path, "identity-ns.kusari-agent", "fe-signalloom-agents\n")
    _write(tmp_path, "identity.cardvault", "agent-cardvault")
    _write(tmp_path, "identity-ns.cardvault", "fe-signalloom-agents")

    mapping = agent_identity_map.load(str(tmp_path))

    assert mapping == {
        "kusari-agent": AgentIdentity(namespace="fe-signalloom-agents", service_account="kusari-agent"),
        "cardvault": AgentIdentity(namespace="fe-signalloom-agents", service_account="agent-cardvault"),
    }


def test_load_drops_an_agent_with_only_one_half_of_the_pair(tmp_path: Path) -> None:
    _write(tmp_path, "identity.sa-only", "some-sa")
    # no identity-ns.sa-only
    _write(tmp_path, "identity-ns.ns-only", "some-ns")
    # no identity.ns-only

    mapping = agent_identity_map.load(str(tmp_path))

    assert mapping == {}


def test_load_missing_directory_is_not_an_error(tmp_path: Path) -> None:
    mapping = agent_identity_map.load(str(tmp_path / "does-not-exist"))
    assert mapping == {}


def test_load_ignores_a_bare_identity_file_with_no_suffix(tmp_path: Path) -> None:
    _write(tmp_path, "identity.", "nothing")
    _write(tmp_path, "identity-ns.", "nothing")
    assert agent_identity_map.load(str(tmp_path)) == {}


def test_load_trims_trailing_whitespace_and_skips_empty_values(tmp_path: Path) -> None:
    _write(tmp_path, "identity.empty-agent", "   \n")
    _write(tmp_path, "identity-ns.empty-agent", "fe-signalloom-agents")
    _write(tmp_path, "identity.kusari-agent", "  kusari-agent  \n")
    _write(tmp_path, "identity-ns.kusari-agent", "  fe-signalloom-agents  \n")
    mapping = agent_identity_map.load(str(tmp_path))
    assert mapping == {"kusari-agent": AgentIdentity(namespace="fe-signalloom-agents", service_account="kusari-agent")}


def test_matches_rejects_a_spoofed_service_account() -> None:
    mapping = {"kusari-agent": AgentIdentity(namespace="fe-signalloom-agents", service_account="kusari-agent")}
    assert agent_identity_map.matches(mapping, "kusari-agent", "fe-signalloom-agents", "kusari-agent") is True
    assert agent_identity_map.matches(mapping, "kusari-agent", "fe-signalloom-agents", "hosted-daytona-coder") is False


def test_matches_rejects_the_right_service_account_name_in_the_wrong_namespace() -> None:
    # A ServiceAccount name is only unique within its namespace. A decoy in
    # hosted-daytona-coder's own namespace naming its ServiceAccount
    # "kusari-agent" must not pass a check that compares the SA name alone.
    mapping = {"kusari-agent": AgentIdentity(namespace="fe-signalloom-agents", service_account="kusari-agent")}
    assert agent_identity_map.matches(mapping, "kusari-agent", "hosted-daytona-coder-workspace", "kusari-agent") is False


def test_matches_is_permissive_for_an_unregistered_agent_name() -> None:
    mapping = {"kusari-agent": AgentIdentity(namespace="fe-signalloom-agents", service_account="kusari-agent")}
    assert agent_identity_map.matches(mapping, "some-unregistered-name", "anywhere", "anything") is True


def test_matches_is_permissive_for_an_empty_agent_name() -> None:
    assert agent_identity_map.matches({}, "", "anywhere", "anything") is True


def test_matches_with_an_empty_mapping_is_permissive() -> None:
    assert agent_identity_map.matches({}, "kusari-agent", "hosted-daytona-coder-workspace", "hosted-daytona-coder") is True
