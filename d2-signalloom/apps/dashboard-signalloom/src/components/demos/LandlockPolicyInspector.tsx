import React, { useMemo, useState } from 'react'

export interface LandlockPathRule {
  readonly path: string
  readonly ruleType: 'LANDLOCK_RULE_PATH_BENEATH'
  readonly accessAllowed: string
  readonly action: 'DENY' | 'ALLOW'
  readonly category: 'restricted_system' | 'telemetry_spool' | 'binary_runtime'
  readonly securityRationale: string
}

export const DEFAULT_LANDLOCK_RULES: readonly LandlockPathRule[] = [
  {
    path: '/home/*/.ssh',
    ruleType: 'LANDLOCK_RULE_PATH_BENEATH',
    accessAllowed: 'NONE',
    action: 'DENY',
    category: 'restricted_system',
    securityRationale: 'Prevents unauthorized exfiltration or manipulation of SSH keypairs.',
  },
  {
    path: '/etc/shadow',
    ruleType: 'LANDLOCK_RULE_PATH_BENEATH',
    accessAllowed: 'NONE',
    action: 'DENY',
    category: 'restricted_system',
    securityRationale: 'Blocks host password hash extraction and offline dictionary cracking.',
  },
  {
    path: '/proc/kcore',
    ruleType: 'LANDLOCK_RULE_PATH_BENEATH',
    accessAllowed: 'NONE',
    action: 'DENY',
    category: 'restricted_system',
    securityRationale: 'Prevents kernel memory dumping and memory disclosure attacks.',
  },
  {
    path: '/var/run/docker.sock',
    ruleType: 'LANDLOCK_RULE_PATH_BENEATH',
    accessAllowed: 'NONE',
    action: 'DENY',
    category: 'restricted_system',
    securityRationale: 'Prevents container breakout via root-equivalent Docker daemon socket.',
  },
  {
    path: '/tmp/agentmaxxing/telemetry',
    ruleType: 'LANDLOCK_RULE_PATH_BENEATH',
    accessAllowed: 'READ_FILE | WRITE_FILE | CREATE_FILE',
    action: 'ALLOW',
    category: 'telemetry_spool',
    securityRationale: 'Designated non-privileged spool for zero-payload metrics and process stats.',
  },
  {
    path: '/var/log/signal-loom',
    ruleType: 'LANDLOCK_RULE_PATH_BENEATH',
    accessAllowed: 'READ_FILE',
    action: 'ALLOW',
    category: 'binary_runtime',
    securityRationale: 'Read-only access for collecting signed audit log verification receipts.',
  },
] as const

export interface LandlockPolicyInspectorProps {
  readonly rules?: readonly LandlockPathRule[]
  readonly defaultOpen?: boolean
  readonly className?: string
  readonly testId?: string
}

export const LandlockPolicyInspector: React.FC<LandlockPolicyInspectorProps> = ({
  rules = DEFAULT_LANDLOCK_RULES,
  defaultOpen = false,
  className = '',
  testId = 'landlock-policy-inspector',
}) => {
  const [isOpen, setIsOpen] = useState(defaultOpen)
  const [filterText, setFilterText] = useState('')
  const [selectedCategory, setSelectedCategory] = useState<'all' | 'restricted_system' | 'telemetry_spool' | 'binary_runtime'>('all')

  const filteredRules = useMemo(() => {
    return rules.filter((r) => {
      const matchesCategory = selectedCategory === 'all' || r.category === selectedCategory
      const matchesText =
        filterText.trim() === '' ||
        r.path.toLowerCase().includes(filterText.toLowerCase()) ||
        r.securityRationale.toLowerCase().includes(filterText.toLowerCase())
      return matchesCategory && matchesText
    })
  }, [rules, selectedCategory, filterText])

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
      {/* Header with expand/collapse toggle */}
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
              color: 'var(--cyan)',
            }}
          >
            Landlock LSM Path Policy Inspector
          </span>
          <span
            className="tag"
            style={{
              fontSize: 10,
              fontFamily: 'monospace',
              background: 'rgba(6, 182, 212, 0.12)',
              color: 'var(--cyan)',
              border: '1px solid rgba(6, 182, 212, 0.3)',
            }}
          >
            ABI v3 (Linux 6.2+)
          </span>
        </div>

        <button
          type="button"
          data-testid={`${testId}-toggle-btn`}
          onClick={() => setIsOpen((prev) => !prev)}
          className="btn btn-secondary"
          style={{
            fontSize: 11,
            fontFamily: 'monospace',
            padding: '4px 10px',
            cursor: 'pointer',
          }}
        >
          {isOpen ? 'Collapse Policy Rules ▲' : 'Inspect Path Rules (6 Active) ▼'}
        </button>
      </div>

      {isOpen && (
        <div style={{ marginTop: 14, display: 'flex', flexDirection: 'column', gap: 12 }}>
          <p style={{ margin: 0, fontSize: 12, color: 'var(--muted)', lineHeight: 1.5 }}>
            Kernel-enforced process restriction rules applied before agent binary execution.
            All unlisted paths deny access by default under Landlock LSM confinement.
          </p>

          {/* Filter Bar */}
          <div
            style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              gap: 10,
              flexWrap: 'wrap',
              borderBottom: '1px solid var(--border)',
              paddingBottom: 10,
            }}
          >
            <input
              type="text"
              data-testid={`${testId}-filter-input`}
              placeholder="Filter paths or rationale..."
              value={filterText}
              onChange={(e) => setFilterText(e.target.value)}
              style={{
                fontSize: 11,
                fontFamily: 'monospace',
                background: 'var(--bg)',
                border: '1px solid var(--border-subtle)',
                borderRadius: 4,
                color: 'var(--text)',
                padding: '4px 10px',
                minWidth: 220,
              }}
            />

            <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
              {(['all', 'restricted_system', 'telemetry_spool'] as const).map((cat) => (
                <button
                  key={cat}
                  type="button"
                  data-testid={`${testId}-category-${cat}`}
                  onClick={() => setSelectedCategory(cat)}
                  style={{
                    fontSize: 10,
                    fontFamily: 'monospace',
                    padding: '3px 8px',
                    borderRadius: 4,
                    border: selectedCategory === cat ? '1px solid var(--cyan)' : '1px solid var(--border)',
                    background: selectedCategory === cat ? 'var(--surface2)' : 'transparent',
                    color: selectedCategory === cat ? 'var(--cyan)' : 'var(--muted)',
                    cursor: 'pointer',
                  }}
                >
                  {cat === 'all' ? 'All Rules' : cat === 'restricted_system' ? 'Restricted System' : 'Telemetry Spool'}
                </button>
              ))}
            </div>
          </div>

          {/* Rules Table */}
          <div style={{ overflowX: 'auto' }}>
            <table
              data-testid={`${testId}-table`}
              style={{
                width: '100%',
                borderCollapse: 'collapse',
                fontSize: 11,
                fontFamily: 'monospace',
              }}
            >
              <thead>
                <tr style={{ background: 'var(--surface2)', color: 'var(--muted)', textAlign: 'left' }}>
                  <th style={{ padding: '8px 10px', fontWeight: 600 }}>Path Rule</th>
                  <th style={{ padding: '8px 10px', fontWeight: 600 }}>Enforcement</th>
                  <th style={{ padding: '8px 10px', fontWeight: 600 }}>Allowed Access</th>
                  <th style={{ padding: '8px 10px', fontWeight: 600 }}>Security Rationale</th>
                </tr>
              </thead>
              <tbody>
                {filteredRules.map((rule) => {
                  const isDeny = rule.action === 'DENY'
                  return (
                    <tr
                      key={rule.path}
                      data-testid={`landlock-rule-${rule.path.replace(/[^a-zA-Z0-9]/g, '-')}`}
                      style={{ borderBottom: '1px solid var(--border)' }}
                    >
                      <td style={{ padding: '8px 10px', color: 'var(--text)', fontWeight: 600 }}>
                        {rule.path}
                      </td>
                      <td style={{ padding: '8px 10px' }}>
                        <span
                          className="tag"
                          style={{
                            fontSize: 10,
                            background: isDeny ? 'rgba(220, 38, 38, 0.15)' : 'rgba(16, 185, 129, 0.15)',
                            color: isDeny ? 'var(--error)' : 'var(--teal)',
                            border: `1px solid ${isDeny ? 'rgba(220, 38, 38, 0.4)' : 'rgba(16, 185, 129, 0.4)'}`,
                          }}
                        >
                          {rule.action}
                        </span>
                      </td>
                      <td style={{ padding: '8px 10px', color: isDeny ? 'var(--muted)' : 'var(--cyan)' }}>
                        {rule.accessAllowed}
                      </td>
                      <td style={{ padding: '8px 10px', color: 'var(--muted)' }}>
                        {rule.securityRationale}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  )
}

export default LandlockPolicyInspector
