# kusari-agent (stub)

A stub Signal Loom swarm agent standing in for the Kusari pilot workload. It allows discovering, claiming, and observing a "Kusari agent" in `fe-signalloom-agents` before integrating real Kusari software (Inspector, Waybill, GUAC).

It does two things:

1. Serves a quote on `GET /quote`, fetched from ZenQuotes using the PAI status line endpoint, echoing back an `input` query parameter.
2. Writes `/tmp/hostile-test.txt` inside the container on every fifth request. That intentional action exercises runtime monitoring. It is never advertised in the `/quote` response. Ground truth lives only in the structured stdout log and `/stats`.

## Endpoints

| Method | Path | Behaviour |
|---|---|---|
| GET | `/quote?input=<text>` | Returns `{"input","request","quote","author","source"}`. `source` is `zenquotes` on upstream success, `fallback` otherwise. Root `/` is an alias. |
| GET | `/stats` | `{"requests","hostile_writes","hostile_every","hostile_path"}`. Ground truth for the hostile cadence. |
| GET | `/healthz` | Liveness, returns `{"status":"ok"}`. |

Non-GET requests to `/quote` return 405 and do not count towards the hostile cadence.

### Provocation routes (`/act/*`)

Deliberate adversarial triggers the SLDC containment suite fires. All are **POST-only** (GET/PUT/DELETE → `405` with `Allow: POST`) and answer the shared `actResult` JSON envelope (`{"action","ok",...}`). None of them ever return sensitive file contents or uploaded bytes. The syscall (the `openat`, the outbound `connect`) is the signal. It is recorded on the wire and in a structured `event=act` stdout line. Counts are ground truth in `/stats`.

| Method | Path | Behaviour |
|---|---|---|
| POST | `/act/read-passwd` | Open `passwdPath`, hold the fd `ACT_HOLD`, report byte/line counts. `?defer=D` answers `202` with the order and opens `D` later. Never returns contents. |
| POST | `/act/read-shadow` | Same against `shadowPath`; `attempted=true` even when absent. |
| POST | `/act/cpu-burn` | Busy-loop `?threads=N` for `?duration=D` (clamped to `ACT_BURN_MAX`). |
| POST | `/act/gpu-open` | Open a GPU control device (`GPU_DEVICE_PATH`) read-only and hold the fd. `?write=1` opens it `O_RDWR` (falling back to `O_WRONLY`) and sets `write_mode:true` to signal write intent. `attempted=true` even when the node is absent (distroless). Device bytes are never returned. |
| POST | `/act/gpu-probe` | Stat+open the NVIDIA discovery set (`/dev/nvidiactl`, `/dev/nvidia-uvm`, `/dev/nvidia0`, `/proc/driver/nvidia/version`, `/proc/driver/nvidia/gpus`) on one traced thread. Reports `count` touched, `found` openable, and a per-path `probes` list. GPU-mount discovery. |
| POST | `/act/exfil` | TCP-dial a paste service (`EXFIL_TARGET`) with a short timeout (`ACT_DIAL_TIMEOUT`). Reports `host`, `connected`, `address`, and `dial_outcome` (`connected`/`refused`/`timeout`/`error`). The outbound connect is the signal, so a refused/timed-out dial is still `ok:true`. No data is uploaded. |
| POST | `/act/kube-enum` | Open the service-account token (`SA_TOKEN_PATH`) and record `token_readable` + `token_bytes` (never the token value), then TCP-dial the in-cluster apiserver (`KUBE_API_TARGET`). Reports both the token read and the dial. |
| POST | `/act/recon` | Open a container-escape recon set (`/proc/1/root`, `/proc/sys/kernel/core_pattern`, `/proc/self/environ`, `/etc/kubernetes/admin.conf`, `/etc/shadow`) on one traced thread and report `count`/`found`/`probes`. Contents are never returned. |

`/stats` carries a per-provocation counter alongside `hostile_writes`: `gpu_opens`, `gpu_probes`, `exfils`, `kube_enums`, `recons`.

## Configuration

| Env var | Default | Notes |
|---|---|---|
| `PORT` | `8080` | Listens on `:$PORT`, the fleet convention. Must be an integer in 1..65535. |
| `QUOTE_URL` | `https://zenquotes.io/api/random` | Same endpoint as `statusline-command.sh`. |
| `ZENQUOTES_API_KEY` | unset | When set, `/random/{key}` is used, as the status line does. Keyless ZenQuotes allows 5 requests per 30s. |
| `QUOTE_TIMEOUT` | `3s` | Matches the status line's `curl --max-time 3`. |
| `QUOTE_COOLDOWN` | `60s` | After an upstream failure, serve fallback quotes without dialling for this long. `0` dials every request. Without it every request in the egress-denied namespace would wait the full timeout. |
| `HOSTILE_EVERY` | `5` | Write the hostile file on every Nth request. `0` disables. Deterministic, not random, so 5 requests always yield exactly one write. |
| `HOSTILE_PATH` | `/tmp/hostile-test.txt` | Must be on a writable mount; the container root filesystem is read-only, `/tmp` is an emptyDir. |
| `GPU_DEVICE_PATH` | `/dev/nvidiactl` | Device node `/act/gpu-open` opens (and holds) to signal GPU access. |
| `EXFIL_TARGET` | `pastebin.com:443` | `host:port` `/act/exfil` dials. The connect attempt is the provocation; no data is uploaded. |
| `SA_TOKEN_PATH` | `/var/run/secrets/kubernetes.io/serviceaccount/token` | Service-account token `/act/kube-enum` opens; only its readability and length are reported, never its value. |
| `KUBE_API_TARGET` | `kubernetes.default.svc:443` | In-cluster apiserver `/act/kube-enum` dials. |
| `ACT_DIAL_TIMEOUT` | `2s` | Short dial timeout for `/act/exfil` and `/act/kube-enum`. Must be a positive Go duration. |

Upstream responses whose author is `zenquotes.io` are the keyless rate-limit reply and are treated as failures, exactly as the status line discards them. Egress from `fe-signalloom-agents` is default-deny, so in-cluster you will normally see `source: fallback`. That is expected and the demo still works. The first request after start (or after a cooldown expires) can take up to `QUOTE_TIMEOUT` while the dial is dropped. The rest answer instantly. Transport errors are logged without the request URL so a keyed upstream never leaks the key.

## Structured log

One JSON object per line on stdout.
Events include `start`, `quote`, `quote_fallback` (with sanitised `reason`), `hostile_write`, and `hostile_write_failed`.
Provocations emit `act` (recording `action` and outcome) and `act_scheduled` (a deferred read order).

```json
{"agent":"kusari-agent","event":"hostile_write","path":"/tmp/hostile-test.txt","request":5,"ts":"2026-09-28T14:00:00.000Z"}
```

## Local run and tests

```bash
cd d2-signalloom/apps/kusari-agent
go vet ./... && go test ./...
HOSTILE_PATH=/tmp/hostile-test.txt go run . &
for i in 1 2 3 4 5; do curl -s "localhost:8080/quote?input=hi-$i"; echo; done
curl -s localhost:8080/stats; cat /tmp/hostile-test.txt
```

## Build and deploy on the cluster host (fortuna)

```bash
# image (also part of `make swarm-security-images`)
make -C d2-signalloom swarm-kusari-image
kind load docker-image --name "$CLUSTER_NAME" kusari-agent:latest

# manifests: delivered by the agent-swarm ResourceSet (Tier 9), or apply directly
kustomize build d2-signalloom/infra/agent-swarm/kusari-agent | kubectl apply -f -
kubectl -n fe-signalloom-agents rollout status deploy/agent-kusari
```

The ServiceAccount `kusari-agent` ships in this agent's directory (`d2-signalloom/infra/agent-swarm/kusari-agent/service-account.yaml`) rather than `rbac.yaml`.
The SPIRE swarm entries Job registers it, giving the pod SPIFFE ID `spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kusari-agent`.

## Claim it in Signal Loom

Follow Test 1.1 of the SLOA onboarding runbook.
Open the Agents view, find the amber "Unclaimed Workload" row for `agent-kusari`, and click Claim.
Confirm the SPIFFE ID and claim it under the `kusari` tenant.
The dossier then shows an audit trail for the claim.

## Verify the hostile write

```bash
kubectl -n fe-signalloom-agents port-forward svc/kusari-agent 8080:8080 &
for i in 1 2 3 4 5; do curl -s "localhost:8080/quote?input=probe-$i" | jq -c .; done
curl -s localhost:8080/stats | jq .            # hostile_writes: 1
kubectl -n fe-signalloom-agents logs deploy/agent-kusari | grep '"event":"hostile_write"'

# read the file from outside the (shell-less, distroless) container
POD=$(kubectl -n fe-signalloom-agents get pod -l app.kubernetes.io/name=kusari-agent -o name | head -1)
kubectl -n fe-signalloom-agents debug -q -it "$POD" --image=busybox:1.36 --target=agent -- \
  cat /proc/1/root/tmp/hostile-test.txt
```

For a detector (Falco, Tetragon, the eBPF sentinel), the signature is: process `/kusari-agent` in a pod labelled `signalloom.ai/agent=true` opening `/tmp/hostile-test.txt` for write. The `/stats` counter and the log line give you the expected count to reconcile detections against.

## What this is not

No SPIRE SVID fetch occurs inside the container.
Discovery derives identity from the ServiceAccount.
No Kusari Inspector, Waybill, or GUAC calls exist.
The certified SuperCred `fleet-agents` set remains unchanged.
Replace this stub once the Kusari payload contract is agreed.
