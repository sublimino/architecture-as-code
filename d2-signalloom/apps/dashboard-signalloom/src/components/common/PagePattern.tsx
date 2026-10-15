import React, { useState, type ReactNode, type CSSProperties } from 'react'
import PixelLoader from '../PixelLoader'
import LoadingState from '../LoadingState'
import ErrorState from '../ErrorState'
import EmptyState from '../EmptyState'
import FeatureGate from './FeatureGate'
import NotFoundPage from '../../pages/NotFoundPage'
import HelpHint from '../HelpHint'

export interface PageHeaderProps {
  title: string
  eyebrow?: string
  description?: ReactNode
  actions?: ReactNode
  hint?: ReactNode
  testId?: string
  style?: CSSProperties
}

/**
 * Standard PageHeader: consistent title, eyebrow, explanatory subtitle,
 * help hint tooltip, and action controls aligned right.
 */
export function PageHeader({
  title,
  eyebrow,
  description,
  actions,
  hint,
  testId,
  style,
}: PageHeaderProps): React.JSX.Element {
  return (
    <div
      data-testid={testId ?? 'page-header'}
      style={{
        display: 'flex',
        justifyContent: 'space-between',
        alignItems: 'flex-start',
        marginBottom: 20,
        gap: 16,
        flexWrap: 'wrap',
        ...style,
      }}
    >
      <div style={{ flex: '1 1 320px', minWidth: 260 }}>
        {eyebrow && (
          <div
            data-testid="page-eyebrow"
            style={{
              fontSize: 11,
              fontWeight: 600,
              textTransform: 'uppercase',
              letterSpacing: '0.06em',
              color: 'var(--muted)',
              marginBottom: 4,
            }}
          >
            {eyebrow}
          </div>
        )}
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <h1 style={{ fontSize: 22, fontWeight: 700, margin: 0, color: 'var(--text)' }}>
            {title}
          </h1>
          {hint && (
            <HelpHint label={`About ${title}`} testId={`${testId || 'page'}-hint`}>
              {hint}
            </HelpHint>
          )}
        </div>
        {description && (
          <p
            data-testid="page-description"
            style={{
              fontSize: 13,
              color: 'var(--muted)',
              marginTop: 6,
              marginBottom: 0,
              lineHeight: 1.5,
              maxWidth: 800,
            }}
          >
            {description}
          </p>
        )}
      </div>

      {actions && (
        <div
          data-testid="page-actions"
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 10,
            flexWrap: 'wrap',
          }}
        >
          {actions}
        </div>
      )}
    </div>
  )
}

/**
 * Branded route & page loader using PixelLoader.
 * Honors the operator's loadTimes settings ('all' | 'long' | 'none').
 * Guaranteed never to flash 404 while routes or feature flags are resolving.
 */
export function PageLoader({
  label = 'Loading',
  minHeight = '60vh',
  testId = 'route-loading',
  announce = true,
}: {
  label?: string
  minHeight?: string | number
  testId?: string
  announce?: boolean
}): React.JSX.Element {
  return (
    <div
      data-testid={testId}
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        minHeight,
        background: 'var(--bg)',
      }}
    >
      <PixelLoader label={label} testId={`${testId}-pixel`} announce={announce} />
    </div>
  )
}

export interface PagePatternProps {
  /** Page title for header */
  title?: string
  /** Domain eyebrow category */
  eyebrow?: string
  /** Explanatory description */
  description?: ReactNode
  /** Action buttons */
  actions?: ReactNode
  /** Help tooltip text or component */
  hint?: ReactNode
  /** Optional feature flag guarding this route/page */
  flag?: string
  /** Data loading active */
  loading?: boolean
  /** Loading label text */
  loadingLabel?: string
  /** Fetch or execution error */
  error?: string | Error | null
  /** Retry handler */
  onRetry?: () => void
  /** Empty dataset active */
  empty?: boolean
  /** Custom empty state or uses EmptyState */
  emptyState?: ReactNode
  /** Empty kicker */
  emptyKicker?: string
  /** Empty body text */
  emptyBody?: string
  /** Minimum container height */
  minHeight?: string | number
  /** Screen reader announcement for loader */
  announceLoader?: boolean
  /** Test identifier */
  testId?: string
  /** Container custom style */
  style?: CSSProperties
  /** Healthy child content */
  children?: ReactNode
}

/**
 * Canonical PagePattern component embedding the Signal Loom page lifecycle:
 * 1. Feature flag gating with FeatureGate (shows PageLoader while resolving; never 404).
 * 2. In-page data loading with LoadingState.
 * 3. In-page error resilience with ErrorState & retry.
 * 4. Empty state guidance with EmptyState.
 * 5. Standard page header and content layout.
 */
export function PagePattern({
  title,
  eyebrow,
  description,
  actions,
  hint,
  flag,
  loading = false,
  loadingLabel,
  error = null,
  onRetry,
  empty = false,
  emptyState,
  emptyKicker,
  emptyBody,
  minHeight,
  announceLoader = true,
  testId = 'page-pattern',
  style,
  children,
}: PagePatternProps): React.JSX.Element {
  const content = (
    <div
      data-testid={testId}
      style={{
        width: '100%',
        minHeight,
        ...style,
      }}
    >
      {title && (
        <PageHeader
          title={title}
          eyebrow={eyebrow}
          description={description}
          actions={actions}
          hint={hint}
          testId={`${testId}-header`}
        />
      )}

      {loading ? (
        <LoadingState
          variant="block"
          status="loading"
          label={loadingLabel ?? (title ? `${title.toLowerCase()} data` : 'data')}
          testId={`${testId}-loading`}
        />
      ) : error ? (
        <ErrorState
          message={typeof error === 'string' ? error : error.message}
          onRetry={onRetry}
        />
      ) : empty ? (
        emptyState ?? (
          <EmptyState
            kicker={emptyKicker ?? 'No items found'}
            body={emptyBody ?? 'No records are currently available for this view.'}
          />
        )
      ) : (
        children
      )}
    </div>
  )

  if (flag) {
    return (
      <FeatureGate
        flag={flag}
        fallback={<NotFoundPage />}
        loadingFallback={
          <PageLoader
            label={`Loading ${title ?? 'Page'}`}
            minHeight="60vh"
            testId="route-loading"
            announce={announceLoader}
          />
        }
      >
        {content}
      </FeatureGate>
    )
  }

  return content
}

export default PagePattern
