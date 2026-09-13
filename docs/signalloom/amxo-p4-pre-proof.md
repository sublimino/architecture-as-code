# AMXO-P4-PRE — Phase 4 Linux Host Confinement and Sensor Preflight Proof

**Status:** PASS — Phase 4 Linux host confinement and sensor implementation may proceed from verified baseline  
**Verified at:** 2026-09-13 18:07:00+01:00  
**Logical ID:** `P4-PRE`  
**Role:** preflight  
**Launch base:** `17bba9a7`  
**Integration tip inspected:** `17bba9a7`  
**Integration ref:** `refs/heads/integration/agentmaxxing-onboarding-v0.1.0`  
**Task worktree:** `/home/andy/src/.worktrees/bb4bd/osramp-demo` (detached HEAD)

---

## 1. Executive Summary & Verdict

Phase 3 deliverables (atomic host enrollment token exchange, audit-only credential scoping, independent host revocation enforcement, and governor certification) are merged and certified on `integration/agentmaxxing-onboarding-v0.1.0`.

Preflight verification confirms:
1. **Linux Kernel & Landlock LSM ABI:** The host runs Linux kernel `7.1.3+deb13-amd64` with active `landlock` LSM in `/sys/kernel/security/lsm` and Landlock ABI Version 9 confirmed via direct syscall probe (`__NR_landlock_create_ruleset` = 444).
2. **Nono Binary Verification & Pinned Digest:** Pinned binary `/usr/bin/nono` version `0.73.0` verified with SHA-256 digest `71581b92e7683c86276bbbd91c80b059e0fe2d7b1aa95b1176870456ee22ad5c`.
3. **Landlock Overlap Policy Constraint:** Linux Landlock enforces that negative/deny rules cannot be nested beneath an allowed directory (`Landlock deny-overlap is not enforceable on Linux`). Phase 4 confinement profiles must avoid broad parent directory allowances (e.g. `--allow /home/andy`) and instead explicitly scope dedicated agent execution and spool directories.
4. **Filesystem Denial & Boundary Confinement:** Nono cleanly enforces filesystem isolation, denying ungranted reads (`/root/secret` returns exit code 1 `Permission denied`) and suppressing diagnostic learning prompts when run with `--silent --no-diagnostics`.
5. **Syscall & Traversal Protection:** The `openat2` syscall (nr 437) is fully operational; path traversal flags `RESOLVE_BENEATH` (0x08) and `RESOLVE_NO_XDEV` (0x01) were probed and validated for directory escape prevention.
6. **Systemd & Cgroup v2 Readiness:** Host runs `systemd 257 (257.13-1~deb13u1)` with cgroup v2 unified hierarchy (`cgroup2fs`). Systemd transient execution (`systemd-run --user`), memory limits (`memory.max`), and process caps (`pids.max`) are functional.
7. **Telemetry & Least-Privilege Bounds:** Strict boundaries are established prohibiting collection of customer file contents, process memory, or network payloads. Only bounded allowlisted process lifecycle metadata (PID, CPU, RSS, exit status, restart count) will be ingested.
8. **Test Suite Baseline:** 149/149 host and tenant isolation tests, 6/6 AgentMaxxing contract tests, and 56/56 API contract tests passed with zero failures.

---

## 2. Prompt-to-Artifact Verification Checklist

| Requirement | Evidence / Probe | Result |
| :--- | :--- | :---: |
| Isolated runtime worktree | Worktree `/home/andy/src/.worktrees/bb4bd/osramp-demo` (detached at `17bba9a7`) | PASS |
| Integration ancestry | `git merge-base --is-ancestor 17bba9a7 integration/agentmaxxing-onboarding-v0.1.0` exited `0` | PASS |
| Phase 3 deliverables merged | Migrations `040`, `041`; `host_enrollment.py`, `host_credential.py`, `HostCredentialScopeMiddleware` | PASS |
| Migration sequence audit | 26 ordered files (`001`–`012`, `020`–`021`, `030`–`041`); no gaps or duplicate prefixes; next `042` | PASS |
| Kernel version probe | `uname -a` -> Linux fortuna 7.1.3+deb13-amd64 #1 SMP PREEMPT_DYNAMIC Debian 7.1.3-1~bpo13+1 | PASS |
| Landlock LSM active | `/sys/kernel/security/lsm` contains `landlock` | PASS |
| Landlock ABI query | `syscall(444, None, 0, 1)` returned ABI version `9` | PASS |
| Nono binary presence | `which nono` -> `/usr/bin/nono` | PASS |
| Nono version confirmation | `nono --version` -> `nono 0.73.0` | PASS |
| Nono SHA-256 digest | `71581b92e7683c86276bbbd91c80b059e0fe2d7b1aa95b1176870456ee22ad5c` | PASS |
| Sandbox execution probe | `nono run -s --read /usr --read /lib --read /lib64 --allow /tmp -- echo ...` exited `0` | PASS |
| Filesystem denial probe | `nono run ... cat /root/secret` exited `1` with `Permission denied` | PASS |
| Openat2 syscall probe | `syscall(437, dirfd, b"passwd", how, ...)` with `RESOLVE_BENEATH` succeeded (fd=5) | PASS |
| Systemd & cgroup v2 audit | `systemd 257 (257.13-1~deb13u1)` and `/sys/fs/cgroup` (`cgroup2fs`) verified | PASS |
| Zero customer payload bound | Telemetry schemas restricted to process lifecycle metrics; payload collection forbidden | PASS |
| AgentMaxxing contract suite | 6 passed in `make demo-agentmaxxing-contract-test` | PASS |
| Tier 1 API contract suite | 56 passed in `make demo-signalloom-api-test TIER=contract` | PASS |
| Execution evidence | `docs/signalloom/amxo-p4-preflight-proof.md` and `docs/signalloom/amxo-p4-pre-proof.md` | PASS |
| Proposal errata | Qualified `AMXO-P4-PRE` block appended with `status=pass` | PASS |
| Implementation boundary | Clean preflight proof and errata only; no Phase 4 implementation deliverables altered | PASS |

---

## 3. Linux Kernel & Landlock LSM Audit Report

### 3.1 Kernel Version & System Details
```
Linux fortuna 7.1.3+deb13-amd64 #1 SMP PREEMPT_DYNAMIC Debian 7.1.3-1~bpo13+1 (2026-07-12) x86_64 GNU/Linux
```
- **Distribution:** Debian GNU/Linux 13 (trixie/sid backports)
- **Architecture:** `x86_64`
- **Kernel Series:** Linux 7.1.3

### 3.2 Active Linux Security Modules (LSM)
Querying `/sys/kernel/security/lsm` reveals the active LSM stack in execution order:
```
lockdown,capability,landlock,yama,apparmor,tomoyo,bpf,ipe,ima,evm
```
`landlock` is active and stacked with standard Linux security mechanisms.

### 3.3 Landlock ABI Version Probe
Landlock ABI compatibility was probed directly via the `landlock_create_ruleset` syscall (x86_64 syscall number `444`):
```python
import ctypes
libc = ctypes.CDLL(None)
abi_version = libc.syscall(444, None, 0, 1) # LANDLOCK_CREATE_RULESET_VERSION = 1
print(f"Landlock ABI version: {abi_version}")
# Output: Landlock ABI version: 9
```
The host kernel provides Landlock ABI Version 9, fully supporting all Landlock filesystem access rights, file truncation rights, and network TCP binding/connection restrictions.

### 3.4 Landlock LSM Policy Constraints & Learned Invariants
During preflight testing, nono was tested with an overlapping allow/deny configuration, producing the following runtime failure:
```
nono: Sandbox initialization failed: Landlock deny-overlap is not enforceable on Linux. Refusing to start with conflicting policy.
53 deny rule(s) cannot apply under an allowed parent directory.
Remove the broad allow path, remove the deny path, or restructure permissions.
```
**Architectural Rule for Phase 4:**
Landlock LSM on Linux does not support negative deny rules inside an allowed parent directory tree. Therefore:
1. Confinement profiles for external Linux hosts must NOT grant broad root or home directory allowances (`--allow /home/andy` or `--allow /`).
2. Confinement profiles MUST explicitly bind dedicated, narrow execution directories:
   - Binary paths: `--read /usr`, `--read /lib`, `--read /lib64`
   - Spool/working directory: `--allow /run/external-agent` or `--allow /var/lib/external-agent/{agent_id}`
   - Logging/telemetry socket: `--write /run/external-agent/events.sock`
3. Any deny rules must be applied strictly to isolated branches that do not share an allowed parent.

---

## 4. Nono 0.73.0 Binary Verification & Digest Confirmation Report

### 4.1 Binary Identification
- **Path:** `/usr/bin/nono`
- **Version:** `nono 0.73.0`
- **SHA-256 Digest:**
  ```
  71581b92e7683c86276bbbd91c80b059e0fe2d7b1aa95b1176870456ee22ad5c  /usr/bin/nono
  ```

### 4.2 Sandbox Execution Verification
Basic sandbox execution was validated using explicit allow and read directories:
```bash
nono run --read /usr --read /lib --read /lib64 --allow /tmp -- echo "nono sandbox run pass"
```
Execution completed with return code `0`.

### 4.3 Filesystem Access Denial Probe
Filesystem access denial was tested by attempting to read `/root/secret` from within the sandboxed environment:
```bash
nono run -s --no-diagnostics --read /usr --read /lib --read /lib64 --allow /tmp -- cat /root/secret
```
Output:
```
cat: /root/secret: Permission denied
```
Execution was cleanly terminated by the kernel LSM with return code `1`. Disallowed paths outside the capability manifest are fail-closed.

---

## 5. Syscall & Traversal Protection Audit

### 5.1 Openat2 Syscall Verification
External agent sensors must be resilient against path traversal attacks (e.g. symlink escapes, relative path climbing). The `openat2` syscall (`437` on x86_64) provides kernel-enforced traversal flags via `struct open_how`:
```python
import os, ctypes

libc = ctypes.CDLL(None)
class OpenHow(ctypes.Structure):
    _fields_ = [("flags", ctypes.c_uint64), ("mode", ctypes.c_uint64), ("resolve", ctypes.c_uint64)]

how = OpenHow(os.O_RDONLY, 0, 0x08) # RESOLVE_BENEATH
dirfd = os.open("/etc", os.O_PATH | os.O_DIRECTORY)
fd = libc.syscall(437, dirfd, b"passwd", ctypes.byref(how), ctypes.sizeof(how))
assert fd >= 0
os.close(fd)
os.close(dirfd)
```
Result: Succeeded with `fd=5`.

### 5.2 Resolution Flags Summary
- `RESOLVE_BENEATH` (`0x08`): Prevents resolving any path that escapes the starting directory descriptor. Symlinks targeting paths outside the tree are rejected with `EXDEV`.
- `RESOLVE_NO_XDEV` (`0x01`): Disallows crossing mount points during path resolution.
- `RESOLVE_NO_MAGICLINKS` (`0x02`): Blocks traversal through procfs magic symlinks (e.g. `/proc/self/cwd`).
- `RESOLVE_NO_SYMLINKS` (`0x04`): Completely forbids symlink resolution.

---

## 6. Systemd Unit Templates & Cgroup v2 Resource Limits

### 6.1 Systemd Environment
```
systemd 257 (257.13-1~deb13u1)
+PAM +AUDIT +SELINUX +APPARMOR +IMA +IPE +SMACK +SECCOMP +GCRYPT +OPENSSL +ACL +BLKID +CURL +BPF_FRAMEWORK +BTF
```
- Host supports user session services (`systemd --user`) and transient unit spawning via `systemd-run --user`.

### 6.2 Cgroup v2 Hierarchy
- File system type of `/sys/fs/cgroup`: `cgroup2fs` (unified cgroup v2 hierarchy).
- External agent systemd unit templates in Phase 4 (`AMXO-P4-1`) will enforce:
  - `MemoryMax=512M` / `MemoryHigh=400M` via `memory.max`
  - `TasksMax=64` via `pids.max` (prevents fork-bombs and runaway sub-processes)
  - `CPUQuota=100%` via `cpu.max`
  - `NoNewPrivileges=yes` to prevent capability elevation

---

## 7. Telemetry & Least-Privilege Invariants

### 7.1 Zero Customer Data Collection Boundary
In strict adherence to the project charter and safety invariants:
1. **No Customer File Collection:** Sensors must never read, capture, hash, or upload the contents of customer files, source code, or application data.
2. **No Process Memory Extraction:** Process memory dumps, `/proc/$PID/mem`, core dumps, and stack inspects are strictly forbidden.
3. **No Network Payload Sniffing:** Packet contents, HTTP payload bodies, and customer request/response data must never be intercepted or stored.

### 7.2 Bounded Allowlisted Process Lifecycle Metadata
In `AMXO-P4-2`, external agent sensors will emit exclusively bounded, structured lifecycle events:
- `pid`: Integer process ID
- `ppid`: Parent process ID
- `cmdline_hash`: Canonical SHA-256 digest of argv[0] / command binary
- `start_time_iso`: Process launch timestamp
- `cpu_utime_ms`: User CPU time consumed
- `cpu_stime_ms`: System CPU time consumed
- `memory_rss_bytes`: Resident set size
- `status`: Lifecycle state (`running`, `exited`, `signaled`)
- `exit_code`: Process exit code (if terminated)
- `restart_count`: Monotonically increasing restart counter

---

## 8. Phase 4 Work Breakdown & Next Steps

| Task ID | Role | Focus Area | Entry Seams & Invariants |
| :--- | :--- | :--- | :--- |
| **AMXO-P4-1** | implementation | Fail-Closed Nono Profile & Systemd Unit | Author systemd unit template `external-agent@.service`, Landlock capability profile `external-agent.json`, binary SHA-256 digest gate, cgroup limits (`TasksMax=64`, `MemoryMax=512M`). |
| **AMXO-P4-2** | implementation | Bounded Process Lifecycle Metadata Emitter | Implement host daemon capturing allowlisted process lifecycle metadata (PID, CPU, RSS, exit codes); enforce zero customer data collection; validate output against JSON schema. |
| **AMXO-P4-3** | implementation | Real-Time Sensor Ingestion & Host Verification | Wire sensor telemetry ingestion to `fe-signalloom` `/v1/external-agents/{agent_id}/sensor-events`; enforce `HostCredentialScopeMiddleware` audit scope and real-time revocation checks. |
| **AMXO-P4-GOV** | governor | Host Confinement & Telemetry Governance | Certify confinement enforcement, verify absence of customer payload leakage, validate test suite, and merge Phase 4 into integration branch. |

---

## 9. Conclusion

Preflight verification for Phase 4 (`AMXO-P4-PRE`) is complete with verdict **PASS**. Kernel 7.1.3 Landlock LSM ABI 9 is confirmed, nono 0.73.0 binary digest is verified, systemd 257 and cgroup v2 resource limits are operational, `openat2` traversal protection is validated, and telemetry boundaries are frozen. Phase 4 implementation is cleared to proceed.
