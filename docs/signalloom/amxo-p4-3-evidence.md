# AMXO-P4-3 verification evidence

**Recorded:** 2026-09-13T18:20:00+01:00  
**Scope:** Descriptor-relative artifact eligibility enforcement and anti-escape filesystem validation in `agentmaxxing-host-sensor`.

## Test ledger

| Command | Outcome | Skips | Evidence |
| :--- | :--- | :--- | :--- |
| `make demo-agentmaxxing-host-test` | 16 pytest + 9 bats passed | 0 | Full host sensor suite verifying descriptor-relative openat2 resolution, pre-read criteria, adversarial traps, zero-read assertions, and BATS integration |
| `python3 -m pytest -v d2-signalloom/apps/agentmaxxing-host-sensor/test_file_validator.py` | 16 passed | 0 | Unit & adversarial matrix: valid regular files, symlinks (inside/outside/nested/dangling), path traversal (`..`), absolute paths, hard links (`nlink > 1`), directories, FIFOs, oversize files, TOCTOU mutations, canary zero-read verification, and kernel syscall audit log |
| `python3 -m pytest -v d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py -k test_anti_escape` | 1 passed | 0 | Anti-escape descriptor-relative integration assertions in `fe-signalloom` test suite |
| `bats test/signalloom/file-validator-anti-escape.bats` | 9 passed | 0 | BATS CLI & execution harness for positive hashing, symlink/hardlink/traversal/device rejection, and 0 bytes read proofs |
| `make demo-agentmaxxing-contract-test` | 6 passed | 0 | Attributable operator identity and governance lifecycle contracts |
| `make demo-signalloom-api-test TIER=contract` | 56 passed | 0 | FastAPI tier 1 contract routes and all database migrations |
| `git diff --check` | passed | n/a | Clean diff formatting with zero whitespace errors |

## Verification details

1. **Descriptor-Relative `openat2()` Implementation (`file_validator.py`)**:
   - Pinned directory descriptor initialization via `PinnedRoot(root_path)` opening with `O_PATH | os.O_DIRECTORY | os.O_CLOEXEC` (or `O_RDONLY`).
   - Syscall wrapper invoking Linux `openat2` (nr 437) using `struct open_how` with exact resolution flags:
     - `RESOLVE_BENEATH` (`0x08`): Restricts path resolution strictly beneath the pinned directory descriptor, returning `EXDEV` on directory escape attempts.
     - `RESOLVE_NO_SYMLINKS` (`0x04`): Completely forbids resolving symbolic links, returning `ELOOP` on symlinks.
     - `RESOLVE_NO_XDEV` (`0x01`): Disallows crossing mount points during path resolution, returning `EXDEV`.
   - Open flags set to `O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK` to prevent hanging on FIFOs or blocking special devices.

2. **Pre-Read Descriptor & Identity Verification**:
   - Kernel `statx` syscall (`__NR_statx` = 332) invoked with `AT_EMPTY_PATH` and `STATX_BASIC_STATS | STATX_MNT_ID`.
   - Regular file verification (`stat.S_ISREG`): Rejects directories (`S_ISDIR`), symbolic links (`S_ISLNK`), FIFOs (`S_ISFIFO`), character/block devices (`S_ISCHR`/`S_ISBLK`), and UNIX sockets (`S_ISSOCK`) before invoking `read()`.
   - Link count verification (`st_nlink == 1`): Rejects hard-linked files (`st_nlink > 1` or `st_nlink == 0`) with `HARDLINK_REJECTED` before reading bytes.
   - Mount boundary verification: Compares candidate `stx_mnt_id` against `root_mnt_id` obtained at root pinning; rejects crossing attempts with `MOUNT_CROSSING_REJECTED`.
   - Size bounds enforcement: Pre-read size check against configured limit (`DEFAULT_MAX_FILE_SIZE_BYTES = 16 MiB`); oversized targets are rejected with `OVERSIZE_REJECTED` before reading.

3. **Safe Bounded Reading & Post-Read TOCTOU Validation**:
   - Reading occurs strictly through the validated file descriptor in 64 KiB chunks (`READ_CHUNK_SIZE`), streaming directly to `hashlib.sha256()`.
   - Cumulative byte counter enforces size limit during streaming.
   - Post-read `statx` re-query asserts exact match against pre-read identity snapshot (`inode`, `mount_id`, `link_count`, `size_bytes`, `mtime_sec`/`nsec`, `ctime_sec`/`nsec`).
   - Any mutation, truncation, or replacement during the read stream immediately invalidates the digest with `CHANGED_DURING_READ`.

4. **Adversarial Traps & Independent Zero-Bytes-Read Proof**:
   - Evaluated 9 distinct adversarial trap categories in `test_independent_canary_proof_zero_reads` using an instrumented `canary_read` wrapper:
     1. Symlink targeting internal file (`canary_sym_in`) -> `RejectionReason.SYMLINK_REJECTED`, 0 bytes read.
     2. Symlink targeting external file (`canary_sym_out`) -> `RejectionReason.SYMLINK_REJECTED`, 0 bytes read.
     3. Parent directory traversal (`../../../etc/shadow`) -> `RejectionReason.ESCAPE_REJECTED`, 0 bytes read.
     4. Absolute path escape (`/etc/hosts`) -> `RejectionReason.ESCAPE_REJECTED`, 0 bytes read.
     5. Hard-link escape (`canary_hardlink`, `nlink=2`) -> `RejectionReason.HARDLINK_REJECTED`, 0 bytes read.
     6. Directory target (`canary_dir`) -> `RejectionReason.DIRECTORY_REJECTED`, 0 bytes read.
     7. FIFO named pipe (`canary_fifo`) -> `RejectionReason.FIFO_REJECTED`, 0 bytes read (no hang).
     8. Oversize file (`canary_oversize`) -> `RejectionReason.OVERSIZE_REJECTED`, 0 bytes read.
     9. Non-existent file -> `RejectionReason.FILE_NOT_FOUND`, 0 bytes read.
   - Proved that `read()` was invoked exactly `0` times and `0` bytes were accessed across all ineligible targets.

5. **Kernel Syscall Audit Log Verification**:
   - Verified that `GLOBAL_AUDIT_LOGGER` records `openat2` calls with `resolve_flags` matching `RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_XDEV` (0x0D mask).

## Delivery boundaries

- No remote push performed.
- No merge or rebase performed.
- No runtime deployment performed.
- No project-board state changed.
- No sibling worktree changed.
