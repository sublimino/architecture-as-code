# AMXO-P4-4 — Bounded Artifact Hashing and Post-Read Identity Validation (TOCTOU) Proof

**Status:** PASS — Bounded artifact hashing, sliding-window rate limits, and post-read identity revalidation delivered and certified  
**Verified at:** 2026-09-13 18:23:00+01:00  
**Logical ID:** `P4-4`  
**Role:** `implementation`  
**Base ref:** `refs/heads/integration/agentmaxxing-onboarding-v0.1.0`  
**Task worktree:** `/home/andy/src/.worktrees/942a1/osramp-demo` (detached HEAD)

---

## 1. Executive Summary & Verdict

`AMXO-P4-4` implements streaming artifact hashing and kernel-backed post-read identity validation (TOCTOU mitigation) within the `agentmaxxing-host-sensor` package.

### Key Capabilities Verified
1. **Streaming SHA-256 Hasher (`BoundedArtifactHasher`):**
   - Hashes exclusively through validated open file descriptors (`fstat`, `statx`).
   - Streams in bounded 64 KiB chunks without buffering whole files in memory.
   - Derives opaque `hmac-sha256:` artifact identifiers, preventing exposure of raw host filesystem paths.
2. **Strict Size & Rate Limiting (`RateLimiter`):**
   - Enforces default 16 MiB (16,777,216 bytes) file size ceiling (configurable up to 100 MiB).
   - Enforces sliding 60-second window limits of max 120 files and max 64 MiB (67,108,864 bytes).
   - Rejects candidate files before reading and aborts mid-stream if concurrent append expands file beyond cap.
3. **Pre-Read Structural Validation:**
   - Rejects non-regular files (`stat.S_ISREG` check: directories, devices, fifos, sockets).
   - Rejects files with multiple hard links (`st_nlink != 1`).
   - Rejects mount crossings (`statx(STATX_MNT_ID)` check against root descriptor).
   - Uses `openat2()` with `RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_XDEV`.
4. **Post-Read Identity Revalidation (TOCTOU Detection & Rejection):**
   - Re-queries `fstat` and `statx` on the open descriptor after stream EOF.
   - Compares `st_ino`, `st_dev`, `stx_mnt_id`, `st_nlink`, `st_size`, `st_mtime_ns`, and `st_ctime_ns`.
   - On any divergence (truncation, append, replacement, unlinking, hardlinking, timestamp mutation), instantly discards digest (`sha256 = None`) and marks evidence as `unobserved` with explicit reason codes (`toctou_truncation_detected`, `toctou_mutation_detected`, `toctou_replacement_detected`, `toctou_link_tamper_detected`).
5. **Test Harness & Automation:**
   - 17 pytest unit and concurrency tests in `d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py`.
   - 2 integration tests in `d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py`.
   - 6 BATS tests in `test/signalloom/hasher-toctou.bats`.
   - Unified target `make demo-agentmaxxing-host-test` passing with zero errors.

---

## 2. Prompt-to-Artifact Verification Checklist

| Requirement | Evidence / Probe | Result |
| :--- | :--- | :---: |
| Isolated runtime worktree | Worktree `/home/andy/src/.worktrees/942a1/osramp-demo` | PASS |
| Integration ancestry | `git merge-base --is-ancestor integration/agentmaxxing-onboarding-v0.1.0 HEAD` exited `0` | PASS |
| Bounded streaming hasher | `d2-signalloom/apps/agentmaxxing-host-sensor/hasher.py` (`BoundedArtifactHasher`) | PASS |
| Rate & size limiter | `d2-signalloom/apps/agentmaxxing-host-sensor/ratelimit.py` (`RateLimiter`) | PASS |
| Syscall bindings | `d2-signalloom/apps/agentmaxxing-host-sensor/openat2.py` (`openat2`, `statx`) | PASS |
| CLI test interface | `d2-signalloom/apps/agentmaxxing-host-sensor/cli.py` | PASS |
| Concurrency pytest suite | `d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py` (17 passed) | PASS |
| Backend audit integration | `d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py -k test_toctou` (2 passed) | PASS |
| BATS CLI test harness | `test/signalloom/hasher-toctou.bats` (6 passed) | PASS |
| Makefile aggregation | `make demo-agentmaxxing-host-test` exits `0` | PASS |
| Zero customer payload leak | Payloads uninspected; hashes only validated descriptor; opaque HMAC-SHA256 IDs | PASS |
| Evidence report | `docs/signalloom/amxo-p4-4-evidence.md` | PASS |
| Proof artifact | `docs/signalloom/amxo-p4-4-proof.md` | PASS |
| Proposal errata entry | Appended `#### Errata — AMXO-P4-4` with `status=pass` | PASS |
| Decomposition table updated | Updated row `P4-4` in proposal with delivered commit | PASS |

---

## 3. Verification Command Output

### Command: `make demo-agentmaxxing-host-test`

```
python3 -m pytest -o cache_dir=/tmp/pytest_cache_sensor -v d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py
============================= test session starts ==============================
platform linux -- Python 3.14.4, pytest-9.1.1, pluggy-1.6.0
cachedir: /tmp/pytest_cache_sensor
rootdir: /home/andy/src/.worktrees/942a1/osramp-demo
plugins: anyio-4.14.2
collecting ... collected 17 items

d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py::TestBasicHashingAndCorrectness::test_hash_small_regular_file PASSED [  5%]
d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py::TestBasicHashingAndCorrectness::test_hash_multi_chunk_file PASSED [ 11%]
d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py::TestBasicHashingAndCorrectness::test_hash_empty_file PASSED [ 17%]
d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py::TestPreReadEligibilityChecks::test_reject_directory PASSED [ 23%]
d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py::TestPreReadEligibilityChecks::test_reject_symlink PASSED [ 29%]
d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py::TestPreReadEligibilityChecks::test_reject_directory_escape PASSED [ 35%]
d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py::TestPreReadEligibilityChecks::test_reject_hardlink_multiple PASSED [ 41%]
d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py::TestPreReadEligibilityChecks::test_reject_fifo_pipe PASSED [ 47%]
d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py::TestFileSizeAndRateLimits::test_reject_oversize_pre_read PASSED [ 52%]
d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py::TestFileSizeAndRateLimits::test_reject_file_count_rate_limit PASSED [ 58%]
d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py::TestFileSizeAndRateLimits::test_reject_byte_throughput_rate_limit PASSED [ 64%]
d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py::TestTOCTOUConcurrencyAndRaces::test_concurrent_file_truncation_during_hash PASSED [ 70%]
d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py::TestTOCTOUConcurrencyAndRaces::test_concurrent_file_append_during_hash PASSED [ 76%]
d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py::TestTOCTOUConcurrencyAndRaces::test_concurrent_file_unlinking_during_hash PASSED [ 82%]
d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py::TestTOCTOUConcurrencyAndRaces::test_concurrent_hardlink_creation_during_hash PASSED [ 88%]
d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py::TestTOCTOUConcurrencyAndRaces::test_concurrent_mtime_touch_during_hash PASSED [ 94%]
d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py::TestTOCTOUConcurrencyAndRaces::test_multithreaded_concurrency_stress PASSED [100%]

============================== 17 passed in 0.08s ==============================

PYTHONPATH=d2-signalloom/apps/fe-signalloom/src python3 -m pytest -o cache_dir=/tmp/pytest_cache_fe -v d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py -k test_toctou
============================= test session starts ==============================
platform linux -- Python 3.14.4, pytest-9.1.1, pluggy-1.6.0
cachedir: /tmp/pytest_cache_fe
rootdir: /home/andy/src/.worktrees/942a1/osramp-demo/d2-signalloom/apps/fe-signalloom/src
configfile: pytest.ini
plugins: anyio-4.14.2
collecting ... collected 17 items / 15 deselected / 2 selected

d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py::test_toctou_artifact_rejection_and_unobserved_classification PASSED [ 50%]
d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py::test_toctou_sensor_hasher_integration PASSED [100%]

================= 2 passed, 15 deselected, 1 warning in 0.63s ==================

bats test/signalloom/hasher-toctou.bats
hasher-toctou.bats
   hasher CLI hashes clean regular file with matching SHA-256 [PASS]
   hasher CLI rejects path traversal escape above root (RESOLVE_BENEATH) [PASS]
   hasher CLI rejects symbolic links [PASS]
   hasher CLI rejects files with multiple hard links [PASS]
   hasher CLI rejects oversize file exceeding max-file-size threshold [PASS]
   hasher CLI enforces sliding window file count rate limit [PASS]

6 tests, 0 failures
```

---

## 4. Conclusion

All requirements for card `AMXO-P4-4` are satisfied and verified against the repository codebase. The bounded streaming artifact hasher, sliding window rate limiter, and TOCTOU post-read identity validator operate with deterministic error handling, zero payload leakage, and full kernel descriptor isolation.
