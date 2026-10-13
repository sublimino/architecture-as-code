# eBPF endpoint telemetry: OLD (Tetragon gRPC client) vs NEW (own-eBPF)

This page compares the two shapes the signal-ingest `collectors/ebpf` endpoint
collector has taken, and records what the live-wiring in this card changed. The
OLD shape is reconstructed from git history. The de-Tetragon work landed on
`feat/fu-de-tetragon`, merged at `ccd6e1c2`. It included the collector refactor
in `3698c23f` and the dependency/agent removal in `4a0a767b`. The deleted files
(`client.go`, `normalize.go`, `jsonstream.go`, `ringbuffer.go`, `metrics.go`,
`testserver.go`, `tetragon_test.go`) are read out of parent `3b13af74`.

## One-line difference

- **OLD:** signal-ingest was a **gRPC client of a deployed Tetragon agent**. It
  dialled the agent's unix socket, opened a `FineGuidanceSensors` event stream,
  and normalised each Tetragon event into `netebpf.InboundFlowEvent`.
- **NEW:** the **stun-sentinel's own in-kernel eBPF probes** emit
  `sentinel.ebpf.syscall_trace` events (already shaped as
  `netebpf.InboundFlowEvent`), which signal-ingest projects directly with
  `collectors/ebpf/endpoint.go` `ProjectEndpoint`. No gRPC hop, no third-party
  agent, no `cilium/tetragon` dependency.

## Dependency surface

| | OLD | NEW |
|---|---|---|
| Third-party Go modules | `github.com/cilium/tetragon/api/v1/tetragon`, `google.golang.org/grpc`, `google.golang.org/grpc/credentials/insecure` | none — stdlib only (`context`, `errors`, `fmt`, `io`, `log/slog`, `sync`, `sync/atomic`) |
| `go.mod` / `go.sum` | carried `cilium/tetragon` + the gRPC stack | both **absent** at the current base — confirmed by `rg -c "cilium/tetragon\|google.golang.org/grpc" go.mod` returning no matches |
| Cluster components | a Tetragon DaemonSet (`tetragon-agent-telemetry.yaml` in `d2-signalloom/deploy/`) + Helm values (`tetragon-helm-values.yaml`) | the existing stun-sentinel DaemonSet (`d2-signalloom/deploy/stun-sentinel-daemonset.yaml`) — no new component |
| Generated/pinned API types | the Tetragon protobuf `GetEventsResponse`, `GetProcessExec`, `GetProcessKprobe`, … | the first-party `netebpf.InboundFlowEvent` struct, shared with the socket-trace collector |

The two manifests above are **removed by this card** (task 1). No kustomization
or overlay referenced them (there is no `kustomization.yaml` in `deploy/`), so
no resource list needed editing. The only remaining mentions of the filenames
are in test-harness bats/scripts and docs, which belong to a separate card.

## Trust boundary

- **OLD:** the trust boundary ran through a **separately-deployed third-party
  agent**. Tetragon ran as a privileged DaemonSet and served its event stream
  over `/var/run/cilium/tetragon/tetragon.sock` with
  `grpc.WithTransportCredentials(insecure.NewCredentials())` — an **unauthenticated,
  unencrypted** local gRPC channel. Correctness of the telemetry depended on the
  agent's version, its `TracingPolicy` configuration, and a namespace allow-list
  that the client re-checked as defence-in-depth. A third party owned the kernel
  probes. Therefore, signal-ingest trusted whatever it streamed.
- **NEW:** the kernel probes are owned by the **stun-sentinel we build and
  deploy**. The sentinel is a telemetry *producer* only, with no LSM enforcement.
  Containment stays on the sentinel Tier-0 cgroup-freeze / TC-drop path and the
  Flux Tier-1 path. Next, signal-ingest consumes the sentinel's normalised events
  and projects them. The boundary is first-party on both sides. The socket-trace
  and syscall-trace streams share the same wire type and the same segment
  label allow-list discipline.

## Data path

- **OLD** (gRPC pull stream):

  ```
  Tetragon DaemonSet (in-kernel sensors)
    └─ gRPC FineGuidanceSensors over unix socket (insecure creds)
       └─ StreamClient.Dial → NewFineGuidanceSensorsClient → GetEvents stream
          └─ stream.Recv() loop, reconnect backoff 100ms→30s, bounded ring buffer
             └─ normalize → netebpf.InboundFlowEvent (FlowProcessor)
                └─ netebpf sequence-gap detection + Observation conversion → sink
  ```

  Characteristics: a long-lived **out-of-process network stream** the client had
  to dial, keep alive, and reconnect to. It also used a bounded ring buffer
  between reader and consumer, and a client-side namespace allow-list.

- **NEW** (in-process projection):

  ```
  stun-sentinel in-kernel eBPF (openat/openat2/execve + kprobes/tracepoints)
    └─ normalised netebpf.InboundFlowEvent posted to signal-ingest
       over POST /api/v1/observations
          └─ ProjectEndpoint: InboundFlowEvent → endpoint_host observation
             └─ IngestionSink → FrostDB
  ```

  Characteristics: **no socket to dial, no gRPC stream to keep alive, no
  reconnect state machine**. The projection is a pure function
  (`ProjectEndpoint`) that both the fixture replay and the live consume loop
  share. Thus, the e2e asserts the production projection rather than a test-only
  corpus.

## Failure modes

| Concern | OLD | NEW |
|---|---|---|
| Source unavailable | Tetragon socket down/restarting → reconnect-forever backoff (capped 30s); a genuinely dead agent = a silent telemetry hole the gap detector reports but cannot fill | no socket; the sentinel posts over the observations API; a missing stream is caught at startup (see below) |
| Silent degradation | a dropped blank import or a misconfigured `TracingPolicy` could leave live mode collecting nothing | live mode with no stream wired returns `ErrLiveSourceNotWired` (loud); `Health` reports it, so an unconfigured live collector is never reported ready |
| Transport trust | insecure gRPC creds on the unix socket | first-party API ingress; no third-party channel |
| Dependency CVE surface | `cilium/tetragon` + full gRPC stack | none (stdlib only) |
| Back-pressure | bounded ring buffer between gRPC reader and consumer | the consume loop ingests synchronously per event and fails loud on a sink error, so evidence is never silently dropped |

## What the live-wiring in this card (task 2) changed

Before this card, `collectors/ebpf/collector.go` had a `Start` loop whose
`ModeLive` returned a deferred sentinel error. The projection contract
(`ProjectEndpoint`) and the fixture replay existed, but nothing consumed the
live `sentinel.ebpf.syscall_trace` stream. This card made the live consume path
real, mirroring exactly how `collectors/netebpf` consumes `socket_trace`:

- An **injectable seam** `EndpointEventStream` (`Recv(ctx) (*netebpf.InboundFlowEvent, error)`)
  supplies live events, and `Collector.SetStream` wires it. The real subscriber
  (the sentinel posting to `/api/v1/observations`) is not reachable from a unit
  test or an offline sandbox. Therefore, the external I/O is injected, while the
  **consume-and-project loop itself is real and tested**.
- `ProcessSyscallEvent` projects each event through the existing
  `ProjectEndpoint` and ingests the `endpoint_host` result. A `network_connect`
  (egress, owned by netebpf), an `unattributed` event, or a nil projection is
  skipped — not an error. A sink ingestion failure is wrapped and propagated so
  the loop fails loudly.
- `ModeLive` `Start` spawns the consume loop in a goroutine (the registry starts
  collectors synchronously, so `Start` must not block), cancelled by `Stop`. Its
  terminal error is stored and surfaced via `Health`. With no stream wired,
  `Start`/`Health` return `ErrLiveSourceNotWired`.
- `Stats()` exposes received / projected / skipped counters.

`ProjectEndpoint`, the `InboundFlowEvent` wire type, and the embedded fixture
corpus were **not** modified. The live path consumes them as-is. Consequently,
breaking `ProjectEndpoint` turns the new live-consume test red (verified by
mutation).

The one boundary deliberately left injected is the **real transport from the
sentinel's `/api/v1/observations` ingress into an `EndpointEventStream`**. It is
not wired in `main.go`. The collector is still registered unwired, so a live
deployment returns `ErrLiveSourceNotWired` until a stream is set. Binding that
HTTP ingress to the seam is the remaining follow-up. The in-process
consume-and-project loop is complete and under test.
