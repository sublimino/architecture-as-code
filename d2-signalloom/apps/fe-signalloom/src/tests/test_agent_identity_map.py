"""agent_identity_map mirrors d2-signalloom/apps/fleet-manager/identity_map.go:
both read one identity.<agent-name> file per registered agent from a
ConfigMap volume mount, and the contract -- missing directory is "no
mapping", an unregistered name always matches -- must stay identical on both
sides, since the Go and Python readers consume the same fleet-config
ConfigMap.
"""
from __future__ import annotations

from pathlib import Path

import agent_identity_map


def _write(directory: Path, name: str, content: str) -> None:
    (directory / name).write_text(content)


def test_load_reads_identity_prefixed_files(tmp_path: Path) -> None:
    _write(tmp_path, "fleet.yaml", "agents: []\n")  # must be ignored
    _write(tmp_path, "identity.kusari-agent", "kusari-agent\n")
    _write(tmp_path, "identity.cardvault", "agent-cardvault")

    mapping = agent_identity_map.load(str(tmp_path))

    assert mapping == {"kusari-agent": "kusari-agent", "cardvault": "agent-cardvault"}


def test_load_missing_directory_is_not_an_error(tmp_path: Path) -> None:
    mapping = agent_identity_map.load(str(tmp_path / "does-not-exist"))
    assert mapping == {}


def test_load_ignores_a_bare_identity_file_with_no_suffix(tmp_path: Path) -> None:
    _write(tmp_path, "identity.", "nothing")
    assert agent_identity_map.load(str(tmp_path)) == {}


def test_load_trims_trailing_whitespace_and_skips_empty_values(tmp_path: Path) -> None:
    _write(tmp_path, "identity.empty-agent", "   \n")
    _write(tmp_path, "identity.kusari-agent", "  kusari-agent  \n")
    mapping = agent_identity_map.load(str(tmp_path))
    assert mapping == {"kusari-agent": "kusari-agent"}


def test_matches_rejects_a_spoofed_service_account() -> None:
    mapping = {"kusari-agent": "kusari-agent"}
    assert agent_identity_map.matches(mapping, "kusari-agent", "kusari-agent") is True
    assert agent_identity_map.matches(mapping, "kusari-agent", "hosted-daytona-coder") is False


def test_matches_is_permissive_for_an_unregistered_agent_name() -> None:
    mapping = {"kusari-agent": "kusari-agent"}
    assert agent_identity_map.matches(mapping, "some-unregistered-name", "anything") is True


def test_matches_is_permissive_for_an_empty_agent_name() -> None:
    assert agent_identity_map.matches({}, "", "anything") is True


def test_matches_with_an_empty_mapping_is_permissive() -> None:
    assert agent_identity_map.matches({}, "kusari-agent", "hosted-daytona-coder") is True
