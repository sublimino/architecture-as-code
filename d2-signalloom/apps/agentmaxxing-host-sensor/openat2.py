"""
openat2 and statx syscall bindings for descriptor-relative filesystem operations.
Provides kernel-enforced traversal prevention and mount tracking.
"""

import ctypes
import os
import stat
from typing import Optional, Tuple

libc = ctypes.CDLL(None, use_errno=True)

# Architecture-specific syscall numbers (Linux x86_64)
SYS_statx = 332
SYS_openat2 = 437

# openat2 resolve flags
RESOLVE_NO_XDEV = 0x01
RESOLVE_NO_MAGICLINKS = 0x02
RESOLVE_NO_SYMLINKS = 0x04
RESOLVE_BENEATH = 0x08
RESOLVE_IN_ROOT = 0x10
RESOLVE_CACHED = 0x20

# statx flags
AT_EMPTY_PATH = 0x1000
AT_SYMLINK_NOFOLLOW = 0x0100
STATX_BASIC_STATS = 0x07FF
STATX_MNT_ID = 0x1000


class OpenHow(ctypes.Structure):
    _fields_ = [
        ("flags", ctypes.c_uint64),
        ("mode", ctypes.c_uint64),
        ("resolve", ctypes.c_uint64),
    ]


class StatxTimestamp(ctypes.Structure):
    _fields_ = [
        ("tv_sec", ctypes.c_int64),
        ("tv_nsec", ctypes.c_uint32),
        ("__statx_pad1", ctypes.c_int32),
    ]


class Statx(ctypes.Structure):
    _fields_ = [
        ("stx_mask", ctypes.c_uint32),
        ("stx_blksize", ctypes.c_uint32),
        ("stx_attributes", ctypes.c_uint64),
        ("stx_nlink", ctypes.c_uint32),
        ("stx_uid", ctypes.c_uint32),
        ("stx_gid", ctypes.c_uint32),
        ("stx_mode", ctypes.c_uint16),
        ("__statx_pad1", ctypes.c_uint16 * 1),
        ("stx_ino", ctypes.c_uint64),
        ("stx_size", ctypes.c_uint64),
        ("stx_blocks", ctypes.c_uint64),
        ("stx_attributes_mask", ctypes.c_uint64),
        ("stx_atime", StatxTimestamp),
        ("stx_btime", StatxTimestamp),
        ("stx_ctime", StatxTimestamp),
        ("stx_mtime", StatxTimestamp),
        ("stx_rdev_major", ctypes.c_uint32),
        ("stx_rdev_minor", ctypes.c_uint32),
        ("stx_dev_major", ctypes.c_uint32),
        ("stx_dev_minor", ctypes.c_uint32),
        ("stx_mnt_id", ctypes.c_uint64),
        ("__statx_pad2", ctypes.c_uint64 * 14),
    ]


def open_beneath(
    dirfd: int,
    relpath: str,
    flags: int = os.O_RDONLY | os.O_CLOEXEC,
    mode: int = 0,
) -> int:
    """
    Opens a path relative to dirfd using openat2 with strict kernel-enforced
    traversal protection: RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_XDEV.
    """
    how = OpenHow(
        flags,
        mode,
        RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_XDEV,
    )
    ret = libc.syscall(
        SYS_openat2,
        dirfd,
        relpath.encode("utf-8"),
        ctypes.byref(how),
        ctypes.sizeof(how),
    )
    if ret < 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))
    return ret


def query_statx(fd: int) -> Optional[Statx]:
    """Queries statx for the given file descriptor using AT_EMPTY_PATH."""
    sx = Statx()
    res = libc.syscall(
        SYS_statx,
        fd,
        b"",
        AT_EMPTY_PATH,
        STATX_BASIC_STATS | STATX_MNT_ID,
        ctypes.byref(sx),
    )
    if res == 0:
        return sx
    return None


def get_statx_mnt_id(fd: int) -> int:
    """Returns the mount ID (stx_mnt_id) of the given file descriptor, or 0 if unavailable."""
    sx = query_statx(fd)
    if sx is not None and (sx.stx_mask & STATX_MNT_ID):
        return sx.stx_mnt_id
    # Fallback to dev_id
    st = os.fstat(fd)
    return st.st_dev
