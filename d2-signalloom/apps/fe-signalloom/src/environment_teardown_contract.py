"""Stable boundary between lifecycle orchestration and teardown providers."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Protocol


class TeardownError(Exception):
    """Base exception for all teardown operations."""


class TeardownAuthorizationError(TeardownError):
    """Raised when an operation fails due to authorization/permission denial (e.g. HTTP 403)."""


class TeardownSecurityError(TeardownError):
    """Raised when a security invariant or provider error occurs."""


class AttributionError(TeardownError):
    """Raised when an unowned, non-fixture, or unattributed resource is encountered."""


class DeadlineExceeded(TeardownError):
    """Raised when an operation exceeds its configured deadline."""


class TeardownStage(str, Enum):
    ROUTE = "route"
    MESH = "mesh"
    KEY_SPIRE = "key_spire"
    NAMESPACE_STORAGE = "namespace_storage"


ORDERED_STAGES = (
    TeardownStage.ROUTE,
    TeardownStage.MESH,
    TeardownStage.KEY_SPIRE,
    TeardownStage.NAMESPACE_STORAGE,
)


@dataclass(frozen=True)
class StageRequest:
    customer_hash: str
    teardown_id: str
    deadline: float


@dataclass(frozen=True)
class StageResult:
    stage: TeardownStage
    success: bool
    detail: str = ""
    evidence: dict = field(default_factory=dict)


class StageExecutor(Protocol):
    def execute(self, stage: TeardownStage, request: StageRequest) -> StageResult:
        """Execute one stage synchronously; the lifecycle owner offloads it."""
        ...

    def verify(self, stage: TeardownStage, request: StageRequest) -> StageResult:
        """Verify one stage synchronously without mutating state."""
        ...


__all__ = [
    "AttributionError",
    "DeadlineExceeded",
    "ORDERED_STAGES",
    "StageExecutor",
    "StageRequest",
    "StageResult",
    "TeardownAuthorizationError",
    "TeardownError",
    "TeardownSecurityError",
    "TeardownStage",
]
