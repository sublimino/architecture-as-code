import React, { Component, type ErrorInfo, type ReactNode } from 'react'
import { useFeatureFlag } from '../../hooks/useFeatureFlag'
import { useFeatureFlagContext } from '../../providers/FeatureFlagProvider'
import ErrorState from '../ErrorState'

// ─── Error Boundary ─────────────────────────────────────────────────────────

interface ErrorBoundaryProps {
  fallback: ReactNode
  children: ReactNode
}

interface ErrorBoundaryState {
  hasError: boolean
  error: Error | null
}

class FeatureGateErrorBoundary extends Component<
  ErrorBoundaryProps,
  ErrorBoundaryState
> {
  constructor(props: ErrorBoundaryProps) {
    super(props)
    this.state = { hasError: false, error: null }
  }

  static getDerivedStateFromError(error: Error): ErrorBoundaryState {
    return { hasError: true, error }
  }

  componentDidCatch(error: Error, errorInfo: ErrorInfo): void {
    console.error('[FeatureGate] Gated component failed during render:', error, errorInfo)
  }

  render(): ReactNode {
    if (this.state.hasError) {
      return this.props.fallback ?? null
    }
    return this.props.children
  }
}

// ─── FeatureGate Props & Component ──────────────────────────────────────────

export interface FeatureGateProps {
  /**
   * The feature flag key to evaluate (e.g. 'demos_fleet', 'supercred', 'audit').
   */
  flag: string

  /**
   * Optional node to render when the flag is disabled, or when the gated
   * children crash during render. Defaults to null.
   *
   * It is never rendered while the flag is unknown (resolving, or the fetch
   * failed): a fallback such as a 404 states that the feature is off, which
   * only the server can say.
   */
  fallback?: ReactNode

  /**
   * Optional placeholder or skeleton node to render during flag resolution.
   * If omitted, nothing is rendered while resolving (never `fallback`, so a
   * gated route cannot flash its 404).
   */
  loadingFallback?: ReactNode

  /**
   * If true, inverts evaluation logic (renders children when flag is disabled).
   */
  invert?: boolean

  /**
   * Protected child components to render when flag evaluation succeeds.
   */
  children: ReactNode
}

/**
 * FeatureGate
 *
 * Declarative component for feature-flag gated UI sections.
 * Evaluates the specified flag with OpenFeature React SDK and renders:
 * - while resolving: `loadingFallback`, or nothing;
 * - enabled: children;
 * - disabled: `fallback`, or nothing;
 * - flags could not be fetched for this tenant (FeatureFlagProvider gave up
 *   after its retries): with a `fallback`, an ErrorState with Retry, because
 *   the "disabled" screen would be a guess presented as fact; without one
 *   (e.g. Sidebar nav links), the client default for the flag, so navigation
 *   survives a blip and each gated page then shows its own error and Retry.
 *
 * Usage examples:
 *   <FeatureGate flag="demos_fleet">
 *     <FleetDemoDashboard />
 *   </FeatureGate>
 *
 *   <FeatureGate flag="supercred" fallback={<UpgradeNotice feature="SuperCred" />}>
 *     <SuperCredConsole />
 *   </FeatureGate>
 */
export function FeatureGate({
  flag,
  fallback = null,
  loadingFallback,
  invert = false,
  children,
}: FeatureGateProps): React.JSX.Element {
  const { enabled, isLoading, error } = useFeatureFlag(flag)
  const { isResolved, refetch } = useFeatureFlagContext()

  // While resolving: the dedicated loading node, or nothing. Never `fallback`.
  if (isLoading) {
    if (loadingFallback !== undefined) {
      return <>{loadingFallback}</>
    }
    return <></>
  }

  // The fetch failed and the server never answered for this tenant, so
  // `enabled` is only the client default. A gate with a "disabled" fallback
  // must not show it, nor show children the tenant may have switched off.
  // Fallback-less gates fall through to the client default (see above).
  if (error && !isResolved && fallback !== null && fallback !== undefined) {
    return (
      <div data-testid="feature-gate-error">
        <ErrorState
          message={`Could not load feature settings: ${error.message}`}
          onRetry={() => {
            void refetch()
          }}
        />
      </div>
    )
  }

  const shouldRender = invert ? !enabled : enabled

  return (
    <FeatureGateErrorBoundary fallback={fallback ?? null}>
      {shouldRender ? <>{children}</> : <>{fallback ?? null}</>}
    </FeatureGateErrorBoundary>
  )
}

export default FeatureGate
