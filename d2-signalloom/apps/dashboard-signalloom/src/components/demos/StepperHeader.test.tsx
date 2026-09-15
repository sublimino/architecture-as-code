import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import StepperHeader from './StepperHeader'
import { STAGE_IDS, type StageExecutionStatus, type StageId } from './types'

describe('StepperHeader', () => {
  const defaultStatuses: Record<StageId, StageExecutionStatus> = {
    operator_init: 'confirmed',
    host_enrolled: 'idle',
    confinement_streaming: 'idle',
    adversarial_tamper: 'idle',
    revocation_denied: 'idle',
  }

  it('renders all five stage indicators with stable data-testid attributes', () => {
    render(
      <StepperHeader
        currentStage="operator_init"
        stageStatuses={defaultStatuses}
      />,
    )

    expect(screen.getByTestId('stepper-header')).toBeInTheDocument()

    for (const stageId of STAGE_IDS) {
      expect(screen.getByTestId(`stage-indicator-${stageId}`)).toBeInTheDocument()
      expect(screen.getByTestId(`stage-status-${stageId}`)).toBeInTheDocument()
      expect(screen.getByTestId(`stage-jump-${stageId}`)).toBeInTheDocument()
    }

    expect(screen.getByTestId('stage-step-1')).toBeInTheDocument()
    expect(screen.getByTestId('stage-step-2')).toBeInTheDocument()
    expect(screen.getByTestId('stage-step-3')).toBeInTheDocument()
    expect(screen.getByTestId('stage-step-4')).toBeInTheDocument()
    expect(screen.getByTestId('stage-step-5')).toBeInTheDocument()
  })

  it('displays accurate stage titles and short titles', () => {
    render(
      <StepperHeader
        currentStage="operator_init"
        stageStatuses={defaultStatuses}
      />,
    )

    expect(screen.getByText('Token Issue')).toBeInTheDocument()
    expect(screen.getByText('Host Enrollment')).toBeInTheDocument()
    expect(screen.getByText('Confinement & Hashing')).toBeInTheDocument()
    expect(screen.getByText('Tamper Simulation')).toBeInTheDocument()
    expect(screen.getByText('Attributable Revocation')).toBeInTheDocument()
  })

  it('marks active stage with aria-current="step"', () => {
    render(
      <StepperHeader
        currentStage="host_enrolled"
        stageStatuses={{
          ...defaultStatuses,
          host_enrolled: 'in_flight',
        }}
      />,
    )

    const activeBtn = screen.getByTestId('stage-jump-host_enrolled')
    expect(activeBtn).toHaveAttribute('aria-current', 'step')

    const inactiveBtn = screen.getByTestId('stage-jump-operator_init')
    expect(inactiveBtn).not.toHaveAttribute('aria-current')
  })

  it('renders distinct visual statuses (confirmed, in_flight, failed, idle)', () => {
    const statuses: Record<StageId, StageExecutionStatus> = {
      operator_init: 'confirmed',
      host_enrolled: 'confirmed',
      confinement_streaming: 'in_flight',
      adversarial_tamper: 'failed',
      revocation_denied: 'idle',
    }

    render(
      <StepperHeader
        currentStage="confinement_streaming"
        stageStatuses={statuses}
      />,
    )

    expect(screen.getByTestId('stage-status-operator_init')).toHaveTextContent('confirmed')
    expect(screen.getByTestId('stage-status-host_enrolled')).toHaveTextContent('confirmed')
    expect(screen.getByTestId('stage-status-confinement_streaming')).toHaveTextContent('in_flight')
    expect(screen.getByTestId('stage-status-adversarial_tamper')).toHaveTextContent('failed')
    expect(screen.getByTestId('stage-status-revocation_denied')).toHaveTextContent('idle')
  })

  it('disables stage buttons when inFlight is true', () => {
    const onSelect = vi.fn()
    render(
      <StepperHeader
        currentStage="operator_init"
        stageStatuses={defaultStatuses}
        inFlight={true}
        onSelectStage={onSelect}
      />,
    )

    const stage1Btn = screen.getByTestId('stage-jump-operator_init')
    expect(stage1Btn).toBeDisabled()

    fireEvent.click(stage1Btn)
    expect(onSelect).not.toHaveBeenCalled()
  })

  it('disables stage buttons when disabled prop is true', () => {
    const onSelect = vi.fn()
    render(
      <StepperHeader
        currentStage="operator_init"
        stageStatuses={defaultStatuses}
        disabled={true}
        onSelectStage={onSelect}
      />,
    )

    const stage1Btn = screen.getByTestId('stage-jump-operator_init')
    expect(stage1Btn).toBeDisabled()

    fireEvent.click(stage1Btn)
    expect(onSelect).not.toHaveBeenCalled()
  })

  it('invokes onSelectStage when an accessible stage is clicked', () => {
    const onSelect = vi.fn()
    render(
      <StepperHeader
        currentStage="host_enrolled"
        stageStatuses={{
          ...defaultStatuses,
          operator_init: 'confirmed',
          host_enrolled: 'confirmed',
        }}
        onSelectStage={onSelect}
      />,
    )

    const stage1Btn = screen.getByTestId('stage-jump-operator_init')
    expect(stage1Btn).not.toBeDisabled()

    fireEvent.click(stage1Btn)
    expect(onSelect).toHaveBeenCalledWith('operator_init')
  })

  it('supports keyboard navigation with arrow keys and enter', () => {
    const onSelect = vi.fn()
    render(
      <StepperHeader
        currentStage="host_enrolled"
        stageStatuses={{
          ...defaultStatuses,
          operator_init: 'confirmed',
          host_enrolled: 'confirmed',
        }}
        onSelectStage={onSelect}
      />,
    )

    const stage2Btn = screen.getByTestId('stage-jump-host_enrolled')

    // Right arrow on stage 2 -> selects stage 3
    fireEvent.keyDown(stage2Btn, { key: 'ArrowRight' })
    expect(onSelect).toHaveBeenCalledWith('confinement_streaming')

    // Left arrow on stage 2 -> selects stage 1
    fireEvent.keyDown(stage2Btn, { key: 'ArrowLeft' })
    expect(onSelect).toHaveBeenCalledWith('operator_init')

    // Enter key on stage 2 -> selects stage 2
    fireEvent.keyDown(stage2Btn, { key: 'Enter' })
    expect(onSelect).toHaveBeenCalledWith('host_enrolled')
  })
})
