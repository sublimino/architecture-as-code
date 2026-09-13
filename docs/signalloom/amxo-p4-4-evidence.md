# AMXO-P4-4 Evidence Report: Bounded Hasher and Post-Read Identity Validation (TOCTOU)

- **Task:** `AMXO-P4-4`
- **Role:** `implementation`
- **Subject:** Bounded artifact hashing, rate-limiting, and post-read identity revalidation (TOCTOU prevention) in `agentmaxxing-host-sensor`
- **Status:** PASS
- **Target Command:** `make demo-agentmaxxing-host-test`

---

## 1. Architectural Summary & Defense-in-Depth

The AgentMaxxing host sensor enforces strict descriptor-relative isolation, bounded resource limits, and kernel-backed TOCTOU (Time-of-Check to Time-of-Use) validation for all hashed disk artifacts.

```
                    ┌────────────────────────────────────────────────────────┐
                    │ Approved Root Descriptor (e.g. /var/lib/agentmaxxing)  │
                    └──────────────────────────┬─────────────────────────────┘
                                               │
                                               ▼
                              openat2(RESOLVE_BENEATH |
                                      RESOLVE_NO_SYMLINKS |
                                      RESOLVE_NO_XDEV)
                                               │
                                               ▼
                                 [ Open File Descriptor ]
                                               │
               ┌───────────────────────────────┴───────────────────────────────┐
               │                                                               │
               ▼                                                               ▼
    [ 1. Pre-Read Validation ]                                     [ 2. Rate Limiting Gate ]
    - fstat: S_ISREG == True (regular file)                        - File size <= 16 MiB (max 100 MiB)
    - fstat: st_nlink == 1 (no hardlinks)                          - Window count <= 120 files / 60s
    - statx: stx_mnt_id == root_mnt_id                             - Throughput <= 64 MiB / 60s
    - Snapshot: (ino, dev, mnt, nlink, size, mtime, ctime)                     │
               │                                                               │
               └───────────────────────────────┬───────────────────────────────┘
                                               │
                                               ▼
                                  [ 3. Chunked Streaming Read ]
                                  - 64 KiB bounded buffer chunks
                                  - Abort if stream > max_file_size
                                  - Accumulate total_bytes_read
                                               │
                                               ▼
                                  [ 4. Post-Read Validation ]
                                  - fstat & statx re-query on open fd
                                  - Check: post.ino == pre.ino
                                  - Check: post.dev == pre.dev
                                  - Check: post.mnt_id == pre.mnt_id
                                  - Check: post.nlink == 1
                                  - Check: post.size == pre.size == total_bytes_read
                                  - Check: post.mtime_ns == pre.mtime_ns
                                  - Check: post.ctime_ns == pre.ctime_ns
                                               │
                    ┌──────────────────────────┴──────────────────────────┐
                    │                                                     │
                    ▼                                                     ▼
           [ ALL MATCH: PASS ]                                   [ ANY MISMATCH: REJECT ]
           - observation_state: observed                         - observation_state: unobserved
           - integrity_state: verified                           - integrity_state: unverified
           - sha256: <hexdigest>                                 - sha256: None (DISCARDED)
           - Commit to rate limiter                              - reason_code: toctou_*_detected
```

---

## 2. TOCTOU Mitigation Mechanics & Protection Invariants

| Attack / Race Vector | Kernel / Sensor Protection Mechanism | Detection Phase | Resulting Telemetry State |
| :--- | :--- | :--- | :--- |
| **Path Traversal Escape** | `openat2()` with `RESOLVE_BENEATH` and `RESOLVE_NO_XDEV` | Pre-open | `denied`, `reason_code: openat2_escape_rejected`, `sha256: null` |
| **Symlink Substitution** | `openat2()` with `RESOLVE_NO_SYMLINKS` | Pre-open | `denied`, `reason_code: openat2_escape_rejected`, `sha256: null` |
| **Directory / Device Node** | `fstat()` verifies `stat.S_ISREG(st_mode)` | Pre-read | `denied`, `reason_code: not_regular_file`, `sha256: null` |
| **Multiple Hard Links** | `fstat()` verifies `st_nlink == 1` | Pre-read | `denied`, `reason_code: hardlink_forbidden`, `sha256: null` |
| **Mount Crossing** | `statx(STATX_MNT_ID)` matches approved root mount | Pre-read | `denied`, `reason_code: cross_mount_forbidden`, `sha256: null` |
| **Oversize Payload** | `st_size <= max_file_size_bytes` | Pre-read & Mid-stream | `unobserved`, `reason_code: max_file_size_exceeded`, `sha256: null` |
| **Rate Limit Exhaustion** | Sliding 60s window tracking files and byte volume | Pre-read | `unobserved`, `reason_code: max_files_per_window_exceeded` / `max_bytes_per_window_exceeded`, `sha256: null` |
| **Concurrent Truncation** | Stream `total_bytes_read != pre.size` or post `st_size != pre.size` | Post-read | `unobserved`, `reason_code: toctou_truncation_detected`, `sha256: null` |
| **Concurrent Append** | Stream `total_bytes_read > pre.size` or post `st_size != pre.size` | Post-read | `unobserved`, `reason_code: toctou_append_detected`, `sha256: null` |
| **Concurrent File Replacement** | Post-hash `fstat()` detects `st_ino != pre.ino` | Post-read | `unobserved`, `reason_code: toctou_replacement_detected`, `sha256: null` |
| **Concurrent Unlink** | Post-hash `fstat()` detects `st_nlink == 0` | Post-read | `unobserved`, `reason_code: toctou_link_tamper_detected`, `sha256: null` |
| **Concurrent Hardlink** | Post-hash `fstat()` detects `st_nlink > 1` | Post-read | `unobserved`, `reason_code: toctou_link_tamper_detected`, `sha256: null` |
| **Concurrent Mutation (mtime)** | Post-hash `fstat()` detects `st_mtime_ns != pre.mtime_ns` | Post-read | `unobserved`, `reason_code: toctou_mutation_detected`, `sha256: null` |
| **Concurrent Metadata Touch (ctime)** | Post-hash `fstat()` detects `st_ctime_ns != pre.ctime_ns` | Post-read | `unobserved`, `reason_code: toctou_metadata_tamper_detected`, `sha256: null` |

---

## 3. Test Execution Verification

### 3.1 Suite Output: `make demo-agentmaxxing-host-test`

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

## 4. Invariant Confirmation

1. **Zero Customer Content / Payload Leakage:** The hasher never exposes raw file buffers, payload streams, or command memory. Artifacts are exported purely as opaque `hmac-sha256:...` identifiers paired with SHA-256 digests and file sizes.
2. **Deterministic Rejection:** Any mid-stream filesystem tampering results in instantaneous digest disposal (`sha256 = None`) and classification as `unobserved` / `unverified`.
3. **Descriptor Pinning:** Strings are never reopened after validation; hashing proceeds strictly through validated open descriptors using kernel VFS guarantees.
