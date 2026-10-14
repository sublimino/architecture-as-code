---
title: Developer onboarding
description: Start a disposable local environment, make one small change, and prepare tested delivery.
---

Use the [glossary](/dev-docs/reference/glossary/) for shared terms. This procedure is for development, not security assessment.

## Prerequisites

The procedure needs a repository checkout, Docker, Kind, kubectl, Make, and Bun. API contract tests also need `uv`.
The [root guide](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/AGENTS.md) describes the shared cluster.

WARNING: Use an approved disposable local environment.
The start targets create workloads, keys, images, and Flux resources.

## Start the local environment

Run these commands from the repository root.

1. Check the selected Kubernetes context.

   ```bash
   kubectl config current-context
   ```

2. Start the shared foundation.

   ```bash
   make up
   ```

3. Start Signal Loom.

   ```bash
   make demo-signalloom-up
   ```

4. Check foundation readiness.

   ```bash
   make healthcheck
   ```

5. Start the dashboard port-forward in a separate terminal.

   ```bash
   kubectl -n fe-signalloom port-forward svc/dashboard-signalloom 5173:8080
   ```

6. Open `http://localhost:5173`.
7. Request approved local access from the environment owner.
8. Check that the dashboard loads after authentication.

The [Makefile](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/Makefile) owns these targets.
`make up` starts the foundation. `make demo-signalloom-up` also creates caller keys and publishes workload images.

## Make one small change

A wording change is a suitable first contribution. A behaviour change needs a failing test before implementation.

1. Select one approved page or component.
2. Read its source and nearest tests.
3. Record the expected result.
4. Change only that item.
5. Run the relevant check from the table below.
6. Review the diff for unrelated changes.
7. Check the changed page in a browser.

| Change | Check | Source |
| :--- | :--- | :--- |
| Documentation | `make docs-lint` | [Makefile](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/Makefile) |
| Portal rendering | `make docs-render-check` | [Render script](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/scripts/docs-render-check.sh) |
| Dashboard types | `bun run typecheck` from the dashboard directory | [Package scripts](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/d2-signalloom/apps/dashboard-signalloom/package.json) |
| Weave or Signal Fusion | `make test-dashboard-weave` | [Makefile](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/Makefile) |
| API contract | `make demo-signalloom-api-test` | [Contract runner](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/scripts/signalloom-api-test.sh) |

The API target defaults to the contract tier. Integration tests need an approved test database.
Skipped tests do not prove a pass.

## Optional dashboard source server

The [Vite configuration](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/d2-signalloom/apps/dashboard-signalloom/vite.config.ts) uses port 3000.
Its API and Dex proxies use the dashboard port-forward at port 5173.

1. Open a terminal in the dashboard directory.
2. Install the locked dependencies.

   ```bash
   bun install --frozen-lockfile
   ```

3. Start the source server.

   ```bash
   bun run dev
   ```

4. Check the changed view at `http://localhost:3000`.

The source server is not a deployment. Its port does not establish an approved OIDC redirect URI.

## Prepare delivery

Flux manages the deployed manifests. A local source change does not update a running image.
The [build script](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/scripts/build-sign-dashboard.sh) creates dashboard supply-chain evidence and signs the image.

1. Record the changed files and test results.
2. Record skipped checks and their reasons.
3. Request review of the diff.
4. Hand approved delivery to the environment owner.
5. Check the deployed image identity after approved delivery.

Do not use direct deployment as a substitute for the approved Flux path.
Stop if the task requires a shared environment change without approval.
