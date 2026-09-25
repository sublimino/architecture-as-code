import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import React from 'react'
import {
  AttestationBundleExport,
  buildInTotoAttestationBundle,
} from './AttestationBundleExport'
import { HAPPY_PATH_PRESET, TAMPER_BREACH_PRESET } from './scenarios'

describe('AttestationBundleExport', () => {
  it('generates a valid in-toto Statement v1 envelope with predicate and subject', () => {
    const bundle = buildInTotoAttestationBundle(
      HAPPY_PATH_PRESET,
      'confinement_streaming',
      undefined,
      { artifact_sha256: 'a1b2c3d4e5f67890123456789012345678901234567890123456789012345678' },
    )

    expect(bundle._type).toBe('https://in-toto.io/Statement/v1')
    expect(bundle.subject[0].digest.sha256).toBe(
      'a1b2c3d4e5f67890123456789012345678901234567890123456789012345678',
    )
    expect(bundle.predicateType).toBe(
      'https://controlplane.io/attestations/agentmaxxing-confinement/v1',
    )
    expect(bundle.predicate.confinement).toMatchObject({
      lsm: 'landlock-abi-v3',
      zeroCustomerPayloadInvariant: true,
      allowedTelemetryFields: 24,
    })
  })

  it('renders attestation actions and summary badge', () => {
    render(
      <AttestationBundleExport
        preset={HAPPY_PATH_PRESET}
        activeStage="confinement_streaming"
      />,
    )

    expect(screen.getByTestId('attestation-bundle-export')).toBeInTheDocument()
    expect(screen.getByText('Cryptographic Attestation Bundle')).toBeInTheDocument()
    expect(screen.getByText('in-toto Statement v1')).toBeInTheDocument()
    expect(screen.getByTestId('attestation-download-btn')).toBeInTheDocument()
    expect(screen.getByTestId('attestation-copy-btn')).toBeInTheDocument()
    expect(screen.getByTestId('attestation-preview-toggle')).toBeInTheDocument()
  })

  it('toggles statement preview JSON on button click', () => {
    render(
      <AttestationBundleExport
        preset={HAPPY_PATH_PRESET}
        activeStage="confinement_streaming"
      />,
    )

    expect(screen.queryByTestId('attestation-json-preview')).not.toBeInTheDocument()

    const toggleBtn = screen.getByTestId('attestation-preview-toggle')
    fireEvent.click(toggleBtn)

    expect(screen.getByTestId('attestation-json-preview')).toBeInTheDocument()
    expect(screen.getByTestId('attestation-json-preview').textContent).toContain(
      'https://in-toto.io/Statement/v1',
    )

    fireEvent.click(toggleBtn)
    expect(screen.queryByTestId('attestation-json-preview')).not.toBeInTheDocument()
  })

  it('handles clipboard copy interaction', async () => {
    const writeTextMock = vi.fn().mockResolvedValue(undefined)
    Object.assign(navigator, {
      clipboard: {
        writeText: writeTextMock,
      },
    })

    render(
      <AttestationBundleExport
        preset={HAPPY_PATH_PRESET}
        activeStage="confinement_streaming"
      />,
    )

    const copyBtn = screen.getByTestId('attestation-copy-btn')
    fireEvent.click(copyBtn)

    await waitFor(() => {
      expect(writeTextMock).toHaveBeenCalledTimes(1)
      expect(copyBtn.textContent).toContain('Copied')
    })
  })
})
