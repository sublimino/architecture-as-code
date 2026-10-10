import {
  OpenFeatureEventEmitter,
  ProviderEvents,
  StandardResolutionReasons,
  type EvaluationContext,
  type JsonValue,
  type Logger,
  type Provider,
  type ProviderMetadata,
  type ResolutionDetails,
} from '@openfeature/web-sdk'
import { DEFAULT_SYSTEM_FLAGS } from '../types/features'

/**
 * Custom OpenFeature Web Provider for Signal Loom.
 *
 * Maintains evaluated in-memory flags fetched from /api/v1/features.
 * Emits OpenFeature events (READY, CONFIGURATION_CHANGED, ERROR) to reactively
 * re-render React UI components using useBooleanFlagValue / useFeatureFlag.
 */
export class SignalLoomFeatureProvider implements Provider {
  readonly metadata: ProviderMetadata = {
    name: 'signalloom-web-provider',
  }

  readonly runsOn = 'client' as const

  readonly events = new OpenFeatureEventEmitter()

  private flags: Record<string, boolean | JsonValue> = {}
  private isReady = false

  constructor(initialFlags?: Record<string, boolean | JsonValue>) {
    this.flags = {
      ...(initialFlags ?? {}),
    }
  }

  async initialize(_context?: EvaluationContext): Promise<void> {
    this.isReady = true
  }

  async onContextChange(
    _oldContext: EvaluationContext,
    _newContext: EvaluationContext,
  ): Promise<void> {
    // Context change lifecycle handled by OpenFeature SDK
  }

  async onClose(): Promise<void> {
    this.isReady = false
  }

  /**
   * Replace active in-memory flag dictionary and emit CONFIGURATION_CHANGED event
   * for any keys whose evaluation changed.
   */
  setFlags(newFlags: Record<string, boolean | JsonValue>): void {
    const previous = { ...this.flags }
    this.flags = {
      ...newFlags,
    }

    const changedKeys = Array.from(
      new Set([...Object.keys(previous), ...Object.keys(this.flags)]),
    ).filter((key) => JSON.stringify(previous[key]) !== JSON.stringify(this.flags[key]))

    if (!this.isReady) {
      this.isReady = true
    }

    if (changedKeys.length > 0) {
      this.events.emit(ProviderEvents.ConfigurationChanged, {
        flagsChanged: changedKeys,
      })
    }
  }

  /**
   * Returns current flag snapshot merged with system defaults.
   */
  getFlags(): Record<string, boolean | JsonValue> {
    return {
      ...DEFAULT_SYSTEM_FLAGS,
      ...this.flags,
    }
  }

  /**
   * Emit an error event and update provider status.
   */
  setError(message?: string): void {
    this.events.emit(ProviderEvents.Error, {
      message: message ?? 'Failed to evaluate flags from Signal Loom backend',
    })
  }

  resolveBooleanEvaluation(
    flagKey: string,
    defaultValue: boolean,
    _context?: EvaluationContext,
    _logger?: Logger,
  ): ResolutionDetails<boolean> {
    if (flagKey in this.flags) {
      const raw = this.flags[flagKey]
      const value = typeof raw === 'boolean' ? raw : Boolean(raw)
      return {
        value,
        reason: StandardResolutionReasons.TARGETING_MATCH,
      }
    }

    if (flagKey in DEFAULT_SYSTEM_FLAGS) {
      return {
        value: DEFAULT_SYSTEM_FLAGS[flagKey],
        reason: StandardResolutionReasons.STATIC,
      }
    }

    return {
      value: defaultValue,
      reason: StandardResolutionReasons.DEFAULT,
    }
  }

  resolveStringEvaluation(
    flagKey: string,
    defaultValue: string,
    _context?: EvaluationContext,
    _logger?: Logger,
  ): ResolutionDetails<string> {
    if (flagKey in this.flags && typeof this.flags[flagKey] === 'string') {
      return {
        value: this.flags[flagKey] as string,
        reason: StandardResolutionReasons.TARGETING_MATCH,
      }
    }

    return {
      value: defaultValue,
      reason: StandardResolutionReasons.DEFAULT,
    }
  }

  resolveNumberEvaluation(
    flagKey: string,
    defaultValue: number,
    _context?: EvaluationContext,
    _logger?: Logger,
  ): ResolutionDetails<number> {
    if (flagKey in this.flags && typeof this.flags[flagKey] === 'number') {
      return {
        value: this.flags[flagKey] as number,
        reason: StandardResolutionReasons.TARGETING_MATCH,
      }
    }

    return {
      value: defaultValue,
      reason: StandardResolutionReasons.DEFAULT,
    }
  }

  resolveObjectEvaluation<T extends JsonValue>(
    flagKey: string,
    defaultValue: T,
    _context?: EvaluationContext,
    _logger?: Logger,
  ): ResolutionDetails<T> {
    if (
      flagKey in this.flags &&
      typeof this.flags[flagKey] === 'object' &&
      this.flags[flagKey] !== null
    ) {
      return {
        value: this.flags[flagKey] as T,
        reason: StandardResolutionReasons.TARGETING_MATCH,
      }
    }

    return {
      value: defaultValue,
      reason: StandardResolutionReasons.DEFAULT,
    }
  }
}
