import { describe, it, expect, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import PolicyEditor, { tokenizeCel, validateCelExpression } from './PolicyEditor'
import type { PolicyBundle, VersionHistoryItem } from '../types/policies'

const mockBundle: PolicyBundle = {
  id: 'eu-ai-act-v2.1.0',
  framework_id: 'eu-ai-act',
  version: 'v2.1.0',
  author: 'system',
  description: 'EU AI Act Regulatory Bundle',
  created_at: '2026-09-28T12:00:00Z',
  checksum: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
  rules: [
    {
      id: 'container-run-as-non-root',
      name: 'AI system container runs as non-root',
      description: 'Ensures high-risk AI workloads do not execute with root UID privileges.',
      cel_expression: 'object.spec.containers.all(c, c.securityContext.runAsNonRoot == true)',
      severity: 'high',
      remediation: 'Configure securityContext.runAsNonRoot to true.',
    },
    {
      id: 'block-unauthorized-host-exec',
      name: 'Human authorization for host exec',
      description: 'Mandates human approval credential for sensitive host execution actions.',
      cel_expression: "request.tool_call.action in ['exec', 'write_file'] ? (has(request.context.claims) && request.context.claims.exists(c, c.type == 'human_approval_svid' && c.valid == true)) : true",
      severity: 'critical',
      remediation: 'Obtain valid human approval SVID.',
    },
  ],
}

const mockHistory: VersionHistoryItem[] = [
  {
    version: 'v2.1.0',
    author: 'system',
    description: 'Updated EU AI Act rules',
    created_at: '2026-09-28T12:00:00Z',
    rule_count: 2,
    checksum: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
  },
  {
    version: 'v2.0.0',
    author: 'alice',
    description: 'Initial draft of rules',
    created_at: '2026-09-20T10:00:00Z',
    rule_count: 1,
    checksum: 'a1b2c3d4e5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcdef0',
  },
]

describe('tokenizeCel helper', () => {
  it('tokenizes keywords, variables, macros, strings, and operators', () => {
    const code = "request.tool_call.action in ['exec'] && object.spec.containers.all(c, c.securityContext.runAsNonRoot == true)"
    const tokens = tokenizeCel(code)
    expect(tokens.length).toBe(1)
    const lineTokens = tokens[0]

    const types = lineTokens.map((t) => t.type)
    expect(types).toContain('variable') // request, object
    expect(types).toContain('keyword')  // in, true
    expect(types).toContain('macro')    // all
    expect(types).toContain('string')   // 'exec'
    expect(types).toContain('operator') // &&, ==
  })
})

describe('validateCelExpression helper', () => {
  it('returns valid for well-formed CEL expressions', () => {
    const res = validateCelExpression('object.spec.containers.all(c, c.securityContext.runAsNonRoot == true)')
    expect(res.valid).toBe(true)
  })

  it('returns invalid with line and column for malformed CEL expressions', () => {
    const res = validateCelExpression('object.spec.containers.all(c, c.securityContext.runAsNonRoot == )')
    expect(res.valid).toBe(false)
    expect(res.message).toBeDefined()
  })
})

describe('PolicyEditor Component', () => {
  it('renders the policy editor with bundle header and rule tabs', () => {
    render(<PolicyEditor bundle={mockBundle} versionHistory={mockHistory} />)
    expect(screen.getByTestId('policy-editor-container')).toBeInTheDocument()
    expect(screen.getByTestId('policy-version-badge')).toHaveTextContent('v2.1.0')
    expect(screen.getByTestId('rule-tab-container-run-as-non-root')).toBeInTheDocument()
    expect(screen.getByTestId('rule-tab-block-unauthorized-host-exec')).toBeInTheDocument()
  })

  it('displays valid CEL diagnostic badge on valid syntax', () => {
    render(<PolicyEditor bundle={mockBundle} versionHistory={mockHistory} />)
    expect(screen.getByTestId('cel-diagnostic-valid')).toBeInTheDocument()
    expect(screen.getByText('Valid CEL syntax')).toBeInTheDocument()
  })

  it('displays real-time error marker on invalid syntax and clears on correction', async () => {
    const user = userEvent.setup()
    render(<PolicyEditor bundle={mockBundle} versionHistory={mockHistory} />)

    const textarea = screen.getByTestId('cel-code-textarea')
    await user.clear(textarea)
    await user.type(textarea, 'request.action == &&')

    expect(await screen.findByTestId('cel-diagnostic-error')).toBeInTheDocument()
    expect(screen.getByTestId('cel-editor-workspace')).toHaveStyle('border: 1px solid var(--error)')

    // Correct syntax
    await user.clear(textarea)
    await user.type(textarea, "request.action == 'exec'")

    await waitFor(() => {
      expect(screen.getByTestId('cel-diagnostic-valid')).toBeInTheDocument()
    })
  })

  it('toggles version history drawer and displays monotonic versions', async () => {
    const user = userEvent.setup()
    render(<PolicyEditor bundle={mockBundle} versionHistory={mockHistory} />)

    const historyBtn = screen.getByTestId('toggle-version-history-btn')
    await user.click(historyBtn)

    expect(screen.getByTestId('version-history-drawer')).toBeInTheDocument()
    expect(screen.getByTestId('version-item-v2.1.0')).toBeInTheDocument()
    expect(screen.getByTestId('version-item-v2.0.0')).toBeInTheDocument()
  })

  it('displays diff viewer when a historical version is selected', async () => {
    const user = userEvent.setup()
    render(<PolicyEditor bundle={mockBundle} versionHistory={mockHistory} />)

    await user.click(screen.getByTestId('toggle-version-history-btn'))
    await user.click(screen.getByTestId('version-item-v2.0.0'))

    expect(screen.getByTestId('version-diff-viewer')).toBeInTheDocument()
    expect(screen.getByText(/v2.0.0 vs v2.1.0/i)).toBeInTheDocument()
  })

  it('opens confirmation modal and triggers rollback dispatch on confirmation', async () => {
    const user = userEvent.setup()
    const handleRollback = vi.fn().mockResolvedValue(undefined)

    render(
      <PolicyEditor
        bundle={mockBundle}
        versionHistory={mockHistory}
        onRollback={handleRollback}
      />,
    )

    await user.click(screen.getByTestId('toggle-version-history-btn'))
    await user.click(screen.getByTestId('version-item-v2.0.0'))

    const rollbackBtn = screen.getByTestId('rollback-btn')
    await user.click(rollbackBtn)

    // Confirmation modal should appear
    expect(screen.getByText('Confirm Policy Rollback')).toBeInTheDocument()
    const confirmButtons = screen.getAllByRole('button', { name: /Rollback to v2.0.0/i })
    const confirmBtn = confirmButtons[confirmButtons.length - 1]
    await user.click(confirmBtn)

    await waitFor(() => {
      expect(handleRollback).toHaveBeenCalledWith('eu-ai-act', 'v2.0.0')
    })
  })

  it('calls onSave with monotonic version increment when save button is clicked', async () => {
    const user = userEvent.setup()
    const handleSave = vi.fn().mockResolvedValue(undefined)

    render(
      <PolicyEditor
        bundle={mockBundle}
        versionHistory={mockHistory}
        onSave={handleSave}
      />,
    )

    const saveBtn = screen.getByTestId('save-policy-btn')
    await user.click(saveBtn)

    await waitFor(() => {
      expect(handleSave).toHaveBeenCalledWith(
        expect.objectContaining({
          version: 'v2.1.1',
          framework_id: 'eu-ai-act',
        }),
      )
    })
  })

  it('disables save button when expression has syntax error', async () => {
    const user = userEvent.setup()
    const handleSave = vi.fn()

    render(
      <PolicyEditor
        bundle={mockBundle}
        versionHistory={mockHistory}
        onSave={handleSave}
      />,
    )

    const textarea = screen.getByTestId('cel-code-textarea')
    await user.clear(textarea)
    await user.type(textarea, 'invalid syntax === !!!')

    const saveBtn = screen.getByTestId('save-policy-btn')
    expect(saveBtn).toBeDisabled()
  })

  it('handles escape key press without trapping focus', async () => {
    const user = userEvent.setup()
    render(<PolicyEditor bundle={mockBundle} versionHistory={mockHistory} />)

    const textarea = screen.getByTestId('cel-code-textarea')
    textarea.focus()
    expect(document.activeElement).toBe(textarea)

    await user.keyboard('{Escape}')
    expect(document.activeElement).not.toBe(textarea)
  })
})
