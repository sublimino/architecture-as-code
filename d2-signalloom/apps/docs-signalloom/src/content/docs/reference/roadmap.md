---
title: Current limits and roadmap
description: Separate verified demonstration behaviour from planned platform behaviour.
---

## Available now

- Local Kind deployment through repository Make targets.
- Dex demonstration identities.
- Agent registration through the dashboard and API.
- Signal Loom inventory, posture, compliance, and audit views.
- SuperCredential demonstration phases.
- Agent stun demonstration behaviour.
- KubeSec-AFM integration when its separate slice is deployed.

## TODO: close authorization gaps

- Enforce a real view-only role on mutation endpoints.
- Define advanced-user permissions.
- Define security-team permissions.
- Define platform-admin permissions.
- Require superadmin authorization for direct stun operations.
- Add an authenticated generic unstun API.

## TODO: complete onboarding

- Persist provider configuration outside the mock connector client.
- Call the backend onboarding completion endpoint from the dashboard.
- Seed one verified agent during the first-user journey.
- Show one deterministic success check after registration.

## TODO: replace demonstration simulations

- Replace the Fleet Manager no-op client with an authenticated client.
- Compute Fleet risk values from observed evidence.
- Protect Fleet Manager mutation routes.

## Later roadmap

- Publish immutable versioned documentation.
- Add authenticated operator documentation.
- Add documentation ownership and review dates.
- Add telemetry-free local search quality checks.
- Add translation only after the English task model stabilizes.
