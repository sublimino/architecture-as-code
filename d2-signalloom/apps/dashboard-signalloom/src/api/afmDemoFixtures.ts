/**
 * Deterministic, offline demo dataset for the Collusion & Access page.
 *
 * Two fixed runs stand in for AFM job history so the run-selector dropdown has
 * something to browse even when the backend is unreachable, and the two are
 * built from what were previously this page's only content: the collusion
 * pairs, shared-role pivots and remediation fixes that used to be hardcoded
 * directly into the component. Their union — DEMO_AGGREGATE — is what "All
 * runs (aggregate)" renders, so the page's original narrative content is
 * still fully reachable, just now behind the same run-shaped data model that
 * live mode uses.
 *
 * Timestamps are fixed (not `Date.now()`) so demo mode is byte-for-byte
 * reproducible across renders and test runs — the whole point of "demo mode
 * stays deterministic and offline".
 */
import type { AnalysisResult, Guard, GroupEscalation, SharedRoleEntry } from './afmApi'

export interface DemoRun {
  id: string
  clusterId: string
  clusterName: string
  createdAt: string
  finishedAt: string
  analysis: AnalysisResult
  sharedRoles: SharedRoleEntry[]
  guards: Guard[]
}

function groupEscalation(
  group: [string, string],
  gainedResource: string,
  pivotRole: string,
  depth: number,
  level: 'critical' | 'high' | 'medium',
): GroupEscalation {
  const [primaryActor, collaborator] = group
  return {
    group: [primaryActor, collaborator],
    primaryActor,
    scope: 'cluster-wide',
    primaryGain: { verb: '*', resource: gainedResource, namespace: 'cluster' },
    collaboratorGains: [
      { subject: collaborator, permission: { verb: 'bind', resource: pivotRole, namespace: 'cluster' } },
    ],
    risk: {
      level,
      reason: `pivots through ${pivotRole}, ${depth}-step joint trace`,
    },
  }
}

export const DEMO_RUN_PROD: DemoRun = {
  id: 'demo-run-prod-eu-1',
  clusterId: 'prod-eu-1',
  clusterName: 'Prod GitOps Cluster (EU)',
  createdAt: '2026-07-28T09:12:00Z',
  finishedAt: '2026-07-28T09:12:04Z',
  analysis: {
    schemaVersion: 'demo',
    subjects: ['group:dev-eu', 'sa:ci/runner', 'group:ops-oncall', 'sa:platform/backup'],
    singleEscalations: [],
    groupEscalations: [
      groupEscalation(['group:dev-eu', 'sa:ci/runner'], 'clusterrole:admin', 'role:flux-reconciler', 4, 'critical'),
      groupEscalation(['group:ops-oncall', 'sa:platform/backup'], 'clusterrole:node-proxy', 'role:pv-manager', 5, 'high'),
    ],
  },
  sharedRoles: [
    { role: 'role:flux-reconciler', sharedBy: 4, privilegedSubjects: ['sa:ci/runner'] },
    { role: 'role:pv-manager', sharedBy: 3, privilegedSubjects: [] },
  ],
  guards: [
    {
      name: 'Remove escalate verb from role:flux-reconciler',
      kind: 'group',
      escalationIndex: 0,
      participants: ['group:dev-eu', 'sa:ci/runner'],
      wouldBlock: true,
    },
    {
      name: 'NetworkPolicy deny to longhorn-backend',
      kind: 'group',
      escalationIndex: 1,
      participants: ['group:ops-oncall', 'sa:platform/backup'],
      wouldBlock: true,
    },
  ],
}

export const DEMO_RUN_STAGING: DemoRun = {
  id: 'demo-run-staging-1',
  clusterId: 'staging-1',
  clusterName: 'Staging Cluster',
  createdAt: '2026-07-30T14:47:00Z',
  finishedAt: '2026-07-30T14:47:03Z',
  analysis: {
    schemaVersion: 'demo',
    subjects: ['sa:apps/frontend', 'sa:apps/worker', 'group:analysts', 'sa:data/etl'],
    singleEscalations: [],
    groupEscalations: [
      groupEscalation(['sa:apps/frontend', 'sa:apps/worker'], 'role:namespace-admin', 'role:secret-reader', 3, 'high'),
      groupEscalation(['group:analysts', 'sa:data/etl'], 'role:workflow-admin', 'role:configmap-writer', 2, 'medium'),
    ],
  },
  sharedRoles: [
    { role: 'role:secret-reader', sharedBy: 7, privilegedSubjects: ['sa:apps/frontend', 'sa:apps/worker'] },
  ],
  guards: [
    {
      name: 'Split role:secret-reader per namespace',
      kind: 'group',
      escalationIndex: 0,
      participants: ['sa:apps/frontend', 'sa:apps/worker'],
      wouldBlock: true,
    },
    {
      name: 'Scope sa:ci/runner to namespace flux-system',
      kind: 'group',
      escalationIndex: 1,
      participants: ['group:analysts', 'sa:data/etl'],
      wouldBlock: true,
    },
  ],
}

export const DEMO_RUNS: DemoRun[] = [DEMO_RUN_PROD, DEMO_RUN_STAGING]

/** The union of every demo run — what "All runs (aggregate)" renders in demo mode. */
export const DEMO_AGGREGATE: DemoRun = {
  id: 'demo-aggregate',
  clusterId: 'all',
  clusterName: 'All demo clusters',
  createdAt: DEMO_RUN_PROD.createdAt,
  finishedAt: DEMO_RUN_STAGING.finishedAt,
  analysis: {
    schemaVersion: 'demo',
    subjects: Array.from(new Set([...DEMO_RUN_PROD.analysis.subjects, ...DEMO_RUN_STAGING.analysis.subjects])),
    singleEscalations: [],
    groupEscalations: [...DEMO_RUN_PROD.analysis.groupEscalations, ...DEMO_RUN_STAGING.analysis.groupEscalations],
  },
  sharedRoles: [...DEMO_RUN_PROD.sharedRoles, ...DEMO_RUN_STAGING.sharedRoles],
  guards: [...DEMO_RUN_PROD.guards, ...DEMO_RUN_STAGING.guards],
}
