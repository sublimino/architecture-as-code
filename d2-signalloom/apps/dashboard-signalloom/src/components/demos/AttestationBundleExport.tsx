import React, { useMemo, useState } from 'react'
import type { DemoStepperState, StageId } from './types'
import type { ScenarioPreset } from './scenarios'

export interface InTotoSubject {
  readonly name: string
  readonly digest: Record<string, string>
}

export interface InTotoStatement {
  readonly _type: 'https://in-toto.io/Statement/v1'
  readonly subject: readonly InTotoSubject[]
  readonly predicateType: string
  readonly predicate: Record<string, unknown>
}

export interface AttestationBundleExportProps {
  readonly preset?: ScenarioPreset
  readonly activeStage?: StageId
  readonly state?: DemoStepperState
  readonly payload?: unknown
  readonly className?: string
  readonly testId?: string
}

export function buildInTotoAttestationBundle(
  preset?: ScenarioPreset,
  activeStage?: StageId,
  state?: DemoStepperState,
  payload?: unknown,
): InTotoStatement {
  const stageName = activeStage || state?.currentStage || 'operator_init'
  const presetId = preset?.id || 'amxd-demo-happy-path'
  const presetName = preset?.name || 'Happy Path'
  const agentId = preset?.agent_id || 'amxd-demo-agent-01'
  const hostId = preset?.host_id || 'amxd-demo-host-01'

  // Extract or synthesize a deterministic subject digest
  let artifactDigest = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
  if (payload && typeof payload === 'object') {
    const p = payload as Record<string, unknown>
    if (typeof p.artifact_sha256 === 'string') {
      artifactDigest = p.artifact_sha256
    } else if (typeof p.tampered_digest === 'string') {
      artifactDigest = p.tampered_digest
    } else if (typeof p.token_digest === 'string') {
      artifactDigest = p.token_digest
    }
  }

  return {
    _type: 'https://in-toto.io/Statement/v1',
    subject: [
      {
        name: `agentmaxxing-runtime-${agentId}`,
        digest: {
          sha256: artifactDigest,
        },
      },
    ],
    predicateType: 'https://controlplane.io/attestations/agentmaxxing-confinement/v1',
    predicate: {
      metadata: {
        generator: 'Signal Loom AMXD Attestation Authority v0.1.0',
        timestamp: new Date().toISOString(),
        environment: 'linux-landlock-abi-v3',
      },
      scenario: {
        presetId,
        presetName,
        mode: preset?.mode || 'mock',
        activeStage: stageName,
      },
      agent: {
        agentId,
        hostId,
        tenantId: preset?.tenant_id || 'amxd-demo-tenant-primary',
      },
      confinement: {
        lsm: 'landlock-abi-v3',
        zeroCustomerPayloadInvariant: true,
        allowedTelemetryFields: 24,
        enforcedDeniedPaths: [
          '/home/*/.ssh',
          '/etc/shadow',
          '/proc/kcore',
          '/var/run/docker.sock',
        ],
      },
      stageState: {
        currentStage: state?.currentStage || stageName,
        statuses: state?.stageStatuses || {},
      },
      evidencePayload: payload ?? null,
    },
  }
}

export const AttestationBundleExport: React.FC<AttestationBundleExportProps> = ({
  preset,
  activeStage,
  state,
  payload,
  className = '',
  testId = 'attestation-bundle-export',
}) => {
  const [copied, setCopied] = useState(false)
  const [showPreview, setShowPreview] = useState(false)

  const bundle = useMemo(
    () => buildInTotoAttestationBundle(preset, activeStage, state, payload),
    [preset, activeStage, state, payload],
  )

  const jsonString = useMemo(() => JSON.stringify(bundle, null, 2), [bundle])
  const byteCount = useMemo(() => new Blob([jsonString]).size, [jsonString])

  const handleDownload = () => {
    try {
      const blob = new Blob([jsonString], { type: 'application/json' })
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      const filename = `signal-loom-attestation-${preset?.id || 'agentmaxxing'}-${activeStage || 'stage'}.json`
      a.href = url
      a.download = filename
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
      URL.revokeObjectURL(url)
    } catch {
      /* fallback if blob download fails in test or restricted environment */
    }
  }

  const handleCopy = async () => {
    try {
      if (typeof navigator !== 'undefined' && navigator.clipboard) {
        await navigator.clipboard.writeText(jsonString)
        setCopied(true)
        setTimeout(() => setCopied(false), 2000)
      }
    } catch {
      /* clipboard write error */
    }
  }

  return (
    <div
      data-testid={testId}
      className={`card ${className}`}
      style={{
        background: 'var(--surface)',
        border: '1px solid var(--border)',
        borderRadius: 8,
        marginTop: 16,
        padding: '14px 18px',
      }}
    >
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          gap: 12,
          flexWrap: 'wrap',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <span
            style={{
              fontSize: 11,
              fontFamily: 'monospace',
              fontWeight: 700,
              textTransform: 'uppercase',
              letterSpacing: '0.06em',
              color: 'var(--teal)',
            }}
          >
            Cryptographic Attestation Bundle
          </span>
          <span
            className="tag"
            style={{
              fontSize: 10,
              fontFamily: 'monospace',
              background: 'rgba(16, 185, 129, 0.12)',
              color: 'var(--teal)',
              border: '1px solid rgba(16, 185, 129, 0.3)',
            }}
          >
            in-toto Statement v1
          </span>
          <span style={{ fontSize: 11, fontFamily: 'monospace', color: 'var(--muted)' }}>
            ({byteCount} bytes)
          </span>
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
          <button
            type="button"
            data-testid="attestation-preview-toggle"
            onClick={() => setShowPreview((prev) => !prev)}
            className="btn btn-secondary"
            style={{
              fontSize: 11,
              fontFamily: 'monospace',
              padding: '4px 10px',
              cursor: 'pointer',
            }}
          >
            {showPreview ? 'Hide JSON ▲' : 'View Statement ▼'}
          </button>

          <button
            type="button"
            data-testid="attestation-copy-btn"
            onClick={handleCopy}
            className="btn btn-secondary"
            style={{
              fontSize: 11,
              fontFamily: 'monospace',
              padding: '4px 10px',
              cursor: 'pointer',
            }}
          >
            {copied ? '✓ Copied' : 'Copy JSON'}
          </button>

          <button
            type="button"
            data-testid="attestation-download-btn"
            onClick={handleDownload}
            className="btn btn-primary"
            style={{
              fontSize: 11,
              fontFamily: 'monospace',
              padding: '4px 12px',
              cursor: 'pointer',
            }}
          >
            Download Bundle (.json)
          </button>
        </div>
      </div>

      {showPreview && (
        <div style={{ marginTop: 12 }}>
          <pre
            data-testid="attestation-json-preview"
            style={{
              margin: 0,
              padding: '12px 14px',
              background: 'var(--surface2)',
              border: '1px solid var(--border)',
              borderRadius: 6,
              fontSize: 11,
              fontFamily: 'monospace',
              color: 'var(--text)',
              maxHeight: 280,
              overflowY: 'auto',
              lineHeight: 1.4,
            }}
          >
            {jsonString}
          </pre>
        </div>
      )}
    </div>
  )
}

export default AttestationBundleExport
