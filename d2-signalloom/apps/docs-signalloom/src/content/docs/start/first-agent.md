---
title: Onboard your first agent
description: Register an agent and check the resulting inventory record.
---

## What onboarding means

Signal Loom has two onboarding flows:

- The tenant wizard configures providers and preferences.
- Agent registration adds an agent record to the inventory.

This guide covers agent registration.

## Prerequisites

- Start Signal Loom.
- Sign in with either demonstration account.
- Complete or skip the tenant onboarding gate.

## Register the agent

1. Open **Agents**.
2. Select **Register Agent**.
3. Enter the agent name.
4. Select the agent type.
5. Enter an owner if the agent has one.
6. Select **Register**.

The browser sends `POST /api/agents`. The current API requires authentication.
It does not require a stronger role.

## Check the result

1. Find the new row on the **Agents** page.
2. Open the agent detail page.
3. Check the displayed identity state.
4. Check the displayed policy posture.

You can also inspect the API response while you are authenticated:

```text
GET /api/agents
```

## Current limit

The tenant wizard uses mock connector operations by default. Its connector state
can disappear after a reload. The user interface does not yet call the backend
completion endpoint. Treat durable tenant onboarding as roadmap work.
