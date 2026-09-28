import { describe, it, expect, vi } from 'vitest'
import { oidcConfig } from './oidc'

describe('OIDC silent renewal and token configuration', () => {
  it('disables automatic silent renew in oidcConfig to prevent redirect loops with Dex', () => {
    expect(oidcConfig.automaticSilentRenew).toBe(false)
  })

  it('configures silent_redirect_uri matching the callback endpoint', () => {
    expect(oidcConfig.silent_redirect_uri).toBe(`${window.location.origin}/callback`)
    expect(oidcConfig.redirect_uri).toBe(`${window.location.origin}/callback`)
  })

  it('does not have prompt: login globally in oidcConfig (which would break silent renew)', () => {
    expect((oidcConfig as any).extraQueryParams?.prompt).toBeUndefined()
  })

  it('configures localStorage user and state stores', () => {
    expect(oidcConfig.userStore).toBeDefined()
    expect(oidcConfig.stateStore).toBeDefined()
  })
})
