"""
Bounded streaming SHA-256 artifact hasher with post-read identity revalidation (TOCTOU protection).
Operates exclusively on validated open file descriptors beneath pinned root descriptors.
"""

from dataclasses import asdict, dataclass
import errno
import hashlib
import hmac
import os
import stat
import time
from typing import Callable, Dict, Optional, Tuple

try:
    from .openat2 import get_statx_mnt_id, open_beneath, query_statx
    from .ratelimit import RateLimiter
except (ImportError, ValueError):
    from openat2 import get_statx_mnt_id, open_beneath, query_statx
    from ratelimit import RateLimiter


class HasherError(Exception):
    """Base exception for artifact hasher errors."""
    pass


class FileOversizeError(HasherError):
    """Raised when file exceeds the maximum permissible size threshold."""
    pass


class RateLimitExceededError(HasherError):
    """Raised when throughput or file count exceeds sliding window rate limits."""
    pass


class InvalidArtifactError(HasherError):
    """Raised when artifact fails pre-read structural eligibility checks."""
    pass


class TOCTOURaceDetectedError(HasherError):
    """Raised when post-read identity revalidation detects concurrent tampering/replacement."""
    pass


@dataclass(frozen=True)
class FileIdentitySnapshot:
    """Immutable snapshot of filesystem metadata captured before and after reading."""
    ino: int
    dev: int
    mnt_id: int
    nlink: int
    size: int
    mtime_ns: int
    ctime_ns: int
    is_regular: bool


@dataclass
class ArtifactHashResult:
    """Structured allowlisted artifact evidence record."""
    artifact_id: str
    root_id: str
    sha256: Optional[str]
    size_bytes: int
    mtime_ns: int
    observation_state: str  # "observed", "denied", "unobserved"
    integrity_state: str    # "verified", "unverified"
    reason_code: Optional[str] = None
    error_detail: Optional[str] = None

    def to_dict(self) -> Dict[str, object]:
        return {
            "artifact_id": self.artifact_id,
            "root_id": self.root_id,
            "sha256": self.sha256,
            "size_bytes": self.size_bytes,
            "mtime_ns": self.mtime_ns,
            "observation_state": self.observation_state,
            "integrity_state": self.integrity_state,
            "reason_code": self.reason_code,
            "error_detail": self.error_detail,
        }


@dataclass
class CollectionLimitRecord:
    """Structured collection limit telemetry record emitted when caps are hit."""
    reason_code: str
    max_file_size_bytes: int
    max_files_per_window: int
    max_bytes_per_window: int
    window_seconds: float

    def to_dict(self) -> Dict[str, object]:
        return asdict(self)


class BoundedArtifactHasher:
    """
    Streaming SHA-256 artifact hasher enforcing strict boundaries:
      1. Operates solely on open file descriptors (never re-resolving string paths).
      2. Enforces maximum file size limit before and during chunked streaming.
      3. Enforces sliding window throughput and file count rate limits.
      4. Captures pre-read inode, device, mount ID, link count, size, and mutation timestamps.
      5. Streams bytes in bounded 64KB chunks without whole-file buffering.
      6. Re-stats descriptor via fstat/statx post-read and compares with pre-read snapshot.
      7. Rejects and invalidates digest on any mismatch (detecting TOCTOU replacement/truncation/mutation).
    """

    def __init__(
        self,
        rate_limiter: Optional[RateLimiter] = None,
        max_file_size_bytes: int = 16_777_216,  # 16 MiB default (configurable up to 100 MiB)
        chunk_size: int = 65_536,               # 64 KiB chunks
        hmac_key: bytes = b"signal-loom-sensor-v1-artifact-id-key",
    ):
        self.max_file_size_bytes = max_file_size_bytes
        self.chunk_size = chunk_size
        self.hmac_key = hmac_key
        self.rate_limiter = rate_limiter or RateLimiter(
            max_file_size_bytes=max_file_size_bytes
        )

    def compute_artifact_id(self, root_id: str, relpath: str) -> str:
        """
        Derives an opaque HMAC-SHA256 identifier for an artifact under a root ID.
        Ensures raw local filesystem paths are not exported to server timelines.
        """
        h = hmac.new(self.hmac_key, f"{root_id}:{relpath}".encode("utf-8"), hashlib.sha256)
        return f"hmac-sha256:{h.hexdigest()}"

    def snapshot_identity(self, fd: int) -> FileIdentitySnapshot:
        """
        Queries fstat and statx to capture a full identity snapshot of the open descriptor.
        """
        st = os.fstat(fd)
        mnt_id = get_statx_mnt_id(fd)

        # Retrieve high-resolution timestamps
        mtime_ns = getattr(st, "st_mtime_ns", int(st.st_mtime * 1_000_000_000))
        ctime_ns = getattr(st, "st_ctime_ns", int(st.st_ctime * 1_000_000_000))

        return FileIdentitySnapshot(
            ino=st.st_ino,
            dev=st.st_dev,
            mnt_id=mnt_id,
            nlink=st.st_nlink,
            size=st.st_size,
            mtime_ns=mtime_ns,
            ctime_ns=ctime_ns,
            is_regular=stat.S_ISREG(st.st_mode),
        )

    def validate_pre_read(
        self,
        fd: int,
        root_fd: Optional[int] = None,
        now: Optional[float] = None,
    ) -> Tuple[bool, Optional[str], Optional[FileIdentitySnapshot]]:
        """
        Validates candidate descriptor eligibility before reading any bytes:
          - Regular file check (S_ISREG)
          - Exactly 1 hard link (st_nlink == 1)
          - Mount ID matches root descriptor (if root_fd supplied)
          - Size threshold check (st_size <= max_file_size_bytes)
          - Windowed rate limits check
        """
        try:
            snapshot = self.snapshot_identity(fd)
        except OSError as e:
            return False, f"fstat_failed: {e}", None

        if not snapshot.is_regular:
            return False, "not_regular_file", snapshot

        if snapshot.nlink != 1:
            if snapshot.nlink == 0:
                return False, "unlinked_file_forbidden", snapshot
            return False, "hardlink_forbidden", snapshot

        if root_fd is not None:
            try:
                root_mnt_id = get_statx_mnt_id(root_fd)
                if snapshot.mnt_id != root_mnt_id:
                    return False, "cross_mount_forbidden", snapshot
            except OSError as e:
                return False, f"root_stat_failed: {e}", snapshot

        allowed, reason = self.rate_limiter.check_candidate(snapshot.size, now=now)
        if not allowed:
            return False, reason or "rate_limit_exceeded", snapshot

        return True, None, snapshot

    def hash_descriptor(
        self,
        fd: int,
        root_id: str = "agent-work",
        relpath: str = "",
        root_fd: Optional[int] = None,
        read_delay_hook: Optional[Callable[[], None]] = None,
        now: Optional[float] = None,
    ) -> ArtifactHashResult:
        """
        Performs bounded streaming hash over an open file descriptor with post-read
        identity revalidation.

        Returns an allowlisted ArtifactHashResult.
        """
        artifact_id = self.compute_artifact_id(root_id, relpath)

        # 1. Pre-read eligibility check
        valid, pre_reason, pre_snapshot = self.validate_pre_read(fd, root_fd=root_fd, now=now)
        if not valid or pre_snapshot is None:
            size_bytes = pre_snapshot.size if pre_snapshot else 0
            mtime_ns = pre_snapshot.mtime_ns if pre_snapshot else 0
            obs_state = "denied" if pre_reason in ("not_regular_file", "hardlink_forbidden", "cross_mount_forbidden") else "unobserved"
            return ArtifactHashResult(
                artifact_id=artifact_id,
                root_id=root_id,
                sha256=None,
                size_bytes=size_bytes,
                mtime_ns=mtime_ns,
                observation_state=obs_state,
                integrity_state="unverified",
                reason_code=pre_reason,
                error_detail=f"Pre-read validation failed: {pre_reason}",
            )

        # 2. Seek to start of descriptor
        try:
            os.lseek(fd, 0, os.SEEK_SET)
        except OSError as e:
            return ArtifactHashResult(
                artifact_id=artifact_id,
                root_id=root_id,
                sha256=None,
                size_bytes=pre_snapshot.size,
                mtime_ns=pre_snapshot.mtime_ns,
                observation_state="unobserved",
                integrity_state="unverified",
                reason_code="lseek_failed",
                error_detail=str(e),
            )

        # 3. Streaming SHA-256 hash in bounded chunks
        hasher = hashlib.sha256()
        total_bytes_read = 0

        try:
            while True:
                # Optional hook for concurrency race simulation testing
                if read_delay_hook is not None:
                    read_delay_hook()

                chunk = os.read(fd, self.chunk_size)
                if not chunk:
                    break

                total_bytes_read += len(chunk)

                # Guard against runaway streaming / concurrent file expansion exceeding limit
                if total_bytes_read > self.max_file_size_bytes:
                    return ArtifactHashResult(
                        artifact_id=artifact_id,
                        root_id=root_id,
                        sha256=None,
                        size_bytes=total_bytes_read,
                        mtime_ns=pre_snapshot.mtime_ns,
                        observation_state="unobserved",
                        integrity_state="unverified",
                        reason_code="max_file_size_exceeded",
                        error_detail="File exceeded maximum allowed size during streaming",
                    )

                hasher.update(chunk)

        except OSError as e:
            return ArtifactHashResult(
                artifact_id=artifact_id,
                root_id=root_id,
                sha256=None,
                size_bytes=total_bytes_read,
                mtime_ns=pre_snapshot.mtime_ns,
                observation_state="unobserved",
                integrity_state="unverified",
                reason_code="read_error",
                error_detail=str(e),
            )

        # 4. Post-read identity validation (TOCTOU check)
        try:
            post_snapshot = self.snapshot_identity(fd)
        except OSError as e:
            return ArtifactHashResult(
                artifact_id=artifact_id,
                root_id=root_id,
                sha256=None,
                size_bytes=total_bytes_read,
                mtime_ns=pre_snapshot.mtime_ns,
                observation_state="unobserved",
                integrity_state="unverified",
                reason_code="post_fstat_failed",
                error_detail=str(e),
            )

        # Check for TOCTOU discrepancies:
        # A. Inode change (file replaced/rebound)
        if post_snapshot.ino != pre_snapshot.ino:
            return ArtifactHashResult(
                artifact_id=artifact_id,
                root_id=root_id,
                sha256=None,
                size_bytes=post_snapshot.size,
                mtime_ns=post_snapshot.mtime_ns,
                observation_state="unobserved",
                integrity_state="unverified",
                reason_code="toctou_replacement_detected",
                error_detail="File inode changed post-hash",
            )

        # B. Device or Mount ID change
        if post_snapshot.dev != pre_snapshot.dev or post_snapshot.mnt_id != pre_snapshot.mnt_id:
            return ArtifactHashResult(
                artifact_id=artifact_id,
                root_id=root_id,
                sha256=None,
                size_bytes=post_snapshot.size,
                mtime_ns=post_snapshot.mtime_ns,
                observation_state="unobserved",
                integrity_state="unverified",
                reason_code="toctou_mount_change_detected",
                error_detail="File device or mount ID changed post-hash",
            )

        # C. Link count change (unlinked st_nlink == 0 or hard-linked st_nlink > 1)
        if post_snapshot.nlink != 1:
            return ArtifactHashResult(
                artifact_id=artifact_id,
                root_id=root_id,
                sha256=None,
                size_bytes=post_snapshot.size,
                mtime_ns=post_snapshot.mtime_ns,
                observation_state="unobserved",
                integrity_state="unverified",
                reason_code="toctou_link_tamper_detected",
                error_detail=f"File hardlink count changed post-hash (nlink={post_snapshot.nlink})",
            )

        # D. Size mismatch (bytes read != pre_snapshot size or != post_snapshot size)
        if total_bytes_read != pre_snapshot.size or post_snapshot.size != pre_snapshot.size:
            reason = "toctou_truncation_detected" if total_bytes_read < pre_snapshot.size else "toctou_append_detected"
            return ArtifactHashResult(
                artifact_id=artifact_id,
                root_id=root_id,
                sha256=None,
                size_bytes=post_snapshot.size,
                mtime_ns=post_snapshot.mtime_ns,
                observation_state="unobserved",
                integrity_state="unverified",
                reason_code=reason,
                error_detail=f"File size mutated during hash: pre={pre_snapshot.size}, read={total_bytes_read}, post={post_snapshot.size}",
            )

        # E. Modification timestamp mutation
        if post_snapshot.mtime_ns != pre_snapshot.mtime_ns:
            return ArtifactHashResult(
                artifact_id=artifact_id,
                root_id=root_id,
                sha256=None,
                size_bytes=post_snapshot.size,
                mtime_ns=post_snapshot.mtime_ns,
                observation_state="unobserved",
                integrity_state="unverified",
                reason_code="toctou_mutation_detected",
                error_detail=f"File mtime changed post-hash: pre={pre_snapshot.mtime_ns}, post={post_snapshot.mtime_ns}",
            )

        # F. Change timestamp mutation (metadata / attribute change)
        if post_snapshot.ctime_ns != pre_snapshot.ctime_ns:
            return ArtifactHashResult(
                artifact_id=artifact_id,
                root_id=root_id,
                sha256=None,
                size_bytes=post_snapshot.size,
                mtime_ns=post_snapshot.mtime_ns,
                observation_state="unobserved",
                integrity_state="unverified",
                reason_code="toctou_metadata_tamper_detected",
                error_detail=f"File ctime changed post-hash: pre={pre_snapshot.ctime_ns}, post={post_snapshot.ctime_ns}",
            )

        # 5. Commit consumption to rate limiter
        self.rate_limiter.record_consumption(total_bytes_read, now=now)

        # 6. Verified success
        return ArtifactHashResult(
            artifact_id=artifact_id,
            root_id=root_id,
            sha256=hasher.hexdigest(),
            size_bytes=total_bytes_read,
            mtime_ns=post_snapshot.mtime_ns,
            observation_state="observed",
            integrity_state="verified",
            reason_code=None,
            error_detail=None,
        )

    def hash_relative_path(
        self,
        root_dir_path: str,
        relpath: str,
        root_id: str = "agent-work",
        read_delay_hook: Optional[Callable[[], None]] = None,
        now: Optional[float] = None,
    ) -> ArtifactHashResult:
        """
        Opens root directory descriptor, opens candidate descriptor relative using
        openat2 with RESOLVE_BENEATH, and delegates to hash_descriptor.
        """
        artifact_id = self.compute_artifact_id(root_id, relpath)

        try:
            root_fd = os.open(root_dir_path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        except OSError as e:
            return ArtifactHashResult(
                artifact_id=artifact_id,
                root_id=root_id,
                sha256=None,
                size_bytes=0,
                mtime_ns=0,
                observation_state="unobserved",
                integrity_state="unverified",
                reason_code="root_open_failed",
                error_detail=str(e),
            )

        try:
            try:
                candidate_fd = open_beneath(root_fd, relpath, flags=os.O_RDONLY | os.O_CLOEXEC)
            except OSError as e:
                # Detect symlink or boundary escape
                return ArtifactHashResult(
                    artifact_id=artifact_id,
                    root_id=root_id,
                    sha256=None,
                    size_bytes=0,
                    mtime_ns=0,
                    observation_state="denied" if e.errno in (errno.EXDEV, errno.ELOOP, errno.EACCES, errno.ENOENT, errno.EPERM) else "unobserved",
                    integrity_state="unverified",
                    reason_code="openat2_escape_rejected",
                    error_detail=f"openat2 failed: {e}",
                )

            try:
                return self.hash_descriptor(
                    fd=candidate_fd,
                    root_id=root_id,
                    relpath=relpath,
                    root_fd=root_fd,
                    read_delay_hook=read_delay_hook,
                    now=now,
                )
            finally:
                os.close(candidate_fd)
        finally:
            os.close(root_fd)
