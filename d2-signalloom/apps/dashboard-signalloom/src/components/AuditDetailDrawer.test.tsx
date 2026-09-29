// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import AuditDetailDrawer from './AuditDetailDrawer'
import type { AuditEventResponse } from '../types/api'

const SAMPLE_EVENT: AuditEventResponse = {
  id: 'evt-audit-12345678',
  timestamp: '2026-09-29T10:15:30.000Z',
  event_type: 'agent.credential_issued',
  agent_id: 'agent-uuid-1111',
  agent_name: 'test-governed-agent',
  actor: 'operator@signal-loom.ai',
  spiffe_id: 'spiffe://cluster.local/ns/default/sa/test-agent',
  authorizing_principal_id: 'principal-superadmin-99',
  executing_actor_id: 'actor-executor-01',
  attribution_rationale: 'Mandatory quarterly credential renewal under EU-AI-Act control A.4',
  evidence_ref: 'sha256:4a8b7c9e0f123456789abcdef0123456789abcdef0123456789abcdef0123456',
  kernel_telemetry_ref: 'lsm:landlock:rule-882:enforced',
  detail: {
    action: 'issue_certificate',
    ttl_seconds: 3600,
    renew_allowed: true,
    revocation_reason: null,
    nested: {
      key: 'value',
      count: 42,
    },
  },
}

function renderDrawer(props: { isOpen: boolean; event: AuditEventResponse | null; onClose?: () => void }) {
  const onClose = props.onClose ?? vi.fn()
  return {
    ...render(
      <MemoryRouter>
        <AuditDetailDrawer isOpen={props.isOpen} event={props.event} onClose={onClose} />
      </MemoryRouter>,
    ),
    onClose,
  }
}

describe('AuditDetailDrawer', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('renders nothing when isOpen is false or event is null', () => {
    const { container: c1 } = renderDrawer({ isOpen: false, event: SAMPLE_EVENT })
    expect(c1.innerHTML).toBe('')

    const { container: c2 } = renderDrawer({ isOpen: true, event: null })
    expect(c2.innerHTML).toBe('')
  })

  it('renders with accessible dialog role and labelled title', () => {
    renderDrawer({ isOpen: true, event: SAMPLE_EVENT })

    const dialog = screen.getByRole('dialog')
    expect(dialog).toHaveAttribute('aria-modal', 'true')
    expect(dialog).toHaveAttribute('aria-labelledby', 'audit-detail-drawer-title')
    expect(screen.getByRole('heading', { level: 2, name: 'agent.credential_issued' })).toBeInTheDocument()
  })

  it('displays all structured sections: Metadata, Actor & SPIFFE, Cryptography, and Payload', () => {
    renderDrawer({ isOpen: true, event: SAMPLE_EVENT })

    expect(screen.getByTestId('audit-drawer-metadata')).toBeInTheDocument()
    expect(screen.getByTestId('audit-drawer-actor')).toBeInTheDocument()
    expect(screen.getByTestId('audit-drawer-cryptography')).toBeInTheDocument()
    expect(screen.getByTestId('audit-drawer-payload')).toBeInTheDocument()

    // Metadata
    expect(screen.getByText('test-governed-agent')).toBeInTheDocument()
    expect(screen.getByText('agent-uuid-1111')).toBeInTheDocument()

    // Actor Identity & SPIFFE
    expect(screen.getByText('operator@signal-loom.ai')).toBeInTheDocument()
    expect(screen.getByText('spiffe://cluster.local/ns/default/sa/test-agent')).toBeInTheDocument()
    expect(screen.getByText('principal-superadmin-99')).toBeInTheDocument()
    expect(screen.getByText('actor-executor-01')).toBeInTheDocument()
    expect(screen.getByText(/Mandatory quarterly credential renewal/)).toBeInTheDocument()

    // Attestation Cryptography
    expect(screen.getByText('sha256:4a8b7c9e0f123456789abcdef0123456789abcdef0123456789abcdef0123456')).toBeInTheDocument()
    expect(screen.getByText('lsm:landlock:rule-882:enforced')).toBeInTheDocument()
    expect(screen.getByText('Immutable Append-Only Log')).toBeInTheDocument()
  })

  it('syntax highlights JSON payload keys, strings, booleans, numbers, and null', () => {
    renderDrawer({ isOpen: true, event: SAMPLE_EVENT })

    const viewer = screen.getByTestId('audit-json-viewer')
    expect(viewer).toBeInTheDocument()
    expect(viewer.textContent).toContain('"action": "issue_certificate"')
    expect(viewer.textContent).toContain('"ttl_seconds": 3600')
    expect(viewer.textContent).toContain('"renew_allowed": true')
    expect(viewer.textContent).toContain('"revocation_reason": null')
  })

  it('handles copy payload button click with clipboard confirmation', async () => {
    const writeTextMock = vi.fn().mockResolvedValue(undefined)
    Object.defineProperty(navigator, 'clipboard', {
      value: { writeText: writeTextMock },
      configurable: true,
      writable: true,
    })
    renderDrawer({ isOpen: true, event: SAMPLE_EVENT })

    const copyBtn = screen.getByTestId('audit-copy-payload-button')
    expect(copyBtn).toHaveTextContent('Copy Payload')

    fireEvent.click(copyBtn)

    expect(writeTextMock).toHaveBeenCalledWith(
      JSON.stringify(SAMPLE_EVENT.detail, null, 2),
    )
    expect(await screen.findByText('Copied!')).toBeInTheDocument()
  })

  it('calls onClose when close button is clicked', () => {
    const { onClose } = renderDrawer({ isOpen: true, event: SAMPLE_EVENT })

    const closeBtn = screen.getByTestId('audit-detail-drawer-close')
    fireEvent.click(closeBtn)

    expect(onClose).toHaveBeenCalledOnce()
  })

  it('calls onClose when backdrop is clicked', () => {
    const { onClose } = renderDrawer({ isOpen: true, event: SAMPLE_EVENT })

    const backdrop = screen.getByTestId('audit-detail-drawer-backdrop')
    fireEvent.click(backdrop)

    expect(onClose).toHaveBeenCalledOnce()
  })

  it('closes on Escape key press', () => {
    const { onClose } = renderDrawer({ isOpen: true, event: SAMPLE_EVENT })

    fireEvent.keyDown(window, { key: 'Escape' })
    expect(onClose).toHaveBeenCalledOnce()
  })

  it('renders raw string payloads safely without error', () => {
    const rawStringEvent: AuditEventResponse = {
      ...SAMPLE_EVENT,
      id: 'evt-raw',
      detail: 'plain text raw payload' as unknown as Record<string, unknown>,
    }
    renderDrawer({ isOpen: true, event: rawStringEvent })

    const viewer = screen.getByTestId('audit-json-viewer')
    expect(viewer.textContent).toContain('plain text raw payload')
  })
})
