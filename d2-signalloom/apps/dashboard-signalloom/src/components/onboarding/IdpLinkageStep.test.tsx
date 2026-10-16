import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import IdpLinkageStep from './IdpLinkageStep'

describe('IdpLinkageStep component', () => {
  const mockOnNext = vi.fn()
  const mockOnBack = vi.fn()
  const mockOnSkip = vi.fn()
  const mockOnTestConnection = vi.fn()

  beforeEach(() => {
    vi.clearAllMocks()
  })

  function renderStep(initialValues = {}) {
    return render(
      <IdpLinkageStep
        initialValues={initialValues}
        onNext={mockOnNext}
        onBack={mockOnBack}
        onSkip={mockOnSkip}
        onTestConnection={mockOnTestConnection}
      />,
    )
  }

  it('renders both Claude and OpenAI options in the IdP selection grid', () => {
    renderStep()

    expect(screen.getByTestId('idp-option-claude')).toBeInTheDocument()
    expect(screen.getByTestId('idp-option-openai')).toBeInTheDocument()
    expect(screen.getByText('Anthropic Claude')).toBeInTheDocument()
    expect(screen.getByText('OpenAI Platform')).toBeInTheDocument()
  })

  it('clicking idp-option-claude selects Claude and pre-fills defaults and adapted labels', async () => {
    const user = userEvent.setup()
    renderStep()

    await user.click(screen.getByTestId('idp-option-claude'))

    expect(screen.getByText(/Configuration: Anthropic Claude/i)).toBeInTheDocument()
    expect(screen.getByTestId('input-idp-issuer-url')).toHaveValue('https://api.anthropic.com/v1')
    expect(screen.getByTestId('input-idp-client-id')).toHaveValue('wrkspc_default')
    expect(screen.getByTestId('input-idp-scopes')).toHaveValue('models.read messages.read batches.read')

    // Form labels and placeholders adapt cleanly
    expect(screen.getByLabelText(/OIDC \/ Endpoint URL/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/Client \/ Workspace ID/i)).toBeInTheDocument()
    expect(screen.getByTestId('input-idp-client-secret')).toHaveAttribute('placeholder', 'sk-ant-...')
  })

  it('clicking idp-option-openai selects OpenAI and pre-fills defaults and adapted labels', async () => {
    const user = userEvent.setup()
    renderStep()

    await user.click(screen.getByTestId('idp-option-openai'))

    expect(screen.getByText(/Configuration: OpenAI Platform/i)).toBeInTheDocument()
    expect(screen.getByTestId('input-idp-issuer-url')).toHaveValue('https://api.openai.com/v1')
    expect(screen.getByTestId('input-idp-client-id')).toHaveValue('signalloom-openai-reader')
    expect(screen.getByTestId('input-idp-scopes')).toHaveValue('assistants.read models.read threads.read')
    expect(screen.getByTestId('input-idp-client-secret')).toHaveAttribute('placeholder', 'sk-admin-...')
  })

  it('clicking Test Connection calls onTestConnection with the issuer URL and displays the resulting message', async () => {
    const user = userEvent.setup()
    mockOnTestConnection.mockResolvedValueOnce({
      ok: true,
      message: 'Anthropic Claude endpoint reachable: read-only inventory session verified.',
    })

    renderStep()
    await user.click(screen.getByTestId('idp-option-claude'))

    const testBtn = screen.getByTestId('test-idp-connection-button')
    await user.click(testBtn)

    expect(mockOnTestConnection).toHaveBeenCalledWith('https://api.anthropic.com/v1')
    expect(await screen.findByTestId('idp-connection-success')).toHaveTextContent(
      'Anthropic Claude endpoint reachable: read-only inventory session verified.',
    )
  })

  it('clicking Next calls onNext with configured Claude values', async () => {
    const user = userEvent.setup()
    mockOnTestConnection.mockResolvedValueOnce({
      ok: true,
      message: 'Verified successfully',
    })

    renderStep()
    await user.click(screen.getByTestId('idp-option-claude'))

    // Test connection first
    await user.click(screen.getByTestId('test-idp-connection-button'))
    await screen.findByTestId('idp-connection-success')

    // Submit
    await user.click(screen.getByTestId('next-step-button'))

    expect(mockOnNext).toHaveBeenCalledWith(
      expect.objectContaining({
        providerId: 'claude',
        providerName: 'Anthropic Claude',
        issuerUrl: 'https://api.anthropic.com/v1',
        clientId: 'wrkspc_default',
        scopes: 'models.read messages.read batches.read',
        connectionTested: true,
        connectionMessage: 'Verified successfully',
      }),
    )
  })

  it('validates URL protocol and required fields on submission', async () => {
    const user = userEvent.setup()
    renderStep()

    await user.click(screen.getByTestId('idp-option-claude'))

    // Clear endpoint URL
    const urlInput = screen.getByTestId('input-idp-issuer-url')
    await user.clear(urlInput)

    // Clear client ID
    const clientInput = screen.getByTestId('input-idp-client-id')
    await user.clear(clientInput)

    // Clear scopes
    const scopesInput = screen.getByTestId('input-idp-scopes')
    await user.clear(scopesInput)

    await user.click(screen.getByTestId('next-step-button'))

    expect(screen.getByText('OIDC / Endpoint URL is required.')).toBeInTheDocument()
    expect(screen.getByText('Client / Workspace ID is required.')).toBeInTheDocument()
    expect(screen.getByText('At least one scope is required.')).toBeInTheDocument()
    expect(mockOnNext).not.toHaveBeenCalled()

    // Test non-https/http url
    await user.type(urlInput, 'ftp://invalid-url.com')
    await user.type(clientInput, 'wrkspc_123')
    await user.type(scopesInput, 'models.read')
    await user.click(screen.getByTestId('next-step-button'))

    expect(screen.getByText('Endpoint URL must be a valid HTTP or HTTPS address.')).toBeInTheDocument()
    expect(mockOnNext).not.toHaveBeenCalled()
  })

  it('reports connection error when endpoint URL protocol is invalid', async () => {
    const user = userEvent.setup()
    renderStep()

    await user.click(screen.getByTestId('idp-option-claude'))
    const urlInput = screen.getByTestId('input-idp-issuer-url')
    await user.clear(urlInput)
    await user.type(urlInput, 'invalid-domain.com')

    await user.click(screen.getByTestId('test-idp-connection-button'))

    expect(await screen.findByTestId('idp-connection-error')).toHaveTextContent(
      'Invalid Endpoint URL. Must start with https:// or http://',
    )
    expect(mockOnTestConnection).not.toHaveBeenCalled()
  })
})
