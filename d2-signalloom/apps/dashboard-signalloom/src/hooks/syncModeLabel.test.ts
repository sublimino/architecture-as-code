import { describe, it, expect } from 'vitest'
import { syncModeLabel } from './useConnectorStream'

const base = { last_success_at: null, last_error: null, last_poll_at: '2026-10-16T16:00:00Z', next_poll_at: '2026-10-16T16:00:30Z' }

describe('syncModeLabel covers every mode the backend sends', () => {
  it.each([
    ['poll', 'Polling every 30 s'],
    ['poll+stream', 'Live sessions + polling every 30 s'],
    ['stream', 'Live (provider stream)'],
  ])('%s → %s', (mode, label) => {
    expect(syncModeLabel({ ...base, mode })).toBe(label)
  })

  it('names backoff and its failure count instead of a raw mode string', () => {
    expect(syncModeLabel({ ...base, mode: 'backoff', consecutive_failures: 3 })).toBe('Backing off after errors (3 consecutive failures)')
  })

  it('shows minutes for long intervals', () => {
    expect(syncModeLabel({ ...base, mode: 'poll', next_poll_at: '2026-10-16T16:05:00Z' })).toBe('Polling every 5 min')
  })
})
