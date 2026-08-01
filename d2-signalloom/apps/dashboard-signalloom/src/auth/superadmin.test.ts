import { describe, it, expect, beforeEach } from 'vitest'
import { installMemoryStorage } from '../test-utils/memoryStorage'
import {
  SUPERADMIN_STORAGE_KEY,
  isSuperadminEligible,
  readSuperadmin,
  writeSuperadmin,
} from './superadmin'

// Fresh, empty localStorage per test — see test-utils/memoryStorage.ts for why
// the jsdom default is not usable here.
beforeEach(() => {
  installMemoryStorage()
})

describe('isSuperadminEligible', () => {
  it('accepts the demo user by email claim', () => {
    expect(isSuperadminEligible({ email: 'demo-user@signalloom.local' })).toBe(true)
  })

  it('accepts the demo user by preferred_username claim', () => {
    expect(isSuperadminEligible({ preferred_username: 'demo-user' })).toBe(true)
  })

  it('accepts the demo user by name claim', () => {
    expect(isSuperadminEligible({ name: 'demo-user' })).toBe(true)
  })

  it('rejects any other user', () => {
    expect(isSuperadminEligible({ email: 'auditor@bank.example', name: 'Auditor' })).toBe(false)
    expect(isSuperadminEligible({ preferred_username: 'demo-user-2' })).toBe(false)
    expect(isSuperadminEligible({})).toBe(false)
  })

  it('rejects a missing profile', () => {
    expect(isSuperadminEligible(undefined)).toBe(false)
    expect(isSuperadminEligible(null)).toBe(false)
  })

  it('ignores non-string claim values', () => {
    expect(isSuperadminEligible({ email: 42, name: { toString: () => 'demo-user' } })).toBe(false)
  })
})

describe('superadmin persistence', () => {
  it('uses a namespaced storage key', () => {
    expect(SUPERADMIN_STORAGE_KEY).toBe('signalloom.superadmin')
  })

  it('defaults to off when nothing is stored', () => {
    expect(readSuperadmin()).toBe(false)
  })

  it('round-trips through localStorage', () => {
    writeSuperadmin(true)
    expect(localStorage.getItem(SUPERADMIN_STORAGE_KEY)).toBe('true')
    expect(readSuperadmin()).toBe(true)

    writeSuperadmin(false)
    expect(localStorage.getItem(SUPERADMIN_STORAGE_KEY)).toBe('false')
    expect(readSuperadmin()).toBe(false)
  })

  it('treats an unrecognised stored value as off', () => {
    localStorage.setItem(SUPERADMIN_STORAGE_KEY, 'yes-please')
    expect(readSuperadmin()).toBe(false)
  })
})
