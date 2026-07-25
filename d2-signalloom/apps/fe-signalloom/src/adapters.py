"""Environment-selected integration adapter registries for the demo."""
from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from typing import Mapping

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class AdapterSelection:
    category: str
    backend: str
    enabled: bool


@dataclass(frozen=True)
class AdapterRegistry:
    category: str
    variable: str
    default: str
    backends: frozenset[str]
    required: bool = False

    def select(self, environment: Mapping[str, str] | None = None) -> AdapterSelection:
        environment = environment or os.environ
        backend = environment.get(self.variable, self.default).strip().lower()
        if backend == "disabled":
            if self.required:
                raise ValueError(f"{self.category} backend cannot be disabled")
            return AdapterSelection(self.category, backend, False)
        if backend not in self.backends:
            raise ValueError(f"unknown {self.category} backend: {backend}")
        return AdapterSelection(self.category, backend, True)


REGISTRIES = (
    AdapterRegistry("LLM discovery", "LLM_DISCOVERY_BACKEND", "fake-openai", frozenset({"fake-openai", "azure-foundry", "aws-bedrock"}), required=True),
    AdapterRegistry("CRM", "CRM_BACKEND", "fake-hubspot", frozenset({"fake-hubspot", "hubspot", "disabled"})),
    AdapterRegistry("notification", "NOTIFICATION_BACKEND", "fake-slack", frozenset({"fake-slack", "webhook", "disabled"})),
    AdapterRegistry("outbound reporting", "OUTBOUND_REPORTING_BACKEND", "fake-email", frozenset({"fake-email", "email", "disabled"})),
)


def load_adapter_selections(environment: Mapping[str, str] | None = None) -> dict[str, AdapterSelection]:
    """Validate all configured adapter names and emit startup-safe visibility."""
    selections = {registry.category: registry.select(environment) for registry in REGISTRIES}
    for selection in selections.values():
        state = "enabled" if selection.enabled else "disabled"
        logger.info("discovery portal adapter: category=%s backend=%s state=%s", selection.category, selection.backend, state)
    return selections
