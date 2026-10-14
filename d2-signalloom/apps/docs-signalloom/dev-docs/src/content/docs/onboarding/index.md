---
title: Engineering onboarding
description: Choose a scoped engineering path and confirm its permissions before work.
---

Start with the [glossary](/dev-docs/reference/glossary/). Each path has a different permission boundary.

| Path | Required context | Completion evidence |
| :--- | :--- | :--- |
| [Developer](/dev-docs/onboarding/developer/) | Disposable local environment and approved change | Small diff, relevant tests, and delivery notes |
| [Support engineer](/dev-docs/onboarding/support-engineer/) | Named environment and scoped read access | Failed hop, redacted evidence, and escalation |
| [Security engineer](/dev-docs/onboarding/security-engineer/) | Approved read-only scope and evidence store | Findings in the [assessment template](/dev-docs/reference/security-assessment-template/) |

## Select context

1. Record the task and environment.
2. Read the [root guide](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/AGENTS.md).
3. Read the [slice guide](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/d2-signalloom/AGENTS.md).
4. Select only the component sources required for the task.
5. Confirm the namespace and permitted operations with the owner.
6. Confirm the evidence destination and retention period.
7. Check that the selected path matches the approved permissions.

Least privilege applies to information as well as access. A request failure rarely requires secret values or a complete transcript.

## Stop conditions

WARNING: Stop if the context, authority, or data classification is unclear.
A command against the wrong environment can expose data or change shared services.

- Stop if a command needs broader privileges than the approved scope.
- Stop if output can contain credentials or customer payloads.
- Stop if a check requires a write, a restart, or a destructive test.
- Stop if evidence cannot enter an approved restricted store.
- Stop if a previous result conflicts with the current environment.

Support and security paths do not inherit developer mutation permissions. Remediation requires separate approval.
