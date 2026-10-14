/**
 * GitOps Detection Engine & Manifest Remediation Generator
 *
 * Detects whether an autonomous agent or Kubernetes workload is under GitOps
 * control (Flux, ArgoCD, or Generic GitOps controllers) and provides declarative
 * git-first remediation guidance and patch snippets.
 */

export interface GitOpsMetadata {
  isGitOps: boolean
  engine: 'flux' | 'argo' | 'generic' | null
  resourceName?: string
  namespace?: string
  commitSha?: string
  repoUrl?: string
  syncWave?: string
  recommendation: string
  patchYaml?: string
}

export interface GitOpsDetectionOptions {
  tenant?: string
}

const FLUX_KUSTOMIZE_KEYS = [
  'kustomize.toolkit.fluxcd.io/name',
  'kustomize.toolkit.fluxcd.io/namespace',
  'kustomize.toolkit.fluxcd.io/reconcile',
]

const FLUX_HELM_KEYS = [
  'helm.toolkit.fluxcd.io/name',
  'helm.toolkit.fluxcd.io/namespace',
]

const ARGO_KEYS = [
  'argocd.argoproj.io/instance',
  'argocd.argoproj.io/sync-wave',
  'argocd.argoproj.io/tracking-id',
]

const COMMIT_SHA_KEYS = [
  'fluxcd.io/git-commit',
  'argocd.argoproj.io/git-commit',
  'git/commit-sha',
]

const REPO_URL_KEYS = [
  'fluxcd.io/git-url',
  'argocd.argoproj.io/repo-url',
  'git/repo-url',
  'kustomize.toolkit.fluxcd.io/source',
]

/**
 * Extracts normalized labels and annotations from a workload object,
 * pod definition, or AgentResponse.
 */
function extractMetadataMaps(workload: unknown): {
  labels: Record<string, string>
  annotations: Record<string, string>
} {
  if (!workload || typeof workload !== 'object') {
    return { labels: {}, annotations: {} }
  }

  const obj = workload as Record<string, any>

  const rawLabels = {
    ...(obj.metadata?.labels || {}),
    ...(obj.labels || {}),
    ...(obj.runtime?.labels || {}),
  }

  const rawAnnotations = {
    ...(obj.metadata?.annotations || {}),
    ...(obj.annotations || {}),
    ...(obj.runtime?.annotations || {}),
  }

  const clean = (input: Record<string, unknown>): Record<string, string> => {
    const out: Record<string, string> = {}
    for (const [key, val] of Object.entries(input)) {
      if (val !== undefined && val !== null) {
        out[key] = String(val)
      }
    }
    return out
  }

  return {
    labels: clean(rawLabels),
    annotations: clean(rawAnnotations),
  }
}

/**
 * Generates a standard YAML metadata patch snippet carrying the signalloom.ai/tenant label.
 */
export function generateGitOpsPatch(options?: {
  resourceName?: string
  namespace?: string
  tenant?: string
}): string {
  const lines: string[] = ['metadata:']
  if (options?.resourceName) {
    lines.push(`  name: ${options.resourceName}`)
  }
  if (options?.namespace) {
    lines.push(`  namespace: ${options.namespace}`)
  }
  lines.push('  labels:')
  lines.push(`    signalloom.ai/tenant: ${options?.tenant || 'default'}`)
  return lines.join('\n')
}

/**
 * Pure, reusable function to detect GitOps management across any Kubernetes workload
 * or AgentResponse record.
 */
export function detectGitOps(workload: any, options?: GitOpsDetectionOptions): GitOpsMetadata {
  if (!workload || typeof workload !== 'object') {
    return {
      isGitOps: false,
      engine: null,
      recommendation: 'No GitOps management detected. Imperative changes via kubectl are permitted.',
    }
  }

  const { labels, annotations } = extractMetadataMaps(workload)

  const findValue = (keys: string[]): string | undefined => {
    for (const k of keys) {
      if (labels[k]) return labels[k]
      if (annotations[k]) return annotations[k]
    }
    return undefined
  }

  const hasAny = (keys: string[]): boolean => findValue(keys) !== undefined

  const hasFluxKustomize = hasAny(FLUX_KUSTOMIZE_KEYS)
  const hasFluxHelm = hasAny(FLUX_HELM_KEYS)
  const hasArgo = hasAny(ARGO_KEYS)
  const hasCommitSha = hasAny(COMMIT_SHA_KEYS)
  const hasRepoUrl = hasAny(REPO_URL_KEYS)

  const managedBy = (
    labels['app.kubernetes.io/managed-by'] ||
    annotations['app.kubernetes.io/managed-by'] ||
    (typeof workload.managedBy === 'string' ? workload.managedBy : '')
  )
    .toLowerCase()
    .trim()

  const isGenericManagedBy = ['flux', 'argocd', 'helm', 'gitops'].includes(managedBy)

  let isGitOps = false
  let engine: 'flux' | 'argo' | 'generic' | null = null

  if (hasFluxKustomize || hasFluxHelm || managedBy === 'flux') {
    isGitOps = true
    engine = 'flux'
  } else if (hasArgo || managedBy === 'argocd') {
    isGitOps = true
    engine = 'argo'
  } else if (isGenericManagedBy || hasCommitSha || hasRepoUrl) {
    isGitOps = true
    engine = 'generic'
  }

  if (!isGitOps) {
    return {
      isGitOps: false,
      engine: null,
      recommendation: 'No GitOps management detected. Imperative changes via kubectl are permitted.',
    }
  }

  const resourceName =
    labels['kustomize.toolkit.fluxcd.io/name'] ||
    annotations['kustomize.toolkit.fluxcd.io/name'] ||
    labels['helm.toolkit.fluxcd.io/name'] ||
    annotations['helm.toolkit.fluxcd.io/name'] ||
    labels['argocd.argoproj.io/instance'] ||
    annotations['argocd.argoproj.io/instance'] ||
    labels['app.kubernetes.io/name'] ||
    workload.metadata?.name ||
    workload.runtime?.pod_name ||
    workload.name ||
    workload.id ||
    undefined

  const namespace =
    labels['kustomize.toolkit.fluxcd.io/namespace'] ||
    annotations['kustomize.toolkit.fluxcd.io/namespace'] ||
    labels['helm.toolkit.fluxcd.io/namespace'] ||
    annotations['helm.toolkit.fluxcd.io/namespace'] ||
    workload.metadata?.namespace ||
    workload.runtime?.namespace ||
    workload.namespace ||
    undefined

  const commitSha = findValue(COMMIT_SHA_KEYS) || (typeof workload.commitSha === 'string' ? workload.commitSha : undefined)
  const repoUrl = findValue(REPO_URL_KEYS) || (typeof workload.repoUrl === 'string' ? workload.repoUrl : undefined)
  const syncWave =
    labels['argocd.argoproj.io/sync-wave'] ||
    annotations['argocd.argoproj.io/sync-wave'] ||
    (typeof workload.syncWave === 'string' ? workload.syncWave : undefined)

  const resolvedTenant =
    options?.tenant ||
    workload.tenant ||
    (workload.tenant_id && workload.tenant_id !== 'undeclared' ? workload.tenant_id : undefined) ||
    labels['signalloom.ai/tenant'] ||
    annotations['signalloom.ai/tenant'] ||
    'default'

  const recommendation = `This workload is managed by GitOps (${engine}). Imperative changes via kubectl will be overwritten by GitOps reconciliation. Commit the governance label change to your git repository or Kustomization manifest.`

  const patchYaml = generateGitOpsPatch({
    resourceName,
    namespace,
    tenant: resolvedTenant,
  })

  const result: GitOpsMetadata = {
    isGitOps: true,
    engine,
    recommendation,
    patchYaml,
  }

  if (resourceName) result.resourceName = resourceName
  if (namespace) result.namespace = namespace
  if (commitSha) result.commitSha = commitSha
  if (repoUrl) result.repoUrl = repoUrl
  if (syncWave) result.syncWave = syncWave

  return result
}
