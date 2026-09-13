"""Attributable operator and platform user lifecycle for Signal Loom.

This module provides the platform user and operator identity endpoints,
re-exporting and integrating the attributable operator identity models,
lifecycle operations, authorization matrix, and tenant scope enforcement.
"""
from __future__ import annotations

from operator_identity import (
    AUTHORIZATION_MATRIX,
    OperatorIdentitiesResponse,
    OperatorIdentityCreateRequest,
    OperatorIdentityRemovalRequest,
    OperatorIdentityResponse,
    OperatorPrincipal,
    OperatorRemovalResponse,
    OperatorSessionResponse,
    create_operator_identity,
    enforce_strict_operator_tenant,
    ensure_active_operator,
    list_operator_identities,
    operator_from_row,
    operator_session,
    remove_operator_identity,
    router,
)

__all__ = [
    "AUTHORIZATION_MATRIX",
    "OperatorIdentitiesResponse",
    "OperatorIdentityCreateRequest",
    "OperatorIdentityRemovalRequest",
    "OperatorIdentityResponse",
    "OperatorPrincipal",
    "OperatorRemovalResponse",
    "OperatorSessionResponse",
    "create_operator_identity",
    "enforce_strict_operator_tenant",
    "ensure_active_operator",
    "list_operator_identities",
    "operator_from_row",
    "operator_session",
    "remove_operator_identity",
    "router",
]
