# AGENTS.md — d2-cpai (CPAI Runtime Proxy)

The `d2-cpai` slice deploys the CPAI runtime proxy. The proxy provides an OpenAI-compatible API server that forwards requests to Vertex AI. It runs in the dedicated `cpai` namespace.

## Stack

| Component | Technology | Path |
|---|---|---|
| Runtime server | Go API server with OpenAI compatibility | Built from `$CPAI_CLI_ROOT` |
| Manifests | Kustomize base and local overlay | [`apps/cpai-runtime/base/`](apps/cpai-runtime/base/), [`apps/cpai-runtime/local/`](apps/cpai-runtime/local/) |
| Smoke tests | BATS suite | [`test/cpai-runtime.bats`](test/cpai-runtime.bats) |
| Multi-turn test | BATS suite with aichat | [`test/conversation.bats`](test/conversation.bats) |
| Client config | aichat configuration | [`test/aichat/config.yaml`](test/aichat/config.yaml) |

## Namespaces

| Namespace | Contents |
|---|---|
| `cpai` | CPAI runtime pod, service, and Google Cloud credentials secret |

## Architecture

The diagram shows the request path from a client to Vertex AI.

```mermaid
flowchart LR
  CLIENT["OpenAI Client<br/>(curl / aichat / SDK)"]
  PORT["Service port 8080<br/>(local port 18080)"]
  POD["cpai-runtime pod<br/>(namespace: cpai)"]
  VERTEX["Google Cloud Vertex AI<br/>(gemini-2.5-flash)"]

  CLIENT -- "OpenAI /v1/chat/completions" --> PORT
  PORT --> POD
  POD -- "ADC Credentials<br/>(cpai-gcp-adc secret)" --> VERTEX

  classDef box fill:#e3f2fd,stroke:#1565c0,color:#0d47a1;
  class CLIENT,PORT,POD,VERTEX box;
```

## Lifecycle

Run these lifecycle targets from the repository root:

```bash
make demo-cpai-up            # Build image, push to Zot, sign with Cosign, and deploy
make demo-cpai-test          # Run smoke tests and single-turn completion test
make demo-cpai-conversation  # Run multi-turn context recall test with aichat
make demo-cpai-down          # Delete the cpai namespace
```

To run CPAI without the full foundation, use `make cpai-only`. It makes a
minimal foundation (`make cpai-foundation`: Kind, Zot, and cosign keys only)
and then deploys CPAI.

## Prerequisites

1. Start the cluster foundation with `make up`.
2. Check that `$CPAI_CLI_ROOT` points to a checkout of `cpai-cli` that contains `Dockerfile.runtime`.
3. Run `gcloud auth application-default login`, or set
   `GOOGLE_APPLICATION_CREDENTIALS` to a service account key file.
   `make demo-cpai-up` makes the `cpai-gcp-adc` Secret from these credentials.
   If it cannot read them, it gives a warning, and the model calls fail.
4. Install `aichat` to run the multi-turn conversation test.

To replace expired credentials, run `make demo-cpai-up` again, then restart the
deployment:

```bash
kubectl -n cpai rollout restart deployment/cpai-runtime
```

The deployment also mounts the optional Secret `cpai-codex-auth` and sets
`CPAI_BIN=opencode`
([`deployment.yaml`](apps/cpai-runtime/base/deployment.yaml)).

## Direct Service Access

Forward the service port to query the runtime:

```bash
kubectl -n cpai port-forward svc/cpai-runtime 18080:8080 &

# Check health endpoint
curl -s http://localhost:18080/healthz

# List models
curl -s http://localhost:18080/v1/models | jq .

# Run one-shot completion
curl -s http://localhost:18080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "google-vertex/gemini-2.5-flash",
    "messages": [{"role": "user", "content": "Say hello world"}],
    "max_tokens": 20
  }' | jq -r '.choices[0].message.content'
```

## Common Pitfalls

- **HTTP 5xx responses or skipped tests:** The `cpai-gcp-adc` Secret is missing or expired. Run `make demo-cpai-up` again and restart the deployment.
- **Image build failure:** `$CPAI_CLI_ROOT` does not point to the expected branch. Set the variable explicitly when you run `make demo-cpai-up`.
- **Port-forward stops on rollout:** Restart the `kubectl port-forward` command after every deployment restart.
