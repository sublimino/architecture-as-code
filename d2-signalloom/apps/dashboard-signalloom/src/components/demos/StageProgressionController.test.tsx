import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, act, waitFor } from '@testing-library/react'
import StageProgressionController, { AMXD_DEMO_STAGE_STORAGE_KEY } from './StageProgressionController'
import { createMockBridge } from './bridge'
import { HAPPY_PATH_PRESET } from './scenarios'

class MockStorage implements Storage {
  private store = new Map<string, string>()

  get length(): number {
    return this.store.size
  }

  clear(): void {
    this.store.clear()
  }

  getItem(key: string): string | null {
    return this.store.get(key) ?? null
  }

  key(index: number): string | null {
    return Array.from(this.store.keys())[index] ?? null
  }

  removeItem(key: string): void {
    this.store.delete(key)
  }

  setItem(key: string, value: string): void {
    this.store.set(key, value)
  }
}

describe('StageProgressionController', () => {
  let storage: MockStorage

  beforeEach(() => {
    storage = new MockStorage()
  })

  it('renders in clean initial state (Stage 1, operator_init) on first mount with no prior state', () => {
    render(
      <StageProgressionController
        channel="mock"
        preset={HAPPY_PATH_PRESET}
        storage={storage}
      />,
    )

    expect(screen.getByTestId('stage-progression-controller')).toBeInTheDocument()
    expect(screen.getByTestId('stepper-header')).toBeInTheDocument()
    expect(screen.getByTestId('stepper-controls-bar')).toBeInTheDocument()

    // Stage 1 indicator is confirmed and active
    expect(screen.getByTestId('stage-status-operator_init')).toHaveTextContent('confirmed')
    expect(screen.getByTestId('stage-status-host_enrolled')).toHaveTextContent('idle')
    expect(screen.getByTestId('stage-jump-operator_init')).toHaveAttribute('aria-current', 'step')

    // Back button is disabled at Stage 1
    const backBtn = screen.getByTestId('stepper-retreat-button')
    expect(backBtn).toBeDisabled()

    // Advance button is enabled
    const advanceBtn = screen.getByTestId('stepper-advance-button')
    expect(advanceBtn).not.toBeDisabled()
  })

  it('advances sequentially to Stage 2 when Advance is clicked and settles with payload', async () => {
    const onStageChange = vi.fn()

    render(
      <StageProgressionController
        channel="mock"
        preset={HAPPY_PATH_PRESET}
        autoDwellMs={10}
        storage={storage}
        onStageChange={onStageChange}
      />,
    )

    const advanceBtn = screen.getByTestId('stepper-advance-button')

    await act(async () => {
      fireEvent.click(advanceBtn)
    })

    await waitFor(() => {
      expect(screen.getByTestId('stage-status-host_enrolled')).toHaveTextContent('confirmed')
    })

    expect(screen.getByTestId('stage-jump-host_enrolled')).toHaveAttribute('aria-current', 'step')
    expect(storage.getItem(AMXD_DEMO_STAGE_STORAGE_KEY)).toBe('host_enrolled')
    expect(onStageChange).toHaveBeenCalledWith('host_enrolled', expect.anything())
  })

  it('disables all navigation controls during in-flight async transition', async () => {
    let resolveAdvance: () => void = () => {}
    const slowBridge = createMockBridge({
      preset: HAPPY_PATH_PRESET,
      storage,
    })

    // Custom advance that stays pending until resolveAdvance is invoked
    const originalAdvance = slowBridge.advance.bind(slowBridge)
    const customAdvance = ((stage: any, opts: any) => {
      return new Promise((resolve) => {
        resolveAdvance = () => {
          resolve(originalAdvance(stage, opts))
        }
      })
    }) as typeof slowBridge.advance
    slowBridge.advance = customAdvance

    render(
      <StageProgressionController
        bridge={slowBridge}
        autoDwellMs={10}
        storage={storage}
      />,
    )

    const advanceBtn = screen.getByTestId('stepper-advance-button')
    const backBtn = screen.getByTestId('stepper-retreat-button')
    const resetBtn = screen.getByTestId('stepper-reset-button')
    const stage1Jump = screen.getByTestId('stage-jump-operator_init')

    // Start transition
    act(() => {
      fireEvent.click(advanceBtn)
    })

    // During in-flight: all controls are disabled
    expect(advanceBtn).toBeDisabled()
    expect(advanceBtn).toHaveTextContent('Advancing...')
    expect(backBtn).toBeDisabled()
    expect(resetBtn).toBeDisabled()
    expect(stage1Jump).toBeDisabled()

    // Settle transition
    await act(async () => {
      resolveAdvance()
    })

    await waitFor(() => {
      expect(screen.getByTestId('stage-status-host_enrolled')).toHaveTextContent('confirmed')
    })

    expect(advanceBtn).not.toBeDisabled()
    expect(backBtn).not.toBeDisabled()
    expect(resetBtn).not.toBeDisabled()
  })

  it('ensures rapid double-clicking during in-flight transition is a strict no-op', async () => {
    let resolveFirstAdvance: () => void = () => {}
    const bridge = createMockBridge({
      preset: HAPPY_PATH_PRESET,
      storage,
    })

    const originalAdvance = bridge.advance.bind(bridge)
    const advanceSpy = vi.fn((stage: any, opts: any) => {
      return new Promise((resolve) => {
        resolveFirstAdvance = async () => {
          const res = await originalAdvance(stage, opts)
          resolve(res)
        }
      })
    })
    bridge.advance = advanceSpy as unknown as typeof bridge.advance

    render(
      <StageProgressionController
        bridge={bridge}
        autoDwellMs={10}
        storage={storage}
      />,
    )

    const advanceBtn = screen.getByTestId('stepper-advance-button')

    // First click initiates transition
    act(() => {
      fireEvent.click(advanceBtn)
    })

    expect(advanceSpy).toHaveBeenCalledTimes(1)

    // Rapid second and third clicks while still in-flight
    act(() => {
      fireEvent.click(advanceBtn)
      fireEvent.click(advanceBtn)
    })

    // advanceSpy should still only have been called once!
    expect(advanceSpy).toHaveBeenCalledTimes(1)

    // Settle
    await act(async () => {
      resolveFirstAdvance()
    })

    await waitFor(() => {
      expect(screen.getByTestId('stage-status-host_enrolled')).toHaveTextContent('confirmed')
    })

    expect(advanceSpy).toHaveBeenCalledTimes(1)
  })

  it('allows stepping back to previous stage when Back is clicked', async () => {
    render(
      <StageProgressionController
        channel="mock"
        preset={HAPPY_PATH_PRESET}
        autoDwellMs={10}
        storage={storage}
      />,
    )

    // Advance to Stage 2
    const advanceBtn = screen.getByTestId('stepper-advance-button')
    await act(async () => {
      fireEvent.click(advanceBtn)
    })

    await waitFor(() => {
      expect(screen.getByTestId('stage-status-host_enrolled')).toHaveTextContent('confirmed')
    })

    const backBtn = screen.getByTestId('stepper-retreat-button')
    expect(backBtn).not.toBeDisabled()

    // Click Back
    act(() => {
      fireEvent.click(backBtn)
    })

    // Active view returns to Stage 1
    expect(screen.getByTestId('stage-jump-operator_init')).toHaveAttribute('aria-current', 'step')
  })

  it('jumps directly to a previously confirmed stage when clicked', async () => {
    render(
      <StageProgressionController
        channel="mock"
        preset={HAPPY_PATH_PRESET}
        autoDwellMs={10}
        storage={storage}
      />,
    )

    // Advance to Stage 2
    const advanceBtn = screen.getByTestId('stepper-advance-button')
    await act(async () => {
      fireEvent.click(advanceBtn)
    })

    await waitFor(() => {
      expect(screen.getByTestId('stage-status-host_enrolled')).toHaveTextContent('confirmed')
    })

    // Click Stage 1 jump button
    const stage1Btn = screen.getByTestId('stage-jump-operator_init')
    act(() => {
      fireEvent.click(stage1Btn)
    })

    expect(stage1Btn).toHaveAttribute('aria-current', 'step')
  })

  it('resets entire demo estate to Stage 1 when Reset Estate is clicked', async () => {
    const onReset = vi.fn()

    render(
      <StageProgressionController
        channel="mock"
        preset={HAPPY_PATH_PRESET}
        autoDwellMs={10}
        storage={storage}
        onReset={onReset}
      />,
    )

    // Advance to Stage 2
    const advanceBtn = screen.getByTestId('stepper-advance-button')
    await act(async () => {
      fireEvent.click(advanceBtn)
    })

    await waitFor(() => {
      expect(screen.getByTestId('stage-status-host_enrolled')).toHaveTextContent('confirmed')
    })

    expect(storage.getItem(AMXD_DEMO_STAGE_STORAGE_KEY)).toBe('host_enrolled')

    // Click Reset Estate
    const resetBtn = screen.getByTestId('stepper-reset-button')
    act(() => {
      fireEvent.click(resetBtn)
    })

    // State reset to Stage 1
    expect(screen.getByTestId('stage-status-operator_init')).toHaveTextContent('confirmed')
    expect(screen.getByTestId('stage-status-host_enrolled')).toHaveTextContent('idle')
    expect(screen.getByTestId('stage-jump-operator_init')).toHaveAttribute('aria-current', 'step')

    // Persisted stage cleared from storage
    expect(storage.getItem(AMXD_DEMO_STAGE_STORAGE_KEY)).toBeNull()
    expect(onReset).toHaveBeenCalledTimes(1)
  })

  it('restores persisted stage on reload within the same session', () => {
    // Simulate pre-existing stored stage
    storage.setItem(AMXD_DEMO_STAGE_STORAGE_KEY, 'confinement_streaming')

    render(
      <StageProgressionController
        channel="mock"
        preset={HAPPY_PATH_PRESET}
        storage={storage}
      />,
    )

    // Restores at Stage 3 with stages 1, 2, 3 confirmed
    expect(screen.getByTestId('stage-status-operator_init')).toHaveTextContent('confirmed')
    expect(screen.getByTestId('stage-status-host_enrolled')).toHaveTextContent('confirmed')
    expect(screen.getByTestId('stage-status-confinement_streaming')).toHaveTextContent('confirmed')
    expect(screen.getByTestId('stage-status-adversarial_tamper')).toHaveTextContent('idle')
    expect(screen.getByTestId('stage-jump-confinement_streaming')).toHaveAttribute('aria-current', 'step')
  })

  it('announces stage changes through ARIA live region', async () => {
    render(
      <StageProgressionController
        channel="mock"
        preset={HAPPY_PATH_PRESET}
        autoDwellMs={10}
        storage={storage}
      />,
    )

    const liveRegion = screen.getByTestId('stepper-aria-live')
    expect(liveRegion).toHaveAttribute('aria-live', 'polite')
    expect(liveRegion).toHaveTextContent(/AgentMaxxing Demo Console loaded/i)

    const advanceBtn = screen.getByTestId('stepper-advance-button')
    await act(async () => {
      fireEvent.click(advanceBtn)
    })

    await waitFor(() => {
      expect(liveRegion).toHaveTextContent(/Host Ed25519 Enrollment confirmed/i)
    })
  })

  it('supports keyboard navigation via ArrowRight and ArrowLeft', async () => {
    render(
      <StageProgressionController
        channel="mock"
        preset={HAPPY_PATH_PRESET}
        autoDwellMs={10}
        storage={storage}
      />,
    )

    const controller = screen.getByTestId('stage-progression-controller')

    // ArrowRight advances to Stage 2
    await act(async () => {
      fireEvent.keyDown(controller, { key: 'ArrowRight' })
    })

    await waitFor(() => {
      expect(screen.getByTestId('stage-status-host_enrolled')).toHaveTextContent('confirmed')
    })

    // ArrowLeft retreats to Stage 1
    act(() => {
      fireEvent.keyDown(controller, { key: 'ArrowLeft' })
    })

    expect(screen.getByTestId('stage-jump-operator_init')).toHaveAttribute('aria-current', 'step')
  })
})
