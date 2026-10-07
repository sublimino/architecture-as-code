import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import ContainmentPolicyConsentStep from './ContainmentPolicyConsentStep'

describe('ContainmentPolicyConsentStep', () => {
  const defaultProps = {
    tenantProfile: { organizationName: 'Acme Corp', workspaceId: 'acme-corp', adminEmail: 'admin@acme.com', environment: 'production' as const },
    idpConfig: { providerId: 'oidc', providerName: 'Dex OIDC', issuerUrl: 'https://dex.example.com', clientId: 'client', scopes: 'openid' },
    onSubmit: vi.fn(),
    onBack: vi.fn(),
    onSkip: vi.fn(),
  }

  it('renders security containment profiles with Sentinel eBPF description', () => {
    render(<ContainmentPolicyConsentStep {...defaultProps} />)

    expect(screen.getByText('Security Containment Profile')).toBeInTheDocument()
    expect(screen.getByText('Strict Sandboxed & Hash-Chained Audit (Recommended)')).toBeInTheDocument()
    expect(
      screen.getByText(/Applies Linux Landlock LSM unprivileged sandboxing \(nono\), SPIFFE detached signatures, and real-time Sentinel eBPF telemetry with sub-second execution halt\./)
    ).toBeInTheDocument()
  })

  it('submits containment policy with default strict sandboxed values', () => {
    const onSubmit = vi.fn()
    render(<ContainmentPolicyConsentStep {...defaultProps} onSubmit={onSubmit} />)

    const submitButton = screen.getByTestId('complete-onboarding-button')
    fireEvent.click(submitButton)

    expect(onSubmit).toHaveBeenCalledWith({
      policyTier: 'strict-sandboxed',
      zeroTrustIdentity: true,
      autonomousContainment: true,
      auditTrailRetention: true,
    })
  })

  it('allows selecting standard-baseline tier and submitting', () => {
    const onSubmit = vi.fn()
    render(<ContainmentPolicyConsentStep {...defaultProps} onSubmit={onSubmit} />)

    const standardOption = screen.getByText('Standard Containerized Baseline')
    fireEvent.click(standardOption)

    const submitButton = screen.getByTestId('complete-onboarding-button')
    fireEvent.click(submitButton)

    expect(onSubmit).toHaveBeenCalledWith({
      policyTier: 'standard-baseline',
      zeroTrustIdentity: true,
      autonomousContainment: true,
      auditTrailRetention: true,
    })
  })

  it('validates required consent checkboxes before submitting', () => {
    const onSubmit = vi.fn()
    render(<ContainmentPolicyConsentStep {...defaultProps} onSubmit={onSubmit} />)

    // Uncheck zero trust identity
    const zeroTrustCheckbox = screen.getByTestId('consent-zero-trust')
    fireEvent.click(zeroTrustCheckbox)

    const submitButton = screen.getByTestId('complete-onboarding-button')
    fireEvent.click(submitButton)

    expect(onSubmit).not.toHaveBeenCalled()
    expect(
      screen.getByText('Zero-Trust Workload Identity consent is required for autonomous agent security.')
    ).toBeInTheDocument()
  })

  it('invokes onBack and onSkip callbacks cleanly', () => {
    const onBack = vi.fn()
    const onSkip = vi.fn()
    render(<ContainmentPolicyConsentStep {...defaultProps} onBack={onBack} onSkip={onSkip} />)

    fireEvent.click(screen.getByTestId('back-step-button'))
    expect(onBack).toHaveBeenCalledTimes(1)

    fireEvent.click(screen.getByRole('button', { name: /skip for now/i }))
    expect(onSkip).toHaveBeenCalledTimes(1)
  })
})
