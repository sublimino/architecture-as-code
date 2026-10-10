import { describe, expect, it, vi } from 'vitest'
import { OpenFeature, ProviderEvents, StandardResolutionReasons } from '@openfeature/web-sdk'
import { SignalLoomFeatureProvider } from './SignalLoomFeatureProvider'
import { DEFAULT_SYSTEM_FLAGS } from '../types/features'

describe('SignalLoomFeatureProvider', () => {
  it('initializes with default system flags', () => {
    const provider = new SignalLoomFeatureProvider()
    const flags = provider.getFlags()

    expect(flags.core_governance).toBe(true)
    expect(flags.audit).toBe(true)
    expect(flags.compliance).toBe(true)
    expect(flags.demos_fleet).toBe(false)
    expect(flags.supercred).toBe(false)
  })

  it('accepts initial flag overrides in constructor', () => {
    const provider = new SignalLoomFeatureProvider({
      demos_fleet: true,
      custom_flag: true,
    })
    const flags = provider.getFlags()

    expect(flags.demos_fleet).toBe(true)
    expect(flags.custom_flag).toBe(true)
    expect(flags.core_governance).toBe(true)
  })

  it('resolves boolean evaluation correctly with targeting and static reasons', () => {
    const provider = new SignalLoomFeatureProvider({
      demos_fleet: true,
    })

    const evalTrue = provider.resolveBooleanEvaluation('demos_fleet', false)
    expect(evalTrue.value).toBe(true)
    expect(evalTrue.reason).toBe(StandardResolutionReasons.TARGETING_MATCH)

    const evalDefaultSystem = provider.resolveBooleanEvaluation('supercred', true)
    expect(evalDefaultSystem.value).toBe(false)
    expect(evalDefaultSystem.reason).toBe(StandardResolutionReasons.STATIC)

    const evalUnknown = provider.resolveBooleanEvaluation('unknown_flag', true)
    expect(evalUnknown.value).toBe(true)
    expect(evalUnknown.reason).toBe(StandardResolutionReasons.DEFAULT)
  })

  it('resolves string, number, and object evaluations', () => {
    const provider = new SignalLoomFeatureProvider({
      theme: 'dark',
      max_retries: 5,
      config: { tier: 'enterprise' },
    })

    const strEval = provider.resolveStringEvaluation('theme', 'light')
    expect(strEval.value).toBe('dark')

    const numEval = provider.resolveNumberEvaluation('max_retries', 1)
    expect(numEval.value).toBe(5)

    const objEval = provider.resolveObjectEvaluation<{ tier: string }>('config', { tier: 'free' })
    expect(objEval.value).toEqual({ tier: 'enterprise' })

    const missingStr = provider.resolveStringEvaluation('missing', 'fallback')
    expect(missingStr.value).toBe('fallback')
  })

  it('updates flags and emits ConfigurationChanged event when values change', () => {
    const provider = new SignalLoomFeatureProvider({ demos_fleet: false })
    const listener = vi.fn()
    provider.events.addHandler(ProviderEvents.ConfigurationChanged, listener)

    provider.setFlags({ demos_fleet: true, audit: true })

    expect(listener).toHaveBeenCalledTimes(1)
    expect(listener).toHaveBeenCalledWith(
      expect.objectContaining({
        flagsChanged: expect.arrayContaining(['demos_fleet']),
      }),
    )

    const updated = provider.resolveBooleanEvaluation('demos_fleet', false)
    expect(updated.value).toBe(true)
  })

  it('does not emit ConfigurationChanged event if no flags changed', () => {
    const provider = new SignalLoomFeatureProvider({ ...DEFAULT_SYSTEM_FLAGS })
    const listener = vi.fn()
    provider.events.addHandler(ProviderEvents.ConfigurationChanged, listener)

    provider.setFlags({ ...DEFAULT_SYSTEM_FLAGS })
    expect(listener).not.toHaveBeenCalled()
  })

  it('emits Error event when setError is called', () => {
    const provider = new SignalLoomFeatureProvider()
    const errorListener = vi.fn()
    provider.events.addHandler(ProviderEvents.Error, errorListener)

    provider.setError('API network timeout')

    expect(errorListener).toHaveBeenCalledTimes(1)
    expect(errorListener).toHaveBeenCalledWith(
      expect.objectContaining({
        message: 'API network timeout',
      }),
    )
  })

  it('integrates cleanly with OpenFeature client evaluation', async () => {
    const provider = new SignalLoomFeatureProvider({
      core_governance: true,
      demos_fleet: false,
    })

    await OpenFeature.setProviderAndWait('test-domain', provider)
    const client = OpenFeature.getClient('test-domain')

    expect(client.getBooleanValue('core_governance', false)).toBe(true)
    expect(client.getBooleanValue('demos_fleet', true)).toBe(false)

    provider.setFlags({ demos_fleet: true })
    expect(client.getBooleanValue('demos_fleet', false)).toBe(true)
  })
})
