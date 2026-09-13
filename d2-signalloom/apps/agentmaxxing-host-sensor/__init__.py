"""AgentMaxxing Linux Host Sensor package."""
from __future__ import annotations

import os
import sys

# Ensure directory is on sys.path for direct imports
_CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
if _CURRENT_DIR not in sys.path:
    sys.path.insert(0, _CURRENT_DIR)

try:
    from .file_validator import (
        ArtifactHashResult,
        EligibilityStatus,
        FileIdentitySnapshot,
        PinnedRoot,
        RejectionReason,
        ValidationResult,
        validate_and_hash_artifact,
    )
except (ImportError, ValueError):
    from file_validator import (  # type: ignore[no-redef]
        ArtifactHashResult,
        EligibilityStatus,
        FileIdentitySnapshot,
        PinnedRoot,
        RejectionReason,
        ValidationResult,
        validate_and_hash_artifact,
    )

__all__ = [
    "ArtifactHashResult",
    "EligibilityStatus",
    "FileIdentitySnapshot",
    "PinnedRoot",
    "RejectionReason",
    "ValidationResult",
    "validate_and_hash_artifact",
]
