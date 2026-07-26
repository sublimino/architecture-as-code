---
task: Explain browser test commands and Signal Loom frontend routing
slug: 20260726-212900_browser-tests-signal-loom-routing
effort: standard
phase: observe
progress: 0/8
mode: interactive
started: 2026-07-26T21:29:00+01:00
updated: 2026-07-26T21:29:00+01:00
---

## Context

Determine the repository-supported commands for running the newly added browser
acceptance tests and reaching the Signal Loom frontend. This is documentation
only: inspect existing Make targets, Playwright configuration, Kubernetes
service names, and ingress/routing manifests without changing deployment code.

## Criteria

- [ ] ISC-1: Browser test directory and framework are identified
- [ ] ISC-2: Browser test dependency installation command is identified
- [ ] ISC-3: Browser test startup prerequisite command is identified
- [ ] ISC-4: Browser test execution command is identified
- [ ] ISC-5: Browser test debugging command is identified
- [ ] ISC-6: Frontend Kubernetes namespace is identified
- [ ] ISC-7: Frontend service and port are identified
- [ ] ISC-8: Port-forward or routed access command is identified

## Decisions

Use repository-native Make targets first, then provide the underlying
port-forward fallback where it is explicitly supported by manifests or docs.

## Verification
