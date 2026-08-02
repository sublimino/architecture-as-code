import { describe, it, expect, beforeEach } from 'vitest'
import {
  clearDemoActivity,
  demoActivityEvents,
  recordDemoActivity,
  DEMO_ACTIVITY_LIMIT,
} from './demoActivity'

beforeEach(() => {
  clearDemoActivity()
})

describe('demoActivity', () => {
  it('starts empty', () => {
    expect(demoActivityEvents()).toEqual([])
  })

  it('records an event carrying timestamp, agent, action, actor and outcome', () => {
    const event = recordDemoActivity({
      event_type: 'agent.stunned',
      agent_id: 'agent-cardvault',
      agent_name: 'Cardvault Agent',
      actor: 'demo-operator',
      detail: { outcome: 'stunned', reason: 'compliance-failure' },
    })

    expect(event.id).toMatch(/\S/)
    expect(Number.isNaN(Date.parse(event.timestamp))).toBe(false)
    expect(event.event_type).toBe('agent.stunned')
    expect(event.agent_id).toBe('agent-cardvault')
    expect(event.actor).toBe('demo-operator')
    expect(event.detail).toMatchObject({ outcome: 'stunned' })
    expect(demoActivityEvents()).toEqual([event])
  })

  it('returns newest first so the timeline reads top-down', () => {
    const first = recordDemoActivity({ event_type: 'agent.stunned', actor: 'a' })
    const second = recordDemoActivity({ event_type: 'agent.stunned', actor: 'b' })

    expect(demoActivityEvents().map(e => e.id)).toEqual([second.id, first.id])
  })

  it('mints a distinct id per event even within the same millisecond', () => {
    const ids = Array.from({ length: 5 }, () =>
      recordDemoActivity({ event_type: 'agent.stunned', actor: 'demo-operator' }).id,
    )
    expect(new Set(ids).size).toBe(5)
  })

  it('hands back a copy so callers cannot mutate the store', () => {
    recordDemoActivity({ event_type: 'agent.stunned', actor: 'demo-operator' })
    demoActivityEvents().pop()
    expect(demoActivityEvents()).toHaveLength(1)
  })

  it('caps the log so a long demo session cannot grow without bound', () => {
    for (let i = 0; i < DEMO_ACTIVITY_LIMIT + 10; i++) {
      recordDemoActivity({ event_type: 'agent.stunned', actor: `actor-${i}` })
    }
    const events = demoActivityEvents()
    expect(events).toHaveLength(DEMO_ACTIVITY_LIMIT)
    // The oldest are the ones dropped.
    expect(events[0].actor).toBe(`actor-${DEMO_ACTIVITY_LIMIT + 9}`)
  })

  it('defaults the optional fields so the audit table always has something to render', () => {
    const event = recordDemoActivity({ event_type: 'agent.stunned', actor: 'demo-operator' })
    expect(event.agent_id).toBeNull()
    expect(event.agent_name).toBeNull()
    expect(event.detail).toEqual({})
  })
})
