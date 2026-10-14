import type { FC, ReactNode } from 'react'
import type { PolicyRule } from '../types/policies'
import './GovernancePolicyTable.css'

export interface GovernancePolicyTableProps {
  rules: PolicyRule[]
  frameworkId: string
  frameworkActive?: boolean
  disabledPolicyIds?: string[]
  onTogglePolicy?: (ruleId: string) => void
  onEditPolicy?: (frameworkId: string, ruleId: string) => void
  onClickRow?: (frameworkId: string, ruleId: string) => void
  renderToggle?: (rule: PolicyRule, isActive: boolean) => ReactNode
  testId?: string
  className?: string
}

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function isSurrogateUuid(id: string): boolean {
  return UUID_REGEX.test(id)
}

export const GovernancePolicyTable: FC<GovernancePolicyTableProps> = ({
  rules,
  frameworkId,
  frameworkActive = true,
  disabledPolicyIds = [],
  onTogglePolicy,
  onEditPolicy,
  onClickRow,
  renderToggle,
  testId,
  className = '',
}) => {
  if (rules.length === 0) {
    return (
      <div
        data-testid={testId || `framework-children-${frameworkId}`}
        className={`governance-policy-table ${className}`.trim()}
        style={{ padding: '12px 16px', color: 'var(--muted)', fontSize: 12 }}
      >
        No child policies or controls registered for this framework.
      </div>
    )
  }

  return (
    <div
      data-testid={testId || `framework-children-${frameworkId}`}
      className={`governance-policy-table ${className}`.trim()}
    >
      <div className="governance-policy-table__header">
        <div className="governance-policy-table__header-col">Control & Policy</div>
        <div className="governance-policy-table__header-col">Description & Governance Intent</div>
        <div className="governance-policy-table__header-col governance-policy-table__header-col--actions">Status</div>
      </div>

      {rules.map((rule) => {
        const isRuleActive = frameworkActive && !disabledPolicyIds.includes(rule.id)
        const isManual = Boolean(rule.manual_attestation || rule.attestation_type === 'manual' || rule.attestation_type === 'cluster')
        const showIdBadge = !isSurrogateUuid(rule.id)
        const severity = rule.severity?.toLowerCase() || 'high'

        const handleRowClick = () => {
          if (onClickRow) {
            onClickRow(frameworkId, rule.id)
          } else if (onEditPolicy) {
            onEditPolicy(frameworkId, rule.id)
          }
        }

        return (
          <div
            key={rule.id}
            data-testid={`policy-row-${rule.id}`}
            className="governance-policy-table__row"
          >
            <div
              className="governance-policy-table__identity"
              onClick={handleRowClick}
              title="Click to view and edit this policy in the Policy Editor"
            >
              <div className="governance-policy-table__title-line">
                <span className="governance-policy-table__title">
                  {rule.name}
                </span>

                {showIdBadge && (
                  <span className="governance-policy-table__id-badge">
                    {rule.id}
                  </span>
                )}

                {isManual && (
                  <span
                    data-testid={`manual-sign-${rule.id}`}
                    className="governance-policy-table__manual-badge"
                    title={rule.manual_attestation_note || 'Manual Attestation / Non-CEL control'}
                  >
                    📋 Manual Attestation
                  </span>
                )}

                <span
                  className={`governance-policy-table__severity-badge governance-policy-table__severity-badge--${severity}`}
                >
                  {rule.severity || 'high'}
                </span>
              </div>
            </div>

            <div className="governance-policy-table__description-col">
              {rule.description ? (
                <div className="governance-policy-table__description">
                  {rule.description}
                </div>
              ) : (
                <span style={{ color: 'var(--dim)', fontSize: 11, fontStyle: 'italic' }}>
                  No description provided
                </span>
              )}
            </div>

            <div className="governance-policy-table__actions">
              <button
                type="button"
                className="governance-policy-table__edit-btn"
                onClick={(e) => {
                  e.stopPropagation()
                  onEditPolicy?.(frameworkId, rule.id)
                }}
                title="Open rule in CEL editor"
              >
                Edit ↗
              </button>

              {renderToggle ? (
                renderToggle(rule, isRuleActive)
              ) : (
                <button
                  type="button"
                  role="switch"
                  aria-checked={isRuleActive}
                  onClick={(e) => {
                    e.stopPropagation()
                    onTogglePolicy?.(rule.id)
                  }}
                  style={{
                    flexShrink: 0,
                    width: 44,
                    height: 24,
                    borderRadius: 12,
                    padding: 0,
                    border: 'none',
                    cursor: 'pointer',
                    background: isRuleActive ? 'var(--cyan)' : 'var(--slate-gray)',
                    transition: 'background var(--motion-fast)',
                    position: 'relative',
                  }}
                >
                  <span
                    style={{
                      position: 'absolute',
                      top: 3,
                      left: isRuleActive ? 23 : 3,
                      width: 18,
                      height: 18,
                      borderRadius: '50%',
                      background: 'var(--on-accent, #ffffff)',
                      transition: 'left var(--motion-fast)',
                      boxShadow: '0 1px 3px rgba(0,0,0,0.3)',
                    }}
                  />
                </button>
              )}
            </div>
          </div>
        )
      })}
    </div>
  )
}

export default GovernancePolicyTable
