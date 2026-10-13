# Kusari pilot: the five malicious agent behaviours and how the platform detects them

This page is the walkthrough for the runtime adversarial behaviours the
`kusari-agent` stub performs and the detection each one is meant to produce. The
reader is a Kusari or ControlPlane engineer who wants to run the behaviours,
watch the detections fire, or add a new behaviour. Sibling page:
[kusari-e2e](kusari-e2e.md) covers the AWS/CloudTrail signal path. This page
covers the node-runtime path through the `stun-sentinel` correlator.

## Why this exists

"The platform catches bad agents" has to be a gate, not a claim. The stub
(`d2-signalloom/apps/kusari-agent`) deliberately misbehaves. The sentinel's eBPF
probe observes the kernel signal independently of anything the agent reports, and
the correlator turns that into a detection. A single coverage test drives every
behaviour and fails unless every corresponding detection has fired.

## The behaviours and their detections

Each behaviour is a POST-only `/act/*` route on the stub. The detection is what
the `stun-sentinel` correlator emits for the kernel signal the action produces.

| Behaviour (stub route) | Kernel signal | Detection |
|---|---|---|
| `/act/gpu-open` | `openat("/dev/nvidiactl", O_RDONLY)` | sensitive-path open on a GPU control node (`gpu_control_access`) |
| `/act/gpu-open?write=1` | `openat("/dev/nvidiactl", O_RDWR)` | same, plus the `write_mode=true` label — write-intent, distinct from a read (`gpu_control_write`) |
| `/act/gpu-probe` | `openat("/proc/driver/nvidia/version", ...)` | GPU-mount discovery (`gpu_mount_probe`) |
| `/act/exfil` | `connect(<paste-service IP>:443)` | egress connect to an off-cluster destination (`exfil_egress`) |
| `/act/kube-enum` | `openat(<SA token>)` + `connect(kubernetes.default.svc:443)` | service-account token read (`kube_sa_token_read`) + apiserver egress (`kube_api_egress`) |
| `/act/recon` | `openat("/proc/1/root/...", "/proc/sys/kernel/...", "/etc/kubernetes/...")` | container-escape / host recon (`proc_etc_recon`) |

Five behaviours produce seven distinct detections. The GPU behaviour yields
access, write, and mount-probe, while the kube behaviour yields token-read and
egress.

## How write-intent is detected without a wire-format change

The probe captures the `openat(2)` flags argument into four bytes the
`syscall_event_t` struct already reserved as padding (offset 36, between `dport`
and `daddr`). The record stays 344 bytes and every pinned offset is unchanged, so
the layout contract (`TestSyscallEventLayoutMatchesBTF`) is untouched. The
correlator derives `write_mode` from the access-mode bits (`O_WRONLY`/`O_RDWR`)
and labels the observation. A record from a probe built before this change
carries zero there, which reads as `O_RDONLY` — no false positive. The
`write_mode` label rides the sentinel observation and the stdout audit line. It
is not forwarded to signal-ingest's store (`toIngest` forwards a fixed key set),
just as the `opener` identity is not.

## Sensitive-path table

The GPU, `/proc` and `/etc` targets are added to
`correlator.DefaultSensitivePrefixes` — the ONE source of the table.
`bpf/sensitive_prefixes.h` (the kernel prefilter's copy) is regenerated from it
with `go run ./cmd/gen-sensitive-prefixes`, and
`prefilter_agreement_test.go` compiles that header natively and proves it agrees
with `IsSensitivePath`. Matching is component-exact: `/dev/nvidiactl` covers
`/dev/nvidiactl` and anything beneath it, not `/dev/nvidiactlX`. Each GPU device
node is therefore enumerated.

## Running it

The detection-coverage gate (offline, deterministic):

```
make test-kusari-behaviours
# coverage: all 7 kusari detections fired over 25 runs
```

It drives each behaviour through the real correlator N times and classifies each
resulting observation. It fails if any detection never fired OR if any
observation matched no behaviour (over-trigger). A companion mutation test
removes `/dev/nvidiactl` from the table and asserts the GPU detection stops, so
the gate cannot pass vacuously.

## What is deferred

- **In-kernel flags capture** — the probe C change is authored. However, it only
  fires on a node with the eBPF object rebuilt (needs the hermetic bpf toolchain).
  The correlator logic is proven here with synthetic records carrying the flags
  exactly as the probe would write them.
- **In-cluster live firing** — proving the detections on `kind-osramp` needs the
  rebuilt sentinel image deployed. Meanwhile, the coverage gate and the stub's
  own behaviour run on any host.
- **Post-detection response** — what the platform *does* once a detection fires
  (freeze vs network quarantine) is a separate decision. The behaviours split
  into local-resource-abuse (GPU, recon → cgroup action) and egress/exfil
  (pastebin, kube-enum → network quarantine). The current freeze path keys on
  `(syscall, target)` only and does not yet act on `write_mode` or egress.
