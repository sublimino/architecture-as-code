import { describe, it, expect } from 'vitest'
import { isPublicRoute } from './oidc'

describe('isPublicRoute', () => {
  it('identifies public invitation and signup routes', () => {
    expect(isPublicRoute('/redeem-invite')).toBe(true)
    expect(isPublicRoute('/redeem-invite?token=abc')).toBe(true)
    expect(isPublicRoute('/redeem-invite/123')).toBe(true)
    expect(isPublicRoute('/signup')).toBe(true)
    expect(isPublicRoute('/signup/')).toBe(true)
  })

  it('rejects protected routes as non-public', () => {
    expect(isPublicRoute('/agents')).toBe(false)
    expect(isPublicRoute('/governance')).toBe(false)
    expect(isPublicRoute('/compliance')).toBe(false)
    expect(isPublicRoute('/onboarding')).toBe(false)
    expect(isPublicRoute('/settings')).toBe(false)
    expect(isPublicRoute('/')).toBe(false)
  })
})
