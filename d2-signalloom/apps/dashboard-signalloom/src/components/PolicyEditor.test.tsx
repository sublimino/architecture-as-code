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

  it('never publishes catalogue-only rules, and never labels them engine-evaluated', async () => {
    const user = userEvent.setup()
    const handleSave = vi.fn().mockResolvedValue(undefined)
    const catalogueRule = {
      id: 'cis-5.4.1',
      name: 'CIS 5.4.1: ResourceQuotas',
      cel_expression: 'has(object.spec.hard)',
      catalogue_only: true,
    }
    render(
      <PolicyEditor
        bundle={{ ...mockBundle, rules: [catalogueRule, ...mockBundle.rules] }}
        onSave={handleSave}
      />,
    )

    // The catalogue rule is selected first: shown as reference, not as evaluated, not editable.
    expect(screen.getByTestId('catalogue-only-badge')).toBeInTheDocument()
    expect(screen.queryByTestId('cel-evaluated-badge')).toBeNull()
    expect(screen.getByTestId('cel-code-textarea')).toHaveAttribute('readonly')

    await user.click(screen.getByTestId('save-policy-btn'))
    await waitFor(() => expect(handleSave).toHaveBeenCalledTimes(1))
    expect(handleSave.mock.calls[0][0].rules).toEqual(mockBundle.rules)
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

  it('prettifies unformatted CEL expression when Prettify button is clicked', async () => {
    const user = userEvent.setup()
    const bundleWithUnformatted: PolicyBundle = {
      ...mockBundle,
      rules: [
        {
          id: 'long-rule',
          name: 'Long Rule',
          cel_expression: 'has(object.spec.hostPID) && object.spec.hostPID == false && has(object.spec.hostIPC) && object.spec.hostIPC == false',
        },
      ],
    }

    render(<PolicyEditor bundle={bundleWithUnformatted} />)

    const textarea = screen.getByTestId('cel-code-textarea') as HTMLTextAreaElement
    const prettifyBtn = screen.getByTestId('prettify-cel-btn')
    await user.click(prettifyBtn)

    expect(textarea.value).toContain('\n  && ')
  })

  it('toggles line wrapping when wrap button is clicked', async () => {
    const user = userEvent.setup()
    render(<PolicyEditor bundle={mockBundle} />)

    const wrapBtn = screen.getByTestId('toggle-wrap-btn')
    expect(wrapBtn).toHaveTextContent('Wrap: ON')

    const textarea = screen.getByTestId('cel-code-textarea')
    expect(textarea.style.whiteSpace).toBe('pre-wrap')

    await user.click(wrapBtn)
    expect(wrapBtn).toHaveTextContent('Wrap: OFF')
    expect(textarea.style.whiteSpace).toBe('pre')
  })

  it('filters rules list using the search input', async () => {
    const user = userEvent.setup()
    render(<PolicyEditor bundle={mockBundle} />)

    expect(screen.getByTestId('rule-tab-container-run-as-non-root')).toBeInTheDocument()
    expect(screen.getByTestId('rule-tab-block-unauthorized-host-exec')).toBeInTheDocument()

    const searchInput = screen.getByTestId('rule-search-input')
    await user.type(searchInput, 'non-root')

    expect(screen.getByTestId('rule-tab-container-run-as-non-root')).toBeInTheDocument()
    expect(screen.queryByTestId('rule-tab-block-unauthorized-host-exec')).not.toBeInTheDocument()
  })

  it('displays manual attestation badge for non-CEL controls', () => {
    const bundleWithManual: PolicyBundle = {
      ...mockBundle,
      rules: [
        {
          id: 'art-11-tech-doc',
          name: 'Art. 11 Technical Documentation',
          cel_expression: '/* Non-CEL: Requires human architect certification. */',
          manual_attestation: true,
          manual_attestation_note: 'Non-CEL control. Requires manual sign-off.',
        },
      ],
    }

    render(<PolicyEditor bundle={bundleWithManual} />)
    expect(screen.getByTestId('manual-attestation-badge')).toBeInTheDocument()
    expect(screen.getByText(/Non-CEL Verification Context/i)).toBeInTheDocument()
  })

  it('renders resilient empty bundle state without removing framework selector', () => {
    const emptyBundle: PolicyBundle = {
      ...mockBundle,
      rules: [],
    }

    const available = [{ id: 'eu-ai-act', name: 'EU AI Act' }, { id: 'cra', name: 'Cyber Resilience Act' }]
    const onSelect = vi.fn()

    render(
      <PolicyEditor
        bundle={emptyBundle}
        availableFrameworks={available}
        onSelectFramework={onSelect}
      />
    )

    expect(screen.getByTestId('empty-bundle-notice')).toBeInTheDocument()
    expect(screen.getByTestId('framework-selector')).toBeInTheDocument()
    expect(screen.getByTestId('initialize-template-btn')).toBeInTheDocument()
  })

  it('handles clipboard writeText safely when pre-granted or rejected', async () => {
    const user = userEvent.setup()

    // Test rejection: writeText rejects (e.g. clipboard permissions not pre-granted)
    const writeTextMock = vi.fn().mockRejectedValue(new Error('NotAllowedError: Clipboard permission denied'))
    Object.defineProperty(navigator, 'clipboard', {
      value: { writeText: writeTextMock },
      configurable: true,
    })

    render(<PolicyEditor bundle={mockBundle} versionHistory={mockHistory} />)
    const shareBtn = screen.getByText(/Share Link/i)
    expect(shareBtn).toBeInTheDocument()

    // Clicking share link when clipboard rejects must not throw unhandled rejection
    await user.click(shareBtn)
    expect(writeTextMock).toHaveBeenCalledWith(
      expect.stringContaining('/policies?framework=eu-ai-act&rule=container-run-as-non-root')
    )
    expect(screen.getByText('✓ Copied')).toBeInTheDocument()

    // Test resolution: writeText succeeds
    writeTextMock.mockResolvedValue(undefined)
    await user.click(shareBtn)
    expect(screen.getByText('✓ Copied')).toBeInTheDocument()
  })
})

