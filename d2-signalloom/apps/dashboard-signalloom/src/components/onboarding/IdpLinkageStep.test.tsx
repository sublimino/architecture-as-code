import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import IdpLinkageStep from './IdpLinkageStep'
import type { ConnectorProvider, TenantConnector } from '../../types/connectors'

vi.mock('../../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently: () => Promise.resolve('tok') }),
}))

const api = vi.hoisted(() => ({
  listProviders: vi.fn(),
  listConnectors: vi.fn(),
  createConnector: vi.fn(),
  testProviderCredentials: vi.fn(),
  testConnector: vi.fn(),
}))
vi.mock('../../api/connectorsClient', () => ({
  connectorsApi: api,
  isConnectorsMockMode: () => false,
}))

const provider = (provider_id: string, display_name: string, fields: [string, string][]): ConnectorProvider => ({
  provider_id,
  display_name,
  wizard_config: {
    fields: fields.map(([name, label]) => ({ name, label, type: 'password' as const, required: true })),
    permissions: ['read'],
    docs_link: '',
    help_text: '',
  },
})

// The backend catalogue (routers/connectors.py STANDARD_PROVIDERS), trimmed.
const PROVIDERS = [
  provider('okta', 'Okta', [['okta_domain', 'Okta Domain'], ['api_token', 'API Token']]),
  provider('ad_entra', 'Microsoft Entra ID', [['tenant_directory_id', 'Directory (tenant) ID'], ['client_id', 'Application (client) ID'], ['client_secret', 'Client secret']]),
  provider('google_workspace', 'Google Workspace', [['admin_email', 'Admin Email'], ['service_account_json', 'Service Account Key (JSON)']]),
  provider('aws_iam', 'AWS IAM', [['account_id', 'AWS Account ID'], ['role_arn', 'Role ARN'], ['external_id', 'External ID']]),
  provider('claude', 'Anthropic Claude', [['api_key', 'Anthropic API Key']]),
  provider('openai', 'OpenAI', [['api_key', 'OpenAI API Key']]),
]

describe('IdpLinkageStep', () => {
  const onNext = vi.fn()
  const onBack = vi.fn()
  const onSkip = vi.fn()
  const onTestConnection = vi.fn()

  beforeEach(() => {
    vi.clearAllMocks()
    api.listProviders.mockResolvedValue(PROVIDERS)
    api.listConnectors.mockResolvedValue([])
    api.createConnector.mockImplementation(async (_t: string, body: { provider_id: string }) => ({ connector_id: `conn-${body.provider_id}`, provider_id: body.provider_id, status: 'connected' }))
    onTestConnection.mockResolvedValue({ ok: true, message: 'Portal session verified' })
  })

  function renderStep(initialValues = {}, entries = ['/onboarding']) {
    return render(
      <MemoryRouter initialEntries={entries}>
        <IdpLinkageStep initialValues={initialValues} onNext={onNext} onBack={onBack} onSkip={onSkip} onTestConnection={onTestConnection} />
      </MemoryRouter>,
    )
  }

  async function openCard(user: ReturnType<typeof userEvent.setup>, id: string) {
    await user.click(await screen.findByTestId(`configure-idp-${id}`))
    return screen.findByRole('dialog')
  }

  it('has no hidden compatibility scaffolding', async () => {
    renderStep()
    await screen.findByTestId('idp-option-claude')
    for (const id of ['input-idp-issuer-url', 'input-idp-client-id', 'input-idp-api-key', 'test-idp-connection-button', 'configure-provider-claude']) {
      expect(screen.queryByTestId(id)).not.toBeInTheDocument()
    }
  })

  it('renders the fields the backend declares for the provider, not OIDC issuer fields', async () => {
    const user = userEvent.setup()
    renderStep()
    const dialog = await openCard(user, 'okta')
    expect(within(dialog).getByTestId('wizard-field-okta_domain')).toBeInTheDocument()
    expect(within(dialog).queryByTestId('wizard-field-issuer_url')).not.toBeInTheDocument()
  })

  it('a failed create stays in the modal with the error and does not mark the provider configured', async () => {
    const user = userEvent.setup()
    api.createConnector.mockRejectedValue(new Error('403: superadmin required'))
    renderStep()
    await openCard(user, 'claude')
    await user.type(screen.getByTestId('wizard-field-api_key'), 'sk-ant-k')
    await user.click(screen.getByTestId('btn-modal-save-connector'))

    expect(await screen.findByTestId('connector-save-error')).toHaveTextContent('403: superadmin required')
    expect(screen.getByRole('dialog')).toBeInTheDocument()
    expect(screen.queryByTestId('configured-tag-claude')).not.toBeInTheDocument()
  })

  it('a successful save creates the connector against the backend provider and marks it configured, but not verified', async () => {
    const user = userEvent.setup()
    renderStep()
    await openCard(user, 'claude')
    await user.type(screen.getByTestId('wizard-field-api_key'), 'sk-ant-k')
    await user.click(screen.getByTestId('btn-modal-save-connector'))

    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())
    expect(api.createConnector).toHaveBeenCalledWith('tok', expect.objectContaining({ provider_id: 'claude', credentials: { api_key: 'sk-ant-k' } }))
    expect(screen.getByTestId('configured-tag-claude')).toBeInTheDocument()

    await user.click(screen.getByTestId('next-step-button'))
    expect(onNext).toHaveBeenCalledWith(expect.objectContaining({ providerId: 'claude', connectionTested: false }))
  })

  it('a server-verified test is what records the connection as tested', async () => {
    const user = userEvent.setup()
    api.testProviderCredentials.mockResolvedValue({ valid: true, scopes_ok: true, error_msg: null, credential_expires_at: null, needs_rotation: false })
    renderStep()
    await openCard(user, 'claude')
    await user.type(screen.getByTestId('wizard-field-api_key'), 'sk-ant-k')
    await user.click(screen.getByTestId('btn-modal-test-connection'))
    await screen.findByTestId('test-connection-success')
    await user.click(screen.getByTestId('btn-modal-save-connector'))
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())

    await user.click(screen.getByTestId('next-step-button'))
    expect(onNext).toHaveBeenCalledWith(expect.objectContaining({ providerId: 'claude', connectionTested: true }))
  })

  it('switching provider does not carry a typed secret into the next provider', async () => {
    const user = userEvent.setup()
    renderStep()
    await openCard(user, 'claude')
    await user.type(screen.getByTestId('wizard-field-api_key'), 'sk-ant-secret')
    await user.click(screen.getByTestId('btn-modal-save-connector'))
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())

    await openCard(user, 'okta')
    expect(screen.getByTestId('wizard-field-okta_domain')).toHaveValue('')
    expect(screen.getByTestId('wizard-field-api_token')).toHaveValue('')
    await user.type(screen.getByTestId('wizard-field-okta_domain'), 'acme.okta.com')
    await user.type(screen.getByTestId('wizard-field-api_token'), 'okta-tok')
    await user.click(screen.getByTestId('btn-modal-save-connector'))

    await waitFor(() => expect(api.createConnector).toHaveBeenCalledTimes(2))
    expect(api.createConnector.mock.calls[1][1].credentials).toEqual({ okta_domain: 'acme.okta.com', api_token: 'okta-tok' })
  })

  it('in-cluster Dex is verified by the session probe and never posted as a connector', async () => {
    const user = userEvent.setup()
    renderStep()
    await openCard(user, 'dex')
    await user.click(screen.getByTestId('btn-modal-test-connection'))
    expect(await screen.findByTestId('test-connection-success')).toHaveTextContent('Portal session verified')
    expect(onTestConnection).toHaveBeenCalled()
    await user.click(screen.getByTestId('btn-modal-save-connector'))
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())

    expect(api.createConnector).not.toHaveBeenCalled()
    expect(screen.getByTestId('idp-connection-success')).toHaveTextContent('Portal session verified')
    await user.click(screen.getByTestId('next-step-button'))
    expect(onNext).toHaveBeenCalledWith(expect.objectContaining({ providerId: 'dex', connectionTested: true }))
  })

  it('a provider the server already holds credentials for opens with the stored-credentials note', async () => {
    const user = userEvent.setup()
    const existing: TenantConnector = {
      connector_id: 'conn-openai-01', provider_id: 'openai', display_name: 'OpenAI', status: 'connected',
      credential_expires_at: null, last_tested_at: null, last_scan_at: null, metadata: {}, created_at: '2026-10-01T00:00:00Z',
    }
    api.listConnectors.mockResolvedValue([existing])
    renderStep()
    expect(await screen.findByTestId('configured-tag-openai')).toBeInTheDocument()
    await openCard(user, 'openai')
    expect(screen.getByTestId('connector-stored-credentials-note')).toBeInTheDocument()
  })

  it('deep-links ?provider=claude straight into the modal', async () => {
    renderStep({}, ['/onboarding?provider=claude'])
    expect(await screen.findByRole('heading', { name: /Configure Anthropic Claude/i })).toBeInTheDocument()
    expect(screen.getByTestId('wizard-field-api_key')).toBeInTheDocument()
  })

  describe('provider radiogroup', () => {
    it('is a labelled radiogroup of radios, with Configure outside the radio', async () => {
      renderStep()
      const group = await screen.findByRole('radiogroup', { name: 'Select Identity Provider' })
      const radios = within(group).getAllByRole('radio')
      expect(radios).toHaveLength(7)

      // No nested interactive element: the Configure <button> for each option
      // is not a descendant of its radio.
      const dexRadio = within(group).getByRole('radio', { name: 'Dex OIDC (In-Cluster)' })
      expect(within(dexRadio).queryByRole('button')).not.toBeInTheDocument()
    })

    it('exposes selection state via aria-checked and defaults to Dex', async () => {
      renderStep()
      const dexRadio = await screen.findByRole('radio', { name: 'Dex OIDC (In-Cluster)' })
      const oktaRadio = screen.getByRole('radio', { name: 'Okta Workforce Identity' })
      expect(dexRadio).toHaveAttribute('aria-checked', 'true')
      expect(oktaRadio).toHaveAttribute('aria-checked', 'false')
    })

    it('uses a roving tabindex: only the selected radio is a tab stop', async () => {
      renderStep()
      const dexRadio = await screen.findByRole('radio', { name: 'Dex OIDC (In-Cluster)' })
      const oktaRadio = screen.getByRole('radio', { name: 'Okta Workforce Identity' })
      expect(dexRadio).toHaveAttribute('tabindex', '0')
      expect(oktaRadio).toHaveAttribute('tabindex', '-1')
    })

    it('ArrowDown moves selection and focus to the next provider without opening Configure', async () => {
      const user = userEvent.setup()
      renderStep()
      const dexRadio = await screen.findByRole('radio', { name: 'Dex OIDC (In-Cluster)' })
      dexRadio.focus()
      await user.keyboard('{ArrowDown}')

      const oktaRadio = screen.getByRole('radio', { name: 'Okta Workforce Identity' })
      expect(oktaRadio).toHaveAttribute('aria-checked', 'true')
      expect(oktaRadio).toHaveFocus()
      expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    })

    it('ArrowUp from the first option wraps to the last', async () => {
      const user = userEvent.setup()
      renderStep()
      const dexRadio = await screen.findByRole('radio', { name: 'Dex OIDC (In-Cluster)' })
      dexRadio.focus()
      await user.keyboard('{ArrowUp}')

      const lastRadio = screen.getByRole('radio', { name: 'OpenAI Platform' })
      expect(lastRadio).toHaveAttribute('aria-checked', 'true')
      expect(lastRadio).toHaveFocus()
    })

    it('clicking the radio selects it without opening Configure', async () => {
      const user = userEvent.setup()
      renderStep()
      const oktaRadio = await screen.findByRole('radio', { name: 'Okta Workforce Identity' })
      await user.click(oktaRadio)

      expect(oktaRadio).toHaveAttribute('aria-checked', 'true')
      expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    })

    it('has no orphan label: the legend names the radiogroup', async () => {
      renderStep()
      await screen.findByTestId('idp-option-dex')
      expect(screen.queryByText('Select Identity Provider')?.tagName).toBe('LEGEND')
    })
  })

  it('the connection outcome line is an announced status, not assertive colour-only text', async () => {
    const user = userEvent.setup()
    renderStep()
    await openCard(user, 'dex')
    await user.click(screen.getByTestId('btn-modal-test-connection'))
    await screen.findByTestId('test-connection-success')
    await user.click(screen.getByTestId('btn-modal-save-connector'))
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())

    const outcome = screen.getByTestId('idp-connection-success')
    expect(outcome).toHaveAttribute('role', 'status')
    expect(outcome).toHaveTextContent('Portal session verified')
  })

  it('surfaces a provider-load failure through the shared validation banner', async () => {
    api.listProviders.mockRejectedValue(new Error('upstream unavailable'))
    renderStep()

    const banner = await screen.findByTestId('validation-error-banner')
    expect(banner).toHaveTextContent('Connector providers could not be loaded: upstream unavailable')
  })
})
