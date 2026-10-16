import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ConnectorConfigureModal from './ConnectorConfigureModal'
import type { ConnectorProvider, TenantConnector } from '../types/connectors'

vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently: () => Promise.resolve('tok') }),
}))

const api = vi.hoisted(() => ({
  testProviderCredentials: vi.fn(),
  testConnector: vi.fn(),
}))
vi.mock('../api/connectorsClient', () => ({
  connectorsApi: api,
  isConnectorsMockMode: () => false,
}))

// Mirrors STANDARD_PROVIDERS in fe-signalloom routers/connectors.py.
const claude: ConnectorProvider = {
  provider_id: 'claude',
  display_name: 'Anthropic Claude',
  wizard_config: {
    fields: [
      { name: 'api_key', label: 'Anthropic API Key', type: 'password', required: true },
      { name: 'workspace_id', label: 'Workspace ID (optional)', type: 'text', required: false },
      { name: 'admin_api_key', label: 'Admin API Key (optional)', type: 'password', required: false },
    ],
    permissions: ['read'],
    docs_link: '',
    help_text: '',
  },
}

const awsIam: ConnectorProvider = {
  provider_id: 'aws_iam',
  display_name: 'AWS IAM',
  wizard_config: {
    fields: [
      { name: 'account_id', label: 'AWS Account ID', type: 'text', required: true },
      { name: 'role_arn', label: 'Cross-Account Role ARN', type: 'text', required: true },
      { name: 'external_id', label: 'External ID', type: 'password', required: true },
    ],
    permissions: ['read'],
    docs_link: '',
    help_text: '',
  },
}

const stored: TenantConnector = {
  connector_id: 'conn-claude-01',
  provider_id: 'claude',
  display_name: 'Prod Claude',
  status: 'connected',
  credential_expires_at: null,
  last_tested_at: null,
  last_scan_at: null,
  metadata: {},
  created_at: '2026-10-01T00:00:00Z',
}

const ok = { valid: true, scopes_ok: true, error_msg: null, credential_expires_at: null, needs_rotation: false }

describe('ConnectorConfigureModal', () => {
  const onSave = vi.fn()
  const onClose = vi.fn()

  beforeEach(() => {
    vi.clearAllMocks()
    onSave.mockResolvedValue(undefined)
  })

  function open(props: Partial<React.ComponentProps<typeof ConnectorConfigureModal>> = {}) {
    return render(
      <ConnectorConfigureModal isOpen provider={claude} onClose={onClose} onSave={onSave} {...props} />,
    )
  }

  it('renders the provider fields declared by wizard_config, including the Claude admin key', async () => {
    const user = userEvent.setup()
    open()
    expect(screen.queryByTestId('tab-auth-oidc')).not.toBeInTheDocument()
    expect(screen.queryByTestId('radio-connector-test-simulated')).not.toBeInTheDocument()

    await user.type(screen.getByTestId('wizard-field-api_key'), 'sk-ant-k')
    await user.type(screen.getByTestId('wizard-field-admin_api_key'), 'sk-ant-admin-k')
    await user.click(screen.getByTestId('btn-modal-save-connector'))

    await waitFor(() => expect(onSave).toHaveBeenCalled())
    expect(onSave.mock.calls[0][0].credentials).toEqual({ api_key: 'sk-ant-k', admin_api_key: 'sk-ant-admin-k' })
  })

  it('a passing test never substitutes for a missing required credential', async () => {
    const user = userEvent.setup()
    open({ verify: async () => ({ status: 'verified', message: 'ok' }) })

    await user.click(screen.getByTestId('btn-modal-test-connection'))
    await screen.findByTestId('test-connection-success')
    await user.click(screen.getByTestId('btn-modal-save-connector'))

    expect(await screen.findByTestId('connector-save-error')).toHaveTextContent('Anthropic API Key is required.')
    expect(onSave).not.toHaveBeenCalled()
  })

  it('validates every required wizard_config field for generic providers', async () => {
    const user = userEvent.setup()
    open({ provider: awsIam })
    await user.type(screen.getByTestId('wizard-field-account_id'), '123456789012')
    await user.click(screen.getByTestId('btn-modal-save-connector'))

    expect(await screen.findByTestId('connector-save-error')).toHaveTextContent('Cross-Account Role ARN is required.')
    expect(onSave).not.toHaveBeenCalled()
  })

  it('keeps stored credentials when nothing is typed, and does not overwrite the custom name', async () => {
    const user = userEvent.setup()
    open({ connector: stored })
    expect(screen.getByTestId('connector-stored-credentials-note')).toBeInTheDocument()

    await user.click(screen.getByTestId('btn-modal-save-connector'))

    await waitFor(() => expect(onSave).toHaveBeenCalled())
    const payload = onSave.mock.calls[0][0]
    expect(payload.credentials).toEqual({})
    expect(payload).not.toHaveProperty('display_name')
  })

  it('a partial edit of a stored connector must re-enter the required fields, since the server replaces the set', async () => {
    const user = userEvent.setup()
    open({ connector: stored })
    await user.type(screen.getByTestId('wizard-field-workspace_id'), 'wrkspc_2')
    await user.click(screen.getByTestId('btn-modal-save-connector'))

    expect(await screen.findByTestId('connector-save-error')).toHaveTextContent('Anthropic API Key is required.')
    expect(onSave).not.toHaveBeenCalled()
  })

  it('a new connector is named after the provider', async () => {
    const user = userEvent.setup()
    open()
    await user.type(screen.getByTestId('wizard-field-api_key'), 'sk-ant-k')
    await user.click(screen.getByTestId('btn-modal-save-connector'))
    await waitFor(() => expect(onSave).toHaveBeenCalled())
    expect(onSave.mock.calls[0][0].display_name).toBe('Anthropic Claude')
  })

  it('tests a stored connector through its own route and never sends a placeholder secret', async () => {
    const user = userEvent.setup()
    api.testConnector.mockResolvedValue({ connector_id: stored.connector_id, ...ok })
    open({ connector: stored })

    await user.click(screen.getByTestId('btn-modal-test-connection'))

    expect(await screen.findByTestId('test-connection-success')).toBeInTheDocument()
    expect(api.testConnector).toHaveBeenCalledWith('tok', 'conn-claude-01')
    expect(api.testProviderCredentials).not.toHaveBeenCalled()
  })

  it('shows success only when the server verified the typed credentials', async () => {
    const user = userEvent.setup()
    api.testProviderCredentials.mockResolvedValue(ok)
    open()
    await user.type(screen.getByTestId('wizard-field-api_key'), 'sk-ant-k')
    await user.click(screen.getByTestId('btn-modal-test-connection'))

    expect(await screen.findByTestId('test-connection-success')).toBeInTheDocument()
    expect(api.testProviderCredentials).toHaveBeenCalledWith('tok', 'claude', { api_key: 'sk-ant-k' })
    expect(screen.queryByText(/Discovered remote agent/)).not.toBeInTheDocument()
  })

  it('a key that merely looks right is not verified when the server rejects it', async () => {
    const user = userEvent.setup()
    api.testProviderCredentials.mockResolvedValue({ ...ok, valid: false, scopes_ok: false, error_msg: 'invalid x-api-key' })
    open()
    await user.type(screen.getByTestId('wizard-field-api_key'), 'sk-ant-looks-fine')
    await user.click(screen.getByTestId('btn-modal-test-connection'))

    expect(await screen.findByTestId('test-connection-error')).toHaveTextContent('invalid x-api-key')
    expect(screen.queryByTestId('test-connection-success')).not.toBeInTheDocument()
  })

  it('a provider with no real verifier reports Not checked', async () => {
    const user = userEvent.setup()
    api.testProviderCredentials.mockRejectedValue({ response: { status: 501, data: { error: { code: 'test_unsupported' } } } })
    open()
    await user.type(screen.getByTestId('wizard-field-api_key'), 'sk-ant-k')
    await user.click(screen.getByTestId('btn-modal-test-connection'))

    expect(await screen.findByTestId('test-connection-unchecked')).toHaveTextContent(
      'Not checked: this provider cannot be verified before saving',
    )
    expect(screen.queryByTestId('test-connection-success')).not.toBeInTheDocument()
  })

  it('reports the verdict to the parent', async () => {
    const user = userEvent.setup()
    const onTested = vi.fn()
    api.testProviderCredentials.mockResolvedValue(ok)
    open({ onTested })
    await user.type(screen.getByTestId('wizard-field-api_key'), 'sk-ant-k')
    await user.click(screen.getByTestId('btn-modal-test-connection'))
    await waitFor(() => expect(onTested).toHaveBeenCalledWith(expect.objectContaining({ status: 'verified' })))
  })

  it('prefills initial values', async () => {
    const user = userEvent.setup()
    open({ provider: awsIam, initialValues: { account_id: '123456789012', role_arn: 'arn:aws:iam::1:role/r', external_id: 'ext' } })
    await user.click(screen.getByTestId('btn-modal-save-connector'))
    await waitFor(() => expect(onSave).toHaveBeenCalled())
    expect(onSave.mock.calls[0][0].credentials).toEqual({ account_id: '123456789012', role_arn: 'arn:aws:iam::1:role/r', external_id: 'ext' })
  })

  it('a save failure stays in the modal with the error', async () => {
    const user = userEvent.setup()
    onSave.mockRejectedValue(new Error('403 forbidden'))
    open()
    await user.type(screen.getByTestId('wizard-field-api_key'), 'sk-ant-k')
    await user.click(screen.getByTestId('btn-modal-save-connector'))
    expect(await screen.findByTestId('connector-save-error')).toHaveTextContent('403 forbidden')
    expect(onClose).not.toHaveBeenCalled()
  })

  // ── Design-system audit A7 cleanup ──────────────────────────────────────

  it('lets .card supply the dialog surface instead of a duplicate inline background/border/radius', () => {
    open()
    const dialog = screen.getByRole('dialog')
    expect(dialog).toHaveClass('card')
    const style = dialog.getAttribute('style') ?? ''
    expect(style).not.toContain('background')
    expect(style).not.toContain('border-radius')
    // 'border' as a longhand (not just border-top etc.) must be absent too.
    expect(style).not.toMatch(/(?:^|;)\s*border:/)
  })

  it('themes the stored-credentials note with tint() instead of the unthemed --cyan-focus/-border alpha ramp', () => {
    open({ connector: stored })
    const note = screen.getByTestId('connector-stored-credentials-note')
    const style = note.getAttribute('style') ?? ''
    expect(style).not.toContain('var(--cyan-focus)')
    expect(style).not.toContain('var(--cyan-border)')
    expect(style).toContain('color-mix(in srgb, var(--cyan)')
  })

  it('themes the save-error banner with tint() instead of the unthemed --red-focus/-border alpha ramp', async () => {
    const user = userEvent.setup()
    onSave.mockRejectedValue(new Error('403 forbidden'))
    open()
    await user.type(screen.getByTestId('wizard-field-api_key'), 'sk-ant-k')
    await user.click(screen.getByTestId('btn-modal-save-connector'))
    const banner = await screen.findByTestId('connector-save-error')
    const style = banner.getAttribute('style') ?? ''
    expect(style).not.toContain('var(--red-focus)')
    expect(style).not.toContain('var(--red-border)')
    expect(style).toContain('color-mix(in srgb, var(--error)')
  })

  it('renders nothing when closed', () => {
    render(<ConnectorConfigureModal isOpen={false} provider={claude} onClose={onClose} onSave={onSave} />)
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })

  // rules-of-hooks is off repo-wide, and React 18 does not throw when an early
  // return skips every hook (it silently remounts state), so the only reliable
  // guard on the hook order of this file is the lint rule itself.
  it('calls no hook after an early return (react-hooks/rules-of-hooks)', async () => {
    const { ESLint } = await import('eslint')
    const eslint = new ESLint({ overrideConfig: { rules: { 'react-hooks/rules-of-hooks': 'error' } } })
    const [result] = await eslint.lintFiles([`${process.cwd()}/src/components/ConnectorConfigureModal.tsx`])
    expect(result.messages.filter((m) => m.ruleId === 'react-hooks/rules-of-hooks')).toEqual([])
  }, 30_000)
})
