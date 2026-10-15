import { describe, it, expect } from 'vitest'
import {
  buildEngineSavePayload,
  getBundleForFramework,
  harmonizeBundleRules,
  normalizeFrameworkId,
  selectEngineSummary,
} from './regulatoryFrameworks'
import type { PolicyBundle, PolicyRule } from '../types/policies'

const catalogue = (fw: string) => getBundleForFramework(fw)!.rules

// Engine rules as the Go policy-engine serves cis-kubernetes/v1.8: no CIS prefix in
// the name, and extra fields (risk_triple) the dashboard type does not declare.
const cisEngineRules = [
  {
    id: 'no-root-containers',
    name: 'Containers do not run as root',
    cel_expression: 'object.spec.containers.all(c, c.securityContext.runAsNonRoot == true)',
    severity: 'high',
    risk_triple: { min: 1, mode: 2, max: 3 },
  },
  {
    id: 'sa-token-automount-disabled',
    name: 'Service account token auto-mount disabled',
    cel_expression: 'object.spec.automountServiceAccountToken == false',
    severity: 'high',
  },
] as unknown as PolicyRule[]

describe('harmonizeBundleRules: engine authority', () => {
  it('marks every catalogue rule the engine does not hold as catalogue_only, and no engine rule', () => {
    const merged = harmonizeBundleRules(catalogue('k8s-cis-benchmark'), cisEngineRules)
    const engineIds = new Set(cisEngineRules.map((r) => r.id))
    const fromEngine = merged.filter((r) => engineIds.has(r.id))
    const fromCatalogue = merged.filter((r) => !engineIds.has(r.id))

    expect(fromEngine.map((r) => r.catalogue_only)).toEqual([undefined, undefined])
    expect(fromCatalogue.length).toBe(catalogue('k8s-cis-benchmark').length - cisEngineRules.length)
    expect(fromCatalogue.every((r) => r.catalogue_only === true)).toBe(true)
  })

  it('does not graft catalogue attestation flags onto a matched engine rule', () => {
    const engine: PolicyRule = {
      id: 'resource-quotas',
      name: 'CIS 5.4.1 ResourceQuotas present',
      cel_expression: 'true',
    }
    const merged = harmonizeBundleRules(catalogue('k8s-cis-benchmark'), [engine])
    const out = merged.find((r) => r.id === 'resource-quotas')!
    expect(out.tested_separately).toBeUndefined()
    expect(out.manual_attestation).toBeUndefined()
    expect(out.attestation_type).toBeUndefined()
    expect(out.cel_expression).toBe('true')
    // The one-to-one match still fills display-only reference text and claims no-secrets-in-env.
    expect(out.docs_url).toContain('kubernetes.io')
    expect(merged.some((r) => r.id === 'no-secrets-in-env')).toBe(false)
  })
})

describe('harmonizeBundleRules: one-to-one matcher, never on a partial number', () => {
  it('IA-2 merges into the IA-2 control, not AC-2, and AC-2 is not lost', () => {
    const engine: PolicyRule = { id: 'workload-mtls', name: 'IA-2 Workload mTLS authentication', cel_expression: 'true' }
    const nist = catalogue('nist-800-53')
    const ia2 = nist.find((r) => r.name.startsWith('IA-2'))!
    const ac2 = nist.find((r) => r.name.startsWith('AC-2'))!
    const merged = harmonizeBundleRules(nist, [engine])

    expect(merged[0]).toEqual({ ...engine, description: ia2.description, docs_url: ia2.docs_url })
    expect(merged.some((r) => r.id === ia2.id)).toBe(false)
    expect(merged.find((r) => r.id === ac2.id)?.catalogue_only).toBe(true)
  })

  it('Art. 1 does not merge into Art. 10', () => {
    const engine: PolicyRule = { id: 'subject-matter', name: 'Art. 1 Subject matter', cel_expression: 'true' }
    const merged = harmonizeBundleRules(catalogue('eu-ai-act'), [engine])
    expect(merged[0]).toEqual(engine)
    expect(merged.find((r) => r.id === 'training-data-provenance')?.catalogue_only).toBe(true)
  })

  it('CIS 5.4 does not take cis-5.4.1 metadata', () => {
    const engine: PolicyRule = { id: 'secrets-mgmt', name: 'CIS 5.4 Secrets management', cel_expression: 'true' }
    const merged = harmonizeBundleRules(catalogue('k8s-cis-benchmark'), [engine])
    expect(merged[0]).toEqual(engine)
    expect(merged.find((r) => r.id === 'no-secrets-in-env')?.catalogue_only).toBe(true)
  })

  it('two engine rules competing for one catalogue control claim it zero times, not twice', () => {
    const a: PolicyRule = { id: 'quota-a', name: 'CIS 5.4.1 quotas A', cel_expression: 'true' }
    const b: PolicyRule = { id: 'quota-b', name: 'CIS 5.4.1 quotas B', cel_expression: 'false' }
    const merged = harmonizeBundleRules(catalogue('k8s-cis-benchmark'), [a, b])
    expect(merged.slice(0, 2)).toEqual([a, b])
    expect(merged.filter((r) => r.id === 'no-secrets-in-env').length).toBe(1)
  })
})

describe('buildEngineSavePayload', () => {
  const engineBundle: PolicyBundle = {
    id: 'cis-kubernetes-v1.8',
    framework_id: 'cis-kubernetes',
    version: 'v1.8',
    author: 'system',
    created_at: '2026-10-01T00:00:00Z',
    checksum: 'abc',
    rules: cisEngineRules,
  }

  it('sends only engine rules, under the engine framework id, carrying the edited CEL', () => {
    const merged = harmonizeBundleRules(catalogue('k8s-cis-benchmark'), cisEngineRules)
    merged[1] = { ...merged[1], cel_expression: 'object.spec.automountServiceAccountToken != true' }
    const edited: PolicyBundle = {
      ...engineBundle,
      framework_id: 'k8s-cis-benchmark',
      version: 'v1.8.1',
      created_at: '2026-10-15T00:00:00Z',
      rules: merged,
    }

    const payload = buildEngineSavePayload(edited, engineBundle, 'cis-kubernetes')

    expect(payload.framework_id).toBe('cis-kubernetes')
    expect(payload.version).toBe('v1.8.1')
    expect(payload.rules).toEqual([
      cisEngineRules[0],
      { ...cisEngineRules[1], cel_expression: 'object.spec.automountServiceAccountToken != true' },
    ])
    expect(payload.rules.some((r) => r.cel_expression.trim().startsWith('/*'))).toBe(false)
  })
})

describe('selectEngineSummary', () => {
  const cisKube = { framework_id: 'cis-kubernetes' }
  const k8sCis = { framework_id: 'k8s-cis-benchmark' }

  it('is independent of the engine list order for an alias pair', () => {
    expect(selectEngineSummary([cisKube, k8sCis], 'k8s-cis-benchmark')).toBe(k8sCis)
    expect(selectEngineSummary([k8sCis, cisKube], 'k8s-cis-benchmark')).toBe(k8sCis)
  })

  it('falls back to the alias when only the alias is registered', () => {
    expect(selectEngineSummary([cisKube], 'k8s-cis-benchmark')).toBe(cisKube)
  })
})

describe('normalizeFrameworkId: cra only as a whole token', () => {
  it.each([
    ['Democracy and AI Principles', 'democracy and ai principles'],
    ['Bureaucracy Reduction Act', 'bureaucracy reduction act'],
  ])('does not map name %s to cra', (name, expected) => {
    expect(normalizeFrameworkId(null, name)).toBe(expected)
  })

  it.each(['scra', 'craft-ai-standard'])('does not map id %s to cra', (id) => {
    expect(normalizeFrameworkId(id)).toBe(id)
  })

  it.each([
    ['eu-cra', undefined],
    [null, 'EU CRA'],
    [null, 'Cyber Resilience Act (EU) 2024/2847'],
  ])('maps %s / %s to cra', (id, name) => {
    expect(normalizeFrameworkId(id, name)).toBe('cra')
  })
})

describe('k8s-cis-benchmark canonical bundle', () => {
  it('returns all 17 canonical rules with exact check IDs, non-empty cel_expressions, and required checks', () => {
    const bundle = getBundleForFramework('k8s-cis-benchmark')
    expect(bundle).not.toBeNull()
    expect(bundle!.rules).toHaveLength(17)

    const expectedRuleIds = [
      'sa-token-automount-disabled',
      'no-privileged-containers',
      'no-host-pid',
      'no-host-ipc',
      'no-host-network',
      'no-privilege-escalation',
      'no-root-containers',
      'no-net-raw',
      'no-added-capabilities',
      'capabilities-dropped-all',
      'no-windows-hostprocess',
      'no-hostpath-volumes',
      'no-host-ports',
      'no-secrets-in-env',
      'seccomp-runtime-default',
      'security-context-applied',
      'no-default-namespace',
    ]

    const actualRuleIds = bundle!.rules.map((r) => r.id)
    expect(actualRuleIds).toEqual(expectedRuleIds)

    expect(actualRuleIds).toContain('no-root-containers')
    expect(actualRuleIds).toContain('no-privilege-escalation')

    for (const rule of bundle!.rules) {
      expect(rule.cel_expression).toBeDefined()
      expect(rule.cel_expression.trim().length).toBeGreaterThan(0)
    }
  })
})
