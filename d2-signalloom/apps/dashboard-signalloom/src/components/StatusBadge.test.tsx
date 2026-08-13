import { describe, it, expect } from 'vitest'
import { render } from '@testing-library/react'
import StatusBadge, { getStatusColor } from './StatusBadge'

describe('StatusBadge', () => {
  it('resolves lifecycle "active" to the teal token, not a hardcoded hex', () => {
    const { color, bg, border } = getStatusColor('active', 'lifecycle')
    expect(color).toBe('var(--teal)')
    expect(bg).toContain('var(--teal)')
    expect(border).toContain('var(--teal)')
  })

  it('resolves risk "high_risk" to the amber token', () => {
    const { color, bg } = getStatusColor('high_risk', 'risk')
    expect(color).toBe('var(--amber)')
    expect(bg).toContain('var(--amber)')
  })

  it('falls back to the neutral token for an unrecognized status', () => {
    const { color } = getStatusColor('totally_unknown')
    expect(color).toBe('var(--muted)')
  })

  it('renders the status text with underscores replaced by spaces', () => {
    const { getByText } = render(<StatusBadge status="high_risk" variant="risk" />)
    expect(getByText('high risk')).toBeTruthy()
  })

  it('carries a title and a test id when the caller needs the badge to explain itself', () => {
    const { getByTestId } = render(
      <StatusBadge status="config" testId="provenance-tag" title="Declared in the manifests, not observed" />,
    )
    expect(getByTestId('provenance-tag')).toHaveAttribute('title', 'Declared in the manifests, not observed')
  })

  describe('the three variants added for the superadmin pages', () => {
    it('reads a credential "pending" as in-flight, not as an unrun assessment', () => {
      // Same word as compliance's `pending`, opposite meaning — which is why
      // it needed its own map rather than a key on an existing one.
      expect(getStatusColor('pending', 'credential').color).toBe('var(--cyan)')
      expect(getStatusColor('pending', 'compliance').color).toBe('var(--muted)')
    })

    it('colours the credential states the inventory actually renders', () => {
      const expected = {
        active: 'var(--teal)', pending: 'var(--cyan)', expired: 'var(--amber)',
        failed: 'var(--error)', revoked: 'var(--error)',
      }
      for (const [status, color] of Object.entries(expected)) {
        expect(getStatusColor(status, 'credential').color, status).toBe(color)
      }
    })

    it('colours seal state and PQC readiness', () => {
      expect(getStatusColor('unsealed', 'crypto').color).toBe('var(--teal)')
      expect(getStatusColor('sealed', 'crypto').color).toBe('var(--error)')
      expect(getStatusColor('ready', 'crypto').color).toBe('var(--teal)')
      expect(getStatusColor('hybrid', 'crypto').color).toBe('var(--cyan)')
      expect(getStatusColor('classical', 'crypto').color).toBe('var(--amber)')
      expect(getStatusColor('expiring', 'crypto').color).toBe('var(--amber)')
    })

    it('colours federation state', () => {
      expect(getStatusColor('federated', 'federation').color).toBe('var(--teal)')
      expect(getStatusColor('connecting', 'federation').color).toBe('var(--cyan)')
    })

    // The one way adding a map can break a page that never asked for it: an
    // un-varianted lookup takes the first match in insertion order, so a new
    // map inserted ahead of an old one silently recolours other pages.
    it('leaves every un-varianted lookup resolving exactly where it did before', () => {
      const before: Record<string, string> = {
        // lifecycle
        enrolled: 'var(--cyan)', active: 'var(--teal)', suspended: 'var(--amber)', revoked: 'var(--error)',
        // risk
        high_risk: 'var(--amber)', unacceptable_risk: 'var(--error)', gpai: 'var(--violet)',
        // privilege
        standard: 'var(--muted)', elevated: 'var(--amber)', enterprise_admin: 'var(--error)',
        // violation
        new: 'var(--error)', acknowledged: 'var(--amber)', resolved: 'var(--teal)',
        // compliance — `pending` is the collision the new maps could have stolen
        pass: 'var(--teal)', fail: 'var(--error)', pending: 'var(--muted)',
        // nhi
        discovered: 'var(--violet)', dismissed: 'var(--muted)',
      }
      for (const [status, color] of Object.entries(before)) {
        expect(getStatusColor(status).color, status).toBe(color)
      }
    })
  })
})
