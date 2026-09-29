import React, { useState, useEffect, useMemo, useRef, useCallback } from 'react'
import { parse } from '@marcbachmann/cel-js'
import type { PolicyBundle, PolicyRule, VersionHistoryItem } from '../types/policies'
import ConfirmDialog from './ConfirmDialog'

export interface PolicyEditorProps {
  bundle: PolicyBundle
  versionHistory?: VersionHistoryItem[]
  onSave?: (updatedBundle: PolicyBundle) => Promise<void>
  onRollback?: (frameworkId: string, targetVersion: string) => Promise<void>
  readOnly?: boolean
  availableFrameworks?: Array<{ id: string; name: string }>
  onSelectFramework?: (frameworkId: string) => void
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
        } else if (celVariables.has(ident)) {
          tokens.push({ text: ident, type: 'variable' })
        } else if (celMacros.has(ident)) {
          tokens.push({ text: ident, type: 'macro' })
        } else {
          tokens.push({ text: ident, type: 'identifier' })
        }
        continue
      }

      // Operators and Punctuation
      if (/[:?&|=!<>+\-*/%~^]/.test(ch)) {
        let op = ch
        i++
        while (i < line.length && /[:?&|=!<>+\-*/%~^]/.test(line[i])) {
          op += line[i]
          i++
        }
        tokens.push({ text: op, type: 'operator' })
        continue
      }

      if (/[()\[\]{},;.]/.test(ch)) {
        tokens.push({ text: ch, type: 'punctuation' })
        i++
        continue
      }

      tokens.push({ text: ch, type: 'identifier' })
      i++
    }
    return tokens
  })
}

export function validateCelExpression(expression: string): CelDiagnostic {
  const trimmed = expression.trim()
  if (!trimmed) {
    return { valid: true }
  }
  try {
    parse(trimmed)
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
}: PolicyEditorProps) {
  const [selectedRuleIndex, setSelectedRuleIndex] = useState(0)
  const [rules, setRules] = useState<PolicyRule[]>(bundle.rules || [])
  const [historyOpen, setHistoryOpen] = useState(false)
  const [selectedHistoryVersion, setSelectedHistoryVersion] = useState<string | null>(null)
  const [rollbackConfirmOpen, setRollbackConfirmOpen] = useState(false)
  const [saving, setSaving] = useState(false)
  const [saveSuccess, setSaveSuccess] = useState(false)
  const [saveError, setSaveError] = useState<string | null>(null)
  const [rollbackError, setRollbackError] = useState<string | null>(null)
  const [diagnosticTooltipOpen, setDiagnosticTooltipOpen] = useState(false)

  const textareaRef = useRef<HTMLTextAreaElement>(null)

  useEffect(() => {
    setRules(bundle.rules || [])
    setSelectedRuleIndex(0)
  }, [bundle])

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

  const handleSave = async () => {
    if (readOnly || !onSave) return
    if (!diagnostic.valid) {
      setSaveError(`Cannot save invalid CEL syntax: ${diagnostic.message}`)
      return
    }

    setSaving(true)
    setSaveError(null)
    try {
      // Monotonically bump patch version (e.g. v2.1.0 -> v2.1.1)
      const verParts = bundle.version.replace(/^v/, '').split('.').map(Number)
      while (verParts.length < 3) verParts.push(0)
      verParts[2] = (verParts[2] || 0) + 1
      const nextVersion = `v${verParts.join('.')}`

      const updatedBundle: PolicyBundle = {
        ...bundle,
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
      await onRollback(bundle.framework_id, selectedHistoryVersion)
      setHistoryOpen(false)
    } catch (err: unknown) {
      setRollbackError(err instanceof Error ? err.message : 'Rollback failed')
    }
  }

  // Token color styling mapping
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
      {/* Top Header Bar */}
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
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          {availableFrameworks.length > 0 && onSelectFramework ? (
            <select
              data-testid="framework-selector"
              value={bundle.framework_id}
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
              {bundle.framework_id.toUpperCase()}
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
            {bundle.version}
          </span>

          {bundle.status === 'placeholder' && (
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
              disabled={saving || !diagnostic.valid}
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

      {/* Main Workspace Layout */}
      <div style={{ display: 'grid', gridTemplateColumns: historyOpen ? '1fr 340px' : '1fr', gap: 16 }}>
        {/* Editor Main Column */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          {/* Rules Tabs */}
          <div
            style={{
              display: 'flex',
              gap: 6,
              overflowX: 'auto',
              paddingBottom: 4,
              borderBottom: '1px solid var(--border)',
            }}
          >
            {rules.map((rule, idx) => {
              const isSelected = idx === selectedRuleIndex
              const ruleDiag = validateCelExpression(rule.cel_expression || '')
              return (
                <button
                  key={rule.id}
                  data-testid={`rule-tab-${rule.id}`}
                  type="button"
                  onClick={() => setSelectedRuleIndex(idx)}
                  style={{
                    padding: '6px 12px',
                    borderRadius: '6px 6px 0 0',
                    border: '1px solid',
                    borderColor: isSelected ? 'var(--cyan)' : 'transparent',
                    borderBottom: isSelected ? '2px solid var(--cyan)' : 'none',
                    background: isSelected ? 'var(--bg)' : 'transparent',
                    color: isSelected ? 'var(--text)' : 'var(--muted)',
                    fontSize: 12,
                    fontWeight: isSelected ? 600 : 400,
                    cursor: 'pointer',
                    display: 'flex',
                    alignItems: 'center',
                    gap: 6,
                    whiteSpace: 'nowrap',
                  }}
                >
                  <span>{rule.id}</span>
                  {!ruleDiag.valid && (
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

          {/* Rule Metadata Header */}
          <div
            style={{
              display: 'flex',
              flexDirection: 'column',
              gap: 4,
              padding: '10px 14px',
              background: 'var(--bg)',
              borderRadius: 6,
              border: '1px solid var(--border)',
            }}
          >
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)' }}>
                {currentRule.name}
              </span>
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
            {currentRule.description && (
              <p style={{ fontSize: 11, color: 'var(--muted)', margin: 0 }}>
                {currentRule.description}
              </p>
            )}
            {currentRule.remediation && (
              <p style={{ fontSize: 11, color: 'var(--muted)', margin: 0 }}>
                <strong style={{ color: 'var(--text)' }}>Remediation:</strong> {currentRule.remediation}
              </p>
            )}
          </div>

          {/* CEL Code Editor Area */}
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
            {/* Editor Focus Accessibility Help */}
            <div
              style={{
                position: 'absolute',
                top: 6,
                right: 10,
                fontSize: 10,
                color: 'var(--muted)',
                zIndex: 10,
                pointerEvents: 'none',
              }}
            >
              Press Esc to exit editor focus
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
                    whiteSpace: 'pre',
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
                    whiteSpace: 'pre',
                    fontFamily: 'monospace',
                    fontSize: 13,
                    lineHeight: '20px',
                    pointerEvents: 'none',
                  }}
                >
                  {tokenizedLines.map((lineTokens, lineIdx) => {
                    const isErrorLine = !diagnostic.valid && (diagnostic.line === lineIdx + 1 || (tokenizedLines.length === 1 && lineIdx === 0))
                    return (
                      <div key={lineIdx} style={{ height: 20 }}>
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
                  <span style={{ width: 8, height: 8, borderRadius: '50%', background: 'var(--teal)' }} />
                  <span>Valid CEL syntax</span>
                </div>
              ) : (
                <div
                  data-testid="cel-diagnostic-error"
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 8,
                    color: 'var(--error)',
                    fontWeight: 500,
                  }}
                >
                  <span style={{ width: 8, height: 8, borderRadius: '50%', background: 'var(--error)' }} />
                  <span>{diagnostic.message} (line {diagnostic.line}, col {diagnostic.column})</span>
                  <button
                    type="button"
                    onClick={() => setDiagnosticTooltipOpen(!diagnosticTooltipOpen)}
                    style={{
                      background: 'none',
                      border: '1px solid var(--error)',
                      color: 'var(--error)',
                      borderRadius: 4,
                      fontSize: 10,
                      padding: '1px 6px',
                      cursor: 'pointer',
                    }}
                  >
                    Details
                  </button>
                </div>
              )}

              <span style={{ fontSize: 11, color: 'var(--muted)' }}>
                Evaluator: Go Policy Engine (Authoritative)
              </span>
            </div>

            {/* Diagnostic Details Popover Tooltip */}
            {!diagnostic.valid && diagnosticTooltipOpen && diagnostic.snippet && (
              <div
                data-testid="cel-diagnostic-tooltip"
                style={{
                  padding: 10,
                  background: 'var(--surface2)',
                  borderTop: '1px solid var(--error)',
                  color: 'var(--text)',
                  fontSize: 11,
                  fontFamily: 'monospace',
                  whiteSpace: 'pre-wrap',
                }}
              >
                {diagnostic.snippet}
              </div>
            )}
          </div>
        </div>

        {/* Version History Drawer / Column */}
        {historyOpen && (
          <div
            data-testid="version-history-drawer"
            style={{
              display: 'flex',
              flexDirection: 'column',
              gap: 12,
              background: 'var(--bg)',
              border: '1px solid var(--border)',
              borderRadius: 6,
              padding: 12,
            }}
          >
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
              <span style={{ fontSize: 13, fontWeight: 700, color: 'var(--text)' }}>
                Monotonic Versions
              </span>
              <button
                type="button"
                className="btn btn-secondary"
                onClick={() => setHistoryOpen(false)}
                style={{ fontSize: 11, padding: '2px 6px' }}
              >
                Close
              </button>
            </div>

            {rollbackError && (
              <div
                data-testid="rollback-error"
                style={{
                  padding: '6px 8px',
                  borderRadius: 4,
                  background: 'rgba(220, 38, 38, 0.15)',
                  color: 'var(--error)',
                  fontSize: 11,
                }}
              >
                {rollbackError}
              </div>
            )}

            <div
              data-testid="version-history-list"
              style={{ display: 'flex', flexDirection: 'column', gap: 6, maxHeight: 300, overflowY: 'auto' }}
            >
              {versionHistory.map((item) => {
                const isSelected = selectedHistoryVersion === item.version
                const isCurrent = item.version === bundle.version
                return (
                  <div
                    key={item.version}
                    data-testid={`version-item-${item.version}`}
                    onClick={() => setSelectedHistoryVersion(item.version)}
                    style={{
                      padding: 8,
                      borderRadius: 6,
                      background: isSelected ? 'var(--surface2)' : 'var(--surface)',
                      border: `1px solid ${isSelected ? 'var(--cyan)' : 'var(--border)'}`,
                      cursor: 'pointer',
                      display: 'flex',
                      flexDirection: 'column',
                      gap: 4,
                    }}
                  >
                    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                      <span style={{ fontSize: 12, fontWeight: 700, color: 'var(--text)' }}>
                        {item.version}
                      </span>
                      {isCurrent && (
                        <span
                          style={{
                            fontSize: 9,
                            fontWeight: 700,
                            padding: '1px 5px',
                            borderRadius: 4,
                            background: 'rgba(16, 185, 129, 0.15)',
                            color: 'var(--teal)',
                          }}
                        >
                          ACTIVE
                        </span>
                      )}
                    </div>
                    <div style={{ fontSize: 10, color: 'var(--muted)' }}>
                      Author: {item.author || 'system'}
                    </div>
                    <div style={{ fontSize: 10, color: 'var(--muted)' }}>
                      {new Date(item.created_at).toLocaleString('en-GB')}
                    </div>
                    {item.checksum && (
                      <div
                        style={{
                          fontSize: 9,
                          fontFamily: 'monospace',
                          color: 'var(--muted)',
                          overflow: 'hidden',
                          textOverflow: 'ellipsis',
                        }}
                      >
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
                    {selectedHistoryVersion} vs {bundle.version}
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
                  {selectedHistoryVersion === bundle.version ? (
                    <span>No differences. Current active version.</span>
                  ) : (
                    <span>
                      - Target Version: {selectedHistoryVersion}{'\n'}
                      + Active Version: {bundle.version}{'\n'}
                      Rules count: {rules.length}
                    </span>
                  )}
                </div>

                {!readOnly && onRollback && selectedHistoryVersion !== bundle.version && (
                  <button
                    data-testid="rollback-btn"
                    type="button"
                    className="btn btn-secondary"
                    onClick={handleTriggerRollback}
                    style={{
                      marginTop: 4,
                      fontSize: 11,
                      padding: '4px 8px',
                      color: 'var(--amber)',
                      borderColor: 'var(--amber)',
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

      {/* Rollback Confirmation Modal */}
      {rollbackConfirmOpen && selectedHistoryVersion && (
        <ConfirmDialog
          title="Confirm Policy Rollback"
          body={`Are you sure you want to rollback ${bundle.framework_id.toUpperCase()} policy rules to version ${selectedHistoryVersion}? Active evaluation will immediately adopt the target version.`}
          confirmLabel={`Rollback to ${selectedHistoryVersion}`}
          onConfirm={handleConfirmRollback}
          onCancel={() => setRollbackConfirmOpen(false)}
        />
      )}
    </div>
  )
}
