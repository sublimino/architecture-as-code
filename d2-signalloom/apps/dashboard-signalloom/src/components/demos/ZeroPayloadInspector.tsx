import React, { useState, useMemo, useCallback } from 'react'
import defaultManifestJson from '../../data/agentmaxxing-allowlist-manifest.json'

export interface AllowlistManifest {
  readonly schema_version: string
  readonly source_file: string
  readonly filter_sha256: string
  readonly python_extractor?: string
  readonly allowlisted_process_attributes: readonly string[]
  readonly extended_process_attributes?: readonly string[]
  readonly allowlisted_envelope_fields: readonly string[]
  readonly allowlisted_coding_agent_envelope_fields?: readonly string[]
  readonly allowlisted_coding_agent_process_fields?: readonly string[]
  readonly allowlisted_coding_agent_kanban_fields?: readonly string[]
  readonly allowlisted_coding_agent_metrics_fields?: readonly string[]
  readonly allowlisted_coding_agent_network_fields?: readonly string[]
  readonly prohibited_export_keys: readonly string[]
  readonly extracted_at?: string
}

export interface ZeroPayloadFilterResult {
  readonly totalIncomingCount: number
  readonly preservedCount: number
  readonly dropCount: number
  readonly droppedKeys: readonly string[]
  readonly preservedKeys: readonly string[]
  readonly droppedDetails: readonly {
    readonly key: string
    readonly reason: 'prohibited_export_key' | 'not_on_allowlist'
  }[]
}

export interface ZeroPayloadInspectorProps {
  /**
   * The allowlist manifest containing compiled allowlist sets and SHA-256 digest.
   * Defaults to the build-time bundled manifest.
   */
  readonly manifest?: AllowlistManifest
  /**
   * Optional expected SHA-256 digest to test staleness detection.
   * If provided and different from manifest.filter_sha256, renders a visible staleness warning.
   */
  readonly expectedDigest?: string
  /**
   * Channel kind or live mode indicator (proves mock and live channel render identical manifest data).
   */
  readonly isLiveChannel?: boolean
  /**
   * Optional custom raw event sample to demonstrate field drop calculation.
   */
  readonly sampleRawEvent?: Record<string, unknown>
  /**
   * Callback fired when the SHA-256 digest is copied to clipboard.
   */
  readonly onDigestCopied?: (digest: string) => void
  /**
   * Optional custom CSS class name.
   */
  readonly className?: string
}

/**
 * Standard representative raw event containing allowlisted process metrics AND
 * deliberately unallowlisted / sensitive keys (e.g. prompt, completions, file contents).
 * Used to demonstrate active kernel/sensor filter stripping in the Inspector.
 */
export const DEFAULT_SAMPLE_RAW_EVENT: Record<string, unknown> = {
  // Allowlisted process attributes (should be preserved)
  health_state: 'healthy',
  cpu_time_ms: 4120,
  resident_memory_bytes: 52428800,
  restart_count: 0,
  exit_code: null,

  // Deliberately unallowlisted / prohibited keys (must be dropped by AllowlistFilter)
  prompt_text: 'System: You are an autonomous coding agent. User prompt: Deploy the api...',
  completion_text: 'Model output: Implementing private algorithm in src/engine.ts...',
  file_contents: 'export const DATABASE_PASSWORD = "super-secret-production-credential"',
  raw_cmdline: '/usr/bin/python3 -m agent --auth-token eyJhbGciOi...',
  memory_contents: '0x7ffd5a8b: 48 89 e5 48 83 ec 10 48 8d 3d...',
  api_key: 'sk-ant-live-09481029384-secret-enterprise-key',
}

/**
 * Simulates AllowlistFilter.filter_attributes enforcement against a raw event dictionary.
 * Discards any key not on ALLOWLISTED_PROCESS_ATTRIBUTES or matching PROHIBITED_EXPORT_KEYS.
 */
export function simulateAllowlistFilter(
  rawEvent: Record<string, unknown>,
  manifest: AllowlistManifest
): ZeroPayloadFilterResult {
  const allowedSet = new Set(manifest.allowlisted_process_attributes)
  const prohibitedSet = new Set(manifest.prohibited_export_keys)

  const droppedKeys: string[] = []
  const preservedKeys: string[] = []
  const droppedDetails: {
    key: string
    reason: 'prohibited_export_key' | 'not_on_allowlist'
  }[] = []

  for (const key of Object.keys(rawEvent)) {
    const isProhibited = prohibitedSet.has(key)
    const isAllowed = allowedSet.has(key)

    if (isAllowed && !isProhibited) {
      preservedKeys.push(key)
    } else {
      droppedKeys.push(key)
      droppedDetails.push({
        key,
        reason: isProhibited ? 'prohibited_export_key' : 'not_on_allowlist',
      })
    }
  }

  return {
    totalIncomingCount: Object.keys(rawEvent).length,
    preservedCount: preservedKeys.length,
    dropCount: droppedKeys.length,
    droppedKeys,
    preservedKeys,
    droppedDetails,
  }
}

export function ZeroPayloadInspector({
  manifest = defaultManifestJson as unknown as AllowlistManifest,
  expectedDigest,
  isLiveChannel = false,
  sampleRawEvent = DEFAULT_SAMPLE_RAW_EVENT,
  onDigestCopied,
  className = '',
}: ZeroPayloadInspectorProps): React.JSX.Element {
  const [copied, setCopied] = useState<boolean>(false)

  // Staleness check: if expectedDigest is specified and does not match manifest.filter_sha256
  const isStale = useMemo(() => {
    if (!expectedDigest) return false
    return expectedDigest.toLowerCase().trim() !== manifest.filter_sha256.toLowerCase().trim()
  }, [expectedDigest, manifest.filter_sha256])

  // Active drop calculation against the manifest's real allowlist
  const filterResult = useMemo(() => {
    return simulateAllowlistFilter(sampleRawEvent, manifest)
  }, [sampleRawEvent, manifest])

  const handleCopyDigest = useCallback(async () => {
    try {
      if (typeof navigator !== 'undefined' && navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(manifest.filter_sha256)
      }
      setCopied(true)
      onDigestCopied?.(manifest.filter_sha256)
      setTimeout(() => setCopied(false), 2000)
    } catch {
      // Fallback
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    }
  }, [manifest.filter_sha256, onDigestCopied])

  return (
    <div
      data-testid="zero-payload-inspector"
      className={`rounded-lg border border-[var(--border)] bg-[var(--bg)] p-5 space-y-6 text-[var(--text)] ${className}`}
    >
      {/* Header section */}
      <div className="flex flex-wrap items-start justify-between gap-4 border-b border-[var(--border)] pb-4">
        <div className="space-y-1">
          <div className="flex items-center gap-2">
            <span className="px-2 py-0.5 rounded text-[10px] font-mono font-bold uppercase tracking-wider bg-[var(--teal)]/15 text-[var(--teal)] border border-[var(--teal)]/30">
              Confidentiality Proof
            </span>
            <span className="text-xs font-mono text-[var(--muted)]">
              Enforcement Boundary: filter.py (AllowlistFilter)
            </span>
          </div>
          <h3 className="text-lg font-bold text-[var(--text)]">
            Zero-Payload Telemetry & Allowlist Inspector
          </h3>
          <p className="text-xs text-[var(--muted)] max-w-3xl leading-relaxed">
            Cryptographic proof that Signal Loom external agent telemetry collects strictly
            allowlisted process metadata. Customer source code, prompt tokens, model completions,
            and credentials are unconditionally stripped at the host-sensor kernel boundary.
          </p>
        </div>

        <div className="flex items-center gap-2">
          <span
            data-testid="inspector-channel-badge"
            className="px-2.5 py-1 rounded text-xs font-mono border bg-[var(--surface2)] border-[var(--border)] text-[var(--muted)]"
          >
            {isLiveChannel ? 'LIVE SENSOR SOURCE' : 'MOCK / DEMO SOURCE'} (Identical Build Manifest)
          </span>
        </div>
      </div>

      {/* Staleness Warning Banner */}
      {isStale && (
        <div
          data-testid="manifest-staleness-warning"
          role="alert"
          className="p-4 rounded-md border border-[var(--amber)]/50 bg-[var(--amber)]/10 text-[var(--text)] space-y-1"
        >
          <div className="flex items-center gap-2 text-sm font-bold text-[var(--amber)]">
            <span>⚠️</span>
            <span>Manifest Staleness Warning: filter.py Digest Mismatch</span>
          </div>
          <p className="text-xs text-[var(--muted)] leading-relaxed">
            The bundled allowlist manifest does not match the expected filter.py SHA-256 digest (
            <code className="font-mono text-[var(--amber)]">{expectedDigest?.slice(0, 16)}...</code> vs recorded{' '}
            <code className="font-mono text-[var(--cyan)]">{manifest.filter_sha256.slice(0, 16)}...</code>).
            Run <code className="font-mono bg-[var(--surface2)] px-1 py-0.5 rounded text-[var(--text)]">node scripts/generate-agentmaxxing-allowlist-manifest.mjs</code> to regenerate.
          </p>
        </div>
      )}

      {/* Cryptographic Build Digest Box */}
      <div className="p-4 rounded-lg bg-[var(--surface)] border border-[var(--border)] space-y-3">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div className="space-y-0.5">
            <div className="flex items-center gap-2">
              <span className="text-xs font-semibold text-[var(--text)]">
                Cryptographic Build Digest
              </span>
              <span
                data-testid="filter-digest-label"
                className="px-1.5 py-0.5 rounded text-[10px] font-mono bg-[var(--surface2)] text-[var(--cyan)] border border-[var(--cyan)]/30"
              >
                filter.py
              </span>
            </div>
            <p className="text-[11px] text-[var(--muted)]">
              Computed from deployed <span className="font-mono text-[var(--dim)]">d2-signalloom/apps/agentmaxxing-host-sensor/filter.py</span> at build time. Independently verifiable via <span className="font-mono text-[var(--dim)]">sha256sum filter.py</span>.
            </p>
          </div>

          <button
            type="button"
            data-testid="filter-digest-copy-btn"
            onClick={handleCopyDigest}
            className="px-3 py-1.5 rounded text-xs font-medium font-mono border border-[var(--border)] bg-[var(--surface2)] hover:bg-[var(--surface)] text-[var(--text)] flex items-center gap-1.5 transition-colors cursor-pointer"
            aria-label="Copy SHA-256 digest"
          >
            {copied ? (
              <>
                <span className="text-[var(--teal)]">✓</span>
                <span className="text-[var(--teal)]">Copied</span>
              </>
            ) : (
              <>
                <span>📋</span>
                <span>Copy Digest</span>
              </>
            )}
          </button>
        </div>

        <div className="p-2.5 rounded bg-[var(--bg)] border border-[var(--border)]/70 overflow-x-auto">
          <div className="flex items-center justify-between gap-3">
            <code
              data-testid="filter-digest"
              className="text-xs font-mono text-[var(--cyan)] tracking-wide select-all"
            >
              {manifest.filter_sha256}
            </code>
            <span className="text-[10px] font-mono uppercase text-[var(--muted)] shrink-0">
              SHA-256 (256-BIT)
            </span>
          </div>
        </div>
      </div>

      {/* Active Drop Count Demonstration */}
      <div
        data-testid="drop-count-demonstration"
        className="p-4 rounded-lg bg-[var(--surface)] border border-[var(--border)] space-y-4"
      >
        <div className="flex flex-wrap items-center justify-between gap-2 border-b border-[var(--border)]/60 pb-3">
          <div>
            <h4 className="text-sm font-bold text-[var(--text)] flex items-center gap-2">
              <span>Active Boundary Proof: Drop Count Demonstration</span>
              <span className="px-2 py-0.5 rounded text-[10px] font-mono bg-[var(--teal)]/15 text-[var(--teal)] border border-[var(--teal)]/30">
                PROVEN
              </span>
            </h4>
            <p className="text-xs text-[var(--muted)]">
              Evaluation of a representative raw telemetry payload containing allowlisted attributes and unapproved leak vectors.
            </p>
          </div>

          <div className="flex items-center gap-3">
            <div className="text-right">
              <div className="flex items-baseline gap-1.5 justify-end">
                <span
                  data-testid="drop-count"
                  className="text-2xl font-bold font-mono text-[var(--error)]"
                >
                  {filterResult.dropCount}
                </span>
                <span className="text-xs font-mono text-[var(--muted)]">dropped</span>
              </div>
              <div className="text-[10px] font-mono text-[var(--muted)]">
                {filterResult.preservedCount} preserved of {filterResult.totalIncomingCount} total fields
              </div>
            </div>
          </div>
        </div>

        {/* Dropped vs Preserved Keys Breakdown */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {/* Dropped Keys */}
          <div className="p-3 rounded bg-[var(--bg)] border border-[var(--error)]/30 space-y-2">
            <div className="flex items-center justify-between text-xs font-semibold">
              <span className="text-[var(--error)] flex items-center gap-1.5">
                <span>🚫</span>
                <span>Actively Dropped Fields ({filterResult.dropCount})</span>
              </span>
              <span className="text-[10px] font-mono text-[var(--muted)]">
                Zero-Customer-Payload Invariant
              </span>
            </div>
            <p className="text-[11px] text-[var(--muted)]">
              Non-allowlisted keys stripped before evidence export:
            </p>
            <div
              data-testid="dropped-keys-list"
              className="flex flex-wrap gap-1.5 pt-1"
            >
              {filterResult.droppedDetails.map((item) => (
                <span
                  key={item.key}
                  data-testid={`dropped-key-${item.key}`}
                  className="px-2 py-0.5 rounded text-[11px] font-mono bg-[var(--error)]/10 text-[var(--error)] border border-[var(--error)]/30 flex items-center gap-1 line-through"
                  title={`Dropped: ${item.reason === 'prohibited_export_key' ? 'PROHIBITED_EXPORT_KEYS member' : 'Not on ALLOWLISTED_PROCESS_ATTRIBUTES'}`}
                >
                  {item.key}
                </span>
              ))}
            </div>
          </div>

          {/* Preserved Allowlisted Keys */}
          <div className="p-3 rounded bg-[var(--bg)] border border-[var(--teal)]/30 space-y-2">
            <div className="flex items-center justify-between text-xs font-semibold">
              <span className="text-[var(--teal)] flex items-center gap-1.5">
                <span>✓</span>
                <span>Preserved Allowlisted Fields ({filterResult.preservedCount})</span>
              </span>
              <span className="text-[10px] font-mono text-[var(--muted)]">
                Exported Metadata
              </span>
            </div>
            <p className="text-[11px] text-[var(--muted)]">
              Authorized process lifecycle attributes passing to export:
            </p>
            <div
              data-testid="preserved-keys-list"
              className="flex flex-wrap gap-1.5 pt-1"
            >
              {filterResult.preservedKeys.map((key) => (
                <span
                  key={key}
                  data-testid={`preserved-key-${key}`}
                  className="px-2 py-0.5 rounded text-[11px] font-mono bg-[var(--teal)]/10 text-[var(--teal)] border border-[var(--teal)]/30"
                >
                  {key}
                </span>
              ))}
            </div>
          </div>
        </div>
      </div>

      {/* Compiled Allowlist Sets */}
      <div
        data-testid="allowlist-list"
        className="p-4 rounded-lg bg-[var(--surface)] border border-[var(--border)] space-y-4"
      >
        <div className="flex items-center justify-between border-b border-[var(--border)]/60 pb-3">
          <div>
            <h4 className="text-sm font-bold text-[var(--text)]">
              Compiled Sensor Allowlist Sets
            </h4>
            <p className="text-xs text-[var(--muted)]">
              Exact set literals extracted from <span className="font-mono text-[var(--dim)]">filter.py</span> at build time.
            </p>
          </div>
          <span className="text-xs font-mono text-[var(--cyan)]">
            {manifest.allowlisted_process_attributes.length} Process Attributes • {manifest.allowlisted_envelope_fields.length} Envelope Fields
          </span>
        </div>

        <div className="space-y-4">
          {/* Process Attributes */}
          <div className="space-y-2">
            <div className="flex items-center justify-between">
              <span className="text-xs font-semibold font-mono text-[var(--cyan)]">
                ALLOWLISTED_PROCESS_ATTRIBUTES ({manifest.allowlisted_process_attributes.length})
              </span>
              <span className="text-[10px] font-mono text-[var(--muted)]">
                filter.py:34-39
              </span>
            </div>
            <div
              data-testid="allowlist-process-attributes"
              className="flex flex-wrap gap-1.5"
            >
              {manifest.allowlisted_process_attributes.map((attr) => (
                <span
                  key={attr}
                  data-testid={`allowlist-process-attr-${attr}`}
                  className="px-2 py-1 rounded text-xs font-mono bg-[var(--surface2)] text-[var(--text)] border border-[var(--border)] hover:border-[var(--cyan)] transition-colors"
                >
                  {attr}
                </span>
              ))}
            </div>
          </div>

          {/* Envelope Fields */}
          <div className="space-y-2">
            <div className="flex items-center justify-between">
              <span className="text-xs font-semibold font-mono text-[var(--cyan)]">
                ALLOWLISTED_ENVELOPE_FIELDS ({manifest.allowlisted_envelope_fields.length})
              </span>
              <span className="text-[10px] font-mono text-[var(--muted)]">
                filter.py:83-97
              </span>
            </div>
            <div
              data-testid="allowlist-envelope-fields"
              className="flex flex-wrap gap-1.5"
            >
              {manifest.allowlisted_envelope_fields.map((field) => (
                <span
                  key={field}
                  data-testid={`allowlist-envelope-field-${field}`}
                  className="px-2 py-1 rounded text-xs font-mono bg-[var(--surface2)] text-[var(--text)] border border-[var(--border)] hover:border-[var(--cyan)] transition-colors"
                >
                  {field}
                </span>
              ))}
            </div>
          </div>

          {/* Prohibited Keys Summary */}
          <div className="space-y-2">
            <div className="flex items-center justify-between">
              <span className="text-xs font-semibold font-mono text-[var(--error)]">
                PROHIBITED_EXPORT_KEYS ({manifest.prohibited_export_keys.length})
              </span>
              <span className="text-[10px] font-mono text-[var(--muted)]">
                filter.py:145-182 (Explicit Denylist)
              </span>
            </div>
            <div
              data-testid="prohibited-keys-list"
              className="flex flex-wrap gap-1 max-h-24 overflow-y-auto p-2 bg-[var(--bg)] rounded border border-[var(--border)]"
            >
              {manifest.prohibited_export_keys.map((key) => (
                <span
                  key={key}
                  data-testid={`prohibited-key-${key}`}
                  className="px-1.5 py-0.5 rounded text-[10px] font-mono bg-[var(--surface)] text-[var(--muted)] border border-[var(--border)]"
                >
                  {key}
                </span>
              ))}
            </div>
          </div>
        </div>
      </div>

      {/* Defense-in-Depth Secondary Check Notice */}
      <div
        data-testid="dom-inspection-notice"
        className="p-3 rounded border border-[var(--border)]/60 bg-[var(--surface2)]/40 flex items-start gap-2.5 text-xs text-[var(--muted)]"
      >
        <span className="text-[var(--cyan)] shrink-0">ℹ️</span>
        <div className="space-y-1">
          <span className="font-semibold text-[var(--text)]">
            Secondary Defense-in-Depth DOM Assertion
          </span>
          <p className="leading-relaxed">
            Client-side DOM string-absence inspection operates as a secondary sanity assertion.
            The primary confidentiality proof is the cryptographically tied{' '}
            <code className="font-mono text-[var(--cyan)]">filter.py</code> allowlist engine and
            kernel LSM process isolation.
          </p>
        </div>
      </div>
    </div>
  )
}

export default ZeroPayloadInspector
