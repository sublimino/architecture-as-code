import { fireEvent, render } from '@testing-library/react'
import { createPortal } from 'react-dom'
import { MemoryRouter } from 'react-router-dom'
import { describe, expect, it, vi } from 'vitest'
import { AuthorizationProofDrawer } from './AuthorizationProofDrawer'
import CredentialActionsMenu from './CredentialActionsMenu'
import { DelegationAttestationDrawer } from './DelegationAttestationDrawer'
import TriageMenu from './TriageMenu'
import { NodeDetailDrawer } from './trust/NodeDetailDrawer'
import type { TrustNode } from './trust/trustTypes'

function iframeMount() {
  const frame = document.createElement('iframe')
  document.body.appendChild(frame)
  const ownerDocument = frame.contentDocument!
  const mount = ownerDocument.createElement('div')
  ownerDocument.body.appendChild(mount)
  return { frame, ownerDocument, mount }
}

describe('owner-document callbacks', () => {
  it('scopes TriageMenu outside clicks to its iframe document', () => {
    const { frame, ownerDocument, mount } = iframeMount()
    const { unmount } = render(createPortal(<TriageMenu accountId="account-1" onAction={vi.fn()} />, mount))
    const trigger = ownerDocument.querySelector<HTMLElement>('button')!

    fireEvent.click(trigger)
    expect(ownerDocument.body.textContent).toContain('Mark as Reviewed')
    fireEvent.keyDown(document, { key: 'Escape' })
    expect(ownerDocument.body.textContent).toContain('Mark as Reviewed')
    fireEvent.keyDown(ownerDocument, { key: 'Escape' })
    expect(ownerDocument.body.textContent).not.toContain('Mark as Reviewed')
    expect(ownerDocument.activeElement).toBe(trigger)
    fireEvent.click(trigger)
    fireEvent.mouseDown(document.body)
    expect(ownerDocument.body.textContent).toContain('Mark as Reviewed')
    fireEvent.mouseDown(ownerDocument.body)
    expect(ownerDocument.body.textContent).not.toContain('Mark as Reviewed')

    unmount()
    frame.remove()
  })

  it('scopes CredentialActionsMenu outside clicks to its iframe document', () => {
    const { frame, ownerDocument, mount } = iframeMount()
    const { unmount } = render(createPortal(<CredentialActionsMenu onIssue={vi.fn()} onRevoke={vi.fn()} />, mount))
    const trigger = ownerDocument.querySelector<HTMLElement>('button')!

    fireEvent.click(trigger)
    expect(ownerDocument.body.textContent).toContain('Issue Credential')
    fireEvent.keyDown(document, { key: 'Escape' })
    expect(ownerDocument.body.textContent).toContain('Issue Credential')
    fireEvent.keyDown(ownerDocument, { key: 'Escape' })
    expect(ownerDocument.body.textContent).not.toContain('Issue Credential')
    expect(ownerDocument.activeElement).toBe(trigger)
    fireEvent.click(trigger)
    fireEvent.mouseDown(document.body)
    expect(ownerDocument.body.textContent).toContain('Issue Credential')
    fireEvent.mouseDown(ownerDocument.body)
    expect(ownerDocument.body.textContent).not.toContain('Issue Credential')

    unmount()
    frame.remove()
  })

  it.each([
    ['delegation attestation', (onClose: () => void) => <DelegationAttestationDrawer isOpen={true} onClose={onClose} attestation={null} />],
    ['authorization proof', (onClose: () => void) => <AuthorizationProofDrawer isOpen={true} onClose={onClose} />],
  ])('scopes %s Escape handling to its iframe window', (_name, drawer) => {
    const onClose = vi.fn()
    const { frame, mount } = iframeMount()
    const { unmount } = render(createPortal(drawer(onClose), mount))

    fireEvent.keyDown(window, { key: 'Escape' })
    expect(onClose).not.toHaveBeenCalled()
    fireEvent.keyDown(frame.contentWindow!, { key: 'Escape' })
    expect(onClose).toHaveBeenCalledOnce()

    unmount()
    frame.remove()
  })

  it('scopes NodeDetailDrawer Escape and focus trapping to its iframe document', () => {
    const node: TrustNode = {
      id: 'agent-1', label: 'Agent One', kind: 'agent', tenant: 'tenant-1', location: 'in-cluster',
      evidence: 'observed', source: 'test', observedAt: '2026-10-14T00:00:00Z', freshness: 'fixture',
      assurance: 'medium', reason: 'owner-document regression', x: 0, y: 0,
    }
    const onClose = vi.fn()
    const { frame, ownerDocument, mount } = iframeMount()
    const { unmount } = render(createPortal(
      <MemoryRouter>
        <NodeDetailDrawer node={node} isOpen={true} onClose={onClose} nodesById={new Map([[node.id, node]])} />
      </MemoryRouter>,
      mount,
    ))
    const close = ownerDocument.querySelector<HTMLElement>('[data-testid="node-drawer-close-btn"]')!
    const policies = ownerDocument.querySelector<HTMLElement>('[data-testid="drawer-policies-link"]')!
    expect(ownerDocument.activeElement).toBe(close)

    fireEvent.keyDown(document, { key: 'Escape' })
    expect(onClose).not.toHaveBeenCalled()
    policies.focus()
    fireEvent.keyDown(ownerDocument, { key: 'Tab' })
    expect(ownerDocument.activeElement).toBe(close)
    fireEvent.keyDown(ownerDocument, { key: 'Escape' })
    expect(onClose).toHaveBeenCalledOnce()

    unmount()
    frame.remove()
  })
})
