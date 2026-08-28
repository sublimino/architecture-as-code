import { describe, it, expect } from 'vitest'
import {
  SWARM_AUDIT_EVENT_TYPES,
  SWARM_EVENT_LABELS,
  type SwarmAuditEventType,
} from './swarmAuditEvents'
import { FAKE_SWARM_AUDIT_EVENTS } from './fakeSwarmData'

describe('swarmAuditEvents — event type vocabulary', () => {
  it('defines 8 event types', () => {
    expect(SWARM_AUDIT_EVENT_TYPES).toHaveLength(8)
  })

  it('every event type has a human label', () => {
    for (const type of SWARM_AUDIT_EVENT_TYPES) {
      expect(SWARM_EVENT_LABELS[type], `missing label for ${type}`).toBeTruthy()
    }
  })

  it('all event types follow the swarm.* naming convention', () => {
    for (const type of SWARM_AUDIT_EVENT_TYPES) {
      expect(type).toMatch(/^swarm\./)
    }
  })
})

describe('swarmAuditEvents — demo fixtures', () => {
  it('covers all 8 event types', () => {
    const covered = new Set(FAKE_SWARM_AUDIT_EVENTS.map((e) => e.type))
    for (const type of SWARM_AUDIT_EVENT_TYPES) {
      expect(covered, `no demo event for ${type}`).toContain(type)
    }
  })

  it('every event has required fields', () => {
    for (const event of FAKE_SWARM_AUDIT_EVENTS) {
      expect(event.id).toBeTruthy()
      expect(event.type).toBeTruthy()
      expect(event.agent_id).toBeTruthy()
      expect(event.spiffe_id).toMatch(/^spiffe:\/\//)
      expect(event.timestamp).toBeTruthy()
      expect(event.details).toBeDefined()
    }
  })

  it('every event has a unique id', () => {
    const ids = FAKE_SWARM_AUDIT_EVENTS.map((e) => e.id)
    expect(new Set(ids).size).toBe(ids.length)
  })

  it('events are in chronological order (most recent last)', () => {
    for (let i = 1; i < FAKE_SWARM_AUDIT_EVENTS.length; i++) {
      const prev = new Date(FAKE_SWARM_AUDIT_EVENTS[i - 1].timestamp).getTime()
      const curr = new Date(FAKE_SWARM_AUDIT_EVENTS[i].timestamp).getTime()
      expect(curr).toBeGreaterThanOrEqual(prev)
    }
  })
})
