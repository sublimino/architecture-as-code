import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { GovernancePolicyTable, isSurrogateUuid } from './GovernancePolicyTable'
import type { PolicyRule } from '../types/policies'

const MOCK_RULES: PolicyRule[] = [
  {
    id: 'container-run-as-non-root',
    name: 'Art. 9: Workload container execution as non-root',
    description: 'Ensures high-risk AI workloads do not execute with root UID privileges.',
    cel_expression: 'object.spec.containers.all(c, c.securityContext.runAsNonRoot == true)',
    severity: 'high',
    remediation: 'Configure securityContext.runAsNonRoot to true in workload spec.',
    attestation_type: 'cel',
    manual_attestation: false,
  },
  {
    id: 'c0000000-0000-0000-0000-000000000010',
    name: 'CIS 5.1.6 Ensure that the ServiceAccount Tokens are Only Mounted Where Necessary',
    description: 'ServiceAccount tokens should only be mounted where necessary to reduce lateral movement risk.',
    cel_expression: 'object.spec.automountServiceAccountToken == false',
    severity: 'critical',
    remediation: 'Set automountServiceAccountToken to false.',
    attestation_type: 'cel',
    manual_attestation: false,
  },
  {
    id: 'manual-audit-attestation',
    name: 'Art. 11: Technical Documentation Dossier',
    description: 'Manual architectural documentation attestation signed by compliance officer.',
    cel_expression: 'true',
    severity: 'medium',
    remediation: 'Attach signed annex IV dossier.',
    attestation_type: 'manual',
    manual_attestation: true,
    manual_attestation_note: 'Signed by compliance officer',
  },
]

describe('isSurrogateUuid helper', () => {
  it('correctly detects 36-char surrogate UUIDs', () => {
    expect(isSurrogateUuid('c0000000-0000-0000-0000-000000000010')).toBe(true)
    expect(isSurrogateUuid('123e4567-e89b-12d3-a456-426614174000')).toBe(true)
    expect(isSurrogateUuid('container-run-as-non-root')).toBe(false)
    expect(isSurrogateUuid('CIS-5.1.6')).toBe(false)
  })
})

describe('GovernancePolicyTable component', () => {
  it('renders header and all rules with proper testids', () => {
    render(
      <GovernancePolicyTable
        rules={MOCK_RULES}
        frameworkId="eu-ai-act"
      />,
    )

    expect(screen.getByText('Control & Policy')).toBeInTheDocument()
    expect(screen.getByText('Description & Governance Intent')).toBeInTheDocument()
    expect(screen.getByText('Status')).toBeInTheDocument()

    expect(screen.getByTestId('policy-row-container-run-as-non-root')).toBeInTheDocument()
    expect(screen.getByTestId('policy-row-c0000000-0000-0000-0000-000000000010')).toBeInTheDocument()
    expect(screen.getByTestId('policy-row-manual-audit-attestation')).toBeInTheDocument()
  })

  it('sanitizes surrogate UUIDs and does not display raw UUID in title', () => {
    render(
      <GovernancePolicyTable
        rules={MOCK_RULES}
        frameworkId="k8s-cis"
      />,
    )

    // Meaningful human ID badge is shown for container-run-as-non-root
    expect(screen.getByText('container-run-as-non-root')).toBeInTheDocument()

    // Surrogate UUID is NOT displayed as a badge or string in the DOM
    expect(screen.queryByText('c0000000-0000-0000-0000-000000000010')).toBeNull()
    expect(screen.queryByText('(c0000000-0000-0000-0000-000000000010)')).toBeNull()

    // But rule title is visible
    expect(screen.getByText(/Ensure that the ServiceAccount Tokens are Only Mounted Where Necessary/i)).toBeInTheDocument()
  })

  it('renders manual attestation badge and severity badges with proper styling', () => {
    render(
      <GovernancePolicyTable
        rules={MOCK_RULES}
        frameworkId="eu-ai-act"
      />,
    )

    const manualBadge = screen.getByTestId('manual-sign-manual-audit-attestation')
    expect(manualBadge).toBeInTheDocument()
    expect(manualBadge).toHaveTextContent(/Manual Attestation/i)

    expect(screen.getByText('critical')).toBeInTheDocument()
    expect(screen.getByText('high')).toBeInTheDocument()
    expect(screen.getByText('medium')).toBeInTheDocument()
  })

  it('handles row click and edit button clicks', async () => {
    const onEditPolicy = vi.fn()
    const onTogglePolicy = vi.fn()

    render(
      <GovernancePolicyTable
        rules={MOCK_RULES}
        frameworkId="eu-ai-act"
        onEditPolicy={onEditPolicy}
        onTogglePolicy={onTogglePolicy}
      />,
    )

    const row = screen.getByTestId('policy-row-container-run-as-non-root')
    const identityArea = row.querySelector('.governance-policy-table__identity')
    expect(identityArea).not.toBeNull()

    await userEvent.click(identityArea!)
    expect(onEditPolicy).toHaveBeenCalledWith('eu-ai-act', 'container-run-as-non-root')

    const editBtn = row.querySelector('.governance-policy-table__edit-btn')
    expect(editBtn).not.toBeNull()
    await userEvent.click(editBtn!)
    expect(onEditPolicy).toHaveBeenCalledTimes(2)

    const switchBtn = row.querySelector('button[role="switch"]')
    expect(switchBtn).not.toBeNull()
    await userEvent.click(switchBtn!)
    expect(onTogglePolicy).toHaveBeenCalledWith('container-run-as-non-root')
  })

  it('renders empty state when rules array is empty', () => {
    render(
      <GovernancePolicyTable
        rules={[]}
        frameworkId="empty-fw"
      />,
    )

    expect(screen.getByText(/No child policies or controls registered/i)).toBeInTheDocument()
  })
})
