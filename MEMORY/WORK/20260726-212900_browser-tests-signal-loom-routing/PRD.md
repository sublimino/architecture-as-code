---
task: Explain browser test commands and Signal Loom frontend routing
slug: 20260726-212900_browser-tests-signal-loom-routing
effort: standard
phase: complete
progress: 8/8
mode: interactive
started: 2026-07-26T21:29:00+01:00
updated: 2026-07-26T21:36:00+01:00
---

## Context

Determine the repository-supported commands for running the newly added browser
acceptance tests and reaching the Signal Loom frontend. This is documentation
only: inspect existing Make targets, Playwright configuration, Kubernetes
service names, and ingress/routing manifests without changing deployment code.

## Criteria

- [x] ISC-1: Browser test directory and framework are identified
- [x] ISC-2: Browser test dependency installation command is identified
- [x] ISC-3: Browser test startup prerequisite command is identified
- [x] ISC-4: Browser test execution command is identified
- [x] ISC-5: Browser test debugging command is identified
- [x] ISC-6: Frontend Kubernetes namespace is identified
- [x] ISC-7: Frontend service and port are identified
- [x] ISC-8: Port-forward or routed access command is identified

## Decisions

Use repository-native Make targets first, then provide the underlying
port-forward fallback where it is explicitly supported by manifests or docs.

## Verification

- `test/acceptance/package.json` confirms Playwright; `playwright.config.ts` confirms Chromium.
- `test/acceptance/README.md` confirms `bun install`.
- `Makefile` confirms `make demo-signalloom-up` and `make acceptance-test`.
- `scripts/acceptance-test.sh` confirms automatic port-forward mappings and argument passthrough.
- `cluster.spec.ts` confirms Signal Loom URL `http://127.0.0.1:18000`.
- `service.yaml` confirms namespace `fe-signalloom`, Service `fe-signalloom`, port `8000`.
- `cluster-gateway.yaml` exposes wildcard cluster listeners but no Signal Loom HTTPRoute.
- `bash -n scripts/acceptance-test.sh` passed; `make -n acceptance-test` resolved correctly.
