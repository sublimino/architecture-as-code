import React from 'react'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, waitFor, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import CompliancePolicyPage from './CompliancePolicyPage'
import {
  normalizeFrameworkId,
  getBundleForFramework,
  getCanonicalFrameworkOptions,
  harmonizeBundleRules,
  CANONICAL_BUNDLES,
  FRAMEWORK_ALIASES,
} from '../data/regulatoryFrameworks'
import type { PolicyRule } from '../types/policies'

vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({
    getAccessTokenSilently: vi.fn().mockResolvedValue('mock-token'),
    isAuthenticated: true,
  }),
}))

vi.mock('../api/client', () => ({
  api: {
    compliancePolicy: {
      frameworks: vi.fn().mockResolvedValue([
        {
          id: 'k8s-cis-benchmark',
          name: 'CIS Kubernetes Benchmark',
          versions: ['v1.8.0'],
          totalControls: 17,
          passedControls: 15,
          exposure: 12000,
        },
        {
          id: 'eu-ai-act',
          name: 'EU AI Act',
          versions: ['v2.1.0'],
          totalControls: 10,
          passedControls: 8,
          exposure: 25000,
        },
        {
          id: 'nist-800-53',
          name: 'NIST SP 800-53',
          versions: ['Rev. 5'],
          totalControls: 9,
          passedControls: 9,
          exposure: 0,
        },
        {
          id: 'finos-aigf',
          name: 'FINOS AI Governance Framework',
          versions: ['v1.0.0'],
          totalControls: 9,
          passedControls: 7,
          exposure: 8000,
        },
      ]),
      summary: vi.fn().mockResolvedValue({
        scanTimestamp: new Date().toISOString(),
        totalChecks: 45,
        passed: 39,
        failed: 6,
        carried: 45000,
        currency: 'EUR',
      }),
      scan: vi.fn().mockResolvedValue({
        summary: {
          scanTimestamp: new Date().toISOString(),
          totalChecks: 45,
          passed: 40,
          failed: 5,
          carried: 35000,
        },
      }),
    },
    policies: {
      list: vi.fn().mockResolvedValue([
        {
          framework_id: 'cis-kubernetes',
          active_bundle: {
            id: 'cis-kubernetes-v1.8.0',
            framework_id: 'cis-kubernetes',
            version: 'v1.8.0',
            author: 'policy-engine',
            description: 'CIS Kubernetes Benchmark evaluated by CEL engine',
            created_at: new Date().toISOString(),
            checksum: 'abc123hash',
            rules: [
              {
                id: 'sa-token-automount-disabled',
                name: 'Service account token auto-mount disabled',
                description: 'The pod sets automountServiceAccountToken: false',
                cel_expression: 'object.spec.automountServiceAccountToken == false',
                severity: 'high',
                remediation: 'Set automountServiceAccountToken: false in pod spec',
                status: 'enforcing',
              },
              {
                id: 'no-privileged-containers',
                name: 'Minimize the admission of privileged containers',
                description: 'Privileged containers are disabled',
                cel_expression: 'object.spec.containers.all(c, c.securityContext.privileged == false)',
                severity: 'critical',
                remediation: 'Set privileged to false',
                status: 'enforcing',
              },
            ],
          },
          version_history: [],
        },
        {
          framework_id: 'eu-ai-act',
          active_bundle: {
            id: 'eu-ai-act-v2.1.0',
            framework_id: 'eu-ai-act',
            version: 'v2.1.0',
            author: 'policy-engine',
            description: 'EU AI Act bundle',
            created_at: new Date().toISOString(),
            checksum: 'def456hash',
            rules: [
              {
                id: 'container-run-as-non-root',
                name: 'Art. 9: Workload container execution as non-root',
                description: 'Ensures high-risk AI workloads do not execute with root UID privileges.',
                cel_expression: 'object.spec.containers.all(c, c.securityContext.runAsNonRoot == true)',
                severity: 'high',
                status: 'enforcing',
              },
            ],
          },
          version_history: [],
        },
      ]),
      registerBundle: vi.fn().mockResolvedValue({ status: 'ok' }),
      rollback: vi.fn().mockResolvedValue({ status: 'ok' }),
    },
    settings: vi.fn().mockResolvedValue({
      selected_frameworks: ['k8s-cis-benchmark', 'eu-ai-act', 'nist-800-53', 'finos-aigf'],
    }),
  },
}))

describe('Policy Compliance Normalization, Harmonization, and Deep Linking', () => {
  describe('Framework Normalization & Bundles', () => {
    it('normalizes CIS aliases and database UUIDs to k8s-cis-benchmark', () => {
      expect(normalizeFrameworkId('cis-kubernetes')).toBe('k8s-cis-benchmark')
      expect(normalizeFrameworkId('k8s-cis')).toBe('k8s-cis-benchmark')
      expect(normalizeFrameworkId('cis')).toBe('k8s-cis-benchmark')
      expect(normalizeFrameworkId('k8s-cis-benchmark')).toBe('k8s-cis-benchmark')
      expect(normalizeFrameworkId('f0000000-0000-0000-0000-000000000003')).toBe('k8s-cis-benchmark')
      expect(normalizeFrameworkId(null, 'CIS Kubernetes Benchmark')).toBe('k8s-cis-benchmark')
    })

    it('normalizes NIST aliases to canonical nist-800-53', () => {
      expect(normalizeFrameworkId('nist')).toBe('nist-800-53')
      expect(normalizeFrameworkId('nist-800-53')).toBe('nist-800-53')
      expect(normalizeFrameworkId('nist-sp-800-53')).toBe('nist-800-53')
      expect(normalizeFrameworkId(null, 'NIST SP 800-53')).toBe('nist-800-53')
    })

    it('normalizes FINOS aliases and database UUID to canonical finos-aigf', () => {
      expect(normalizeFrameworkId('finos')).toBe('finos-aigf')
      expect(normalizeFrameworkId('finos-aigf')).toBe('finos-aigf')
      expect(normalizeFrameworkId('finos-ai-governance-framework')).toBe('finos-aigf')
      expect(normalizeFrameworkId('f0000000-0000-0000-0000-000000000004')).toBe('finos-aigf')
      expect(normalizeFrameworkId(null, 'FINOS AI Governance Framework')).toBe('finos-aigf')
    })

    it('returns canonical framework options matching available bundle IDs', () => {
      const options = getCanonicalFrameworkOptions()
      const ids = options.map((o) => o.id)
      expect(ids).toContain('k8s-cis-benchmark')
      expect(ids).toContain('eu-ai-act')
      expect(ids).toContain('nist-800-53')
      expect(ids).toContain('finos-aigf')
      expect(ids).toContain('cra')

      // Verify each option resolves to a valid bundle
      for (const id of ids) {
        const bundle = getBundleForFramework(id)
        expect(bundle).not.toBeNull()
        expect(bundle?.rules.length).toBeGreaterThan(0)
      }
    })

    it('resolves bundles via aliases and database UUIDs', () => {
      expect(getBundleForFramework('cis-kubernetes')?.framework_id).toBe('k8s-cis-benchmark')
      expect(getBundleForFramework('nist-sp-800-53')?.framework_id).toBe('nist-800-53')
      expect(getBundleForFramework('finos-ai-governance-framework')?.framework_id).toBe('finos-aigf')
      expect(getBundleForFramework('f0000000-0000-0000-0000-000000000003')?.framework_id).toBe('k8s-cis-benchmark')
    })
  })

  describe('harmonizeBundleRules Engine', () => {
    it('preserves non-CEL / manual attestation rules from template while including active engine rules', () => {
      const template = getBundleForFramework('k8s-cis-benchmark')!
      expect(template.rules.some((r) => r.id === 'cis-5.4.1')).toBe(true)

      const activeRules: PolicyRule[] = [
        {
          id: 'sa-token-automount-disabled',
          name: 'Service account token auto-mount disabled',
          cel_expression: 'object.spec.automountServiceAccountToken == false',
          severity: 'high',
        },
        {
          id: 'no-privileged-containers',
          name: 'Minimize the admission of privileged containers',
          cel_expression: 'object.spec.containers.all(c, c.securityContext.privileged == false)',
          severity: 'critical',
        },
      ]

      const harmonized = harmonizeBundleRules(template.rules, activeRules)

      // Active rules must be present
      expect(harmonized.some((r) => r.id === 'sa-token-automount-disabled')).toBe(true)
      expect(harmonized.some((r) => r.id === 'no-privileged-containers')).toBe(true)

      // Crucial: cis-5.4.1 (ResourceQuotas manual/cluster attestation) MUST be preserved!
      const cis541 = harmonized.find((r) => r.id === 'cis-5.4.1')
      expect(cis541).toBeDefined()
      expect(cis541?.name).toContain('ResourceQuotas')
      expect(cis541?.attestation_type).toBe('cluster')
      expect(cis541?.manual_attestation).toBe(true)
    })

    it('updates CEL expressions and statuses from active rules when IDs match', () => {
      const templateRules: PolicyRule[] = [
        {
          id: 'sa-token-automount-disabled',
          name: 'SA Token Automount',
          cel_expression: 'old_cel()',
          severity: 'low',
        },
      ]
      const activeRules: PolicyRule[] = [
        {
          id: 'sa-token-automount-disabled',
          name: 'SA Token Automount',
          cel_expression: 'object.spec.automountServiceAccountToken == false',
          severity: 'high',
          status: 'enforcing',
        },
      ]

      const harmonized = harmonizeBundleRules(templateRules, activeRules)
      expect(harmonized.length).toBe(1)
      expect(harmonized[0].cel_expression).toBe('object.spec.automountServiceAccountToken == false')
      expect(harmonized[0].severity).toBe('high')
      expect(harmonized[0].status).toBe('enforcing')
    })
  })

  describe('Deep Linking & Dropdown User Journeys in CompliancePolicyPage', () => {
    it('stably selects cis-5.4.1 on deep link without flashing or resetting to sa-token-automount-disabled', async () => {
      render(
        <MemoryRouter initialEntries={['/policies?framework=k8s-cis-benchmark&rule=cis-5.4.1']}>
          <Routes>
            <Route path="/policies" element={<CompliancePolicyPage />} />
          </Routes>
        </MemoryRouter>,
      )

      expect(await screen.findByTestId('policy-editor-container')).toBeInTheDocument()

      // Verify framework selector is set to canonical k8s-cis-benchmark
      const selector = screen.getByTestId('framework-selector') as HTMLSelectElement
      expect(selector.value).toBe('k8s-cis-benchmark')

      // Wait for async load to finish and verify cis-5.4.1 remains selected
      await waitFor(() => {
        expect(screen.getByText(/CIS 5.4.1: Ensure ResourceQuotas are defined for agent namespaces/i)).toBeInTheDocument()
      })

      // Ensure the rule list displays cis-5.4.1 as the active rule
      const activeRuleName = screen.getByText(/CIS 5.4.1: Ensure ResourceQuotas are defined for agent namespaces/i)
      expect(activeRuleName).toBeInTheDocument()

      // Ensure the active rule in the editor is cis-5.4.1
      const selectedRuleName = screen.getByTestId('selected-rule-name')
      expect(selectedRuleName.textContent).toContain('CIS 5.4.1')
      expect(selectedRuleName.textContent).not.toContain('sa-token-automount-disabled')
    })

    it('allows changing framework dropdown to other frameworks cleanly', async () => {
      const user = userEvent.setup()
      render(
        <MemoryRouter initialEntries={['/policies?framework=k8s-cis-benchmark']}>
          <Routes>
            <Route path="/policies" element={<CompliancePolicyPage />} />
          </Routes>
        </MemoryRouter>,
      )

      expect(await screen.findByTestId('policy-editor-container')).toBeInTheDocument()
      const selector = screen.getByTestId('framework-selector') as HTMLSelectElement
      expect(selector.value).toBe('k8s-cis-benchmark')

      // Switch to EU AI Act
      await user.selectOptions(selector, 'eu-ai-act')
      await waitFor(() => {
        const updatedSelector = screen.getByTestId('framework-selector') as HTMLSelectElement
        expect(updatedSelector.value).toBe('eu-ai-act')
      })

      // Switch to FINOS
      await user.selectOptions(selector, 'finos-aigf')
      await waitFor(() => {
        const updatedSelector = screen.getByTestId('framework-selector') as HTMLSelectElement
        expect(updatedSelector.value).toBe('finos-aigf')
      })

      // Switch to NIST SP 800-53
      await user.selectOptions(selector, 'nist-800-53')
      await waitFor(() => {
        const updatedSelector = screen.getByTestId('framework-selector') as HTMLSelectElement
        expect(updatedSelector.value).toBe('nist-800-53')
      })
    })

    it('clears rule query param when switching framework', async () => {
      const user = userEvent.setup()
      render(
        <MemoryRouter initialEntries={['/policies?framework=k8s-cis-benchmark&rule=cis-5.4.1']}>
          <Routes>
            <Route path="/policies" element={<CompliancePolicyPage />} />
          </Routes>
        </MemoryRouter>,
      )

      expect(await screen.findByTestId('policy-editor-container')).toBeInTheDocument()
      const selector = screen.getByTestId('framework-selector') as HTMLSelectElement

      // Switch framework to eu-ai-act
      await user.selectOptions(selector, 'eu-ai-act')
      await waitFor(() => {
        expect(selector.value).toBe('eu-ai-act')
      })

      // Active rule should now be the first rule of eu-ai-act (container-run-as-non-root)
      await waitFor(() => {
        expect(screen.getByText(/Art\. 9: Workload container execution as non-root/i)).toBeInTheDocument()
      })
    })
  })
})

describe('Writes carry only the engine bundle (engine is the authority)', () => {
  // Engine rules as policy-engine serves cis-kubernetes/v1.8: unprefixed names and
  // fields (risk_triple) that the dashboard type does not declare.
  const engineRules = [
    {
      id: 'no-root-containers',
      name: 'Containers do not run as root',
      cel_expression: 'object.spec.containers.all(c, c.securityContext.runAsNonRoot == true)',
      severity: 'high',
      risk_triple: { min: 1, mode: 2, max: 3 },
    },
    {
      id: 'no-privilege-escalation',
      name: 'Privilege escalation disallowed',
      cel_expression: 'object.spec.containers.all(c, c.securityContext.allowPrivilegeEscalation == false)',
      severity: 'high',
    },
    {
      // Matches catalogue cis-5.4.1 one-to-one, so the display gains its description and docs_url.
      id: 'resource-quotas',
      name: 'CIS 5.4.1 ResourceQuotas present',
      cel_expression: 'has(object.spec.hard)',
      severity: 'medium',
    },
  ]
  const summaryFor = (frameworkId: string, history: string[]) => ({
    framework_id: frameworkId,
    active_version: 'v1.8',
    latest_version: 'v1.8',
    active_bundle: {
      id: `${frameworkId}-v1.8`,
      framework_id: frameworkId,
      version: 'v1.8',
      author: 'system',
      description: 'Built-in regulatory framework bundle',
      created_at: '2026-10-01T00:00:00Z',
      checksum: 'abc',
      rules: engineRules,
    },
    version_history: history.map((v) => ({
      version: v,
      author: 'system',
      description: `bundle ${v}`,
      created_at: '2026-10-01T00:00:00Z',
      rule_count: 2,
      checksum: v,
    })),
  })

  let originalList: unknown
  beforeEach(async () => {
    const { api } = await import('../api/client')
    originalList = vi.mocked(api.policies.list).getMockImplementation()
    vi.mocked(api.policies.registerBundle).mockClear()
    vi.mocked(api.policies.rollback).mockClear()
  })
  afterEach(async () => {
    const { api } = await import('../api/client')
    vi.mocked(api.policies.list).mockImplementation(originalList as never)
  })

  const renderCis = () =>
    render(
      <MemoryRouter initialEntries={['/policies?framework=k8s-cis-benchmark']}>
        <Routes>
          <Route path="/policies" element={<CompliancePolicyPage />} />
        </Routes>
      </MemoryRouter>,
    )

  it('save sends the engine rules only, with the edited CEL, under the engine framework id', async () => {
    const { api } = await import('../api/client')
    vi.mocked(api.policies.list).mockResolvedValue([summaryFor('cis-kubernetes', ['v1.8'])] as never)
    const user = userEvent.setup()
    renderCis()

    await screen.findByTestId('rule-tab-no-root-containers')
    // Catalogue rules stay visible, marked as reference material.
    expect(screen.getByTestId('rule-catalogue-only-cis-5.2.6')).toBeInTheDocument()

    const edited = 'object.spec.containers.all(c, c.securityContext.runAsUser != 0)'
    fireEvent.change(screen.getByTestId('cel-code-textarea'), { target: { value: edited } })
    await user.click(screen.getByTestId('save-policy-btn'))

    await waitFor(() => expect(api.policies.registerBundle).toHaveBeenCalledTimes(1))
    const payload = vi.mocked(api.policies.registerBundle).mock.calls[0][1]
    expect(payload.framework_id).toBe('cis-kubernetes')
    expect(payload.version).toBe('v1.8.1')
    // Exactly the engine's rules: no catalogue rules, no catalogue text written back.
    expect(payload.rules).toEqual([{ ...engineRules[0], cel_expression: edited }, engineRules[1], engineRules[2]])
  })

  it.each([
    ['cis-kubernetes first', ['cis-kubernetes', 'k8s-cis-benchmark']],
    ['k8s-cis-benchmark first', ['k8s-cis-benchmark', 'cis-kubernetes']],
  ])('selects the same engine summary for an alias pair regardless of list order (%s)', async (_label, order) => {
    const { api } = await import('../api/client')
    const histories: Record<string, string[]> = {
      'cis-kubernetes': ['v1.8'],
      'k8s-cis-benchmark': ['v1.7', 'v1.8'],
    }
    vi.mocked(api.policies.list).mockResolvedValue(order.map((id) => summaryFor(id, histories[id])) as never)
    const user = userEvent.setup()
    renderCis()

    await screen.findByTestId('rule-tab-no-root-containers')
    await user.click(screen.getByTestId('toggle-version-history-btn'))
    expect(screen.getByTestId('version-item-v1.7')).toBeInTheDocument()
  })

  it('rollback targets the framework id whose history is displayed', async () => {
    const { api } = await import('../api/client')
    vi.mocked(api.policies.list).mockResolvedValue([summaryFor('cis-kubernetes', ['v1.7', 'v1.8'])] as never)
    const user = userEvent.setup()
    renderCis()

    await screen.findByTestId('rule-tab-no-root-containers')
    await user.click(screen.getByTestId('toggle-version-history-btn'))
    await user.click(screen.getByTestId('version-item-v1.7'))
    await user.click(screen.getByTestId('rollback-btn'))
    const confirm = screen.getAllByRole('button', { name: /Rollback to v1.7/i })
    await user.click(confirm[confirm.length - 1])

    await waitFor(() => expect(api.policies.rollback).toHaveBeenCalledTimes(1))
    expect(vi.mocked(api.policies.rollback).mock.calls[0][1]).toEqual({
      framework_id: 'cis-kubernetes',
      target_version: 'v1.7',
    })
  })
})
