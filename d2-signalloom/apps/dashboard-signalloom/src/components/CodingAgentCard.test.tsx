// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { CodingAgentCard } from './CodingAgentCard'
import { FAKE_CODING_AGENT_TELEMETRY } from '../api/fakeCodingAgentData'

describe('CodingAgentCard', () => {
  it('renders all key metadata for claude harness', () => {
    const claudeRecord = FAKE_CODING_AGENT_TELEMETRY.find(r => r.event.harness === 'claude')!
    render(<CodingAgentCard record={claudeRecord} />)

    expect(screen.getByText('claude')).toBeInTheDocument()
    expect(screen.getByText(/comm: claude \(PID: 104231\)/i)).toBeInTheDocument()
    expect(screen.getByText(/SLCD-P5-2/i)).toBeInTheDocument()
    expect(screen.getByText(/#c4a71/i)).toBeInTheDocument()
    expect(screen.getByText(/implementation/i)).toBeInTheDocument()
    expect(screen.getByText(/3m 00s/i)).toBeInTheDocument()
    expect(screen.getByTestId('zero-payload-chip')).toBeInTheDocument()
    expect(screen.getByText(/api\.anthropic\.com/i)).toBeInTheDocument()
    expect(screen.getByText(/512(\.0)? KB egress/i)).toBeInTheDocument()
  })

  it('renders tool counts and tool histogram for antigravity harness', () => {
    const agyRecord = FAKE_CODING_AGENT_TELEMETRY.find(r => r.event.harness === 'antigravity')!
    render(<CodingAgentCard record={agyRecord} />)

    expect(screen.getByText('antigravity')).toBeInTheDocument()
    expect(screen.getByText(/comm: agy \(PID: 1186003\)/i)).toBeInTheDocument()
    expect(screen.getByText(/AMXD-P6-1/i)).toBeInTheDocument()
    expect(screen.getByText(/research/i)).toBeInTheDocument()
    expect(screen.getByText(/view_file:/i)).toBeInTheDocument()
    expect(screen.getByText(/grep_search:/i)).toBeInTheDocument()
    expect(screen.getByText(/run_command:/i)).toBeInTheDocument()
    expect(screen.getByText(/list_dir:/i)).toBeInTheDocument()
    expect(screen.getByText(/generativelanguage\.googleapis\.com/i)).toBeInTheDocument()
  })

  it('calls onSelect when card is clicked', () => {
    const codexRecord = FAKE_CODING_AGENT_TELEMETRY.find(r => r.event.harness === 'codex')!
    const onSelect = vi.fn()
    render(<CodingAgentCard record={codexRecord} onSelect={onSelect} />)

    const card = screen.getByTestId(`coding-agent-card-${codexRecord.event.session_id.slice(0, 8)}`)
    fireEvent.click(card)
    expect(onSelect).toHaveBeenCalledWith(codexRecord)
  })

  it('renders correctly across all 7 supported harnesses', () => {
    const harnesses = ['claude', 'antigravity', 'codex', 'cpai', 'opencode', 'hermes', 'aider'] as const
    for (const h of harnesses) {
      const rec = FAKE_CODING_AGENT_TELEMETRY.find(r => r.event.harness === h)
      expect(rec).toBeDefined()
      const { container } = render(<CodingAgentCard record={rec!} />)
      expect(container.textContent).toContain(h)
    }
  })
})
