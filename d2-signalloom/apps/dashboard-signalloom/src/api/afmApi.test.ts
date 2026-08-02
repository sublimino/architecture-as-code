/**
 * Tests for the escalation-analysis additions to afmApi.ts: jobs, analysis
 * results (single/group escalations), shared-role pivots and TraceGuards.
 *
 * Fixtures below are trimmed from real responses captured against a live
 * KubeSec-AFM instance (`kubectl -n fe-k8s-afm port-forward svc/afm-platform`,
 * clusters `local` and `demo`) — see afm-live-integration branch notes. The
 * wire format is snake_case (FastAPI/pydantic), which is what makes these
 * parsers distinct from the RBAC ones above them in afmApi.ts.
 */
import { describe, expect, it, vi } from 'vitest'
import {
  fetchAnalysisResult,
  fetchAnalysisStatus,
  fetchClusterJobs,
  fetchGuards,
  fetchJobResult,
  fetchSharedRoles,
  parseAnalysisResult,
  parseAnalysisStatus,
  parseGuardsResult,
  parseJobList,
  parseSharedRoles,
} from './afmApi'

function response(ok: boolean, body?: unknown): Response {
  return { ok, json: vi.fn().mockResolvedValue(body) } as unknown as Response
}

describe('parseJobList', () => {
  it('parses a real job-record shape', () => {
    const wire = [{
      id: 'f67bfa2a724b451b8cd86cb84bfaf193',
      cluster_id: 'local',
      facts_sha256: 'abc',
      params_sha256: 'def',
      config_hash: 'def',
      execution_hash: 'ghi',
      status: 'done',
      trigger_source: 'manual',
      created_at: '2026-08-02T06:06:45.027565Z',
      started_at: '2026-08-02T06:06:45.054368Z',
      finished_at: '2026-08-02T06:06:46.762286Z',
      result_path: 'results/f67bfa2a.json',
      error: null,
      resume_from_job_id: null,
    }]

    expect(parseJobList(wire)).toEqual([{
      id: 'f67bfa2a724b451b8cd86cb84bfaf193',
      clusterId: 'local',
      status: 'done',
      triggerSource: 'manual',
      createdAt: '2026-08-02T06:06:45.027565Z',
      startedAt: '2026-08-02T06:06:45.054368Z',
      finishedAt: '2026-08-02T06:06:46.762286Z',
      error: undefined,
    }])
  })

  it('throws on a non-array payload', () => {
    expect(() => parseJobList({})).toThrow(/non-array job list/)
  })

  it('drops an unusable entry rather than failing the whole list', () => {
    expect(parseJobList([{ id: 'ok', cluster_id: 'local', created_at: 't' }, { no: 'id' }])).toHaveLength(1)
  })

  it('falls back to a safe default for an unrecognised status or trigger source', () => {
    const [job] = parseJobList([{ id: 'x', cluster_id: 'c', created_at: 't', status: 'bogus', trigger_source: 'bogus' }])
    expect(job.status).toBe('failed')
    expect(job.triggerSource).toBe('api')
  })
})

describe('parseAnalysisResult', () => {
  it('returns null for AFM\'s legitimate "no run yet" response', () => {
    expect(parseAnalysisResult(null)).toBeNull()
  })

  it('throws on a non-object payload — that is a real contract break, not "no data"', () => {
    expect(() => parseAnalysisResult('nope')).toThrow(/non-object analysis result/)
  })

  it('parses a real single-escalation finding', () => {
    const wire = {
      schema_version: '3.4.0',
      metadata: { subjects: ['sa_fe_signalloom_flux'], admins: [] },
      single_escalations: [{
        escalation_type: 'admin_via_impersonation',
        subject: 'sa_fe_signalloom_flux',
        scope: 'cluster-wide',
        gained_permission: { namespace: 'cluster', resource: 'all', verb: 'all' },
        risk: { score: 48, level: 'high', likelihood: 50, impact: 100, reason: 'grants full cluster administration', auto_patch_recommended: true },
        evidence: { shell: [], documents: [] },
        trace: {},
      }],
      group_escalations: [],
    }

    const result = parseAnalysisResult(wire)
    expect(result).not.toBeNull()
    expect(result?.subjects).toEqual(['sa_fe_signalloom_flux'])
    expect(result?.singleEscalations).toEqual([{
      subject: 'sa_fe_signalloom_flux',
      escalationType: 'admin_via_impersonation',
      scope: 'cluster-wide',
      gainedPermission: { namespace: 'cluster', resource: 'all', verb: 'all' },
      risk: { score: 48, level: 'high', likelihood: 50, impact: 100, reason: 'grants full cluster administration', autoPatchRecommended: true },
    }])
    expect(result?.groupEscalations).toEqual([])
  })

  it('parses a group (collusion) escalation', () => {
    const wire = {
      schema_version: '3.4.0',
      metadata: { subjects: [] },
      single_escalations: [],
      group_escalations: [{
        group: ['group:dev-eu', 'sa:ci/runner'],
        primary_actor: 'group:dev-eu',
        scope: 'cluster-wide',
        primary_gain: { verb: '*', resource: 'clusterrole:admin', namespace: 'cluster' },
        collaborator_gains: [{ subject: 'sa:ci/runner', permission: { verb: 'bind', resource: 'role:flux-reconciler', namespace: 'cluster' } }],
        joint_trace: {},
        evidence: { shell: [], documents: [] },
        risk: { level: 'critical' },
      }],
    }

    const result = parseAnalysisResult(wire)
    expect(result?.groupEscalations).toEqual([{
      group: ['group:dev-eu', 'sa:ci/runner'],
      primaryActor: 'group:dev-eu',
      scope: 'cluster-wide',
      primaryGain: { verb: '*', resource: 'clusterrole:admin', namespace: 'cluster' },
      collaboratorGains: [{ subject: 'sa:ci/runner', permission: { verb: 'bind', resource: 'role:flux-reconciler', namespace: 'cluster' } }],
      risk: { level: 'critical', score: undefined, likelihood: undefined, impact: undefined, reason: undefined, autoPatchRecommended: undefined },
    }])
  })

  it('drops an escalation entry missing its required subject/actor rather than throwing', () => {
    const wire = {
      schema_version: '3.4.0',
      metadata: { subjects: [] },
      single_escalations: [{ escalation_type: 'x' }, { subject: 'ok', escalation_type: 'y', gained_permission: {} }],
      group_escalations: [{ scope: 'x' }],
    }
    const result = parseAnalysisResult(wire)
    expect(result?.singleEscalations).toHaveLength(1)
    expect(result?.groupEscalations).toHaveLength(0)
  })
})

describe('parseSharedRoles', () => {
  it('parses the real shared_roles shape, deriving sharedBy from all_subjects', () => {
    const wire = {
      cluster: { id: 'local', name: 'Local Cluster' },
      results: [{
        role: 'ClusterRole/admin',
        bindings: [],
        all_subjects: ['ServiceAccount/fe-signalloom/flux', 'ServiceAccount/inf-bao/flux'],
        privileged_subjects: [],
        privileged_details: [],
      }],
    }
    expect(parseSharedRoles(wire)).toEqual([{
      role: 'ClusterRole/admin',
      sharedBy: 2,
      privilegedSubjects: [],
    }])
  })

  it('throws when the payload is not shaped like a shared-roles response', () => {
    expect(() => parseSharedRoles({ results: 'nope' })).toThrow(/non-object shared-roles payload/)
  })
})

describe('parseGuardsResult', () => {
  it('parses the real guards shape', () => {
    const wire = {
      job_id: 'f67bfa2a724b451b8cd86cb84bfaf193',
      count: 1,
      guards: [{
        name: 'traceguard-local-single-0',
        kind: 'single',
        escalation_index: 0,
        participants: ['subject:ServiceAccount:fe-signalloom:flux'],
        deny_step_indices: [2],
        would_block: true,
        yaml: 'apiVersion: kubesec.afm/v1alpha1\n...',
      }],
    }
    expect(parseGuardsResult(wire)).toEqual({
      jobId: 'f67bfa2a724b451b8cd86cb84bfaf193',
      guards: [{
        name: 'traceguard-local-single-0',
        kind: 'single',
        escalationIndex: 0,
        participants: ['subject:ServiceAccount:fe-signalloom:flux'],
        wouldBlock: true,
      }],
    })
  })
})

describe('parseAnalysisStatus', () => {
  it('parses the real status shape', () => {
    const wire = {
      has_running: false,
      running_job_id: null,
      last_completed_job_id: 'f67bfa2a724b451b8cd86cb84bfaf193',
      latest_done_at: '2026-08-02T06:06:46.762286Z',
      latest_failed_at: null,
    }
    expect(parseAnalysisStatus(wire)).toEqual({
      hasRunning: false,
      lastCompletedJobId: 'f67bfa2a724b451b8cd86cb84bfaf193',
      latestDoneAt: '2026-08-02T06:06:46.762286Z',
      latestFailedAt: null,
    })
  })
})

describe('fetchers', () => {
  it('fetchClusterJobs hits the correct URL with the limit query param', async () => {
    const fetchMock = vi.fn().mockResolvedValue(response(true, []))
    vi.stubGlobal('fetch', fetchMock)

    await fetchClusterJobs('local', 5)

    expect(fetchMock).toHaveBeenCalledWith('/afm/clusters/local/jobs?limit=5', expect.anything())
    vi.unstubAllGlobals()
  })

  it('fetchAnalysisResult, fetchJobResult, fetchSharedRoles, fetchGuards, fetchAnalysisStatus hit the correct URLs', async () => {
    const fetchMock = vi.fn().mockResolvedValue(response(true, null))
    vi.stubGlobal('fetch', fetchMock)

    await fetchAnalysisResult('local')
    await fetchJobResult('job-1')
    fetchMock.mockResolvedValue(response(true, { results: [] }))
    await fetchSharedRoles('local')
    fetchMock.mockResolvedValue(response(true, { job_id: '', guards: [] }))
    await fetchGuards('local')
    fetchMock.mockResolvedValue(response(true, { has_running: false, running_job_id: null, last_completed_job_id: null, latest_done_at: null, latest_failed_at: null }))
    await fetchAnalysisStatus('local')

    const urls = fetchMock.mock.calls.map(([url]) => url)
    expect(urls).toEqual([
      '/afm/clusters/local/analysis/latest',
      '/afm/jobs/job-1/result',
      '/afm/clusters/local/analysis/shared_roles',
      '/afm/clusters/local/analysis/guards',
      '/afm/clusters/local/analysis/status',
    ])
    vi.unstubAllGlobals()
  })

  it('a cluster id is URL-encoded so it cannot break out of the path segment', async () => {
    const fetchMock = vi.fn().mockResolvedValue(response(true, []))
    vi.stubGlobal('fetch', fetchMock)

    await fetchClusterJobs('a/b c')

    expect(fetchMock).toHaveBeenCalledWith('/afm/clusters/a%2Fb%20c/jobs?limit=25', expect.anything())
    vi.unstubAllGlobals()
  })
})
