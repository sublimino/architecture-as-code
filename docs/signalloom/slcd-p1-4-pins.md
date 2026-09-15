# SLCD-P1-4: Prohibited Procfs Entries Pin Matrix & Exe Resolution

## Overview

This document records the completed security pin coverage for every entry in `PROHIBITED_PROC_ENTRIES` within `d2-signalloom/apps/agentmaxxing-host-sensor/proc.py`.

Under the **Strict Zero-Customer-Payload Invariant**, the host sensor daemon must never read process memory, command-line arguments, environment variables, or private descriptor states that could leak prompt text, user code, or authentication tokens.

## Why `fd`, `fdinfo`, and `net` Are Pinned Before Detector Feature Work

In earlier iterations, `fd`, `fdinfo`, and `net` were listed in `PROHIBITED_PROC_ENTRIES` in `proc.py`, but lacked negative tests in `test_negative_security.py`.

P4-2's planned socket attribution detector matches socket inodes without TLS interception. Without explicit negative test pins on `fd`, `fdinfo`, and `net`, an implementation could silently remove `fd` or `net` from `PROHIBITED_PROC_ENTRIES` to read `/proc/<pid>/fd/`, passing the test suite without any failing security assertions.

SLCD-P1-4 introduces individual, named test methods for `fd`, `fdinfo`, `net`, `io`, `cwd`, `root`, and `attr` before any socket attribution code is written. Any future attempt to delete or weaken these prohibitions will immediately break CI.

## Exe-Based Binary Basename Resolution vs. `cmdline` Carve-Out

The initial mission proposal considered a `cmdline` exception for "bounded binary basename resolution". However:
1. `/proc/<pid>/cmdline` contains the entire command invocation, including flags such as `--token=SECRET_BEARER_TOKEN` or private script arguments. Any read of `cmdline` risks secret exposure if parsing fails or logs leak.
2. Linux procfs already exposes `/proc/<pid>/exe`, which is a symlink directly referencing the executing binary ELF image.
3. `/proc/<pid>/exe` is not prohibited. Resolving its basename via `os.readlink()` provides 100% accurate binary identity (even for renamed or symlinked binaries) while structurally preventing any access to invocation arguments.
4. `ProcReader.read_exe` and `ProcReader.read_exe_basename` implement this resolution safely, stripping ` (deleted)` annotations for unlinked binaries and gracefully returning `None` for missing, unreadable, or kernel-thread processes without ever touching `cmdline`.

## Pin Coverage Matrix

Every member of `PROHIBITED_PROC_ENTRIES` (17 entries total) is verified by test suite assertions in `d2-signalloom/apps/agentmaxxing-host-sensor/test_negative_security.py`.

| # | Procfs Entry | Prohibited Reason & Threat Model | Test Type | Test Method Name in `test_negative_security.py` |
|---|---|---|---|---|
| 1 | `mem` | Raw process virtual memory dump (exposes all in-memory secrets/prompts) | Individual | `test_prohibit_procfs_memory_inspection` |
| 2 | `environ` | Process environment variables (exposes AWS/API keys, bearer tokens) | Individual | `test_prohibit_procfs_environ_inspection` |
| 3 | `cmdline` | Command-line arguments (exposes flags with passwords, tokens, URLs) | Individual | `test_prohibit_procfs_cmdline_inspection` |
| 4 | `fd` | File descriptors (exposes open file handles, private sockets, pipes) | Individual | `test_prohibit_procfs_fd_inspection` |
| 5 | `fdinfo` | File descriptor metadata (exposes seek offsets, lock flags, mount IDs) | Individual | `test_prohibit_procfs_fdinfo_inspection` |
| 6 | `net` | Per-process network namespace directory (exposes raw packet/flow data) | Individual | `test_prohibit_procfs_net_inspection` |
| 7 | `io` | I/O accounting stats (can enable side-channel timing analysis) | Individual | `test_prohibit_procfs_io_inspection` |
| 8 | `cwd` | Current working directory symlink (exposes proprietary filesystem paths) | Individual | `test_prohibit_procfs_cwd_inspection` |
| 9 | `root` | Process root directory symlink (exposes chroot / container escape paths) | Individual | `test_prohibit_procfs_root_inspection` |
| 10 | `attr` | Security attributes directory (SELinux/AppArmor security contexts) | Individual | `test_prohibit_procfs_attr_inspection` |
| 11 | `maps` | Virtual memory area mappings (exposes ASLR layout and loaded library paths) | SubTest | `test_prohibit_procfs_maps_and_stack_inspection` |
| 12 | `smaps` | Detailed memory consumption per mapping (exposes memory layout) | SubTest | `test_prohibit_procfs_maps_and_stack_inspection` |
| 13 | `smaps_rollup` | Consolidated memory consumption rollup (exposes memory mapping data) | SubTest | `test_prohibit_procfs_maps_and_stack_inspection` |
| 14 | `stack` | Kernel call stack trace (exposes kernel addresses and stack execution) | SubTest | `test_prohibit_procfs_maps_and_stack_inspection` |
| 15 | `syscall` | Currently executing system call and arguments (exposes live syscall args) | SubTest | `test_prohibit_procfs_maps_and_stack_inspection` |
| 16 | `pagemap` | Page table mappings (exposes physical page frame numbers) | SubTest | `test_prohibit_procfs_maps_and_stack_inspection` |
| 17 | `clear_refs` | Control interface to reset page reference bits (mutating operation) | SubTest | `test_prohibit_procfs_maps_and_stack_inspection` |

## Binary Basename & Exe Resolution Tests

| Test Purpose | Test Type | Test Method Name in `test_negative_security.py` |
|---|---|---|
| Never fall back to `cmdline` even with secret tokens present | Negative Security | `test_exe_basename_resolution_never_reads_cmdline_secrets` |
| Correct resolution of renamed or symlinked binary targets | Functional Unit | `test_exe_basename_resolution_renamed_binary_target` |
| Safe resolution of unlinked binaries with ` (deleted)` suffix | Functional Unit | `test_exe_resolution_handles_deleted_binary` |

## Verification Command

To verify all security pins and unit tests:

```bash
cd d2-signalloom/apps/agentmaxxing-host-sensor && python3 -m unittest discover -p 'test_*.py' -v
```
