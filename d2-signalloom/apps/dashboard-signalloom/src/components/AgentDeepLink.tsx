import React, { type CSSProperties, type ReactNode, type MouseEvent } from 'react'
import SafeLink from './SafeLink'
import {
  buildAgentDeepLink,
  formatSelectorLabel,
  type AgentNavigationTarget,
  type DeepLinkOptions,
} from '../data/agentDeepLink'

export type AgentDeepLinkVariant = 'link' | 'badge' | 'chip' | 'pill' | 'subtle'

export interface AgentDeepLinkProps {
  target: string | AgentNavigationTarget
  options?: DeepLinkOptions
  variant?: AgentDeepLinkVariant
  label?: ReactNode
  instanceUid?: string
  showIcon?: boolean
  showPrefix?: boolean
  dataTestId?: string
  className?: string
  style?: CSSProperties
  onClick?: (e: MouseEvent<HTMLAnchorElement>) => void
  title?: string
  children?: ReactNode
}

export default function AgentDeepLink({
  target,
  options,
  variant = 'link',
  label,
  instanceUid,
  showIcon = false,
  showPrefix = true,
  dataTestId,
  className,
  style,
  onClick,
  title,
  children,
}: AgentDeepLinkProps) {
  const mergedOptions: DeepLinkOptions = {
    ...options,
    ...(instanceUid ? { instance: instanceUid } : {}),
  }

  const link = buildAgentDeepLink(target, mergedOptions)

  // Resolve visual label
  let content: ReactNode = children
  if (!content) {
    if (label) {
      content = label
    } else if (typeof target === 'string') {
      content = showPrefix ? formatSelectorLabel(target) : target.replace(/^[^:]+:/, '')
    } else if (target.label) {
      content = target.label
    } else if (target.agentId) {
      content = target.agentId
    } else if (target.selector) {
      content = showPrefix ? formatSelectorLabel(target.selector) : target.selector.replace(/^[^:]+:/, '')
    } else {
      content = link.href
    }
  }

  const tooltipTitle =
    title ||
    (typeof target === 'string'
      ? target
      : target.agentId
        ? `Agent: ${target.agentId}${link.instanceUid ? ` (instance: ${link.instanceUid})` : ''}`
        : target.selector || link.href)

  // Variant styles
  const baseStyle: CSSProperties = {
    textDecoration: 'none',
    transition: 'color 0.15s ease, background-color 0.15s ease, border-color 0.15s ease',
    ...style,
  }

  let variantStyle: CSSProperties = {}

  switch (variant) {
    case 'badge':
      variantStyle = {
        display: 'inline-flex',
        alignItems: 'center',
        gap: 5,
        padding: '2px 8px',
        borderRadius: 4,
        fontSize: 12,
        fontWeight: 600,
        background: 'color-mix(in srgb, var(--cyan) 12%, transparent)',
        color: 'var(--cyan)',
        border: '1px solid color-mix(in srgb, var(--cyan) 28%, transparent)',
      }
      break

    case 'chip':
      variantStyle = {
        display: 'inline-flex',
        alignItems: 'center',
        gap: 4,
        padding: '2px 7px',
        borderRadius: 3,
        fontSize: 11,
        fontFamily: 'monospace',
        background: 'var(--surface2)',
        color: 'var(--text)',
        border: '1px solid var(--border)',
      }
      break

    case 'pill':
      variantStyle = {
        display: 'inline-flex',
        alignItems: 'center',
        gap: 4,
        padding: '2px 10px',
        borderRadius: 9999,
        fontSize: 11,
        fontWeight: 500,
        background: 'color-mix(in srgb, var(--cyan) 8%, var(--surface2))',
        color: 'var(--cyan)',
        border: '1px solid color-mix(in srgb, var(--cyan) 20%, var(--border))',
      }
      break

    case 'subtle':
      variantStyle = {
        color: 'var(--muted)',
        fontSize: 12,
        fontWeight: 400,
      }
      break

    case 'link':
    default:
      variantStyle = {
        color: 'var(--cyan)',
        fontSize: 13,
        fontWeight: 600,
        display: 'inline-flex',
        alignItems: 'center',
        gap: 4,
      }
      break
  }

  return (
    <SafeLink
      to={{
        pathname: link.pathname,
        search: link.search,
        hash: link.hash,
      }}
      data-testid={dataTestId || (link.isDirectDossier ? 'agent-dossier-deep-link' : 'agent-selector-deep-link')}
      className={className}
      style={{ ...baseStyle, ...variantStyle }}
      onClick={onClick}
      title={tooltipTitle}
    >
      <span>{content}</span>
      {showIcon && (
        <span
          data-testid="external-nav-glyph"
          style={{ fontSize: 10, opacity: 0.8, lineHeight: 1 }}
          aria-hidden="true"
        >
          {' '}↗
        </span>
      )}
    </SafeLink>
  )
}
