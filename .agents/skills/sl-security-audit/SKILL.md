---
name: sl-security-audit
description: "Restricted offline security assurance for Signal Loom. Runs existing secret and SAST gates without network access, verifies supplied evidence against an independently trusted public key, and reports unsupported live controls honestly. USE WHEN security audit, offline security assurance, sl-security-audit, or /sl-security-audit."
---

# sl-security-audit

Collect a bounded security-assurance report without installing tools, changing
baselines, accessing clusters, reading private keys, or enabling scanner network
access.

## Contract

- Primary workflow: [`Workflows/Audit.md`](Workflows/Audit.md)
- Deterministic collector: [`Tools/security-audit.sh`](Tools/security-audit.sh)
- Public output: one JSON object containing the fixed seven-control idset
- Raw scanner output: private temporary storage, never model input
- Findings: reported through status, reason codes, and nonnegative numeric metrics

This skill collects evidence only. It does not remediate findings, certify live
enforcement, update accepted findings, or fetch scanner rules.
