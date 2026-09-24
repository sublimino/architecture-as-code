# D2 CPAI — Runtime Proxy Demo

The `d2-cpai` slice deploys the CPAI runtime into its own `cpai` namespace. The
runtime is `cpai api`, an OpenAI-compatible API server. It forwards each request
to a private OpenCode process, which calls Vertex AI. The slice is independent
of Signal Loom, OSRAMP, and every other demo. It has its own namespace, its own
image, and its own up and down lifecycle.

The container image is built from `Dockerfile.runtime` in the cpai-cli checkout.
The `cpai-images` target in the root [`Makefile`](../Makefile) builds it, pushes
it to the in-cluster Zot registry, and signs it with cosign. The image build is
the only step that reads outside this repository.

The request path from an OpenAI client to Vertex AI is drawn in
[`AGENTS.md`](AGENTS.md#architecture).

## What you get

- An OpenAI-compatible endpoint (`/v1/chat/completions` and `/v1/models`)
  backed by a real model on Vertex AI. The tests ask for `gemini-2.5-flash` by
  default.
- The liveness and readiness probes both call `/healthz`.
- A signed image in Zot. Check the signature with `cosign verify`.

## Prerequisites and lifecycle

The prerequisites, the `make demo-cpai-*` targets, and the fast path
`make cpai-only` are in [`AGENTS.md`](AGENTS.md#lifecycle).

`make demo-cpai-up` creates the `cpai-gcp-adc` Secret from your ADC file. Run
`gcloud auth application-default login` first. The GCP project defaults to
`cc-vertex-test` ([`deployment.yaml`](apps/cpai-runtime/base/deployment.yaml)).
`CPAI_CLI_ROOT` defaults to `/home/andy/src/cp/cpai-cli`. Set it to your
cpai-cli checkout.

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

Point any OpenAI client at `http://localhost:18080/v1` with the model
`google-vertex/gemini-2.5-flash`. The test client sets `api_key: unused`
([`test/aichat/config.yaml`](test/aichat/config.yaml)).

## Image signing

`make cpai-images` builds the image from `Dockerfile.runtime` in cpai-cli, loads
it into Kind, and pushes it to
`zot.registry.svc.cluster.local:5000/acme/images/cpai/apps/cpai-runtime:latest`.
It signs the image with `$(KEYS_DIR)/cosign.key`. In a worktree, `KEYS_DIR` is
the main checkout's `.keys`. To check a pushed image, run:

```bash
kubectl -n registry port-forward svc/zot 5001:5000 &
DIGEST=$(crane digest --insecure localhost:5001/acme/images/cpai/apps/cpai-runtime:latest)
cosign verify --key "${KEYS_DIR:-.keys}/cosign.pub" --insecure-ignore-tlog \
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
| `CPAI_CLI_ROOT` | `/home/andy/src/cp/cpai-cli` | cpai-cli checkout the image is built from (`make cpai-images`) |
| `CPAI_TEST_MODEL` | `google-vertex/gemini-2.5-flash` | Model the smoke test asks for |
| `CPAI_PORT_FORWARD_PORT` | `18080` | Local port the tests forward to |
| `PORT` | `8080` | Public API port in the container |
| `GOOGLE_CLOUD_PROJECT` | `cc-vertex-test` | Vertex project (set in `deployment.yaml`) |
| `CPAI_CONTEXT_ROOT` | `/context` | Artefact mount path |

## Pitfalls

The known failures and their fixes are in [`AGENTS.md`](AGENTS.md#pitfalls).
For expired credentials, run `make demo-cpai-up` again. Then restart the
deployment with `kubectl -n cpai rollout restart deployment/cpai-runtime`.
