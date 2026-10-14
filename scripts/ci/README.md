# GCP CI Utilities (`scripts/ci/`)

This directory contains helper scripts used by the V2 Terraform GCP CI lanes (`ci-1` and `ci-2` in `sl-port-over-sandbox`) and local CI tooling.

## Architecture & Lanes

CI lanes are provisioned via Terraform (`terraform/platform/`) and driven by `Makefile` targets (`make gcp-tf-up ENV=ci-1`, `make gcp-tf-demo-up ENV=ci-1`, `make gcp-tf-ci-run ENV=ci-1`, `make gcp-tf-destroy ENV=ci-1 CONFIRM=ci-1`).

The full 29-stage verification pipeline executed on remote VMs lives at [`scripts/gcp-tf/demo-pipeline.sh`](../gcp-tf/demo-pipeline.sh).

## Scripts in `scripts/ci/`

| Script | Purpose |
|--------|---------|
| `gcp-tf-ci.sh` | Ephemeral V2 CI lane wrapper (`up`, `run`, `down`, `reap`) around `make gcp-tf-*` |
| `gcp-tf-reaper.sh` | TTL reaper that cleans up expired `managed-by=terraform`, `lane-kind=ci` VMs |
| `install-ci-tools.sh` | Installs and verifies pinned CLI tools (`kind`, `kubectl`, `helm`, `flux`, `cosign`, `trivy`, `crane`, `jq`, `yq`, `bats`, `zstd`) |
| `openreports-convert.sh` | Converts Trivy vulnerability JSON output into OpenReports CRD YAML manifests |
