# D2 CPAI — Runtime Proxy Demo

Isolated demo deploying the CPAI runtime proxy (OpenAI-compatible API server)
into its own `cpai` namespace. Independent of Signal Loom, OSRAMP, and all
other demos.

## Quick start

```bash
# From the repo root (cluster must be up: make up)
make demo-cpai-up       # build image, push to Zot, deploy
make demo-cpai-test     # run smoke tests
make demo-cpai-down     # tear down the cpai namespace
```

## Architecture

The CPAI runtime container runs `cpai api`, which starts:
- A health server on port 8080 (`/healthz`, `/readyz`)
- An OpenAI-compatible sidecar proxying to a private OpenCode instance

The container image is built from `Dockerfile.runtime` in the cpai-cli repo
and pushed to the in-cluster Zot registry with cosign signature.

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `CPAI_CLI_ROOT` | `/home/andy/src/cp/cpai-cli` | Path to cpai-cli repo for image build |
| `PORT` | `8080` | Public API port |
| `CPAI_CONTEXT_ROOT` | `/context` | Artefact mount path |
