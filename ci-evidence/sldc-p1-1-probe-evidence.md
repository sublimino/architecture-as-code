# SLDC-P1-1 — in-sentinel eBPF syscall probe: verification evidence

Captured 2026-09-30 05:55 +01:00 on host kernel `7.1.3+deb13-amd64`, toolchain
image `signalloom-bpf2go:trixie-go1.27` (clang 19.1.7, go 1.27, libbpf-dev).
Regenerate with `d2-signalloom/apps/stun-sentinel/bpf/build.sh sentinel` and
re-prove with `bpf/build.sh test` (privileged, `SENTINEL_REQUIRE_LIVE_BPF=1`).

## Artefacts

| File | sha256 |
|---|---|
| `bpf/sentinel_probe.o` (Makefile build, not committed) | `bbd8ede526edb67407170e208b568285ee487bcafe18768ecc343943e563c73e` |
| `pkg/ebpf/probe_bpfel.o` (embedded, committed) | `7cff3d5f5784420639081971d8534d7cf022745a1906a249c209cc705818849f` |
| `pkg/ebpf/probe_bpfeb.o` (embedded, committed) | `a3e40cb5e304a0f707fe70b02e3bd91e504c45c42755e3d16467e8287bdbf8f2` |

Two consecutive builds of the same source produced the same object hash, so
the compile is reproducible.

## ELF sections (`llvm-readelf -S bpf/sentinel_probe.o`)

```
[ 3] tracepoint/syscalls/sys_enter_openat   PROGBITS  AX
[ 5] tracepoint/syscalls/sys_enter_openat2  PROGBITS  AX
[ 7] tracepoint/syscalls/sys_enter_execve   PROGBITS  AX
[ 9] tracepoint/syscalls/sys_enter_connect  PROGBITS  AX
[14] .maps                                  PROGBITS  WA   (symbols: events, drops)
[25] .BTF  /  [27] .BTF.ext
```

## Verifier (live load, `LogLevelStats`): 0 rejections

```
sys_enter_openat   processed  90 insns (limit 1000000) total_states 6  stack depth 16
sys_enter_openat2  processed  90 insns (limit 1000000) total_states 6  stack depth 16
sys_enter_execve   processed  88 insns (limit 1000000) total_states 6  stack depth 16
sys_enter_connect  processed 142 insns (limit 1000000) total_states 9  stack depth 40
```

## Live tests (`bpf/build.sh test`, privileged): all PASS

```
--- PASS: TestCollectionSpecTracepointSections
--- PASS: TestSyscallEventLayoutMatchesBTF
--- PASS: TestRingBufMapProperties        kernel map: name=events type=RingBuf max_entries=16777216
--- PASS: TestDecodeSyscallEventOpenat
--- PASS: TestDecodeSyscallEventConnect   (ipv4, ipv6)
--- PASS: TestDecodeSyscallEventRejectsMalformed
--- PASS: TestSentinelProbeLoad           programs unloaded (IDs stop resolving) after Close
--- PASS: TestSentinelProbeSyscallCapture openat+execve+connect4+connect6 for child; self openat filtered; drops=0
--- PASS: TestLoaderLifecycleReleasesResources  25 load/stream/close cycles, 0 fd delta
ok  .../stun-sentinel/pkg/ebpf  25.5s
```

Whole module under privilege (`go test ./...`): 8 packages `ok`, 1 without tests, exit 0.
Unprivileged `go test ./pkg/ebpf/...`: tier-1 PASS, 4 live tests SKIP with reason.

## Mutation testing (scratch copy, rebuilt, `TestSentinelProbeSyscallCapture`)

| Mutation | Result | Failure |
|---|---|---|
| M1 comment out `bpf_ringbuf_submit` | FAIL rc=1 | verifier: `Unreleased reference id=3 … would lead to reference leak` |
| M2 `submit` → `bpf_ringbuf_discard` | FAIL rc=1 | `timed out: openat=false execve=false connect4=true connect6=true` |
| M3 self-filter returns 0 | FAIL rc=1 | `kernel self-filter leaked the test process's own openat` |
