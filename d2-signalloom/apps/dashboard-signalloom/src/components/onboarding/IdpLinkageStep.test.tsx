import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import IdpLinkageStep from './IdpLinkageStep'
import { connectorsApi } from '../../api/connectorsClient'

vi.mock('../../auth/oidc', () => ({
  useAuth0: () => ({
    getAccessTokenSilently: vi.fn().mockResolvedValue('test-bearer-token'),
  }),
}))

vi.mock('../../api/connectorsClient', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../api/connectorsClient')>()
  return {
    ...actual,
    connectorsApi: {
      ...actual.connectorsApi,
      createConnector: vi.fn().mockResolvedValue({
        connector_id: 'conn-test-123',
        provider_id: 'claude',
        status: 'connected',
      }),
      configure: vi.fn().mockResolvedValue({
        connector_id: 'conn-test-123',
        provider_id: 'claude',
        status: 'connected',
      }),
    },
  }
})

describe('IdpLinkageStep component', () => {
  const mockOnNext = vi.fn()
  const mockOnBack = vi.fn()
  const mockOnSkip = vi.fn()
  const mockOnTestConnection = vi.fn()

  beforeEach(() => {
    vi.clearAllMocks()
  })

  function renderStep(initialValues = {}, initialEntries = ['/onboarding?step=idp']) {
    return render(
      <MemoryRouter initialEntries={initialEntries}>
        <IdpLinkageStep
          initialValues={initialValues}
          onNext={mockOnNext}
          onBack={mockOnBack}
          onSkip={mockOnSkip}
          onTestConnection={mockOnTestConnection}
        />
      </MemoryRouter>,
    )
  }

  it('renders provider selection cards and does not render the bottom inline configuration form card', () => {
    renderStep()

    expect(screen.getByTestId('idp-option-claude')).toBeInTheDocument()
    expect(screen.getByTestId('idp-option-openai')).toBeInTheDocument()
    expect(screen.getByTestId('idp-option-dex')).toBeInTheDocument()
    expect(screen.getByText('Anthropic Claude')).toBeInTheDocument()
    expect(screen.getByText('OpenAI Platform')).toBeInTheDocument()

    // Bottom inline form card must be eliminated
    expect(screen.queryByText(/Configuration: Dex OIDC/i)).not.toBeInTheDocument()
    expect(screen.queryByTestId('configure-current-provider-modal')).not.toBeInTheDocument()
    expect(screen.queryByTestId('tab-idp-auth-api-key')).not.toBeInTheDocument()
    expect(screen.queryByTestId('tab-idp-auth-oidc')).not.toBeInTheDocument()
  })

  it('each provider card has a Configure button and clicking it opens ConnectorConfigureModal', async () => {
    const user = userEvent.setup()
    renderStep()

    const configureBtn = screen.getByTestId('configure-idp-claude')
    expect(configureBtn).toBeInTheDocument()
    expect(screen.getByTestId('configure-provider-claude')).toBeInTheDocument()

    await user.click(configureBtn)

    expect(await screen.findByRole('dialog')).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: /Configure Anthropic Claude/i })).toBeInTheDocument()
  })

  it('clicking the provider card directly also opens ConnectorConfigureModal', async () => {
    const user = userEvent.setup()
    renderStep()

    const card = screen.getByTestId('idp-option-openai')
    await user.click(card)

    expect(await screen.findByRole('dialog')).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: /Configure OpenAI Platform/i })).toBeInTheDocument()
  })

  it('saving from ConnectorConfigureModal updates step state, marks provider as configured with a "✓ Configured" tag, and records connectionStatus = success', async () => {
    const user = userEvent.setup()
    renderStep()

    const configureBtn = screen.getByTestId('configure-idp-claude')
    await user.click(configureBtn)

    expect(await screen.findByRole('dialog')).toBeInTheDocument()
    const apiKeyInput = screen.getByTestId('input-connector-api-key')
    await user.type(apiKeyInput, 'sk-ant-api03-onboarding-key')

    const wsInput = screen.getByTestId('input-connector-workspace-id')
    await user.type(wsInput, 'wrkspc_onboarding_123')

    const saveBtn = screen.getByTestId('btn-modal-save-connector')
    await user.click(saveBtn)

    await waitFor(() => {
      expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    })

    // Provider card displays "✓ Configured" tag
    const claudeCard = screen.getByTestId('idp-option-claude')
    expect(claudeCard).toHaveTextContent(/✓ Configured/i)

    // Submitting Next step passes through credentials and connectionTested = true
    const nextBtn = screen.getByTestId('next-step-button')
    await user.click(nextBtn)

    expect(mockOnNext).toHaveBeenCalledWith(
      expect.objectContaining({
        providerId: 'claude',
        apiKey: 'sk-ant-api03-onboarding-key',
        workspaceId: 'wrkspc_onboarding_123',
        connectionTested: true,
      }),
    )
  })

  it('supports URL deep-linking on mount via ?provider=claude by auto-opening ConnectorConfigureModal', async () => {
    renderStep({}, ['/onboarding?step=idp&provider=claude'])

    expect(await screen.findByRole('dialog')).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: /Configure Anthropic Claude/i })).toBeInTheDocument()
    expect(screen.getByTestId('input-connector-api-key')).toBeInTheDocument()
  })

  it('supports URL deep-linking on mount via ?configure=openai by auto-opening ConnectorConfigureModal', async () => {
    renderStep({}, ['/onboarding?configure=openai'])

    expect(await screen.findByRole('dialog')).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: /Configure OpenAI Platform/i })).toBeInTheDocument()
  })
})
