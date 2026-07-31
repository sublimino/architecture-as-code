# D2 CPAI — Runtime Proxy Demo

Isolated demo that deploys the **CPAI runtime** (`cpai api` — an OpenAI-compatible
API server fronting a private OpenCode) into its own `cpai` namespace. Fully
independent of Signal Loom, OSRAMP, and every other demo: its own namespace, its
own image, its own up/down lifecycle. Bringing it up or tearing it down never
touches anything else.

The container image is built from `Dockerfile.runtime` in the **cpai-cli** repo,
pushed to the in-cluster Zot registry, and **cosign-signed** — the only code that
reaches outside this repo is that image build, which the `cpai-images` target in
the repo-root `Makefile` drives.

## What you get

- An OpenAI-compatible endpoint (`/v1/chat/completions`, `/v1/models`) backed by a
  **real model** (Vertex AI `gemini-2.5-flash`) — a genuine multi-turn conversation,
  not an echo/mock.
- Liveness/readiness on `/healthz` and `/readyz`.
- A signed image in Zot, verifiable with `cosign verify`.

## Prerequisites

1. **Cluster foundation up:** `make up` from the repo root (creates the kind
   cluster, Zot registry, and cosign keys under `.keys/`).
2. **cpai-cli carries the runtime:** `$CPAI_CLI_ROOT` (default
   `~/cp/cpai-cli`) must contain `Dockerfile.runtime`, `cmd/cpai/cpai` with the
   `api` subcommand, and `services/openai-compat/`. This ships once the
   cpai-runtime work is merged to `main`.
3. **Vertex credentials as a secret.** The runtime calls Vertex AI, so it needs
   Application Default Credentials mounted as the `cpai-gcp-adc` secret. Create it
   once from your local ADC (namespace is created by `demo-cpai-up`):

   ```bash
   kubectl -n cpai create secret generic cpai-gcp-adc \
     --from-file=adc.json="$HOME/.config/gcloud/application_default_credentials.json"
   kubectl -n cpai rollout restart deployment/cpai-runtime
   ```

   The GCP project defaults to `cc-vertex-test` (see `deployment.yaml`).
4. **`aichat`** installed for the conversation test (`brew install aichat`).

## Quick start

```bash
# From the repo root (cluster must already be up: make up)
make demo-cpai-up            # build image from cpai-cli, push to Zot, cosign-sign, deploy
make demo-cpai-test          # smoke: namespace, pod, /healthz, real hello-world completion
make demo-cpai-conversation  # 3-turn real conversation (context recall) via aichat
make demo-cpai-down          # remove the cpai namespace (nothing else is touched)
```

`demo-cpai-up` forces a rollout after apply, so a freshly built+signed image is
always the one that runs (the `:latest` tag alone would otherwise be a no-op).

## Talk to it directly

```bash
# Port-forward the service
kubectl -n cpai port-forward svc/cpai-runtime 18080:8080 &

# Health
curl -s http://localhost:18080/healthz          # {"status":"alive"}

# List models
curl -s http://localhost:18080/v1/models | jq .

# One-shot completion (real Vertex model)
curl -s http://localhost:18080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "google-vertex/gemini-2.5-flash",
    "messages": [{"role": "user", "content": "Say hello world"}],
    "max_tokens": 20
  }' | jq -r '.choices[0].message.content'
```

Point any OpenAI client at `http://localhost:18080/v1` with model
`google-vertex/gemini-2.5-flash` and any (unused) API key.

## Architecture

```
client ──OpenAI /v1──▶ cpai-runtime pod (namespace: cpai)
                         └─ cpai api  (port 8080)
                            ├─ health server  /healthz /readyz
                            └─ openai-compat sidecar ──▶ private OpenCode ──▶ Vertex AI
```

The image is built from `Dockerfile.runtime` in cpai-cli, `kind load`ed, pushed to
`zot.registry.svc.cluster.local:5000/acme/images/cpai/apps/cpai-runtime:latest`,
and cosign-signed with the local key (`.keys/cosign.key`). Verify a pushed image:

```bash
kubectl -n registry port-forward svc/zot 5001:5000 &
DIGEST=$(crane digest --insecure localhost:5001/acme/images/cpai/apps/cpai-runtime:latest)
cosign verify --key .keys/cosign.pub --insecure-ignore-tlog \
  --allow-insecure-registry \
  localhost:5001/acme/images/cpai/apps/cpai-runtime@"$DIGEST"
```

## Layout

```
d2-cpai/
├── Makefile                          # local: kustomize-check + smoke test
├── apps/cpai-runtime/
│   ├── base/                         # namespace, deployment, service, kustomization
│   └── local/                        # local overlay (namespace: cpai)
└── test/
    ├── cpai-runtime.bats             # smoke incl. real hello-world completion
    ├── conversation.bats             # 3-turn real conversation (context recall)
    └── aichat/config.yaml            # aichat client pointed at the runtime
```

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `CPAI_CLI_ROOT` | `~/cp/cpai-cli` | cpai-cli repo the image is built from (`make cpai-images`) |
| `CPAI_TEST_MODEL` | `google-vertex/gemini-2.5-flash` | Model the smoke test asks for |
| `CPAI_PORT_FORWARD_PORT` | `18080` | Local port the tests forward to |
| `PORT` | `8080` | Public API port in the container |
| `GOOGLE_CLOUD_PROJECT` | `cc-vertex-test` | Vertex project (set in `deployment.yaml`) |
| `CPAI_CONTEXT_ROOT` | `/context` | Artefact mount path |

## Troubleshooting

- **Completions return HTTP 5xx / tests skip** — the `cpai-gcp-adc` secret is
  missing or stale. Recreate it (Prerequisites §3) and
  `kubectl -n cpai rollout restart deployment/cpai-runtime`.
- **Build fails: `Dockerfile.runtime` not found** — `$CPAI_CLI_ROOT` is not on a
  branch carrying the runtime. Point it at a checkout that has it, e.g.
  `make demo-cpai-up CPAI_CLI_ROOT=/path/to/cpai-cli-with-runtime`.
- **A rebuild didn't change the running pod** — shouldn't happen (`demo-cpai-up`
  forces a rollout), but `kubectl -n cpai rollout restart deployment/cpai-runtime`
  forces it manually.
- **`aichat: command not found`** — `brew install aichat` (conversation test only).
