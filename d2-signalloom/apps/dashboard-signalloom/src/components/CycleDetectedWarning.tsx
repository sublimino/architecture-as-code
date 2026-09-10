// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import React from 'react'
import { colors } from '../styles/tokens'

export interface CycleDetectedWarningProps {
  cycleDetected?: boolean
  message?: string
  cyclePath?: string[]
}

export const CycleDetectedWarning: React.FC<CycleDetectedWarningProps> = ({
  cycleDetected = true,
  message = 'Adversarial circular delegation cycle detected in delegation graph. Chain traversal clamped to prevent infinite recursion.',
  cyclePath = [],
}) => {
  if (!cycleDetected) return null

  return (
    <div
      data-testid="cycle-detected-warning"
      role="alert"
      aria-live="assertive"
      style={{
        display: 'flex',
        alignItems: 'flex-start',
        gap: 12,
        padding: '12px 16px',
        borderRadius: 8,
        background: 'rgba(239, 68, 68, 0.15)',
        border: '1px solid rgba(239, 68, 68, 0.4)',
        color: colors.red || 'var(--error, #ef4444)',
        marginBottom: 16,
      }}
    >
      <span style={{ fontSize: 20, lineHeight: 1 }} aria-hidden="true">
        ⚠️
      </span>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
          <strong style={{ fontSize: 13, textTransform: 'uppercase', letterSpacing: '0.05em' }}>
            Adversarial Delegation Cycle Detected
          </strong>
          <span
            data-testid="cycle-detected-badge"
            className="tag"
            style={{
              fontSize: 10,
              padding: '2px 6px',
              borderRadius: 4,
              fontWeight: 700,
              background: 'rgba(239, 68, 68, 0.3)',
              color: 'var(--on-accent)',
              border: '1px solid rgba(239, 68, 68, 0.6)',
            }}
          >
            CYCLE BLOCKED
          </span>
        </div>
        <p
          data-testid="cycle-detected-message"
          style={{
            margin: '4px 0 0',
            fontSize: 12,
            color: 'var(--text, #f0f3f8)',
            lineHeight: 1.4,
          }}
        >
          {message}
        </p>
        {cyclePath.length > 0 && (
          <div
            data-testid="cycle-detected-path"
            style={{
              marginTop: 6,
              fontFamily: 'monospace',
              fontSize: 11,
              padding: '4px 8px',
              borderRadius: 4,
              background: 'rgba(0, 0, 0, 0.3)',
              border: '1px solid rgba(239, 68, 68, 0.25)',
              color: colors.red || 'var(--error, #ef4444)',
            }}
          >
            Cycle: {cyclePath.join(' ➔ ')}
          </div>
        )}
      </div>
    </div>
  )
}

export default CycleDetectedWarning
