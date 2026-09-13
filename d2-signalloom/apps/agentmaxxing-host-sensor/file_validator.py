"""Descriptor-relative artifact eligibility validator and secure hasher.

Enforces kernel-level path resolution constraints using openat2() with:
- RESOLVE_BENEATH: Prevents escaping the pinned root directory.
- RESOLVE_NO_SYMLINKS: Forbids resolving any symbolic link component.
- RESOLVE_NO_XDEV: Disallows crossing mount points during path resolution.

Before reading any bytes, validates:
1. File descriptor refers to a regular file (S_ISREG).
2. Hard link count is exactly 1 (st_nlink == 1).
3. Mount ID matches the pinned root mount ID (statx STATX_MNT_ID).
4. File size does not exceed configured limits (max 16 MiB).

Post-read revalidation verifies that inode, mount ID, link count, size,
mtime, and ctime remained unchanged during the read.
"""
from __future__ import annotations

import ctypes
import dataclasses
import enum
import errno
import hashlib
import os
import platform
import stat
import sys
from typing import Callable, Optional, Sequence, Tuple

# Linux Syscall Constants
_NR_OPENAT2_MAP = {
    "x86_64": 437,
    "aarch64": 437,
    "arm64": 437,
    "i386": 437,
    "i686": 437,
}

_NR_STATX_MAP = {
    "x86_64": 332,
    "aarch64": 291,
    "arm64": 291,
    "i386": 383,
    "i686": 383,
}

# openat2 resolve flags
RESOLVE_NO_XDEV = 0x01
RESOLVE_NO_MAGICLINKS = 0x02
RESOLVE_NO_SYMLINKS = 0x04
RESOLVE_BENEATH = 0x08
RESOLVE_IN_ROOT = 0x10
RESOLVE_CACHED = 0x20

# statx constants
AT_EMPTY_PATH = 0x1000
AT_SYMLINK_NOFOLLOW = 0x100
STATX_BASIC_STATS = 0x07FF
STATX_MNT_ID = 0x1000

# Default limits
DEFAULT_MAX_FILE_SIZE_BYTES = 16 * 1024 * 1024  # 16 MiB
READ_CHUNK_SIZE = 64 * 1024  # 64 KiB


class _OpenHow(ctypes.Structure):
    _fields_ = [
        ("flags", ctypes.c_uint64),
        ("mode", ctypes.c_uint64),
        ("resolve", ctypes.c_uint64),
    ]


class _StatxTimestamp(ctypes.Structure):
    _fields_ = [
        ("tv_sec", ctypes.c_int64),
        ("tv_nsec", ctypes.c_uint32),
        ("__reserved", ctypes.c_int32),
    ]


class _Statx(ctypes.Structure):
    _fields_ = [
        ("stx_mask", ctypes.c_uint32),
        ("stx_blksize", ctypes.c_uint32),
        ("stx_attributes", ctypes.c_uint64),
        ("stx_nlink", ctypes.c_uint32),
        ("stx_uid", ctypes.c_uint32),
        ("stx_gid", ctypes.c_uint32),
        ("stx_mode", ctypes.c_uint16),
        ("__spare0", ctypes.c_uint16 * 1),
        ("stx_ino", ctypes.c_uint64),
        ("stx_size", ctypes.c_uint64),
        ("stx_blocks", ctypes.c_uint64),
        ("stx_attributes_mask", ctypes.c_uint64),
        ("stx_atime", _StatxTimestamp),
        ("stx_btime", _StatxTimestamp),
        ("stx_ctime", _StatxTimestamp),
        ("stx_mtime", _StatxTimestamp),
        ("stx_rdev_major", ctypes.c_uint32),
        ("stx_rdev_minor", ctypes.c_uint32),
        ("stx_dev_major", ctypes.c_uint32),
        ("stx_dev_minor", ctypes.c_uint32),
        ("stx_mnt_id", ctypes.c_uint64),
        ("stx_dio_mem_align", ctypes.c_uint32),
        ("stx_dio_offset_align", ctypes.c_uint32),
        ("stx_subvol", ctypes.c_uint64),
        ("stx_mnt_id_next", ctypes.c_uint32),
        ("__spare2", ctypes.c_uint32),
        ("__spare3", ctypes.c_uint64 * 10),
    ]


class EligibilityStatus(str, enum.Enum):
    """Eligibility status of a target artifact candidate."""
    ELIGIBLE = "eligible"
    INELIGIBLE = "ineligible"


class RejectionReason(str, enum.Enum):
    """Specific rejection reason for ineligible targets."""
    SYMLINK_REJECTED = "symlink_rejected"
    ESCAPE_REJECTED = "escape_rejected"
    MOUNT_CROSSING_REJECTED = "mount_crossing_rejected"
    HARDLINK_REJECTED = "hardlink_rejected"
    NON_REGULAR_REJECTED = "non_regular_rejected"
    DIRECTORY_REJECTED = "directory_rejected"
    FIFO_REJECTED = "fifo_rejected"
    DEVICE_REJECTED = "device_rejected"
    SOCKET_REJECTED = "socket_rejected"
    FILE_NOT_FOUND = "file_not_found"
    PERMISSION_DENIED = "permission_denied"
    OVERSIZE_REJECTED = "oversize_rejected"
    CHANGED_DURING_READ = "changed_during_read"
    INVALID_RELATIVE_PATH = "invalid_relative_path"
    ROOT_NOT_PINNED = "root_not_pinned"
    UNSUPPORTED_PLATFORM = "unsupported_platform"


@dataclasses.dataclass(frozen=True)
class FileIdentitySnapshot:
    """Immutable snapshot of file identity metadata for TOCTOU verification."""
    inode: int
    mount_id: int
    link_count: int
    size_bytes: int
    mtime_sec: int
    mtime_nsec: int
    ctime_sec: int
    ctime_nsec: int
    mode: int

    @property
    def mtime_ns(self) -> int:
        return self.mtime_sec * 1_000_000_000 + self.mtime_nsec

    @property
    def ctime_ns(self) -> int:
        return self.ctime_sec * 1_000_000_000 + self.ctime_nsec

    def matches(self, other: FileIdentitySnapshot) -> bool:
        """Check if all key identity attributes match exactly."""
        return (
            self.inode == other.inode
            and self.mount_id == other.mount_id
            and self.link_count == other.link_count
            and self.size_bytes == other.size_bytes
            and self.mtime_sec == other.mtime_sec
            and self.mtime_nsec == other.mtime_nsec
            and self.ctime_sec == other.ctime_sec
            and self.ctime_nsec == other.ctime_nsec
        )


@dataclasses.dataclass
class ValidationResult:
    """Result of pre-read descriptor-relative eligibility evaluation."""
    status: EligibilityStatus
    relative_path: str
    reason: Optional[RejectionReason] = None
    resolved_fd: Optional[int] = None
    identity: Optional[FileIdentitySnapshot] = None
    bytes_read_attempted: int = 0
    rejection_message: Optional[str] = None
    syscall_flags_used: list[str] = dataclasses.field(default_factory=list)

    @property
    def is_eligible(self) -> bool:
        return self.status == EligibilityStatus.ELIGIBLE


@dataclasses.dataclass
class ArtifactHashResult:
    """Final result of artifact validation, reading, and hashing."""
    status: EligibilityStatus
    relative_path: str
    reason: Optional[RejectionReason] = None
    sha256: Optional[str] = None
    size_bytes: int = 0
    mtime_ns: Optional[int] = None
    bytes_read: int = 0
    pre_identity: Optional[FileIdentitySnapshot] = None
    post_identity: Optional[FileIdentitySnapshot] = None
    revalidation_passed: bool = False
    rejection_message: Optional[str] = None
    syscall_flags_used: list[str] = dataclasses.field(default_factory=list)

    @property
    def is_eligible(self) -> bool:
        return self.status == EligibilityStatus.ELIGIBLE and self.revalidation_passed and self.sha256 is not None


class SyscallAuditLogger:
    """In-memory or callback audit logger for kernel syscall verification."""
    def __init__(self) -> None:
        self.records: list[dict] = []

    def record_openat2(self, dirfd: int, rel_path: str, flags: int, resolve_flags: int, result_fd: int, errno_val: int) -> None:
        self.records.append({
            "syscall": "openat2",
            "dirfd": dirfd,
            "path": rel_path,
            "flags": flags,
            "resolve_flags": resolve_flags,
            "result_fd": result_fd,
            "errno": errno_val,
        })

    def record_statx(self, fd: int, flags: int, mask: int, res: int, errno_val: int) -> None:
        self.records.append({
            "syscall": "statx",
            "fd": fd,
            "flags": flags,
            "mask": mask,
            "result": res,
            "errno": errno_val,
        })

    def clear(self) -> None:
        self.records.clear()


# Global audit logger instance
GLOBAL_AUDIT_LOGGER = SyscallAuditLogger()


def _get_libc() -> ctypes.CDLL:
    return ctypes.CDLL(None, use_errno=True)


def _get_openat2_nr() -> int:
    arch = platform.machine()
    if arch not in _NR_OPENAT2_MAP:
        raise OSError(errno.ENOSYS, f"openat2 syscall not mapped for architecture {arch}")
    return _NR_OPENAT2_MAP[arch]


def _get_statx_nr() -> int:
    arch = platform.machine()
    if arch not in _NR_STATX_MAP:
        raise OSError(errno.ENOSYS, f"statx syscall not mapped for architecture {arch}")
    return _NR_STATX_MAP[arch]


def get_mount_id_from_proc_fdinfo(fd: int) -> Optional[int]:
    """Extract mnt_id from /proc/self/fdinfo/<fd> as a secondary verification source."""
    try:
        with open(f"/proc/self/fdinfo/{fd}", "r") as f:
            for line in f:
                if line.startswith("mnt_id:"):
                    return int(line.split()[1].strip())
    except Exception:
        return None
    return None


def query_statx(fd: int) -> FileIdentitySnapshot:
    """Query Linux statx for atomic identity, mount ID, and sub-second timestamps."""
    libc = _get_libc()
    nr_statx = _get_statx_nr()
    stx = _Statx()
    
    # Query basic stats + mount ID
    res = libc.syscall(
        nr_statx,
        ctypes.c_int(fd),
        b"",
        ctypes.c_int(AT_EMPTY_PATH),
        ctypes.c_uint(STATX_BASIC_STATS | STATX_MNT_ID),
        ctypes.byref(stx),
    )
    err = ctypes.get_errno()
    GLOBAL_AUDIT_LOGGER.record_statx(fd, AT_EMPTY_PATH, STATX_BASIC_STATS | STATX_MNT_ID, res, err)
    
    if res != 0:
        # Fallback to fstat and /proc/self/fdinfo
        st = os.fstat(fd)
        mnt_id = get_mount_id_from_proc_fdinfo(fd) or int(st.st_dev)
        return FileIdentitySnapshot(
            inode=st.st_ino,
            mount_id=mnt_id,
            link_count=st.st_nlink,
            size_bytes=st.st_size,
            mtime_sec=int(st.st_mtime),
            mtime_nsec=getattr(st, "st_mtime_ns", int(st.st_mtime * 1e9)) % 1_000_000_000,
            ctime_sec=int(st.st_ctime),
            ctime_nsec=getattr(st, "st_ctime_ns", int(st.st_ctime * 1e9)) % 1_000_000_000,
            mode=st.st_mode,
        )
    
    mnt_id = int(stx.stx_mnt_id)
    if mnt_id == 0:
        # If kernel did not populate stx_mnt_id in mask, check fdinfo
        fdinfo_mnt = get_mount_id_from_proc_fdinfo(fd)
        if fdinfo_mnt is not None:
            mnt_id = fdinfo_mnt

    return FileIdentitySnapshot(
        inode=int(stx.stx_ino),
        mount_id=mnt_id,
        link_count=int(stx.stx_nlink),
        size_bytes=int(stx.stx_size),
        mtime_sec=int(stx.stx_mtime.tv_sec),
        mtime_nsec=int(stx.stx_mtime.tv_nsec),
        ctime_sec=int(stx.stx_ctime.tv_sec),
        ctime_nsec=int(stx.stx_ctime.tv_nsec),
        mode=int(stx.stx_mode),
    )


class PinnedRoot:
    """Manages an immutable, pinned directory file descriptor for descriptor-relative opens."""

    def __init__(self, root_path: str, require_absolute: bool = True) -> None:
        if require_absolute and not os.path.isabs(root_path):
            raise ValueError(f"PinnedRoot path must be absolute: {root_path}")
        
        self.root_path = os.path.realpath(root_path)
        if not os.path.isdir(self.root_path):
            raise NotADirectoryError(f"Root path is not a directory: {self.root_path}")
            
        # Open directory descriptor with O_PATH | O_DIRECTORY | O_CLOEXEC
        # On Linux, O_PATH provides a pure capability descriptor that cannot read directory stream
        # but can serve as base for *at syscalls. Fall back to O_RDONLY if O_PATH fails.
        flags = os.O_PATH | os.O_DIRECTORY | os.O_CLOEXEC
        try:
            self._dirfd: int = os.open(self.root_path, flags)
        except OSError:
            flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
            self._dirfd = os.open(self.root_path, flags)
            
        try:
            self._root_identity = query_statx(self._dirfd)
            self.root_mount_id = self._root_identity.mount_id
        except Exception:
            os.close(self._dirfd)
            raise

        self._closed = False

    @property
    def dirfd(self) -> int:
        if self._closed:
            raise ValueError("PinnedRoot descriptor is closed")
        return self._dirfd

    def close(self) -> None:
        if not self._closed:
            self._closed = True
            try:
                os.close(self._dirfd)
            except OSError:
                pass

    def __enter__(self) -> PinnedRoot:
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        self.close()

    def openat2_validate(
        self,
        relative_path: str,
        max_file_size_bytes: int = DEFAULT_MAX_FILE_SIZE_BYTES,
    ) -> ValidationResult:
        """Evaluate artifact eligibility using openat2 and fstat/statx pre-read checks.

        Returns ValidationResult with status ELIGIBLE or INELIGIBLE.
        If ELIGIBLE, the caller owns the open resolved_fd and MUST close it after use.
        If INELIGIBLE, resolved_fd is None (or closed) and 0 bytes were read.
        """
        flags_used = ["RESOLVE_BENEATH", "RESOLVE_NO_SYMLINKS", "RESOLVE_NO_XDEV"]
        
        if self._closed:
            return ValidationResult(
                status=EligibilityStatus.INELIGIBLE,
                relative_path=relative_path,
                reason=RejectionReason.ROOT_NOT_PINNED,
                rejection_message="PinnedRoot directory descriptor is closed",
                syscall_flags_used=flags_used,
            )

        # Basic path sanitization check: cannot be empty or have null bytes
        if not relative_path or "\0" in relative_path:
            return ValidationResult(
                status=EligibilityStatus.INELIGIBLE,
                relative_path=relative_path,
                reason=RejectionReason.INVALID_RELATIVE_PATH,
                rejection_message="Relative path is empty or contains null bytes",
                syscall_flags_used=flags_used,
            )

        # Reject absolute paths upfront
        if os.path.isabs(relative_path):
            return ValidationResult(
                status=EligibilityStatus.INELIGIBLE,
                relative_path=relative_path,
                reason=RejectionReason.ESCAPE_REJECTED,
                rejection_message="Absolute paths are forbidden; path must be descriptor-relative",
                syscall_flags_used=flags_used,
            )

        libc = _get_libc()
        try:
            nr_openat2 = _get_openat2_nr()
        except OSError as e:
            return ValidationResult(
                status=EligibilityStatus.INELIGIBLE,
                relative_path=relative_path,
                reason=RejectionReason.UNSUPPORTED_PLATFORM,
                rejection_message=str(e),
                syscall_flags_used=flags_used,
            )

        # Prepare open_how structure
        # O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        # O_NONBLOCK ensures we never hang on FIFOs or special device nodes
        open_flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
        resolve_mask = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_XDEV
        how = _OpenHow(
            flags=open_flags,
            mode=0,
            resolve=resolve_mask,
        )

        rel_bytes = relative_path.encode("utf-8")
        fd = libc.syscall(
            nr_openat2,
            ctypes.c_int(self.dirfd),
            rel_bytes,
            ctypes.byref(how),
            ctypes.c_size_t(ctypes.sizeof(how)),
        )
        err = ctypes.get_errno()
        GLOBAL_AUDIT_LOGGER.record_openat2(self.dirfd, relative_path, open_flags, resolve_mask, fd, err)

        if fd < 0:
            # Analyze openat2 kernel rejection
            if err == errno.ELOOP:
                return ValidationResult(
                    status=EligibilityStatus.INELIGIBLE,
                    relative_path=relative_path,
                    reason=RejectionReason.SYMLINK_REJECTED,
                    rejection_message="Kernel rejected symbolic link in path (ELOOP via RESOLVE_NO_SYMLINKS)",
                    syscall_flags_used=flags_used,
                )
            elif err == errno.EXDEV:
                # EXDEV is returned by openat2 for RESOLVE_BENEATH escape or RESOLVE_NO_XDEV mount crossing
                return ValidationResult(
                    status=EligibilityStatus.INELIGIBLE,
                    relative_path=relative_path,
                    reason=RejectionReason.ESCAPE_REJECTED,
                    rejection_message="Kernel rejected path escape or mount boundary crossing (EXDEV)",
                    syscall_flags_used=flags_used,
                )
            elif err == errno.ENOENT:
                return ValidationResult(
                    status=EligibilityStatus.INELIGIBLE,
                    relative_path=relative_path,
                    reason=RejectionReason.FILE_NOT_FOUND,
                    rejection_message="Target file does not exist (ENOENT)",
                    syscall_flags_used=flags_used,
                )
            elif err in (errno.EACCES, errno.EPERM):
                return ValidationResult(
                    status=EligibilityStatus.INELIGIBLE,
                    relative_path=relative_path,
                    reason=RejectionReason.PERMISSION_DENIED,
                    rejection_message=f"Access denied to target file ({errno.errorcode.get(err, err)})",
                    syscall_flags_used=flags_used,
                )
            else:
                return ValidationResult(
                    status=EligibilityStatus.INELIGIBLE,
                    relative_path=relative_path,
                    reason=RejectionReason.NON_REGULAR_REJECTED,
                    rejection_message=f"openat2 failed with errno {err} ({errno.errorcode.get(err, err)})",
                    syscall_flags_used=flags_used,
                )

        # File descriptor opened successfully. Now perform pre-read descriptor validation!
        try:
            identity = query_statx(fd)
            mode = identity.mode

            # 1. Check if regular file (S_ISREG)
            if stat.S_ISDIR(mode):
                os.close(fd)
                return ValidationResult(
                    status=EligibilityStatus.INELIGIBLE,
                    relative_path=relative_path,
                    reason=RejectionReason.DIRECTORY_REJECTED,
                    rejection_message="Target is a directory (S_ISDIR)",
                    syscall_flags_used=flags_used,
                )
            elif stat.S_ISLNK(mode):
                os.close(fd)
                return ValidationResult(
                    status=EligibilityStatus.INELIGIBLE,
                    relative_path=relative_path,
                    reason=RejectionReason.SYMLINK_REJECTED,
                    rejection_message="Target is a symbolic link (S_ISLNK)",
                    syscall_flags_used=flags_used,
                )
            elif stat.S_ISFIFO(mode):
                os.close(fd)
                return ValidationResult(
                    status=EligibilityStatus.INELIGIBLE,
                    relative_path=relative_path,
                    reason=RejectionReason.FIFO_REJECTED,
                    rejection_message="Target is a FIFO/named pipe (S_ISFIFO)",
                    syscall_flags_used=flags_used,
                )
            elif stat.S_ISCHR(mode) or stat.S_ISBLK(mode):
                os.close(fd)
                return ValidationResult(
                    status=EligibilityStatus.INELIGIBLE,
                    relative_path=relative_path,
                    reason=RejectionReason.DEVICE_REJECTED,
                    rejection_message="Target is a character/block device node",
                    syscall_flags_used=flags_used,
                )
            elif stat.S_ISSOCK(mode):
                os.close(fd)
                return ValidationResult(
                    status=EligibilityStatus.INELIGIBLE,
                    relative_path=relative_path,
                    reason=RejectionReason.SOCKET_REJECTED,
                    rejection_message="Target is a UNIX domain socket (S_ISSOCK)",
                    syscall_flags_used=flags_used,
                )
            elif not stat.S_ISREG(mode):
                os.close(fd)
                return ValidationResult(
                    status=EligibilityStatus.INELIGIBLE,
                    relative_path=relative_path,
                    reason=RejectionReason.NON_REGULAR_REJECTED,
                    rejection_message=f"Target is not a regular file (mode={oct(mode)})",
                    syscall_flags_used=flags_used,
                )

            # 2. Check hard link count (must be exactly 1)
            if identity.link_count != 1:
                os.close(fd)
                return ValidationResult(
                    status=EligibilityStatus.INELIGIBLE,
                    relative_path=relative_path,
                    reason=RejectionReason.HARDLINK_REJECTED,
                    rejection_message=f"File has invalid link count: {identity.link_count} != 1",
                    syscall_flags_used=flags_used,
                )

            # 3. Check mount ID (must match pinned root mount ID)
            if self.root_mount_id != 0 and identity.mount_id != 0 and identity.mount_id != self.root_mount_id:
                os.close(fd)
                return ValidationResult(
                    status=EligibilityStatus.INELIGIBLE,
                    relative_path=relative_path,
                    reason=RejectionReason.MOUNT_CROSSING_REJECTED,
                    rejection_message=f"Mount ID mismatch: file mnt_id={identity.mount_id} != root mnt_id={self.root_mount_id}",
                    syscall_flags_used=flags_used,
                )

            # 4. Check size limit before reading
            if identity.size_bytes > max_file_size_bytes:
                os.close(fd)
                return ValidationResult(
                    status=EligibilityStatus.INELIGIBLE,
                    relative_path=relative_path,
                    reason=RejectionReason.OVERSIZE_REJECTED,
                    rejection_message=f"File size {identity.size_bytes} exceeds limit {max_file_size_bytes} bytes",
                    syscall_flags_used=flags_used,
                )

            # All pre-read checks passed! Descriptor is validated and eligible.
            return ValidationResult(
                status=EligibilityStatus.ELIGIBLE,
                relative_path=relative_path,
                resolved_fd=fd,
                identity=identity,
                bytes_read_attempted=0,
                syscall_flags_used=flags_used,
            )
        except Exception as e:
            os.close(fd)
            return ValidationResult(
                status=EligibilityStatus.INELIGIBLE,
                relative_path=relative_path,
                reason=RejectionReason.NON_REGULAR_REJECTED,
                rejection_message=f"Pre-read validation failed with exception: {e}",
                syscall_flags_used=flags_used,
            )

    def validate_and_hash(
        self,
        relative_path: str,
        max_file_size_bytes: int = DEFAULT_MAX_FILE_SIZE_BYTES,
        read_wrapper: Optional[Callable[[int, int], bytes]] = None,
    ) -> ArtifactHashResult:
        """Validate artifact eligibility, read bytes through validated fd, and verify post-read identity."""
        val = self.openat2_validate(relative_path, max_file_size_bytes)
        if not val.is_eligible or val.resolved_fd is None or val.identity is None:
            return ArtifactHashResult(
                status=EligibilityStatus.INELIGIBLE,
                relative_path=relative_path,
                reason=val.reason,
                size_bytes=0,
                bytes_read=0,
                revalidation_passed=False,
                rejection_message=val.rejection_message,
                syscall_flags_used=val.syscall_flags_used,
            )

        fd = val.resolved_fd
        pre_id = val.identity
        hasher = hashlib.sha256()
        total_read = 0
        read_func = read_wrapper or os.read

        try:
            # Set descriptor to blocking or handle EAGAIN cleanly
            while True:
                chunk = read_func(fd, READ_CHUNK_SIZE)
                if not chunk:
                    break
                total_read += len(chunk)
                if total_read > max_file_size_bytes:
                    os.close(fd)
                    return ArtifactHashResult(
                        status=EligibilityStatus.INELIGIBLE,
                        relative_path=relative_path,
                        reason=RejectionReason.OVERSIZE_REJECTED,
                        size_bytes=total_read,
                        bytes_read=total_read,
                        pre_identity=pre_id,
                        revalidation_passed=False,
                        rejection_message=f"File stream exceeded maximum size limit {max_file_size_bytes} during read",
                        syscall_flags_used=val.syscall_flags_used,
                    )
                hasher.update(chunk)

            # Post-read TOCTOU identity verification
            post_id = query_statx(fd)
            os.close(fd)

            if not pre_id.matches(post_id):
                return ArtifactHashResult(
                    status=EligibilityStatus.INELIGIBLE,
                    relative_path=relative_path,
                    reason=RejectionReason.CHANGED_DURING_READ,
                    size_bytes=total_read,
                    bytes_read=total_read,
                    pre_identity=pre_id,
                    post_identity=post_id,
                    revalidation_passed=False,
                    rejection_message="File identity metadata (inode, mnt_id, nlink, size, mtime, ctime) changed during read",
                    syscall_flags_used=val.syscall_flags_used,
                )

            return ArtifactHashResult(
                status=EligibilityStatus.ELIGIBLE,
                relative_path=relative_path,
                sha256=hasher.hexdigest(),
                size_bytes=total_read,
                mtime_ns=post_id.mtime_ns,
                bytes_read=total_read,
                pre_identity=pre_id,
                post_identity=post_id,
                revalidation_passed=True,
                syscall_flags_used=val.syscall_flags_used,
            )
        except Exception as e:
            try:
                os.close(fd)
            except OSError:
                pass
            return ArtifactHashResult(
                status=EligibilityStatus.INELIGIBLE,
                relative_path=relative_path,
                reason=RejectionReason.CHANGED_DURING_READ,
                size_bytes=total_read,
                bytes_read=total_read,
                pre_identity=pre_id,
                revalidation_passed=False,
                rejection_message=f"Hashing failed during read: {e}",
                syscall_flags_used=val.syscall_flags_used,
            )


def validate_and_hash_artifact(
    root_path: str,
    relative_path: str,
    max_file_size_bytes: int = DEFAULT_MAX_FILE_SIZE_BYTES,
) -> ArtifactHashResult:
    """Convenience function to pin root, validate candidate descriptor, and hash artifact."""
    with PinnedRoot(root_path) as root:
        return root.validate_and_hash(relative_path, max_file_size_bytes)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 -m agentmaxxing-host-sensor.file_validator <root_dir> <relative_path>")
        sys.exit(2)
    root_dir = sys.argv[1]
    rel_path = sys.argv[2]
    result = validate_and_hash_artifact(root_dir, rel_path)
    print(f"Status: {result.status.value}")
    if result.is_eligible:
        print(f"SHA256: {result.sha256}")
        print(f"Size: {result.size_bytes} bytes")
        print(f"Mtime: {result.mtime_ns} ns")
        print(f"Bytes Read: {result.bytes_read}")
        print("Revalidation: Passed")
        sys.exit(0)
    else:
        print(f"Reason: {result.reason.value if result.reason else 'unknown'}")
        print(f"Message: {result.rejection_message}")
        print(f"Bytes Read: {result.bytes_read}")
        sys.exit(1)
