import React, { Component, type ErrorInfo, type ReactNode } from 'react'
import { useFeatureFlag } from '../../hooks/useFeatureFlag'

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
   * Optional fallback node to render when the flag is disabled or encounters an error.
   * Defaults to null.
   */
  fallback?: ReactNode

  /**
   * Optional placeholder or skeleton node to render during flag resolution.
   * If omitted, renders `fallback ?? null` to eliminate Cumulative Layout Shift (CLS).
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
 * Evaluates the specified flag with OpenFeature React SDK and renders children
 * when enabled, or fallback / null when disabled or during loading.
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

  // During loading, render dedicated loading fallback or default fallback/null to avoid CLS
  if (isLoading) {
    if (loadingFallback !== undefined) {
      return <>{loadingFallback}</>
    }
    return <></>
  }


  // If evaluation threw an error, gracefully render fallback
  if (error && !enabled) {
    return <>{fallback ?? null}</>
  }

  const shouldRender = invert ? !enabled : enabled

  return (
    <FeatureGateErrorBoundary fallback={fallback ?? null}>
      {shouldRender ? <>{children}</> : <>{fallback ?? null}</>}
    </FeatureGateErrorBoundary>
  )
}

export default FeatureGate
