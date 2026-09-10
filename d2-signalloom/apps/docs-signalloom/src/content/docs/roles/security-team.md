---
title: Security team
description: Use the available evidence views without overstating role enforcement.
---

## Current workflow

A security practitioner can use the present demonstration to:

1. Review agent inventory and posture.
2. Inspect compliance findings.
3. Inspect the audit trail.
4. Review credential evidence.
5. Run RBAC analysis when KubeSec-AFM is deployed.
6. Observe containment evidence in the SuperCredential demo.

Start KubeSec-AFM separately:

```bash
make demo-k8s-afm-up
make demo-k8s-afm-status
```

## Current limit

`security team` is a documented responsibility, not an implemented
authorization persona. Sign-in claims do not grant a distinct security role.

## Roadmap

- Define investigation permissions separately from mutation permissions.
- Add evidence export for regulated review.
- Add saved investigations and review ownership.
- Add role-specific API denial tests.
