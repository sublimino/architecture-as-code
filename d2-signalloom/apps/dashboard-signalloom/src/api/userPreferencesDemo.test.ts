// Demo mode is the default data path for the whole dashboard, so the currency
// preference has to work there too — and "works" includes surviving a reload.
// A setting that resets when you refresh is not a setting, and the demo is the
// path a customer actually sees in a room.

import { describe, it, expect, beforeEach } from 'vitest'
import { installMemoryStorage } from '../test-utils/memoryStorage'
import { resolveFake, resetFakeData, DEMO_CURRENCY_STORAGE_KEY } from './fakeData'

beforeEach(() => {
  // Node's built-in localStorage is inert without --localstorage-file (see
  // test-utils/memoryStorage.ts), so a store that silently drops writes would
  // make every assertion below meaningless.
  installMemoryStorage()
  resetFakeData()
})

describe('the demo-mode currency fixture', () => {
  it('serves USD before anything has been chosen', () => {
    expect(resolveFake('GET', '/user/preferences')).toEqual({ display_currency: 'USD' })
  })

  it('returns the saved choice on the next read', () => {
    resolveFake('PATCH', '/user/preferences', { display_currency: 'EUR' })
    expect(resolveFake('GET', '/user/preferences')).toEqual({ display_currency: 'EUR' })
  })

  it('survives a reload by persisting to localStorage', () => {
    resolveFake('PATCH', '/user/preferences', { display_currency: 'GBP' })
    expect(localStorage.getItem(DEMO_CURRENCY_STORAGE_KEY)).toBe('GBP')

    // A reload drops every module-level variable but keeps browser storage.
    resetFakeData()
    expect(resolveFake('GET', '/user/preferences')).toEqual({ display_currency: 'GBP' })
  })

  it('echoes the current value rather than storing a malformed body', () => {
    resolveFake('PATCH', '/user/preferences', { display_currency: 'EUR' })
    const echoed = resolveFake('PATCH', '/user/preferences', { display_currency: 42 })

    expect(echoed).toEqual({ display_currency: 'EUR' })
    expect(resolveFake('GET', '/user/preferences')).toEqual({ display_currency: 'EUR' })
  })

  it('is reachable as a route, so demo mode does not 501 on it', () => {
    // req() throws a 501 for any path with no fixture route, which would take
    // out the provider's load on every demo session.
    expect(resolveFake('GET', '/user/preferences')).toBeDefined()
    expect(resolveFake('PATCH', '/user/preferences', { display_currency: 'USD' })).toBeDefined()
  })
})
