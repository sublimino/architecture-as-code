# AMXO-P4-3 descriptor-relative artifact eligibility proof

**Evidence captured:** 2026-09-13T18:20:00+01:00  
**Task:** AMXO-P4-3 (Enforce descriptor-relative artifact eligibility before reading bytes in the host sensor)  
**Integration ref:** `refs/heads/integration/agentmaxxing-onboarding-v0.1.0`  

## Prompt-to-artifact checklist

| Required outcome | Artifact | Positive evidence |
| :--- | :--- | :--- |
| Descriptor-relative file opener and validator | `d2-signalloom/apps/agentmaxxing-host-sensor/file_validator.py` | `PinnedRoot`, `openat2_validate`, `validate_and_hash`, `RESOLVE_BENEATH`, `RESOLVE_NO_SYMLINKS`, `RESOLVE_NO_XDEV` |
| Pre-read regular file verification | `file_validator.py`, `test_file_validator.py` | `stat.S_ISREG` check rejects directories, symlinks, FIFOs, character/block devices, sockets before read |
| Pre-read hard-link verification | `file_validator.py`, `test_file_validator.py` | `st_nlink == 1` check rejects hard-linked files with `HARDLINK_REJECTED` before read |
| Pre-read mount-boundary verification | `file_validator.py`, `test_file_validator.py` | `statx` `stx_mnt_id` comparison against `root_mnt_id` rejects mount crossings before read |
| Adversarial test suite | `d2-signalloom/apps/agentmaxxing-host-sensor/test_file_validator.py` | 16/16 test cases passing covering symlink traps, traversal escapes, hardlinks, FIFOs, oversize, mutations |
| Independent zero-bytes-read proof | `test_file_validator.py` | `test_independent_canary_proof_zero_reads` asserts `read()` called 0 times for all ineligible targets |
| Integration anti-escape tests | `d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py` | `test_anti_escape_descriptor_relative_validation` passing with pytest `-k test_anti_escape` |
| BATS test suite | `test/signalloom/file-validator-anti-escape.bats` | 9/9 BATS tests passing covering CLI execution and error handling |
| Make target | `Makefile` | `make demo-agentmaxxing-host-test` target running host validator and BATS suites |
| Syscall audit log | `file_validator.py` | `GLOBAL_AUDIT_LOGGER` records `openat2` and `statx` with exact resolve flags |
| Evidence report | `docs/signalloom/amxo-p4-3-evidence.md` | Verification evidence and test ledger |

## Required commands

```bash
make demo-agentmaxxing-host-test
python3 -m pytest -v d2-signalloom/apps/agentmaxxing-host-sensor/test_file_validator.py
python3 -m pytest d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py -k test_anti_escape
test -f docs/signalloom/amxo-p4-3-evidence.md
test -f docs/signalloom/amxo-p4-3-proof.md
bats test/signalloom/file-validator-anti-escape.bats
```

## Scope and safety gates

```text
WORKTREE=/home/andy/src/.worktrees/af50e/osramp-demo
BASE_REF_GATE=PASS
```

No remote repositories were touched, no branches pushed, and no sibling worktrees modified.
