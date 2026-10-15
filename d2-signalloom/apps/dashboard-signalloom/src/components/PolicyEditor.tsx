import React, { useState, useEffect, useMemo, useRef, useCallback } from 'react'
import { parse } from '@marcbachmann/cel-js'
import type { PolicyBundle, PolicyRule, VersionHistoryItem } from '../types/policies'
import ConfirmDialog from './ConfirmDialog'
import { prettifyCel } from '../utils/celFormatter'
import { getBundleForFramework, normalizeFrameworkId } from '../data/regulatoryFrameworks'

export interface PolicyEditorProps {
  bundle: PolicyBundle | null
  versionHistory?: VersionHistoryItem[]
  onSave?: (updatedBundle: PolicyBundle) => Promise<void>
  onRollback?: (frameworkId: string, targetVersion: string) => Promise<void>
  readOnly?: boolean
  availableFrameworks?: Array<{ id: string; name: string }>
  onSelectFramework?: (frameworkId: string) => void
  selectedRuleId?: string | null
  onSelectRule?: (ruleId: string) => void
}

export interface CelDiagnostic {
  valid: boolean
  message?: string
  line?: number
  column?: number
  snippet?: string
}

// Monarch Tokenizer definitions for CEL
export const celKeywords = new Set(['true', 'false', 'null', 'in', 'as'])
export const celMacros = new Set([
  'has', 'all', 'exists', 'exists_one', 'map', 'filter', 'size', 'type',
  'contains', 'startsWith', 'endsWith', 'matches',
  'int', 'uint', 'double', 'string', 'bytes', 'duration', 'timestamp',
])
export const celVariables = new Set(['agent', 'request', 'object', 'manifest'])

export interface Token {
  text: string
  type: 'keyword' | 'macro' | 'variable' | 'string' | 'number' | 'operator' | 'comment' | 'punctuation' | 'identifier' | 'whitespace' | 'error'
}

export function tokenizeCel(code: string): Token[][] {
  const lines = code.split('\n')
  return lines.map((line) => {
    const tokens: Token[] = []
    let i = 0
    while (i < line.length) {
      const ch = line[i]

      // Whitespace
      if (/\s/.test(ch)) {
        let ws = ch
        i++
        while (i < line.length && /\s/.test(line[i])) {
          ws += line[i]
          i++
        }
        tokens.push({ text: ws, type: 'whitespace' })
        continue
      }

      // Line Comment
      if (ch === '/' && line[i + 1] === '/') {
        tokens.push({ text: line.slice(i), type: 'comment' })
        break
      }

      // Block comment start
      if (ch === '/' && line[i + 1] === '*') {
        const endIdx = line.indexOf('*/', i + 2)
        if (endIdx !== -1) {
          tokens.push({ text: line.slice(i, endIdx + 2), type: 'comment' })
          i = endIdx + 2
        } else {
          tokens.push({ text: line.slice(i), type: 'comment' })
          break
        }
        continue
      }

      // Strings
      if (ch === '"' || ch === "'") {
        const quote = ch
        let str = quote
        i++
        let escaped = false
        while (i < line.length) {
          const c = line[i]
          str += c
          i++
          if (c === '\\' && !escaped) {
            escaped = true
          } else if (c === quote && !escaped) {
            break
          } else {
            escaped = false
          }
        }
        tokens.push({ text: str, type: 'string' })
        continue
      }

      // Numbers
      if (/[0-9]/.test(ch)) {
        let num = ch
        i++
        while (i < line.length && /[0-9.eE_]/.test(line[i])) {
          num += line[i]
          i++
        }
        tokens.push({ text: num, type: 'number' })
        continue
      }

      // Identifiers / Keywords / Variables / Macros
      if (/[a-zA-Z_]/.test(ch)) {
        let ident = ch
        i++
        while (i < line.length && /[a-zA-Z0-9_]/.test(line[i])) {
          ident += line[i]
          i++
        }
        if (celKeywords.has(ident)) {
          tokens.push({ text: ident, type: 'keyword' })
        } else if (celMacros.has(ident)) {
          tokens.push({ text: ident, type: 'macro' })
        } else if (celVariables.has(ident)) {
          tokens.push({ text: ident, type: 'variable' })
        } else {
          tokens.push({ text: ident, type: 'identifier' })
        }
        continue
      }

      // Multi-character operators
      const two = line.slice(i, i + 2)
      if (['==', '!=', '<=', '>=', '&&', '||'].includes(two)) {
        tokens.push({ text: two, type: 'operator' })
        i += 2
        continue
      }

      // Single character operators and punctuation
      if (['<', '>', '!', '+', '-', '*', '/', '%', '?', ':'].includes(ch)) {
        tokens.push({ text: ch, type: 'operator' })
        i++
        continue
      }

      if (['(', ')', '[', ']', '{', '}', '.', ',', ';'].includes(ch)) {
        tokens.push({ text: ch, type: 'punctuation' })
        i++
        continue
      }

      // Fallback
      tokens.push({ text: ch, type: 'error' })
      i++
    }
    return tokens
  })
}

export function validateCelExpression(code: string): CelDiagnostic {
  if (!code || !code.trim()) {
    return { valid: true }
  }

  // Treat comments as valid informational stubs
  const trimmed = code.trim()
  if (trimmed.startsWith('/*') && trimmed.endsWith('*/')) {
    return { valid: true }
  }

  try {
    parse(code)
    return { valid: true }
  } catch (err: unknown) {
    const parseErr = err as { message?: string; line?: number; column?: number }
    const msg = parseErr.message || 'Syntax error in CEL expression'
    const firstLine = msg.split('\n')[0]
    return {
      valid: false,
      message: firstLine,
      line: parseErr.line || 1,
      column: parseErr.column || 1,
      snippet: msg,
    }
  }
}

export default function PolicyEditor({
  bundle,
  versionHistory = [],
  onSave,
  onRollback,
  readOnly = false,
  availableFrameworks = [],
  onSelectFramework,
  selectedRuleId,
  onSelectRule,
}: PolicyEditorProps) {
  const effectiveBundle = bundle || {
    id: 'unregistered-bundle',
    framework_id: availableFrameworks[0]?.id || 'unknown',
    version: 'v0.0.0',
    author: 'system',
    description: 'No bundle registered',
    created_at: new Date().toISOString(),
    checksum: '',
    rules: [],
  }

  const [selectedRuleIndex, setSelectedRuleIndex] = useState(0)
  const [rules, setRules] = useState<PolicyRule[]>(effectiveBundle.rules || [])
  const [historyOpen, setHistoryOpen] = useState(false)
  const [selectedHistoryVersion, setSelectedHistoryVersion] = useState<string | null>(null)
  const [rollbackConfirmOpen, setRollbackConfirmOpen] = useState(false)
  const [saving, setSaving] = useState(false)
  const [saveSuccess, setSaveSuccess] = useState(false)
  const [saveError, setSaveError] = useState<string | null>(null)
  const [rollbackError, setRollbackError] = useState<string | null>(null)
  const [diagnosticTooltipOpen, setDiagnosticTooltipOpen] = useState(false)
  const [ruleSearch, setRuleSearch] = useState('')
  const [wrapLines, setWrapLines] = useState(true)
  const [copiedLink, setCopiedLink] = useState(false)

  const textareaRef = useRef<HTMLTextAreaElement>(null)

  useEffect(() => {
    const bRules = effectiveBundle.rules || []
    setRules(bRules)
    if (selectedRuleId) {
      let idx = bRules.findIndex((r) => r.id === selectedRuleId)
      if (idx === -1) {
        const clean = selectedRuleId.toLowerCase()
        idx = bRules.findIndex(
          (r) =>
            r.id.toLowerCase() === clean ||
            r.id.toLowerCase().includes(clean) ||
            r.name.toLowerCase().includes(clean),
        )
      }
      setSelectedRuleIndex(idx >= 0 ? idx : 0)
    } else {
      setSelectedRuleIndex(0)
    }
  }, [effectiveBundle.rules, effectiveBundle.id, selectedRuleId])

  const filteredRules = useMemo(() => {
    if (!ruleSearch.trim()) return rules
    const q = ruleSearch.toLowerCase()
    return rules.filter(
      (r) =>
        r.id.toLowerCase().includes(q) ||
        r.name.toLowerCase().includes(q) ||
        (r.description && r.description.toLowerCase().includes(q))
    )
  }, [rules, ruleSearch])

  const currentRule = rules[selectedRuleIndex] || {
    id: 'rule-0',
    name: 'New Rule',
    cel_expression: '',
    severity: 'high',
    remediation: '',
  }

  const diagnostic = useMemo(() => {
    return validateCelExpression(currentRule.cel_expression || '')
  }, [currentRule.cel_expression])

  const tokenizedLines = useMemo(() => {
    return tokenizeCel(currentRule.cel_expression || '')
  }, [currentRule.cel_expression])

  const handleSelectRuleAt = (idx: number) => {
    setSelectedRuleIndex(idx)
    if (rules[idx] && onSelectRule) {
      onSelectRule(rules[idx].id)
    }
  }

  const handleExpressionChange = (val: string) => {
    if (readOnly) return
    const updated = [...rules]
    updated[selectedRuleIndex] = {
      ...currentRule,
      cel_expression: val,
    }
    setRules(updated)
    setSaveSuccess(false)
  }

  const handlePrettify = () => {
    if (!currentRule.cel_expression || readOnly) return
    const pretty = prettifyCel(currentRule.cel_expression)
    handleExpressionChange(pretty)
  }

  const handleCopyLink = () => {
    const origin = typeof window !== 'undefined' ? window.location.origin : ''
    const canonicalFw = normalizeFrameworkId(effectiveBundle.framework_id)
    const url = `${origin}/policies?framework=${encodeURIComponent(canonicalFw)}&rule=${encodeURIComponent(currentRule.id)}`
    if (typeof navigator !== 'undefined' && navigator.clipboard) {
      navigator.clipboard.writeText(url).catch(() => {})
      setCopiedLink(true)
      setTimeout(() => setCopiedLink(false), 2000)
    }
  }

  const handleSave = async () => {
    if (readOnly || !onSave) return
    if (!diagnostic.valid) {
      setSaveError(`Cannot save invalid CEL syntax: ${diagnostic.message}`)
      return
    }

    setSaving(true)
    setSaveError(null)
    try {
      const verParts = (effectiveBundle.version || 'v1.0.0').replace(/^v/, '').split('.').map(Number)
      while (verParts.length < 3) verParts.push(0)
      verParts[2] = (verParts[2] || 0) + 1
      const nextVersion = `v${verParts.join('.')}`

      const updatedBundle: PolicyBundle = {
        ...effectiveBundle,
        version: nextVersion,
        rules,
        created_at: new Date().toISOString(),
      }

      await onSave(updatedBundle)
      setSaveSuccess(true)
    } catch (err: unknown) {
      setSaveError(err instanceof Error ? err.message : 'Failed to save policy bundle')
    } finally {
      setSaving(false)
    }
  }

  const handleTriggerRollback = () => {
    if (!selectedHistoryVersion) return
    setRollbackConfirmOpen(true)
  }

  const handleConfirmRollback = async () => {
    if (!selectedHistoryVersion || !onRollback) return
    setRollbackConfirmOpen(false)
    setRollbackError(null)
    try {
      await onRollback(effectiveBundle.framework_id, selectedHistoryVersion)
      setHistoryOpen(false)
    } catch (err: unknown) {
      setRollbackError(err instanceof Error ? err.message : 'Rollback failed')
    }
  }

  const handleInitializeFromTemplate = () => {
    const template = getBundleForFramework(effectiveBundle.framework_id)
    if (template && template.rules.length > 0) {
      setRules(template.rules)
      setSelectedRuleIndex(0)
      if (onSelectRule) onSelectRule(template.rules[0].id)
    }
  }

  const getTokenStyle = (type: Token['type']): React.CSSProperties => {
    switch (type) {
      case 'keyword':
        return { color: 'var(--cyan)', fontWeight: 600 }
      case 'macro':
        return { color: 'var(--violet)', fontWeight: 600 }
      case 'variable':
        return { color: 'var(--cyan)', fontWeight: 600 }
      case 'string':
        return { color: 'var(--teal)' }
      case 'number':
        return { color: 'var(--amber)' }
      case 'comment':
        return { color: 'var(--muted)', fontStyle: 'italic' }
      case 'operator':
      case 'punctuation':
        return { color: 'var(--text)' }
      default:
        return { color: 'var(--text)' }
    }
  }

  const isManualAttestation = Boolean(
    currentRule.manual_attestation || currentRule.attestation_type === 'manual' || currentRule.attestation_type === 'cluster'
  )

  return (
    <div
      data-testid="policy-editor-container"
      style={{
        display: 'flex',
        flexDirection: 'column',
        gap: 16,
        background: 'var(--surface)',
        border: '1px solid var(--border)',
        borderRadius: 8,
        padding: 16,
      }}
    >
      {/* Top Header Bar with Framework Switcher */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          flexWrap: 'wrap',
          gap: 12,
          paddingBottom: 12,
          borderBottom: '1px solid var(--border)',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
          {availableFrameworks.length > 0 && onSelectFramework ? (
            <select
              data-testid="framework-selector"
              value={normalizeFrameworkId(effectiveBundle.framework_id)}
              onChange={(e) => onSelectFramework(e.target.value)}
              style={{
                background: 'var(--bg)',
                color: 'var(--text)',
                border: '1px solid var(--border)',
                borderRadius: 6,
                padding: '6px 12px',
                fontSize: 13,
                fontWeight: 600,
              }}
            >
              {availableFrameworks.map((fw) => (
                <option key={fw.id} value={fw.id}>
                  {fw.name}
                </option>
              ))}
            </select>
          ) : (
            <span style={{ fontSize: 16, fontWeight: 700, color: 'var(--text)' }}>
              {effectiveBundle.framework_id.toUpperCase()}
            </span>
          )}

          <span
            data-testid="policy-version-badge"
            style={{
              fontSize: 11,
              fontWeight: 700,
              textTransform: 'uppercase',
              letterSpacing: '0.06em',
              padding: '2px 8px',
              borderRadius: 99,
              background: 'rgba(6, 182, 212, 0.12)',
              color: 'var(--cyan)',
            }}
          >
            {effectiveBundle.version}
          </span>

          {effectiveBundle.status === 'placeholder' && (
            <span
              data-testid="policy-placeholder-badge"
              style={{
                fontSize: 11,
                fontWeight: 700,
                textTransform: 'uppercase',
                letterSpacing: '0.06em',
                padding: '2px 8px',
                borderRadius: 99,
                background: 'rgba(148, 163, 184, 0.12)',
                color: 'var(--muted)',
              }}
            >
              Placeholder
            </span>
          )}

          <button
            data-testid="copy-shareable-link-btn"
            type="button"
            className="btn btn-secondary"
            onClick={handleCopyLink}
            style={{
              fontSize: 11,
              padding: '4px 8px',
              display: 'inline-flex',
              alignItems: 'center',
              gap: 4,
            }}
            title="Copy shareable link with framework and active rule"
          >
            <span>{copiedLink ? '✓ Copied' : '🔗 Share Link'}</span>
          </button>
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <button
            data-testid="toggle-version-history-btn"
            type="button"
            className="btn btn-secondary"
            onClick={() => setHistoryOpen(!historyOpen)}
            style={{
              display: 'inline-flex',
              alignItems: 'center',
              gap: 6,
              fontSize: 12,
              padding: '6px 12px',
            }}
          >
            <span>Version History</span>
            <span
              style={{
                fontSize: 10,
                padding: '1px 5px',
                borderRadius: 10,
                background: 'var(--surface2)',
                color: 'var(--muted)',
              }}
            >
              {versionHistory.length}
            </span>
          </button>

          {!readOnly && onSave && (
            <button
              data-testid="save-policy-btn"
              type="button"
              className="btn btn-primary"
              onClick={handleSave}
              disabled={saving || (!diagnostic.valid && !isManualAttestation)}
              style={{ fontSize: 12, padding: '6px 14px' }}
            >
              {saving ? 'Saving...' : 'Save New Version'}
            </button>
          )}
        </div>
      </div>

      {saveError && (
        <div
          data-testid="policy-save-error"
          style={{
            padding: '8px 12px',
            borderRadius: 6,
            background: 'rgba(220, 38, 38, 0.15)',
            border: '1px solid var(--error)',
            color: 'var(--error)',
            fontSize: 12,
          }}
        >
          {saveError}
        </div>
      )}

      {saveSuccess && (
        <div
          data-testid="policy-save-success"
          style={{
            padding: '8px 12px',
            borderRadius: 6,
            background: 'rgba(16, 185, 129, 0.15)',
            border: '1px solid var(--teal)',
            color: 'var(--teal)',
            fontSize: 12,
          }}
        >
          Policy version saved successfully.
        </div>
      )}

      {/* When bundle has 0 rules: keep workspace intact with Initialize button */}
      {rules.length === 0 ? (
        <div
          data-testid="empty-bundle-notice"
          style={{
            padding: 36,
            textAlign: 'center',
            background: 'var(--bg)',
            borderRadius: 8,
            border: '1px dashed var(--border)',
          }}
        >
          <div style={{ fontSize: 16, fontWeight: 600, color: 'var(--text)', marginBottom: 8 }}>
            No policy rules registered in &ldquo;{effectiveBundle.framework_id}&rdquo;
          </div>
          <p style={{ fontSize: 13, color: 'var(--muted)', maxWidth: 520, margin: '0 auto 16px auto', lineHeight: 1.5 }}>
            This policy bundle currently contains no active CEL or governance rules. You can select another framework using the dropdown above, or initialize this bundle with default baseline regulatory rules.
          </p>
          <button
            data-testid="initialize-template-btn"
            type="button"
            className="btn btn-primary"
            onClick={handleInitializeFromTemplate}
            style={{ fontSize: 13, padding: '8px 18px' }}
          >
            Initialize from Baseline Template
          </button>
        </div>
      ) : (
        /* Main Workspace Layout */
        <div style={{ display: 'grid', gridTemplateColumns: historyOpen ? '1fr 340px' : '1fr', gap: 16 }}>
          {/* Editor Main Column */}
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            {/* Rules Navigation Bar with Search and Wrapped Chips */}
            <div
              style={{
                display: 'flex',
                flexDirection: 'column',
                gap: 8,
                paddingBottom: 8,
                borderBottom: '1px solid var(--border)',
              }}
            >
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
                <span style={{ fontSize: 11, fontWeight: 700, textTransform: 'uppercase', color: 'var(--muted)', letterSpacing: '0.06em' }}>
                  Policy Controls ({rules.length})
                </span>
                <input
                  data-testid="rule-search-input"
                  type="text"
                  placeholder="Filter rules..."
                  value={ruleSearch}
                  onChange={(e) => setRuleSearch(e.target.value)}
                  style={{
                    padding: '4px 10px',
                    fontSize: 12,
                    background: 'var(--bg)',
                    border: '1px solid var(--border)',
                    borderRadius: 6,
                    color: 'var(--text)',
                    width: 160,
                  }}
                />
              </div>

              {/* Wrapped Rule Selector Chips */}
              <div
                data-testid="rule-chips-container"
                style={{
                  display: 'flex',
                  flexWrap: 'wrap',
                  gap: 6,
                  maxHeight: 140,
                  overflowY: 'auto',
                }}
              >
                {filteredRules.map((rule) => {
                  const actualIdx = rules.findIndex((r) => r.id === rule.id)
                  const isSelected = actualIdx === selectedRuleIndex
                  const isManual = rule.manual_attestation || rule.attestation_type === 'manual' || rule.attestation_type === 'cluster'
                  const ruleDiag = validateCelExpression(rule.cel_expression || '')

                  return (
                    <button
                      key={rule.id}
                      data-testid={`rule-tab-${rule.id}`}
                      type="button"
                      onClick={() => handleSelectRuleAt(actualIdx)}
                      style={{
                        padding: '5px 10px',
                        borderRadius: 6,
                        border: '1px solid',
                        borderColor: isSelected ? 'var(--cyan)' : 'var(--border)',
                        background: isSelected ? 'rgba(6, 182, 212, 0.12)' : 'var(--bg)',
                        color: isSelected ? 'var(--cyan)' : 'var(--text)',
                        fontSize: 12,
                        fontWeight: isSelected ? 600 : 400,
                        cursor: 'pointer',
                        display: 'flex',
                        alignItems: 'center',
                        gap: 6,
                        whiteSpace: 'nowrap',
                        transition: 'all 0.15s ease',
                      }}
                    >
                      {isManual ? (
                        <span title="Manual / Cluster Attestation Control" style={{ fontSize: 11 }}>📋</span>
                      ) : null}
                      <span>{rule.id}</span>
                      {!isManual && !ruleDiag.valid && (
                        <span
                          title={ruleDiag.message}
                          style={{
                            width: 6,
                            height: 6,
                            borderRadius: '50%',
                            background: 'var(--error)',
                          }}
                        />
                      )}
                    </button>
                  )
                })}
              </div>
            </div>

            {/* Redesigned Policy Name & Metadata Header Section */}
            <div
              data-testid="policy-name-header"
              style={{
                display: 'flex',
                flexDirection: 'column',
                gap: 6,
                padding: '12px 16px',
                background: 'var(--bg)',
                borderRadius: 8,
                border: '1px solid var(--border)',
              }}
            >
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 8 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                  <span style={{ fontSize: 11, fontWeight: 700, textTransform: 'uppercase', color: 'var(--cyan)', letterSpacing: '0.06em' }}>
                    {effectiveBundle.framework_id}
                  </span>
                  <span style={{ color: 'var(--border)' }}>/</span>
                  <span style={{ fontSize: 13, fontWeight: 700, color: 'var(--text)', fontFamily: 'monospace' }}>
                    {currentRule.id}
                  </span>
                </div>

                <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                  {isManualAttestation ? (
                    <span
                      data-testid="manual-attestation-badge"
                      style={{
                        fontSize: 10,
                        fontWeight: 700,
                        textTransform: 'uppercase',
                        padding: '2px 8px',
                        borderRadius: 4,
                        background: 'rgba(139, 92, 246, 0.15)',
                        color: 'var(--violet, #a78bfa)',
                        border: '1px solid rgba(139, 92, 246, 0.3)',
                        display: 'inline-flex',
                        alignItems: 'center',
                        gap: 4,
                      }}
                    >
                      📋 Manual Attestation
                    </span>
                  ) : (
                    <span
                      style={{
                        fontSize: 10,
                        fontWeight: 700,
                        textTransform: 'uppercase',
                        padding: '2px 8px',
                        borderRadius: 4,
                        background: 'rgba(6, 182, 212, 0.15)',
                        color: 'var(--cyan)',
                      }}
                    >
                      CEL Evaluated
                    </span>
                  )}

                  <span
                    style={{
                      fontSize: 10,
                      fontWeight: 700,
                      textTransform: 'uppercase',
                      padding: '2px 6px',
                      borderRadius: 4,
                      background: currentRule.severity === 'critical' ? 'rgba(220,38,38,0.15)' : 'rgba(217,119,6,0.15)',
                      color: currentRule.severity === 'critical' ? 'var(--error)' : 'var(--amber)',
                    }}
                  >
                    {currentRule.severity || 'high'}
                  </span>
                </div>
              </div>

              <div
                data-testid="selected-rule-name"
                style={{ fontSize: 15, fontWeight: 600, color: 'var(--text)', marginTop: 2 }}
              >
                {currentRule.name}
              </div>

              {currentRule.description && (
                <p style={{ fontSize: 12, color: 'var(--muted)', margin: 0, lineHeight: 1.4 }}>
                  {currentRule.description}
                </p>
              )}

              {currentRule.remediation && (
                <p style={{ fontSize: 12, color: 'var(--muted)', margin: 0, lineHeight: 1.4 }}>
                  <strong style={{ color: 'var(--text)' }}>Remediation:</strong> {currentRule.remediation}
                </p>
              )}

              {isManualAttestation && (
                <div
                  style={{
                    marginTop: 4,
                    padding: '8px 12px',
                    borderRadius: 6,
                    background: 'rgba(139, 92, 246, 0.08)',
                    border: '1px solid rgba(139, 92, 246, 0.25)',
                    fontSize: 11,
                    color: 'var(--text)',
                    display: 'flex',
                    flexDirection: 'column',
                    gap: 4,
                  }}
                >
                  <div style={{ fontWeight: 600, color: 'var(--violet, #a78bfa)' }}>
                    Non-CEL Verification Context
                  </div>
                  <div>
                    {currentRule.manual_attestation_note ||
                      currentRule.tested_separately_note ||
                      'This control cannot be evaluated via inline CEL pod admission. In upcoming releases, manual auditor attestation and external telemetry connectors can be recorded against this control.'}
                  </div>
                </div>
              )}
            </div>

            {/* CEL Code Editor Area with Prettify and Wrap Toolbar */}
            <div
              data-testid="cel-editor-workspace"
              style={{
                position: 'relative',
                display: 'flex',
                flexDirection: 'column',
                borderRadius: 6,
                border: `1px solid ${diagnostic.valid ? 'var(--border)' : 'var(--error)'}`,
                background: 'var(--bg)',
                fontFamily: 'monospace',
                fontSize: 13,
                lineHeight: '20px',
                overflow: 'hidden',
              }}
            >
              {/* Editor Secondary Actions Bar (Prettify & Line Wrap) */}
              <div
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'space-between',
                  padding: '6px 12px',
                  background: 'var(--surface2)',
                  borderBottom: '1px solid var(--border)',
                  fontSize: 11,
                }}
              >
                <span style={{ color: 'var(--muted)' }}>
                  Common Expression Language (CEL) Syntax
                </span>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                  <button
                    data-testid="prettify-cel-btn"
                    type="button"
                    className="btn btn-secondary"
                    onClick={handlePrettify}
                    style={{ fontSize: 11, padding: '2px 8px' }}
                    title="Intelligently format and indent CEL expression"
                  >
                    ✨ Prettify CEL
                  </button>
                  <button
                    data-testid="toggle-wrap-btn"
                    type="button"
                    className="btn btn-secondary"
                    onClick={() => setWrapLines(!wrapLines)}
                    style={{ fontSize: 11, padding: '2px 8px' }}
                    title="Toggle line wrapping on box width"
                  >
                    {wrapLines ? 'Wrap: ON' : 'Wrap: OFF'}
                  </button>
                </div>
              </div>

              <div style={{ display: 'flex', minHeight: 180, position: 'relative' }}>
                {/* Line Numbers Gutter */}
                <div
                  style={{
                    padding: '12px 8px',
                    background: 'var(--surface2)',
                    color: 'var(--muted)',
                    textAlign: 'right',
                    userSelect: 'none',
                    borderRight: '1px solid var(--border)',
                    minWidth: 40,
                  }}
                >
                  {tokenizedLines.map((_, i) => (
                    <div key={i} style={{ height: 20 }}>
                      {i + 1}
                    </div>
                  ))}
                </div>

                {/* Textarea Input Overlay and Syntax Token Display */}
                <div style={{ position: 'relative', flex: 1, padding: 12, overflow: 'auto' }}>
                  <textarea
                    ref={textareaRef}
                    data-testid="cel-code-textarea"
                    aria-label="CEL Expression Editor"
                    value={currentRule.cel_expression || ''}
                    onChange={(e) => handleExpressionChange(e.target.value)}
                    readOnly={readOnly}
                    spellCheck={false}
                    autoCapitalize="off"
                    autoComplete="off"
                    onKeyDown={(e) => {
                      if (e.key === 'Escape') {
                        textareaRef.current?.blur()
                      }
                    }}
                    style={{
                      position: 'absolute',
                      top: 12,
                      left: 12,
                      right: 12,
                      bottom: 12,
                      width: 'calc(100% - 24px)',
                      height: 'calc(100% - 24px)',
                      background: 'transparent',
                      color: 'transparent',
                      caretColor: 'var(--text)',
                      border: 'none',
                      outline: 'none',
                      resize: 'none',
                      fontFamily: 'monospace',
                      fontSize: 13,
                      lineHeight: '20px',
                      whiteSpace: wrapLines ? 'pre-wrap' : 'pre',
                      wordBreak: wrapLines ? 'break-word' : 'normal',
                      zIndex: 2,
                      margin: 0,
                      padding: 0,
                    }}
                  />

                  {/* Tokenized Syntax Highlighting Display */}
                  <div
                    data-testid="cel-syntax-highlight-overlay"
                    aria-hidden="true"
                    style={{
                      position: 'relative',
                      zIndex: 1,
                      whiteSpace: wrapLines ? 'pre-wrap' : 'pre',
                      wordBreak: wrapLines ? 'break-word' : 'normal',
                      fontFamily: 'monospace',
                      fontSize: 13,
                      lineHeight: '20px',
                      pointerEvents: 'none',
                    }}
                  >
                    {tokenizedLines.map((lineTokens, lineIdx) => {
                      const isErrorLine = !diagnostic.valid && (diagnostic.line === lineIdx + 1 || (tokenizedLines.length === 1 && lineIdx === 0))
                      return (
                        <div key={lineIdx} style={{ minHeight: 20 }}>
                          {lineTokens.map((tok, tokIdx) => (
                            <span
                              key={tokIdx}
                              style={{
                                ...getTokenStyle(tok.type),
                                ...(isErrorLine && tok.type !== 'whitespace'
                                  ? {
                                      textDecoration: 'underline wavy var(--error)',
                                      textUnderlineOffset: 3,
                                    }
                                  : {}),
                              }}
                            >
                              {tok.text}
                            </span>
                          ))}
                        </div>
                      )
                    })}
                  </div>
                </div>
              </div>

              {/* Diagnostic Footer Bar */}
              <div
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'space-between',
                  padding: '8px 12px',
                  borderTop: '1px solid var(--border)',
                  background: diagnostic.valid ? 'var(--surface)' : 'rgba(220, 38, 38, 0.12)',
                  fontSize: 12,
                }}
              >
                {diagnostic.valid ? (
                  <div
                    data-testid="cel-diagnostic-valid"
                    style={{ display: 'flex', alignItems: 'center', gap: 6, color: 'var(--teal)' }}
                  >
                    <span>✓</span>
                    <span>Valid CEL syntax</span>
                  </div>
                ) : (
                  <div
                    data-testid="cel-diagnostic-error"
                    style={{ display: 'flex', alignItems: 'center', gap: 6, color: 'var(--error)' }}
                  >
                    <span>✕</span>
                    <span>Line {diagnostic.line}, Col {diagnostic.column}: {diagnostic.message}</span>
                  </div>
                )}

                <div style={{ display: 'flex', alignItems: 'center', gap: 12, color: 'var(--muted)', fontSize: 11 }}>
                  <span>{tokenizedLines.length} lines</span>
                  <span>{(currentRule.cel_expression || '').length} chars</span>
                </div>
              </div>
            </div>
          </div>

          {/* Version History Drawer Column */}
          {historyOpen && (
            <div
              data-testid="version-history-drawer"
              style={{
                display: 'flex',
                flexDirection: 'column',
                gap: 12,
                background: 'var(--surface2)',
                borderRadius: 8,
                padding: 12,
                border: '1px solid var(--border)',
              }}
            >
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <span style={{ fontSize: 12, fontWeight: 700, textTransform: 'uppercase', color: 'var(--text)' }}>
                  Version History
                </span>
                <button
                  type="button"
                  className="btn btn-secondary"
                  onClick={() => setHistoryOpen(false)}
                  style={{ fontSize: 11, padding: '2px 6px' }}
                >
                  ✕
                </button>
              </div>

              {rollbackError && (
                <div style={{ padding: '6px 10px', borderRadius: 4, background: 'rgba(220,38,38,0.15)', color: 'var(--error)', fontSize: 11 }}>
                  {rollbackError}
                </div>
              )}

              <div style={{ display: 'flex', flexDirection: 'column', gap: 8, maxHeight: 320, overflowY: 'auto' }}>
                {versionHistory.map((item) => {
                  const isSelected = selectedHistoryVersion === item.version
                  const isCurrent = effectiveBundle.version === item.version
                  return (
                    <div
                      key={item.version}
                      data-testid={`version-item-${item.version}`}
                      onClick={() => setSelectedHistoryVersion(item.version)}
                      style={{
                        padding: '10px 12px',
                        borderRadius: 6,
                        background: isSelected ? 'var(--surface)' : 'var(--bg)',
                        border: `1px solid ${isSelected ? 'var(--cyan)' : 'var(--border)'}`,
                        cursor: 'pointer',
                        display: 'flex',
                        flexDirection: 'column',
                        gap: 4,
                      }}
                    >
                      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                        <span style={{ fontSize: 12, fontWeight: 700, color: 'var(--text)' }}>
                          {item.version}
                        </span>
                        {isCurrent && (
                          <span style={{ fontSize: 10, padding: '1px 6px', borderRadius: 99, background: 'rgba(16, 185, 129, 0.15)', color: 'var(--teal)', fontWeight: 600 }}>
                            Active
                          </span>
                        )}
                      </div>
                      <div style={{ fontSize: 11, color: 'var(--muted)' }}>
                        {item.description || 'No description'}
                      </div>
                      <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 10, color: 'var(--muted)' }}>
                        <span>by {item.author}</span>
                        <span>{item.rule_count} rules</span>
                      </div>
                      {item.checksum && (
                        <div style={{ fontSize: 9, fontFamily: 'monospace', color: 'var(--muted)', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                          sha256:{item.checksum.slice(0, 12)}...
                        </div>
                      )}
                    </div>
                  )
                })}
              </div>

              {/* Version Diff View */}
              {selectedHistoryVersion && (
                <div
                  data-testid="version-diff-viewer"
                  style={{
                    display: 'flex',
                    flexDirection: 'column',
                    gap: 8,
                    padding: 10,
                    background: 'var(--surface)',
                    borderRadius: 6,
                    border: '1px solid var(--border)',
                    fontSize: 11,
                  }}
                >
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                    <strong style={{ color: 'var(--text)' }}>Diff Comparison</strong>
                    <span style={{ color: 'var(--muted)', fontSize: 10 }}>
                      {selectedHistoryVersion} vs {effectiveBundle.version}
                    </span>
                  </div>

                  <div
                    style={{
                      background: 'var(--bg)',
                      padding: 8,
                      borderRadius: 4,
                      fontFamily: 'monospace',
                      maxHeight: 120,
                      overflowY: 'auto',
                      whiteSpace: 'pre-wrap',
                      color: 'var(--muted)',
                    }}
                  >
                    {selectedHistoryVersion === effectiveBundle.version ? (
                      <span>No differences. Current active version.</span>
                    ) : (
                      <span>
                        - Target Version: {selectedHistoryVersion}{'\n'}
                        + Active Version: {effectiveBundle.version}{'\n'}
                        Rules count: {rules.length}
                      </span>
                    )}
                  </div>

                  {!readOnly && onRollback && selectedHistoryVersion !== effectiveBundle.version && (
                    <button
                      data-testid="rollback-btn"
                      type="button"
                      className="btn btn-secondary"
                      onClick={handleTriggerRollback}
                      style={{
                        fontSize: 11,
                        padding: '6px 10px',
                        color: 'var(--amber)',
                        borderColor: 'var(--amber)',
                        width: '100%',
                      }}
                    >
                      Rollback to {selectedHistoryVersion}
                    </button>
                  )}
                </div>
              )}
            </div>
          )}
        </div>
      )}

      {/* Rollback Confirmation Modal */}
      {rollbackConfirmOpen && (
        <ConfirmDialog
          title="Confirm Policy Rollback"
          body={`Are you sure you want to rollback ${effectiveBundle.framework_id} to version ${selectedHistoryVersion}? This will revert active rules.`}
          confirmLabel={`Rollback to ${selectedHistoryVersion}`}
          onConfirm={handleConfirmRollback}
          onCancel={() => setRollbackConfirmOpen(false)}
        />
      )}
    </div>
  )
}
