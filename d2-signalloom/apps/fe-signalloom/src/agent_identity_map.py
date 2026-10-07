"""The single source of truth binding a signalloom.ai/agent-name label value
to the NAMESPACE and ServiceAccount the real agent is registered to run as.

A pod's labels are written by whoever creates it -- including
hosted-daytona-coder, which holds pod-create RBAC in fe-signalloom-agents
(d2-signalloom/infra/agent-swarm/hosted-daytona-coder/rolebinding.yaml) -- so
claim_tenancy.authorize() cannot trust a discovered workload's agent_name
label (sourced from signalloom.ai/agent-name) as proof it is the agent it
claims to be. Both namespace and ServiceAccount are required: a
ServiceAccount name is only unique within its namespace, so a decoy in a
DIFFERENT namespace that names its own ServiceAccount after a registered
agent (e.g. a workload in hosted-daytona-coder's own namespace running as a
ServiceAccount literally called "kusari-agent") must not pass a check that
compares the ServiceAccount name alone.

This module mirrors d2-signalloom/apps/fleet-manager/identity_map.go
exactly: both read the SAME fleet-config ConfigMap
(apps/fleet-manager/base/configmap.yaml), which a ConfigMap volume mount
materialises as one file per `identity.<agent-name>` (ServiceAccount) and
`identity-ns.<agent-name>` (namespace) key. There is exactly one authored
list; extending it to a new agent is two lines in that ConfigMap and needs
no change here, in fleet-manager's Go, or in the ValidatingAdmissionPolicy
sl-agent-identity-binding, defined inline in the fleet's cluster-level
ResourceSet at d2-osramp-fleet/tenants/base/policies.yaml (reconciled by
flux-system -- the tenant ServiceAccount that reconciles fe-signalloom's
own Kustomization has no RBAC to touch cluster-scoped admission policies).
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

DEFAULT_IDENTITY_MAP_DIR = "/etc/fe-signalloom/identity-map"
IDENTITY_KEY_PREFIX = "identity."
IDENTITY_NAMESPACE_KEY_PREFIX = "identity-ns."


@dataclass(frozen=True)
class AgentIdentity:
    namespace: str
    service_account: str


def identity_map_dir() -> str:
    return os.environ.get("AGENT_IDENTITY_MAP_DIR", DEFAULT_IDENTITY_MAP_DIR)


def load(directory: str | None = None) -> dict[str, AgentIdentity]:
    """Reads every identity.<agent-name> / identity-ns.<agent-name> file pair
    in directory into a mapping.

    A missing directory is not an error: it means this deployment mounts no
    identity map, and callers must treat the empty result as "no registered
    mapping" -- permissive, never deny-everything. An agent name with only
    one half of the pair present is dropped entirely, never registered with
    a guessed or empty namespace.
    """
    base = Path(directory if directory is not None else identity_map_dir())
    service_accounts: dict[str, str] = {}
    namespaces: dict[str, str] = {}
    if not base.is_dir():
        return {}
    for entry in sorted(base.iterdir()):
        if not entry.is_file():
            continue
        if entry.name.startswith(IDENTITY_NAMESPACE_KEY_PREFIX):
            agent_name = entry.name[len(IDENTITY_NAMESPACE_KEY_PREFIX):]
            target = namespaces
        elif entry.name.startswith(IDENTITY_KEY_PREFIX):
            agent_name = entry.name[len(IDENTITY_KEY_PREFIX):]
            target = service_accounts
        else:
            continue
        if not agent_name:
            continue
        try:
            value = entry.read_text().strip()
        except OSError:
            continue
        if value:
            target[agent_name] = value

    return {
        name: AgentIdentity(namespace=namespaces[name], service_account=sa)
        for name, sa in service_accounts.items()
        if name in namespaces
    }


def matches(
    mapping: dict[str, AgentIdentity],
    agent_name: str,
    actual_namespace: str | None,
    actual_service_account: str | None,
) -> bool:
    """Whether actual_namespace and actual_service_account are BOTH
    consistent with the registered identity for agent_name.

    An unregistered agent_name (absent from mapping) always matches: this
    guard only ever narrows a spoof of a KNOWN identity, it is never a
    second allow-list for which agents may exist. A ServiceAccount name
    alone is not enough -- it is only unique within its namespace.
    """
    if not agent_name:
        return True
    expected = mapping.get(agent_name)
    if expected is None:
        return True
    return expected.namespace == actual_namespace and expected.service_account == actual_service_account
