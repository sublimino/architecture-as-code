"""
agentmaxxing-host-sensor package.
Linux host confinement, process telemetry, and bounded artifact hashing.
"""

import sys
from pathlib import Path

_PKG_DIR = str(Path(__file__).resolve().parent)
if _PKG_DIR not in sys.path:
    sys.path.insert(0, _PKG_DIR)

try:
    from .hasher import (
        ArtifactHashResult,
        BoundedArtifactHasher,
        CollectionLimitRecord,
        FileIdentitySnapshot,
        FileOversizeError,
        HasherError,
        InvalidArtifactError,
        RateLimitExceededError,
        TOCTOURaceDetectedError,
    )
    from .openat2 import get_statx_mnt_id, open_beneath, query_statx
    from .ratelimit import RateLimiter
except (ImportError, ValueError):
    from hasher import (
        ArtifactHashResult,
        BoundedArtifactHasher,
        CollectionLimitRecord,
        FileIdentitySnapshot,
        FileOversizeError,
        HasherError,
        InvalidArtifactError,
        RateLimitExceededError,
        TOCTOURaceDetectedError,
    )
    from openat2 import get_statx_mnt_id, open_beneath, query_statx
    from ratelimit import RateLimiter

__all__ = [
    "ArtifactHashResult",
    "BoundedArtifactHasher",
    "CollectionLimitRecord",
    "FileIdentitySnapshot",
    "FileOversizeError",
    "HasherError",
    "InvalidArtifactError",
    "RateLimiter",
    "RateLimitExceededError",
    "TOCTOURaceDetectedError",
    "get_statx_mnt_id",
    "open_beneath",
    "query_statx",
]
