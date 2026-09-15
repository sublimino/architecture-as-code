import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import React from 'react'
import {
  ZeroPayloadInspector,
  simulateAllowlistFilter,
  DEFAULT_SAMPLE_RAW_EVENT,
  type AllowlistManifest,
} from './ZeroPayloadInspector'
import manifestData from '../../data/agentmaxxing-allowlist-manifest.json'

const testManifest = manifestData as unknown as AllowlistManifest

describe('ZeroPayloadInspector', () => {
  it('bundles a valid allowlist manifest with real filter.py sets and SHA-256 digest', () => {
    expect(testManifest.filter_sha256).toMatch(/^[a-f0-9]{64}$/)
    expect(testManifest.source_file).toContain('filter.py')
    expect(testManifest.allowlisted_process_attributes).toEqual(
      expect.arrayContaining([
        'cpu_time_ms',
        'exit_code',
        'health_state',
        'resident_memory_bytes',
        'restart_count',
      ])
    )
    expect(testManifest.allowlisted_envelope_fields).toEqual(
      expect.arrayContaining([
        'actor_id',
        'agent_id',
        'attributes',
        'evidence_type',
        'host_id',
        'integrity_state',
        'observation_state',
        'observed_at',
        'schema_version',
        'sequence',
        'session_id',
        'source',
        'tenant_id',
      ])
    )
    expect(testManifest.prohibited_export_keys).toEqual(
      expect.arrayContaining([
        'prompt_text',
        'completion_text',
        'file_contents',
        'credentials',
        'secret',
        'password',
      ])
    )
    expect(DEFAULT_SAMPLE_RAW_EVENT).toHaveProperty('prompt_text')
    expect(DEFAULT_SAMPLE_RAW_EVENT).toHaveProperty('health_state')
  })

  it('renders the complete 64-character SHA-256 build digest in copyable monospace format', () => {
    render(<ZeroPayloadInspector manifest={testManifest} />)

    const digestElem = screen.getByTestId('filter-digest')
    expect(digestElem).toBeInTheDocument()
    expect(digestElem.textContent?.trim()).toBe(testManifest.filter_sha256)
    expect(digestElem.textContent?.trim()).toHaveLength(64)

    const labelElem = screen.getByTestId('filter-digest-label')
    expect(labelElem).toBeInTheDocument()
    expect(labelElem.textContent).toContain('filter.py')
  })

  it('handles copy button click and triggers onDigestCopied callback', async () => {
    const onDigestCopied = vi.fn()
    render(
      <ZeroPayloadInspector
        manifest={testManifest}
        onDigestCopied={onDigestCopied}
      />
    )

    const copyBtn = screen.getByTestId('filter-digest-copy-btn')
    expect(copyBtn).toBeInTheDocument()
    expect(copyBtn.textContent).toContain('Copy Digest')

    fireEvent.click(copyBtn)

    expect(onDigestCopied).toHaveBeenCalledWith(testManifest.filter_sha256)
    expect(copyBtn.textContent).toContain('Copied')
  })

  it('renders compiled allowlist process attributes, envelope fields, and prohibited keys', () => {
    render(<ZeroPayloadInspector manifest={testManifest} />)

    expect(screen.getByTestId('allowlist-list')).toBeInTheDocument()
    expect(screen.getByTestId('allowlist-process-attributes')).toBeInTheDocument()
    expect(screen.getByTestId('allowlist-envelope-fields')).toBeInTheDocument()
    expect(screen.getByTestId('prohibited-keys-list')).toBeInTheDocument()

    // Assert each process attribute is rendered
    for (const attr of testManifest.allowlisted_process_attributes) {
      expect(screen.getByTestId(`allowlist-process-attr-${attr}`)).toBeInTheDocument()
    }

    // Assert key envelope fields are rendered
    expect(screen.getByTestId('allowlist-envelope-field-actor_id')).toBeInTheDocument()
    expect(screen.getByTestId('allowlist-envelope-field-agent_id')).toBeInTheDocument()
    expect(screen.getByTestId('allowlist-envelope-field-attributes')).toBeInTheDocument()

    // Assert prohibited key chip is rendered
    expect(screen.getByTestId('prohibited-key-prompt_text')).toBeInTheDocument()
    expect(screen.getByTestId('prohibited-key-file_contents')).toBeInTheDocument()
  })

  it('demonstrates active drop count by actively stripping unapproved keys from sample event', () => {
    render(<ZeroPayloadInspector manifest={testManifest} />)

    expect(screen.getByTestId('drop-count-demonstration')).toBeInTheDocument()

    // DEFAULT_SAMPLE_RAW_EVENT contains 5 allowlisted and 6 unapproved/prohibited keys
    const dropCountElem = screen.getByTestId('drop-count')
    expect(dropCountElem).toBeInTheDocument()
    expect(dropCountElem.textContent).toBe('6')

    // Dropped keys list contains the 6 unapproved keys
    expect(screen.getByTestId('dropped-key-prompt_text')).toBeInTheDocument()
    expect(screen.getByTestId('dropped-key-completion_text')).toBeInTheDocument()
    expect(screen.getByTestId('dropped-key-file_contents')).toBeInTheDocument()
    expect(screen.getByTestId('dropped-key-raw_cmdline')).toBeInTheDocument()
    expect(screen.getByTestId('dropped-key-memory_contents')).toBeInTheDocument()
    expect(screen.getByTestId('dropped-key-api_key')).toBeInTheDocument()

    // Preserved keys list contains the 5 allowlisted keys
    expect(screen.getByTestId('preserved-key-health_state')).toBeInTheDocument()
    expect(screen.getByTestId('preserved-key-cpu_time_ms')).toBeInTheDocument()
    expect(screen.getByTestId('preserved-key-resident_memory_bytes')).toBeInTheDocument()
    expect(screen.getByTestId('preserved-key-restart_count')).toBeInTheDocument()
    expect(screen.getByTestId('preserved-key-exit_code')).toBeInTheDocument()
  })

  it('renders visible staleness warning when manifest digest does not match expected filter.py SHA-256', () => {
    const wrongDigest = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef'

    // With wrong expected digest: warning must be visible
    render(
      <ZeroPayloadInspector
        manifest={testManifest}
        expectedDigest={wrongDigest}
      />
    )

    const warningElem = screen.getByTestId('manifest-staleness-warning')
    expect(warningElem).toBeInTheDocument()
    expect(warningElem.textContent).toContain('Manifest Staleness Warning')
    expect(warningElem.textContent).toContain('filter.py Digest Mismatch')
  })

  it('does NOT render staleness warning when manifest digest matches expected digest', () => {
    render(
      <ZeroPayloadInspector
        manifest={testManifest}
        expectedDigest={testManifest.filter_sha256}
      />
    )

    expect(screen.queryByTestId('manifest-staleness-warning')).not.toBeInTheDocument()
  })

  it('renders identical allowlist data across mock and live channel modes', () => {
    const { unmount } = render(
      <ZeroPayloadInspector manifest={testManifest} isLiveChannel={false} />
    )
    const mockDigest = screen.getByTestId('filter-digest').textContent
    const mockDropCount = screen.getByTestId('drop-count').textContent
    unmount()

    render(
      <ZeroPayloadInspector manifest={testManifest} isLiveChannel={true} />
    )
    const liveDigest = screen.getByTestId('filter-digest').textContent
    const liveDropCount = screen.getByTestId('drop-count').textContent

    expect(mockDigest).toBe(liveDigest)
    expect(mockDropCount).toBe(liveDropCount)
  })

  it('correctly calculates drop count for custom raw events', () => {
    const customEvent: Record<string, unknown> = {
      health_state: 'healthy',
      cpu_time_ms: 1000,
      custom_confidential_token: 'xyz',
      secret_user_id: 'user-123',
    }

    render(
      <ZeroPayloadInspector
        manifest={testManifest}
        sampleRawEvent={customEvent}
      />
    )

    const dropCountElem = screen.getByTestId('drop-count')
    expect(dropCountElem.textContent).toBe('2')
    expect(screen.getByTestId('dropped-key-custom_confidential_token')).toBeInTheDocument()
    expect(screen.getByTestId('dropped-key-secret_user_id')).toBeInTheDocument()
    expect(screen.getByTestId('preserved-key-health_state')).toBeInTheDocument()
    expect(screen.getByTestId('preserved-key-cpu_time_ms')).toBeInTheDocument()
  })

  it('frames DOM string-absence inspection as secondary defense-in-depth notice', () => {
    render(<ZeroPayloadInspector manifest={testManifest} />)

    const domNotice = screen.getByTestId('dom-inspection-notice')
    expect(domNotice).toBeInTheDocument()
    expect(domNotice.textContent).toContain('Secondary Defense-in-Depth DOM Assertion')
    expect(domNotice.textContent).toContain('filter.py')
  })
})

describe('simulateAllowlistFilter helper', () => {
  it('correctly separates allowlisted and prohibited/unallowlisted keys', () => {
    const raw = {
      health_state: 'healthy',
      cpu_time_ms: 500,
      prompt_text: 'sensitive prompt',
      unrecognized_flag: true,
    }

    const result = simulateAllowlistFilter(raw, testManifest)

    expect(result.totalIncomingCount).toBe(4)
    expect(result.preservedCount).toBe(2)
    expect(result.dropCount).toBe(2)
    expect(result.preservedKeys).toEqual(['health_state', 'cpu_time_ms'])
    expect(result.droppedKeys).toEqual(['prompt_text', 'unrecognized_flag'])
    expect(result.droppedDetails).toEqual([
      { key: 'prompt_text', reason: 'prohibited_export_key' },
      { key: 'unrecognized_flag', reason: 'not_on_allowlist' },
    ])
  })

  it('drops all keys when all keys are unallowlisted', () => {
    const raw = {
      prompt: 'bad',
      file: 'data',
      secret: 'val',
    }

    const result = simulateAllowlistFilter(raw, testManifest)
    expect(result.preservedCount).toBe(0)
    expect(result.dropCount).toBe(3)
  })

  it('preserves all keys when all keys are allowlisted', () => {
    const raw = {
      health_state: 'healthy',
      cpu_time_ms: 120,
      resident_memory_bytes: 1048576,
      restart_count: 0,
      exit_code: null,
    }

    const result = simulateAllowlistFilter(raw, testManifest)
    expect(result.preservedCount).toBe(5)
    expect(result.dropCount).toBe(0)
  })
})
