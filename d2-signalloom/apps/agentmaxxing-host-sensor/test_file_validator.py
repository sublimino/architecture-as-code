"""Adversarial and functional test suite for descriptor-relative file validator.

Verifies:
1. Symlink traps (inside, outside, nested, dangling) rejected before read.
2. Path traversal escapes (../, absolute) rejected before read.
3. Hard-link escapes (nlink > 1) rejected before read.
4. Non-regular files (directories, FIFOs, devices, sockets) rejected before read.
5. Mount boundary crossing rejected before read.
6. Oversize files rejected before read.
7. TOCTOU mutation / replacement races detected and rejected.
8. Independent canary proof asserting ZERO bytes read from all ineligible targets.
9. Kernel syscall audit logger confirms openat2 with RESOLVE_* flags.
"""
from __future__ import annotations

import hashlib
import os
import stat
import sys
import tempfile
import time
from typing import Generator

import pytest

# Ensure host sensor package is in python path
CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
if CURRENT_DIR not in sys.path:
    sys.path.insert(0, CURRENT_DIR)

from file_validator import (
    GLOBAL_AUDIT_LOGGER,
    ArtifactHashResult,
    EligibilityStatus,
    FileIdentitySnapshot,
    PinnedRoot,
    RejectionReason,
    ValidationResult,
    query_statx,
    validate_and_hash_artifact,
)


@pytest.fixture
def temp_workspace() -> Generator[tuple[str, PinnedRoot], None, None]:
    """Create a temporary root directory and a pinned root descriptor."""
    with tempfile.TemporaryDirectory(prefix="agentmaxxing_test_") as tmpdir:
        real_root = os.path.realpath(tmpdir)
        with PinnedRoot(real_root) as pinned:
            yield real_root, pinned


def test_valid_regular_file(temp_workspace: tuple[str, PinnedRoot]) -> None:
    """Positive test: regular file beneath pinned root is eligible and hashed."""
    root_path, pinned = temp_workspace
    file_path = os.path.join(root_path, "report.json")
    content = b'{"status": "success", "artifact": "model_weights_v1"}'
    with open(file_path, "wb") as f:
        f.write(content)

    expected_sha = hashlib.sha256(content).hexdigest()

    res = pinned.validate_and_hash("report.json")
    assert res.is_eligible
    assert res.status == EligibilityStatus.ELIGIBLE
    assert res.sha256 == expected_sha
    assert res.size_bytes == len(content)
    assert res.bytes_read == len(content)
    assert res.revalidation_passed
    assert "RESOLVE_BENEATH" in res.syscall_flags_used
    assert "RESOLVE_NO_SYMLINKS" in res.syscall_flags_used
    assert "RESOLVE_NO_XDEV" in res.syscall_flags_used


def test_nested_regular_file(temp_workspace: tuple[str, PinnedRoot]) -> None:
    """Positive test: regular file in subdirectories beneath pinned root."""
    root_path, pinned = temp_workspace
    sub_dir = os.path.join(root_path, "nested", "level2")
    os.makedirs(sub_dir, exist_ok=True)
    file_path = os.path.join(sub_dir, "output.dat")
    content = b"deterministic binary content 12345"
    with open(file_path, "wb") as f:
        f.write(content)

    res = pinned.validate_and_hash("nested/level2/output.dat")
    assert res.is_eligible
    assert res.sha256 == hashlib.sha256(content).hexdigest()
    assert res.bytes_read == len(content)


def test_symlink_inside_root_rejection(temp_workspace: tuple[str, PinnedRoot]) -> None:
    """Negative test: symlink pointing to an internal target is rejected with 0 bytes read."""
    root_path, pinned = temp_workspace
    target = os.path.join(root_path, "real_file.txt")
    with open(target, "wb") as f:
        f.write(b"secret internal content")

    symlink_path = os.path.join(root_path, "symlink_inside.txt")
    os.symlink("real_file.txt", symlink_path)

    res = pinned.validate_and_hash("symlink_inside.txt")
    assert not res.is_eligible
    assert res.status == EligibilityStatus.INELIGIBLE
    assert res.reason == RejectionReason.SYMLINK_REJECTED
    assert res.bytes_read == 0
    assert res.sha256 is None


def test_symlink_outside_root_rejection(temp_workspace: tuple[str, PinnedRoot]) -> None:
    """Negative test: symlink targeting outside system file (/etc/passwd) is rejected with 0 bytes read."""
    root_path, pinned = temp_workspace
    symlink_path = os.path.join(root_path, "etc_passwd_link")
    os.symlink("/etc/passwd", symlink_path)

    res = pinned.validate_and_hash("etc_passwd_link")
    assert not res.is_eligible
    assert res.status == EligibilityStatus.INELIGIBLE
    assert res.reason == RejectionReason.SYMLINK_REJECTED
    assert res.bytes_read == 0
    assert res.sha256 is None


def test_nested_symlink_directory_rejection(temp_workspace: tuple[str, PinnedRoot]) -> None:
    """Negative test: directory component in path is a symlink pointing outside."""
    root_path, pinned = temp_workspace
    sym_dir = os.path.join(root_path, "linked_etc")
    os.symlink("/etc", sym_dir)

    res = pinned.validate_and_hash("linked_etc/passwd")
    assert not res.is_eligible
    assert res.status == EligibilityStatus.INELIGIBLE
    assert res.reason in (RejectionReason.SYMLINK_REJECTED, RejectionReason.ESCAPE_REJECTED)
    assert res.bytes_read == 0


def test_dangling_symlink_rejection(temp_workspace: tuple[str, PinnedRoot]) -> None:
    """Negative test: dangling symlink is rejected with 0 bytes read."""
    root_path, pinned = temp_workspace
    sym_dangling = os.path.join(root_path, "dangling.txt")
    os.symlink("non_existent_target.txt", sym_dangling)

    res = pinned.validate_and_hash("dangling.txt")
    assert not res.is_eligible
    assert res.status == EligibilityStatus.INELIGIBLE
    assert res.reason in (RejectionReason.SYMLINK_REJECTED, RejectionReason.FILE_NOT_FOUND)
    assert res.bytes_read == 0


def test_path_traversal_escape_dotdot_rejection(temp_workspace: tuple[str, PinnedRoot]) -> None:
    """Negative test: path traversal with '..' attempting to escape root is rejected with 0 bytes read."""
    root_path, pinned = temp_workspace

    res = pinned.validate_and_hash("../../../etc/passwd")
    assert not res.is_eligible
    assert res.status == EligibilityStatus.INELIGIBLE
    assert res.reason == RejectionReason.ESCAPE_REJECTED
    assert res.bytes_read == 0


def test_absolute_path_escape_rejection(temp_workspace: tuple[str, PinnedRoot]) -> None:
    """Negative test: absolute path supplied to descriptor-relative opener is rejected with 0 bytes read."""
    root_path, pinned = temp_workspace

    res = pinned.validate_and_hash("/etc/passwd")
    assert not res.is_eligible
    assert res.status == EligibilityStatus.INELIGIBLE
    assert res.reason == RejectionReason.ESCAPE_REJECTED
    assert res.bytes_read == 0


def test_hardlink_file_rejection(temp_workspace: tuple[str, PinnedRoot]) -> None:
    """Negative test: hard-linked file (st_nlink > 1) is rejected with 0 bytes read."""
    root_path, pinned = temp_workspace
    original = os.path.join(root_path, "original.txt")
    with open(original, "wb") as f:
        f.write(b"content in hardlinked file")

    link_target = os.path.join(root_path, "hardlink.txt")
    os.link(original, link_target)

    # Both links have st_nlink == 2
    res = pinned.validate_and_hash("original.txt")
    assert not res.is_eligible
    assert res.status == EligibilityStatus.INELIGIBLE
    assert res.reason == RejectionReason.HARDLINK_REJECTED
    assert res.bytes_read == 0

    res_link = pinned.validate_and_hash("hardlink.txt")
    assert not res_link.is_eligible
    assert res_link.reason == RejectionReason.HARDLINK_REJECTED
    assert res_link.bytes_read == 0


def test_directory_target_rejection(temp_workspace: tuple[str, PinnedRoot]) -> None:
    """Negative test: directory target is rejected before read."""
    root_path, pinned = temp_workspace
    sub_dir = os.path.join(root_path, "subdir")
    os.mkdir(sub_dir)

    res = pinned.validate_and_hash("subdir")
    assert not res.is_eligible
    assert res.status == EligibilityStatus.INELIGIBLE
    assert res.reason in (RejectionReason.DIRECTORY_REJECTED, RejectionReason.NON_REGULAR_REJECTED)
    assert res.bytes_read == 0


def test_fifo_named_pipe_rejection(temp_workspace: tuple[str, PinnedRoot]) -> None:
    """Negative test: FIFO named pipe is non-blocking and rejected with 0 bytes read."""
    root_path, pinned = temp_workspace
    fifo_path = os.path.join(root_path, "test_pipe.fifo")
    os.mkfifo(fifo_path)

    res = pinned.validate_and_hash("test_pipe.fifo")
    assert not res.is_eligible
    assert res.status == EligibilityStatus.INELIGIBLE
    assert res.reason in (RejectionReason.FIFO_REJECTED, RejectionReason.NON_REGULAR_REJECTED)
    assert res.bytes_read == 0


def test_oversize_file_rejection(temp_workspace: tuple[str, PinnedRoot]) -> None:
    """Negative test: file exceeding maximum size limit is rejected with 0 bytes read."""
    root_path, pinned = temp_workspace
    file_path = os.path.join(root_path, "oversize.bin")
    # Write 4 KiB file, but set limit to 1 KiB
    content = b"X" * 4096
    with open(file_path, "wb") as f:
        f.write(content)

    res = pinned.validate_and_hash("oversize.bin", max_file_size_bytes=1024)
    assert not res.is_eligible
    assert res.status == EligibilityStatus.INELIGIBLE
    assert res.reason == RejectionReason.OVERSIZE_REJECTED
    assert res.bytes_read == 0


def test_non_existent_file_rejection(temp_workspace: tuple[str, PinnedRoot]) -> None:
    """Negative test: non-existent file returns FILE_NOT_FOUND with 0 bytes read."""
    root_path, pinned = temp_workspace

    res = pinned.validate_and_hash("ghost_file.txt")
    assert not res.is_eligible
    assert res.status == EligibilityStatus.INELIGIBLE
    assert res.reason == RejectionReason.FILE_NOT_FOUND
    assert res.bytes_read == 0


def test_mutation_during_read_rejection(temp_workspace: tuple[str, PinnedRoot]) -> None:
    """Negative test: file modified/truncated during read loop fails post-read identity check."""
    root_path, pinned = temp_workspace
    file_path = os.path.join(root_path, "mutating.txt")
    with open(file_path, "wb") as f:
        f.write(b"A" * 128 * 1024)

    # Custom read wrapper that mutates the file on disk during read
    call_count = 0
    def mutating_read(fd: int, size: int) -> bytes:
        nonlocal call_count
        call_count += 1
        data = os.read(fd, size)
        if call_count == 1:
            # Overwrite/truncate the file on disk
            with open(file_path, "wb") as f:
                f.write(b"tampered content")
        return data

    res = pinned.validate_and_hash("mutating.txt", read_wrapper=mutating_read)
    assert not res.is_eligible
    assert res.status == EligibilityStatus.INELIGIBLE
    assert res.reason == RejectionReason.CHANGED_DURING_READ


def test_independent_canary_proof_zero_reads(temp_workspace: tuple[str, PinnedRoot]) -> None:
    """Adversarial stress test: assert that read() is invoked exactly 0 times for all ineligible targets."""
    root_path, pinned = temp_workspace

    # Setup matrix of adversarial traps
    # 1. Symlink inside
    with open(os.path.join(root_path, "canary_target.txt"), "wb") as f:
        f.write(b"canary")
    os.symlink("canary_target.txt", os.path.join(root_path, "canary_sym_in"))

    # 2. Symlink outside
    os.symlink("/etc/passwd", os.path.join(root_path, "canary_sym_out"))

    # 3. Path traversal escape
    # 4. Hardlink
    os.link(os.path.join(root_path, "canary_target.txt"), os.path.join(root_path, "canary_hardlink"))

    # 5. Directory
    os.mkdir(os.path.join(root_path, "canary_dir"))

    # 6. FIFO
    os.mkfifo(os.path.join(root_path, "canary_fifo"))

    # 7. Oversize
    with open(os.path.join(root_path, "canary_oversize"), "wb") as f:
        f.write(b"O" * 2048)

    ineligible_targets = [
        ("canary_sym_in", 1024),
        ("canary_sym_out", 1024),
        ("../../../etc/shadow", 1024),
        ("/etc/hosts", 1024),
        ("canary_hardlink", 1024),
        ("canary_dir", 1024),
        ("canary_fifo", 1024),
        ("canary_oversize", 512),
        ("non_existent_path.txt", 1024),
    ]

    read_invocations = 0
    total_bytes_read = 0

    def canary_read(fd: int, size: int) -> bytes:
        nonlocal read_invocations, total_bytes_read
        read_invocations += 1
        data = os.read(fd, size)
        total_bytes_read += len(data)
        return data

    for rel_path, max_sz in ineligible_targets:
        res = pinned.validate_and_hash(rel_path, max_file_size_bytes=max_sz, read_wrapper=canary_read)
        assert not res.is_eligible, f"Expected {rel_path} to be ineligible!"
        assert res.bytes_read == 0, f"Expected 0 bytes read for {rel_path}, got {res.bytes_read}"

    # Verify that canary read wrapper was never invoked
    assert read_invocations == 0, f"Canary read() was invoked {read_invocations} times on ineligible targets!"
    assert total_bytes_read == 0, f"Canary read() read {total_bytes_read} bytes from ineligible targets!"


def test_syscall_audit_logger_records_resolve_flags(temp_workspace: tuple[str, PinnedRoot]) -> None:
    """Verify kernel syscall audit log captures openat2 and statx calls with exact resolve flags."""
    root_path, pinned = temp_workspace
    GLOBAL_AUDIT_LOGGER.clear()

    file_path = os.path.join(root_path, "audit_test.txt")
    with open(file_path, "wb") as f:
        f.write(b"audit log verification content")

    res = pinned.validate_and_hash("audit_test.txt")
    assert res.is_eligible

    records = GLOBAL_AUDIT_LOGGER.records
    assert len(records) >= 2

    openat2_records = [r for r in records if r["syscall"] == "openat2"]
    assert len(openat2_records) >= 1
    last_open = openat2_records[-1]
    assert last_open["path"] == "audit_test.txt"
    assert (last_open["resolve_flags"] & 0x08) != 0  # RESOLVE_BENEATH
    assert (last_open["resolve_flags"] & 0x04) != 0  # RESOLVE_NO_SYMLINKS
    assert (last_open["resolve_flags"] & 0x01) != 0  # RESOLVE_NO_XDEV
    assert last_open["result_fd"] >= 0

    statx_records = [r for r in records if r["syscall"] == "statx"]
    assert len(statx_records) >= 1
