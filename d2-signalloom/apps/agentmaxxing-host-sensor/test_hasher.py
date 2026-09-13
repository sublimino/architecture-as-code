"""
Unit and concurrency test suite for BoundedArtifactHasher and TOCTOU validation.
Simulates concurrent file replacement, truncation, append, unlinking, metadata modification,
oversize payloads, and rate limit exhaustion.
"""

import hashlib
import os
import stat
import tempfile
import threading
import time
from typing import Generator

import pytest

import sys
from pathlib import Path

SENSOR_DIR = Path(__file__).resolve().parent
if str(SENSOR_DIR) not in sys.path:
    sys.path.insert(0, str(SENSOR_DIR))

try:
    from .hasher import (
        ArtifactHashResult,
        BoundedArtifactHasher,
        FileIdentitySnapshot,
        FileOversizeError,
        RateLimitExceededError,
        TOCTOURaceDetectedError,
    )
    from .openat2 import open_beneath
    from .ratelimit import RateLimiter
except (ImportError, ValueError):
    from hasher import (
        ArtifactHashResult,
        BoundedArtifactHasher,
        FileIdentitySnapshot,
        FileOversizeError,
        RateLimitExceededError,
        TOCTOURaceDetectedError,
    )
    from openat2 import open_beneath
    from ratelimit import RateLimiter


@pytest.fixture
def temp_root() -> Generator[str, None, None]:
    with tempfile.TemporaryDirectory(prefix="hasher_test_root_") as tmpdir:
        yield tmpdir


@pytest.fixture
def standard_hasher() -> BoundedArtifactHasher:
    limiter = RateLimiter(
        max_files_per_window=120,
        max_bytes_per_window=67_108_864,
        window_seconds=60.0,
        max_file_size_bytes=16_777_216,
    )
    return BoundedArtifactHasher(
        rate_limiter=limiter,
        max_file_size_bytes=16_777_216,
        chunk_size=4096,  # Smaller chunk for granular test steps
    )


class TestBasicHashingAndCorrectness:
    def test_hash_small_regular_file(self, temp_root: str, standard_hasher: BoundedArtifactHasher):
        content = b"Hello, Signal Loom AgentMaxxing Host Sensor!"
        relpath = "hello.txt"
        filepath = os.path.join(temp_root, relpath)
        with open(filepath, "wb") as f:
            f.write(content)

        result = standard_hasher.hash_relative_path(temp_root, relpath, root_id="agent-work")

        assert result.observation_state == "observed"
        assert result.integrity_state == "verified"
        assert result.sha256 == hashlib.sha256(content).hexdigest()
        assert result.size_bytes == len(content)
        assert result.reason_code is None
        assert result.artifact_id.startswith("hmac-sha256:")

    def test_hash_multi_chunk_file(self, temp_root: str, standard_hasher: BoundedArtifactHasher):
        # 128 KiB file -> 32 chunks of 4KB
        content = b"A" * 131072
        relpath = "large.bin"
        filepath = os.path.join(temp_root, relpath)
        with open(filepath, "wb") as f:
            f.write(content)

        result = standard_hasher.hash_relative_path(temp_root, relpath, root_id="agent-output")

        assert result.observation_state == "observed"
        assert result.integrity_state == "verified"
        assert result.sha256 == hashlib.sha256(content).hexdigest()
        assert result.size_bytes == 131072

    def test_hash_empty_file(self, temp_root: str, standard_hasher: BoundedArtifactHasher):
        relpath = "empty.txt"
        filepath = os.path.join(temp_root, relpath)
        with open(filepath, "wb") as f:
            pass

        result = standard_hasher.hash_relative_path(temp_root, relpath, root_id="agent-work")

        assert result.observation_state == "observed"
        assert result.integrity_state == "verified"
        assert result.sha256 == hashlib.sha256(b"").hexdigest()
        assert result.size_bytes == 0


class TestPreReadEligibilityChecks:
    def test_reject_directory(self, temp_root: str, standard_hasher: BoundedArtifactHasher):
        relpath = "subdir"
        os.makedirs(os.path.join(temp_root, relpath), exist_ok=True)

        result = standard_hasher.hash_relative_path(temp_root, relpath, root_id="agent-work")

        assert result.observation_state == "denied"
        assert result.integrity_state == "unverified"
        assert result.sha256 is None
        assert result.reason_code in ("not_regular_file", "openat2_escape_rejected")

    def test_reject_symlink(self, temp_root: str, standard_hasher: BoundedArtifactHasher):
        target_path = os.path.join(temp_root, "target.txt")
        with open(target_path, "wb") as f:
            f.write(b"Target content")

        symlink_relpath = "link.txt"
        os.symlink(target_path, os.path.join(temp_root, symlink_relpath))

        result = standard_hasher.hash_relative_path(temp_root, symlink_relpath, root_id="agent-work")

        assert result.observation_state == "denied"
        assert result.integrity_state == "unverified"
        assert result.sha256 is None
        assert "escape" in (result.reason_code or "")

    def test_reject_directory_escape(self, temp_root: str, standard_hasher: BoundedArtifactHasher):
        result = standard_hasher.hash_relative_path(temp_root, "../../../etc/passwd", root_id="agent-work")

        assert result.observation_state == "denied"
        assert result.sha256 is None
        assert "escape" in (result.reason_code or "")

    def test_reject_hardlink_multiple(self, temp_root: str, standard_hasher: BoundedArtifactHasher):
        f1 = os.path.join(temp_root, "file1.txt")
        f2 = os.path.join(temp_root, "file2.txt")
        with open(f1, "wb") as f:
            f.write(b"Multi-link content")
        os.link(f1, f2)

        result = standard_hasher.hash_relative_path(temp_root, "file1.txt", root_id="agent-work")

        assert result.observation_state == "denied"
        assert result.integrity_state == "unverified"
        assert result.sha256 is None
        assert result.reason_code == "hardlink_forbidden"

    def test_reject_fifo_pipe(self, temp_root: str, standard_hasher: BoundedArtifactHasher):
        fifo_path = os.path.join(temp_root, "test.fifo")
        try:
            os.mkfifo(fifo_path)
        except AttributeError:
            pytest.skip("os.mkfifo not available")

        # Open non-blocking so test doesn't hang
        root_fd = os.open(temp_root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            fd = os.open(fifo_path, os.O_RDONLY | os.O_NONBLOCK)
            try:
                result = standard_hasher.hash_descriptor(fd, root_id="agent-work", relpath="test.fifo", root_fd=root_fd)
                assert result.observation_state == "denied"
                assert result.sha256 is None
                assert result.reason_code == "not_regular_file"
            finally:
                os.close(fd)
        finally:
            os.close(root_fd)


class TestFileSizeAndRateLimits:
    def test_reject_oversize_pre_read(self, temp_root: str):
        # Limit to 1024 bytes
        limiter = RateLimiter(max_file_size_bytes=1024)
        hasher = BoundedArtifactHasher(rate_limiter=limiter, max_file_size_bytes=1024)

        relpath = "oversize.dat"
        filepath = os.path.join(temp_root, relpath)
        with open(filepath, "wb") as f:
            f.write(b"X" * 2048)

        result = hasher.hash_relative_path(temp_root, relpath)

        assert result.observation_state == "unobserved"
        assert result.sha256 is None
        assert result.reason_code == "max_file_size_exceeded"

    def test_reject_file_count_rate_limit(self, temp_root: str):
        # Max 3 files per window
        limiter = RateLimiter(max_files_per_window=3, window_seconds=10.0)
        hasher = BoundedArtifactHasher(rate_limiter=limiter)

        for i in range(3):
            rel = f"file_{i}.txt"
            with open(os.path.join(temp_root, rel), "wb") as f:
                f.write(f"content {i}".encode())
            res = hasher.hash_relative_path(temp_root, rel)
            assert res.observation_state == "observed"

        # 4th file should be rejected
        rel_4 = "file_3.txt"
        with open(os.path.join(temp_root, rel_4), "wb") as f:
            f.write(b"content 3")
        res_4 = hasher.hash_relative_path(temp_root, rel_4)

        assert res_4.observation_state == "unobserved"
        assert res_4.sha256 is None
        assert res_4.reason_code == "max_files_per_window_exceeded"

    def test_reject_byte_throughput_rate_limit(self, temp_root: str):
        # Max 1000 bytes per window
        limiter = RateLimiter(max_bytes_per_window=1000, window_seconds=10.0)
        hasher = BoundedArtifactHasher(rate_limiter=limiter)

        # 1st file: 600 bytes -> OK
        with open(os.path.join(temp_root, "f1.bin"), "wb") as f:
            f.write(b"A" * 600)
        r1 = hasher.hash_relative_path(temp_root, "f1.bin")
        assert r1.observation_state == "observed"

        # 2nd file: 500 bytes (total 1100 > 1000) -> Rejected
        with open(os.path.join(temp_root, "f2.bin"), "wb") as f:
            f.write(b"B" * 500)
        r2 = hasher.hash_relative_path(temp_root, "f2.bin")
        assert r2.observation_state == "unobserved"
        assert r2.sha256 is None
        assert r2.reason_code == "max_bytes_per_window_exceeded"


class TestTOCTOUConcurrencyAndRaces:
    def test_concurrent_file_truncation_during_hash(self, temp_root: str, standard_hasher: BoundedArtifactHasher):
        relpath = "truncate_me.bin"
        filepath = os.path.join(temp_root, relpath)
        with open(filepath, "wb") as f:
            f.write(b"Z" * 16384)  # 16KB

        root_fd = os.open(temp_root, os.O_RDONLY | os.O_DIRECTORY)
        candidate_fd = open_beneath(root_fd, relpath)

        def race_truncation():
            # Truncate file from another handle while reading chunks
            with open(filepath, "wb") as f:
                f.truncate(1024)

        try:
            result = standard_hasher.hash_descriptor(
                candidate_fd,
                root_id="agent-work",
                relpath=relpath,
                root_fd=root_fd,
                read_delay_hook=race_truncation,
            )

            assert result.observation_state == "unobserved"
            assert result.integrity_state == "unverified"
            assert result.sha256 is None
            assert result.reason_code in ("toctou_truncation_detected", "toctou_mutation_detected")
        finally:
            os.close(candidate_fd)
            os.close(root_fd)

    def test_concurrent_file_append_during_hash(self, temp_root: str, standard_hasher: BoundedArtifactHasher):
        relpath = "append_me.bin"
        filepath = os.path.join(temp_root, relpath)
        with open(filepath, "wb") as f:
            f.write(b"Initial data 4096 bytes" * 100)

        root_fd = os.open(temp_root, os.O_RDONLY | os.O_DIRECTORY)
        candidate_fd = open_beneath(root_fd, relpath)

        appended = False

        def race_append():
            nonlocal appended
            if not appended:
                with open(filepath, "ab") as f:
                    f.write(b"TAMPERED APPENDED DATA")
                    f.flush()
                appended = True

        try:
            result = standard_hasher.hash_descriptor(
                candidate_fd,
                root_id="agent-work",
                relpath=relpath,
                root_fd=root_fd,
                read_delay_hook=race_append,
            )

            assert result.observation_state == "unobserved"
            assert result.integrity_state == "unverified"
            assert result.sha256 is None
            assert "toctou" in (result.reason_code or "")
        finally:
            os.close(candidate_fd)
            os.close(root_fd)

    def test_concurrent_file_unlinking_during_hash(self, temp_root: str, standard_hasher: BoundedArtifactHasher):
        relpath = "unlink_me.bin"
        filepath = os.path.join(temp_root, relpath)
        with open(filepath, "wb") as f:
            f.write(b"A" * 8192)

        root_fd = os.open(temp_root, os.O_RDONLY | os.O_DIRECTORY)
        candidate_fd = open_beneath(root_fd, relpath)

        def race_unlink():
            if os.path.exists(filepath):
                os.unlink(filepath)

        try:
            result = standard_hasher.hash_descriptor(
                candidate_fd,
                root_id="agent-work",
                relpath=relpath,
                root_fd=root_fd,
                read_delay_hook=race_unlink,
            )

            assert result.observation_state == "unobserved"
            assert result.integrity_state == "unverified"
            assert result.sha256 is None
            assert result.reason_code == "toctou_link_tamper_detected"
        finally:
            os.close(candidate_fd)
            os.close(root_fd)

    def test_concurrent_hardlink_creation_during_hash(self, temp_root: str, standard_hasher: BoundedArtifactHasher):
        relpath = "link_me.bin"
        filepath = os.path.join(temp_root, relpath)
        with open(filepath, "wb") as f:
            f.write(b"B" * 8192)

        root_fd = os.open(temp_root, os.O_RDONLY | os.O_DIRECTORY)
        candidate_fd = open_beneath(root_fd, relpath)

        def race_link():
            linkpath = os.path.join(temp_root, "link_target.bin")
            if not os.path.exists(linkpath):
                os.link(filepath, linkpath)

        try:
            result = standard_hasher.hash_descriptor(
                candidate_fd,
                root_id="agent-work",
                relpath=relpath,
                root_fd=root_fd,
                read_delay_hook=race_link,
            )

            assert result.observation_state == "unobserved"
            assert result.integrity_state == "unverified"
            assert result.sha256 is None
            assert result.reason_code == "toctou_link_tamper_detected"
        finally:
            os.close(candidate_fd)
            os.close(root_fd)

    def test_concurrent_mtime_touch_during_hash(self, temp_root: str, standard_hasher: BoundedArtifactHasher):
        relpath = "touch_me.bin"
        filepath = os.path.join(temp_root, relpath)
        with open(filepath, "wb") as f:
            f.write(b"C" * 8192)

        root_fd = os.open(temp_root, os.O_RDONLY | os.O_DIRECTORY)
        candidate_fd = open_beneath(root_fd, relpath)

        def race_touch():
            # Advance mtime by 5 seconds
            t = time.time() + 5
            os.utime(filepath, (t, t))

        try:
            result = standard_hasher.hash_descriptor(
                candidate_fd,
                root_id="agent-work",
                relpath=relpath,
                root_fd=root_fd,
                read_delay_hook=race_touch,
            )

            assert result.observation_state == "unobserved"
            assert result.integrity_state == "unverified"
            assert result.sha256 is None
            assert result.reason_code in ("toctou_mutation_detected", "toctou_metadata_tamper_detected")
        finally:
            os.close(candidate_fd)
            os.close(root_fd)

    def test_multithreaded_concurrency_stress(self, temp_root: str, standard_hasher: BoundedArtifactHasher):
        """Spawns concurrent writer and hasher threads racing on multiple files."""
        stop_event = threading.Event()
        results = []
        errors = []

        def worker_hash(idx: int):
            rel = f"worker_file_{idx}.bin"
            filepath = os.path.join(temp_root, rel)
            with open(filepath, "wb") as f:
                f.write(b"Initial content " * 500)

            for _ in range(5):
                if stop_event.is_set():
                    break
                try:
                    res = standard_hasher.hash_relative_path(temp_root, rel)
                    results.append(res)
                except Exception as e:
                    errors.append(e)
                time.sleep(0.005)

        def worker_mutate(idx: int):
            rel = f"worker_file_{idx}.bin"
            filepath = os.path.join(temp_root, rel)
            for _ in range(5):
                if stop_event.is_set():
                    break
                if os.path.exists(filepath):
                    try:
                        with open(filepath, "ab") as f:
                            f.write(b"X")
                    except OSError:
                        pass
                time.sleep(0.007)

        threads = []
        for i in range(4):
            t_hash = threading.Thread(target=worker_hash, args=(i,))
            t_mut = threading.Thread(target=worker_mutate, args=(i,))
            threads.extend([t_hash, t_mut])

        for t in threads:
            t.start()

        for t in threads:
            t.join()

        assert len(errors) == 0
        assert len(results) > 0

        # Verify invariant: all observed results have sha256, all unobserved have sha256 is None
        for r in results:
            if r.observation_state == "observed":
                assert r.sha256 is not None
                assert r.integrity_state == "verified"
            else:
                assert r.sha256 is None
                assert r.integrity_state == "unverified"
