import { describe, it, expect } from 'vitest'
import { detectGitOps, generateGitOpsPatch, type GitOpsMetadata } from './gitops'

describe('GitOps Detection Engine (detectGitOps)', () => {
  it('detects Flux Kustomize managed workloads', () => {
    const fluxKustomizePod = {
      metadata: {
        name: 'agent-nono-kustomize',
        namespace: 'fe-signalloom-agents',
        labels: {
          'kustomize.toolkit.fluxcd.io/name': 'apps-fleet',
          'kustomize.toolkit.fluxcd.io/namespace': 'flux-system',
          'kustomize.toolkit.fluxcd.io/reconcile': 'enabled',
        },
        annotations: {
          'fluxcd.io/git-commit': '6a4b1c9e2d3f',
        },
      },
      tenant: 'acme-corp',
    }

    const result = detectGitOps(fluxKustomizePod)

    expect(result.isGitOps).toBe(true)
    expect(result.engine).toBe('flux')
    expect(result.resourceName).toBe('apps-fleet')
    expect(result.namespace).toBe('flux-system')
    expect(result.commitSha).toBe('6a4b1c9e2d3f')
    expect(result.recommendation).toBe(
      'This workload is managed by GitOps (flux). Imperative changes via kubectl will be overwritten by GitOps reconciliation. Commit the governance label change to your git repository or Kustomization manifest.'
    )
    expect(result.patchYaml).toContain('signalloom.ai/tenant: acme-corp')
    expect(result.patchYaml).toContain('name: apps-fleet')
  })

  it('detects Flux Helm managed workloads', () => {
    const fluxHelmWorkload = {
      metadata: {
        name: 'agent-helm-worker',
        namespace: 'helm-agents',
        labels: {
          'helm.toolkit.fluxcd.io/name': 'agent-helm-release',
          'helm.toolkit.fluxcd.io/namespace': 'flux-helm-system',
        },
      },
      tenant_id: 'tenant-finance',
    }

    const result = detectGitOps(fluxHelmWorkload)

    expect(result.isGitOps).toBe(true)
    expect(result.engine).toBe('flux')
    expect(result.resourceName).toBe('agent-helm-release')
    expect(result.namespace).toBe('flux-helm-system')
    expect(result.recommendation).toContain('managed by GitOps (flux)')
    expect(result.patchYaml).toContain('signalloom.ai/tenant: tenant-finance')
  })

  it('detects ArgoCD managed workloads with sync-wave and tracking annotations', () => {
    const argoWorkload = {
      metadata: {
        name: 'agent-argo-pipeline',
        namespace: 'argo-agents',
        labels: {
          'argocd.argoproj.io/instance': 'signal-loom-cluster-apps',
        },
        annotations: {
          'argocd.argoproj.io/sync-wave': '3',
          'argocd.argoproj.io/tracking-id': 'signal-loom-cluster-apps:apps/Deployment:argo-agents/agent-argo-pipeline',
          'argocd.argoproj.io/repo-url': 'https://github.com/signalloom/governance-fleet.git',
        },
      },
    }

    const result = detectGitOps(argoWorkload)

    expect(result.isGitOps).toBe(true)
    expect(result.engine).toBe('argo')
    expect(result.resourceName).toBe('signal-loom-cluster-apps')
    expect(result.namespace).toBe('argo-agents')
    expect(result.syncWave).toBe('3')
    expect(result.repoUrl).toBe('https://github.com/signalloom/governance-fleet.git')
    expect(result.recommendation).toBe(
      'This workload is managed by GitOps (argo). Imperative changes via kubectl will be overwritten by GitOps reconciliation. Commit the governance label change to your git repository or Kustomization manifest.'
    )
    expect(result.patchYaml).toContain('signalloom.ai/tenant: default')
  })

  it('detects Generic GitOps through app.kubernetes.io/managed-by and commit sha', () => {
    // Sub-case 1: managed-by: gitops
    const genericManagedWorkload = {
      labels: {
        'app.kubernetes.io/managed-by': 'gitops',
        'app.kubernetes.io/name': 'agent-generic',
      },
      namespace: 'custom-agents',
    }

    const result1 = detectGitOps(genericManagedWorkload)
    expect(result1.isGitOps).toBe(true)
    expect(result1.engine).toBe('generic')
    expect(result1.recommendation).toContain('managed by GitOps (generic)')
    expect(result1.resourceName).toBe('agent-generic')
    expect(result1.namespace).toBe('custom-agents')

    // Sub-case 2: managed-by: helm
    const helmManagedWorkload = {
      metadata: {
        name: 'helm-agent',
        labels: {
          'app.kubernetes.io/managed-by': 'helm',
        },
      },
    }
    const result2 = detectGitOps(helmManagedWorkload)
    expect(result2.isGitOps).toBe(true)
    expect(result2.engine).toBe('generic')

    // Sub-case 3: commit sha annotation without controller prefix
    const commitShaWorkload = {
      name: 'commit-annotated-agent',
      annotations: {
        'git/commit-sha': '7e3d8f1a4b',
        'git/repo-url': 'https://git.internal/org/repo',
      },
    }
    const result3 = detectGitOps(commitShaWorkload)
    expect(result3.isGitOps).toBe(true)
    expect(result3.engine).toBe('generic')
    expect(result3.commitSha).toBe('7e3d8f1a4b')
    expect(result3.repoUrl).toBe('https://git.internal/org/repo')
  })

  it('negative test: bare pod without GitOps labels returns isGitOps: false, engine: null', () => {
    const barePod = {
      metadata: {
        name: 'bare-agent-pod',
        namespace: 'default',
        labels: {
          'app.kubernetes.io/name': 'bare-agent',
          'env': 'production',
        },
      },
    }

    const result = detectGitOps(barePod)

    expect(result.isGitOps).toBe(false)
    expect(result.engine).toBeNull()
    expect(result.patchYaml).toBeUndefined()
    expect(result.recommendation).toContain('No GitOps management detected')

    // Also verify null, undefined, empty inputs
    expect(detectGitOps(null)).toEqual({
      isGitOps: false,
      engine: null,
      recommendation: 'No GitOps management detected. Imperative changes via kubectl are permitted.',
    })
    expect(detectGitOps({})).toEqual({
      isGitOps: false,
      engine: null,
      recommendation: 'No GitOps management detected. Imperative changes via kubectl are permitted.',
    })
  })

  it('supports options tenant override in patch generation', () => {
    const fluxWorkload = {
      labels: {
        'kustomize.toolkit.fluxcd.io/name': 'tenant-workload',
      },
      tenant: 'original-tenant',
    }

    const result = detectGitOps(fluxWorkload, { tenant: 'override-tenant' })
    expect(result.isGitOps).toBe(true)
    expect(result.patchYaml).toContain('signalloom.ai/tenant: override-tenant')
  })

  it('generates well-formed YAML patch with generateGitOpsPatch', () => {
    const patch = generateGitOpsPatch({
      resourceName: 'my-agent',
      namespace: 'fe-signalloom-agents',
      tenant: 'kusari',
    })

    expect(patch).toBe(
      'metadata:\n  name: my-agent\n  namespace: fe-signalloom-agents\n  labels:\n    signalloom.ai/tenant: kusari'
    )
  })
})
