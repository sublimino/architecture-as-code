import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ConnectorConfigureModal from './ConnectorConfigureModal'
import { connectorsApi } from '../api/connectorsClient'
import type { ConnectorProvider, TenantConnector } from '../types/connectors'

describe('ConnectorConfigureModal', () => {
  const mockProvider: ConnectorProvider = {
    provider_id: 'claude',
    display_name: 'Anthropic Claude',
    wizard_config: {
      fields: [],
      permissions: ['read'],
      docs_link: 'https://docs.anthropic.com',
      help_text: 'Claude AI Governance',
    },
  }

  const mockOnSave = vi.fn()
  const mockOnClose = vi.fn()
  const mockOnTestConnection = vi.fn()

  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('fails with "API Key is required." when submitting empty API key and not connected or tested', async () => {
    const user = userEvent.setup()
    render(
      <ConnectorConfigureModal
        isOpen={true}
        provider={mockProvider}
        onClose={mockOnClose}
        onSave={mockOnSave}
      />,
    )

    const saveBtn = screen.getByTestId('btn-modal-save-connector')
    await user.click(saveBtn)

    expect(await screen.findByTestId('connector-save-error')).toHaveTextContent('API Key is required.')
    expect(mockOnSave).not.toHaveBeenCalled()
  })

  it('saves successfully when API key is entered directly', async () => {
    const user = userEvent.setup()
    render(
      <ConnectorConfigureModal
        isOpen={true}
        provider={mockProvider}
        onClose={mockOnClose}
        onSave={mockOnSave}
      />,
    )

    const apiKeyInput = screen.getByTestId('input-connector-api-key')
    await user.type(apiKeyInput, 'sk-ant-test-key-123')

    const saveBtn = screen.getByTestId('btn-modal-save-connector')
    await user.click(saveBtn)

    expect(screen.queryByTestId('connector-save-error')).not.toBeInTheDocument()
    expect(mockOnSave).toHaveBeenCalledWith(
      expect.objectContaining({
        provider_id: 'claude',
        credentials: expect.objectContaining({
          api_key: 'sk-ant-test-key-123',
        }),
      }),
    )
    expect(mockOnClose).toHaveBeenCalled()
  })

  it('recognizes initialApiKey pre-fill without re-entry and submits initialApiKey', async () => {
    const user = userEvent.setup()
    render(
      <ConnectorConfigureModal
        isOpen={true}
        provider={mockProvider}
        initialApiKey="sk-ant-prefilled-key"
        onClose={mockOnClose}
        onSave={mockOnSave}
      />,
    )

    const saveBtn = screen.getByTestId('btn-modal-save-connector')
    await user.click(saveBtn)

    expect(screen.queryByTestId('connector-save-error')).not.toBeInTheDocument()
    expect(mockOnSave).toHaveBeenCalledWith(
      expect.objectContaining({
        provider_id: 'claude',
        credentials: expect.objectContaining({
          api_key: 'sk-ant-prefilled-key',
        }),
      }),
    )
    expect(mockOnClose).toHaveBeenCalled()
  })

  it('preserves existing credentials without requiring re-entry when connector status is connected', async () => {
    const user = userEvent.setup()
    const connectedConnector: TenantConnector = {
      connector_id: 'conn-active-1',
      provider_id: 'claude',
      display_name: 'Anthropic Claude',
      status: 'connected',
      credential_expires_at: null,
      last_tested_at: '2026-10-15T12:00:00Z',
      last_scan_at: '2026-10-15T12:30:00Z',
      metadata: { has_credentials: true },
      created_at: '2026-10-01T00:00:00Z',
    }

    render(
      <ConnectorConfigureModal
        isOpen={true}
        provider={mockProvider}
        connector={connectedConnector}
        onClose={mockOnClose}
        onSave={mockOnSave}
      />,
    )

    // Do NOT type into API key input; leave it blank
    const saveBtn = screen.getByTestId('btn-modal-save-connector')
    await user.click(saveBtn)

    expect(screen.queryByTestId('connector-save-error')).not.toBeInTheDocument()
    expect(mockOnSave).toHaveBeenCalledWith(
      expect.objectContaining({
        provider_id: 'claude',
      }),
    )
    expect(mockOnClose).toHaveBeenCalled()
  })

  it('allows saving when testResult.ok is true even if apiKey state was not dirty', async () => {
    const user = userEvent.setup()
    mockOnTestConnection.mockResolvedValueOnce({ ok: true, message: 'Probe OK' })

    render(
      <ConnectorConfigureModal
        isOpen={true}
        provider={mockProvider}
        onClose={mockOnClose}
        onSave={mockOnSave}
        onTestConnection={mockOnTestConnection}
      />,
    )

    // Test connection
    const testBtn = screen.getByTestId('btn-modal-test-connection')
    await user.click(testBtn)
    expect(await screen.findByTestId('test-connection-success')).toBeInTheDocument()

    // Now save
    const saveBtn = screen.getByTestId('btn-modal-save-connector')
    await user.click(saveBtn)

    expect(screen.queryByTestId('connector-save-error')).not.toBeInTheDocument()
    expect(mockOnSave).toHaveBeenCalled()
    expect(mockOnClose).toHaveBeenCalled()
  })

  it('calls connectorsApi.testConnector with entered API key and displays live discovered agent name', async () => {
    const user = userEvent.setup()
    const testSpy = vi.spyOn(connectorsApi, 'testConnector').mockResolvedValueOnce({
      connector_id: 'conn-claude-01',
      valid: true,
      scopes_ok: true,
      error_msg: null,
      credential_expires_at: null,
      needs_rotation: false,
      message: '✓ Verified connection to Anthropic Claude API. Discovered live agent: Live Console Renamed Agent',
    })

    render(
      <ConnectorConfigureModal
        isOpen={true}
        provider={mockProvider}
        onClose={mockOnClose}
        onSave={mockOnSave}
      />,
    )

    const apiKeyInput = screen.getByTestId('input-connector-api-key')
    await user.type(apiKeyInput, 'sk-ant-live-key-42')

    const testBtn = screen.getByTestId('btn-modal-test-connection')
    await user.click(testBtn)

    expect(testSpy).toHaveBeenCalledWith(
      '',
      'claude',
      expect.objectContaining({
        api_key: 'sk-ant-live-key-42',
      }),
    )

    expect(await screen.findByTestId('test-connection-success')).toHaveTextContent(
      'Live Console Renamed Agent',
    )
  })

  it('displays error message when connectorsApi.testConnector rejects invalid credentials', async () => {
    const user = userEvent.setup()
    vi.spyOn(connectorsApi, 'testConnector').mockResolvedValueOnce({
      connector_id: 'conn-claude-01',
      valid: false,
      scopes_ok: false,
      error_msg: 'Invalid Anthropic API key (HTTP 401 Unauthorized)',
      credential_expires_at: null,
      needs_rotation: false,
      message: '✗ Authentication failed: Invalid Anthropic API key',
    })

    render(
      <ConnectorConfigureModal
        isOpen={true}
        provider={mockProvider}
        onClose={mockOnClose}
        onSave={mockOnSave}
      />,
    )

    const apiKeyInput = screen.getByTestId('input-connector-api-key')
    await user.type(apiKeyInput, 'sk-ant-bad-key')

    const testBtn = screen.getByTestId('btn-modal-test-connection')
    await user.click(testBtn)

    expect(await screen.findByTestId('test-connection-error')).toHaveTextContent(
      'Invalid Anthropic API key',
    )
  })
})
