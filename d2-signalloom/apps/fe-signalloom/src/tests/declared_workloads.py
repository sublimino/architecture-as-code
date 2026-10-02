"""Declared workloads for claim tests, in discovery's contract shape.

Every claim path resolves its target through ``claim_tenancy`` against live
discovery (fake-integration-proxy ``GET /agents``). Claim tests that are about
something else (idempotency, posture seeding, audit, conflicts) declare the
workloads they claim here: a name, the tenant GitOps labelled it with, and the
model it declares. Nothing is permissive by default: an undeclared name is a
404, exactly as against a real cluster.
"""
from __future__ import annotations

from typing import Any

import pytest

import claim_tenancy

NS = "fe-signalloom-agents"


class DeclaredWorkloads:
    def __init__(self) -> None:
        self._items: dict[tuple[str, str], dict[str, Any]] = {}

    def declare(self, name: str, tenant: str | None, *, namespace: str = NS,
                model: str | None = "claude-3-5-sonnet") -> None:
        self._items[(namespace, name)] = {
            "id": name, "name": name, "agent_name": name, "namespace": namespace,
            "tenant": tenant, "model": model,
        }

    def relabel(self, name: str, tenant: str | None, *, namespace: str = NS) -> None:
        """GitOps moved the workload to another tenant; existing claims stay."""
        self._items[(namespace, name)]["tenant"] = tenant

    async def source(self) -> list[dict[str, Any]]:
        return [dict(w) for w in self._items.values()]


def install(monkeypatch: pytest.MonkeyPatch) -> DeclaredWorkloads:
    workloads = DeclaredWorkloads()
    monkeypatch.setattr(claim_tenancy, "workload_source", workloads.source)
    return workloads
