import { describe, it, expect } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import React from 'react'
import {
  LandlockPolicyInspector,
  DEFAULT_LANDLOCK_RULES,
} from './LandlockPolicyInspector'

describe('LandlockPolicyInspector', () => {
  it('renders collapsed by default and displays rule count trigger', () => {
    render(<LandlockPolicyInspector />)

    expect(screen.getByTestId('landlock-policy-inspector')).toBeInTheDocument()
    expect(screen.getByText('Landlock LSM Path Policy Inspector')).toBeInTheDocument()
    expect(screen.getByText('ABI v3 (Linux 6.2+)')).toBeInTheDocument()

    const toggleBtn = screen.getByTestId('landlock-policy-inspector-toggle-btn')
    expect(toggleBtn).toBeInTheDocument()
    expect(toggleBtn.textContent).toContain('Inspect Path Rules (6 Active)')

    // Table should not be visible when collapsed
    expect(screen.queryByTestId('landlock-policy-inspector-table')).not.toBeInTheDocument()
  })

  it('expands on toggle and shows all default Landlock rules', () => {
    render(<LandlockPolicyInspector defaultOpen={true} />)

    expect(screen.getByTestId('landlock-policy-inspector-table')).toBeInTheDocument()
    expect(screen.getByText('/home/*/.ssh')).toBeInTheDocument()
    expect(screen.getByText('/etc/shadow')).toBeInTheDocument()
    expect(screen.getByText('/proc/kcore')).toBeInTheDocument()
    expect(screen.getByText('/var/run/docker.sock')).toBeInTheDocument()
    expect(screen.getByText('/tmp/agentmaxxing/telemetry')).toBeInTheDocument()
    expect(screen.getByText('/var/log/signal-loom')).toBeInTheDocument()
  })

  it('filters rules by text input', () => {
    render(<LandlockPolicyInspector defaultOpen={true} />)

    const filterInput = screen.getByTestId('landlock-policy-inspector-filter-input')
    fireEvent.change(filterInput, { target: { value: 'docker' } })

    expect(screen.getByText('/var/run/docker.sock')).toBeInTheDocument()
    expect(screen.queryByText('/home/*/.ssh')).not.toBeInTheDocument()
    expect(screen.queryByText('/tmp/agentmaxxing/telemetry')).not.toBeInTheDocument()
  })

  it('filters rules by category button', () => {
    render(<LandlockPolicyInspector defaultOpen={true} />)

    const telemetryBtn = screen.getByTestId('landlock-policy-inspector-category-telemetry_spool')
    fireEvent.click(telemetryBtn)

    expect(screen.getByText('/tmp/agentmaxxing/telemetry')).toBeInTheDocument()
    expect(screen.queryByText('/home/*/.ssh')).not.toBeInTheDocument()
    expect(screen.queryByText('/etc/shadow')).not.toBeInTheDocument()
  })
})
