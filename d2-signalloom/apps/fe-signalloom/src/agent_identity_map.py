"""The single source of truth binding a signalloom.ai/agent-name label value
to the ServiceAccount the real agent is registered to run as.

A pod's labels are written by whoever creates it -- including
hosted-daytona-coder, which holds pod-create RBAC in fe-signalloom-agents
(d2-signalloom/infra/agent-swarm/hosted-daytona-coder/rolebinding.yaml) -- so
claim_tenancy.authorize() cannot trust a discovered workload's agent_name
label (sourced from signalloom.ai/agent-name) as proof it is the agent it
claims to be. This module mirrors
d2-signalloom/apps/fleet-manager/identity_map.go exactly: both read the SAME
fleet-config ConfigMap (apps/fleet-manager/base/configmap.yaml), which a
ConfigMap volume mount materialises as one file per `identity.<agent-name>`
key. There is exactly one authored list; extending it to a new agent is one
line in that ConfigMap and needs no change here, in fleet-manager's Go, or
in the ValidatingAdmissionPolicy at
d2-signalloom/apps/fleet-manager/base/agent-identity-binding.yaml.
"""
from __future__ import annotations

import os
from pathlib import Path

DEFAULT_IDENTITY_MAP_DIR = "/etc/fe-signalloom/identity-map"
IDENTITY_KEY_PREFIX = "identity."


def identity_map_dir() -> str:
    return os.environ.get("AGENT_IDENTITY_MAP_DIR", DEFAULT_IDENTITY_MAP_DIR)


def load(directory: str | None = None) -> dict[str, str]:
    """Reads every identity.<agent-name> file in directory into a mapping.

    A missing directory is not an error: it means this deployment mounts no
    identity map, and callers must treat the empty result as "no registered
    mapping" -- permissive, never deny-everything.
    """
    base = Path(directory if directory is not None else identity_map_dir())
    mapping: dict[str, str] = {}
    if not base.is_dir():
        return mapping
    for entry in sorted(base.iterdir()):
        if not entry.is_file() or not entry.name.startswith(IDENTITY_KEY_PREFIX):
            continue
        agent_name = entry.name[len(IDENTITY_KEY_PREFIX):]
        if not agent_name:
            continue
        try:
            value = entry.read_text().strip()
        except OSError:
            continue
        if value:
            mapping[agent_name] = value
    return mapping


def matches(mapping: dict[str, str], agent_name: str, actual_service_account: str | None) -> bool:
    """Whether actual_service_account is consistent with the registered
    identity for agent_name.

    An unregistered agent_name (absent from mapping) always matches: this
    guard only ever narrows a spoof of a KNOWN identity, it is never a
    second allow-list for which agents may exist.
    """
    if not agent_name:
        return True
    expected = mapping.get(agent_name)
    if expected is None:
        return True
    return expected == actual_service_account
