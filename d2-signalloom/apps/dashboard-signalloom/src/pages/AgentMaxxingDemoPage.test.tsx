import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent, act, waitFor } from '@testing-library/react'
import React from 'react'
import AgentMaxxingDemoPage from './AgentMaxxingDemoPage'

describe('AgentMaxxingDemoPage', () => {
  it('renders page header with zero-customer-payload invariant badge and preset switcher', () => {
    render(<AgentMaxxingDemoPage />)

    expect(screen.getByTestId('agentmaxxing-demo-page')).toBeInTheDocument()
    expect(screen.getByText('AgentMaxxing Interactive Demo Console')).toBeInTheDocument()
    expect(screen.getByText('Zero Customer Payload Invariant')).toBeInTheDocument()
    expect(screen.getByText('Agent Governance Lab')).toBeInTheDocument()

    // Preset Switcher
    expect(screen.getByTestId('preset-switcher')).toBeInTheDocument()
    expect(screen.getByTestId('preset-option-amxd-demo-happy-path')).toBeInTheDocument()
    expect(screen.getByTestId('preset-option-amxd-demo-tamper-breach')).toBeInTheDocument()
    expect(screen.getByTestId('preset-option-amxd-demo-revocation-race')).toBeInTheDocument()
  })

  it('allows switching scenario presets from header', async () => {
    render(<AgentMaxxingDemoPage />)

    const tamperBtn = screen.getByTestId('preset-option-amxd-demo-tamper-breach')
    await act(async () => {
      fireEvent.click(tamperBtn)
    })

    expect(screen.getByText(/Adversarial defect simulation/i)).toBeInTheDocument()
    expect(screen.getByText(/MOCK CHANNEL \(Tamper Breach\)/i)).toBeInTheDocument()
  })

  it('renders initial Stage 1 panel and allows stepping to Stage 2', async () => {
    render(<AgentMaxxingDemoPage />)

    expect(screen.getByTestId('stage-panel-operator_init')).toBeInTheDocument()
    expect(screen.getByTestId('panel-status-badge-operator_init')).toHaveTextContent('confirmed')

    const advanceBtn = screen.getByTestId('stepper-advance-button')
    expect(advanceBtn).toBeInTheDocument()

    await act(async () => {
      fireEvent.click(advanceBtn)
    })

    await waitFor(() => {
      expect(screen.getByTestId('stage-panel-host_enrolled')).toBeInTheDocument()
    })

    expect(screen.getByTestId('panel-status-badge-host_enrolled')).toHaveTextContent('confirmed')
  })

  it('renders StatCards row with Stage Progress, Execution State, Channel & Preset, and Invariant Status', () => {
    render(<AgentMaxxingDemoPage />)

    expect(screen.getByText('Stage Progress')).toBeInTheDocument()
    expect(screen.getByText('01 / 05 Confirmed')).toBeInTheDocument()
    expect(screen.getByText('Execution State')).toBeInTheDocument()
    expect(screen.getByText('Active')).toBeInTheDocument()
    expect(screen.getByText('Channel & Preset')).toBeInTheDocument()
    expect(screen.getByText('MOCK / LIVE')).toBeInTheDocument()
    expect(screen.getByText('Invariant Status')).toBeInTheDocument()
    expect(screen.getByText('SHA-256 verifiable')).toBeInTheDocument()
  })

  it('renders attestation bundle export component with in-toto Statement v1', () => {
    render(<AgentMaxxingDemoPage />)

    expect(screen.getByTestId('attestation-bundle-export')).toBeInTheDocument()
    expect(screen.getByText('Cryptographic Attestation Bundle')).toBeInTheDocument()
    expect(screen.getByText('in-toto Statement v1')).toBeInTheDocument()
    expect(screen.getByTestId('attestation-download-btn')).toBeInTheDocument()
    expect(screen.getByTestId('attestation-copy-btn')).toBeInTheDocument()
  })

  it('renders execution log stream slot and mounts ConfinementTelemetryPanel & LandlockPolicyInspector at Stage 3', async () => {
    render(<AgentMaxxingDemoPage />)

    expect(screen.getByTestId('execution-log-stream-slot')).toBeInTheDocument()

    const advanceBtn = screen.getByTestId('stepper-advance-button')

    // Advance to Stage 2
    await act(async () => {
      fireEvent.click(advanceBtn)
    })
    await waitFor(() => {
      expect(screen.getByTestId('stage-panel-host_enrolled')).toBeInTheDocument()
    })

    // Advance to Stage 3
    await act(async () => {
      fireEvent.click(advanceBtn)
    })
    await waitFor(() => {
      expect(screen.getByTestId('stage-panel-confinement_streaming')).toBeInTheDocument()
    })

    expect(screen.getByTestId('panel-status-badge-confinement_streaming')).toHaveTextContent('confirmed')

    // Landlock Policy Inspector mounted in Stage 3
    expect(screen.getByTestId('landlock-policy-inspector')).toBeInTheDocument()
    expect(screen.getByText('Landlock LSM Path Policy Inspector')).toBeInTheDocument()
    expect(screen.getByText('ABI v3 (Linux 6.2+)')).toBeInTheDocument()
  })
})
