// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import { describe, it, expect, beforeEach } from 'vitest'
import { api } from './client'
import { setDemoMode } from './demoMode'
import { FAKE_CODING_AGENT_TELEMETRY } from './fakeCodingAgentData'

describe('Coding Agents API Client', () => {
  beforeEach(() => {
    setDemoMode(true)
  })

  it('lists coding agent telemetry records in demo mode', async () => {
    const list = await api.codingAgents.list('demo-token')
    expect(Array.isArray(list)).toBe(true)
    expect(list.length).toBe(FAKE_CODING_AGENT_TELEMETRY.length)
    expect(list[0].event.harness).toBe('claude')
  })

  it('retrieves aggregate summary metrics with k-anonymity (k=5) protection', async () => {
    const aggregate = await api.codingAgents.aggregate('demo-token')
    expect(aggregate.group_size).toBeGreaterThanOrEqual(5)
    expect(aggregate.total_events).toBe(7)
    expect(aggregate.tool_counts.view_file).toBeGreaterThan(0)
    expect(aggregate.harness_distribution.claude).toBe(1)
  })

  it('evaluates ordering between two records with clock-skew bounds', async () => {
    const ordering = await api.codingAgents.ordering('demo-token', {
      event_a: FAKE_CODING_AGENT_TELEMETRY[0].event,
      event_b: FAKE_CODING_AGENT_TELEMETRY[1].event,
    })
    expect(ordering.verdict).toBe('definite')
    expect(ordering.confidence).toBe('monotonic_anchor')
  })

  it('posts telemetry ingestion event in demo mode', async () => {
    const res = await api.codingAgents.ingest('demo-token', FAKE_CODING_AGENT_TELEMETRY[0].event)
    expect(res.status).toBe('ingested')
  })
})
