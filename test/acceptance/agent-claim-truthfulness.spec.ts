import { spawn, type ChildProcess } from 'node:child_process'
import { createServer } from 'node:net'
import { join } from 'node:path'
import { expect, test } from '@playwright/test'

let server: ChildProcess
let baseURL: string

async function availablePort(): Promise<number> {
  return await new Promise((resolve, reject) => {
    const probe = createServer()
    probe.once('error', reject)
    probe.listen(0, '127.0.0.1', () => {
      const address = probe.address()
      if (!address || typeof address === 'string') {
        probe.close()
        reject(new Error('Could not reserve a local fixture port'))
        return
      }
      probe.close(error => error ? reject(error) : resolve(address.port))
    })
  })
}

async function waitForDashboard(url: string): Promise<void> {
  const deadline = Date.now() + 20_000
  while (Date.now() < deadline) {
    try {
      const response = await fetch(url)
      if (response.ok) return
    } catch {
      // Vite is still starting.
    }
    await new Promise(resolve => setTimeout(resolve, 100))
  }
  throw new Error(`Local dashboard did not become ready at ${url}`)
}

test.beforeAll(async ({}, testInfo) => {
  const port = await availablePort()
  baseURL = `http://127.0.0.1:${port}`
  server = spawn('bun', ['run', 'dev', '--', '--host', '127.0.0.1', '--port', String(port), '--strictPort'], {
    cwd: join(testInfo.config.rootDir, '..', '..', 'd2-signalloom', 'apps', 'dashboard-signalloom'),
    env: { ...process.env, VITE_SL_ENV: 'dev' },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  await waitForDashboard(baseURL)
})

test.afterAll(() => {
  server?.kill('SIGTERM')
})

test('renders consistent owner identity and refuses fabricated rule detail', async ({ page }, testInfo) => {
  const consoleErrors: string[] = []
  page.on('console', message => {
    if (message.type() === 'error') consoleErrors.push(message.text())
  })
  page.on('pageerror', error => consoleErrors.push(error.message))

  await page.addInitScript(() => {
    const authority = `${window.location.origin}/dex`
    const oidcKey = `oidc.user:${authority}:signalloom-dashboard`
    window.localStorage.setItem('sl_demo_mode', 'false')
    window.localStorage.setItem('sl_onboarding_skipped', 'true')
    window.localStorage.setItem(oidcKey, JSON.stringify({
      access_token: 'fixture-token',
      token_type: 'Bearer',
      expires_at: Math.floor(Date.now() / 1000) + 3600,
      profile: {
        sub: 'fixture-operator',
        email: 'operator@fixture.test',
        name: 'Fixture Operator',
      },
    }))
  })

  const agent = {
    id: 'fixture-agent',
    name: 'Fixture Agent',
    type: 'Signal Loom Built',
    owner: null,
    tenant: 'tenant-fixture',
    tenant_id: 'tenant-fixture',
    lifecycle_state: 'discovered',
    last_transition_at: '2026-10-12T12:00:00Z',
    last_transition_by: 'system',
    eu_ai_act_risk_class: 'limited',
    compliance_summary: { total_controls: 1, passing: 0, failing: 1, pending: 0, posture_score: 0 },
    created_at: '2026-10-12T12:00:00Z',
    record_class: 'discovered',
    is_registry_linked: false,
    responsibility: {
      owner_id: 'owner-fixture',
      owner_name: 'responsibility-owner@fixture.test',
      team: 'Platform Security',
      assignment_status: 'assigned',
    },
    runtime: {
      cluster_id: 'fixture-cluster',
      namespace: 'fixture-namespace',
      pod_name: 'fixture-agent-pod',
      pod_uid: 'fixture-pod-uid',
      service_account: 'fixture-agent',
      framework: 'standard-container',
      model: 'fixture/model',
      execution_mode: 'container',
      node: 'fixture-node',
      phase: 'Running',
    },
  }
  const complianceResult = {
    agent_id: agent.id,
    control_id: 'UNKNOWN-9.9',
    control_name: 'Unknown synthetic control',
    framework_name: 'Unknown Framework',
    status: 'fail',
    assessed_at: '2026-10-12T12:00:00Z',
    evidence_ref: 'fixture:unknown',
  }

  await page.route(url => url.origin === baseURL && url.pathname.startsWith('/api/'), async route => {
    const path = new URL(route.request().url()).pathname
    let body: unknown = {}
    if (path === `/api/agents/${agent.id}`) body = agent
    else if (path === `/api/agents/${agent.id}/violations`) body = { violations: [] }
    else if (path === `/api/agents/${agent.id}/telemetry`) body = { observations: [] }
    else if (path === `/api/agents/${agent.id}/external-evidence`) body = { evidence: [] }
    else if (path === '/api/compliance/posture') body = { agents: [{ agent_id: agent.id, results: [complianceResult] }] }
    else if (path === '/api/audit') body = { events: [], total: 0, page: 1, limit: 50 }
    else if (path === '/api/onboarding/status') body = { completed: true, skipped: true }
    else if (path === '/api/v1/features') body = { tenant_id: 'tenant-fixture', flags: {} }
    await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) })
  })

  await page.goto(`${baseURL}/agents/${agent.id}?tab=overview`, { waitUntil: 'domcontentloaded' })

  await expect(page.getByTestId('dossier-owner-header')).toContainText('responsibility-owner@fixture.test')
  await expect(page.getByTestId('overview-responsibility-owner')).toHaveText('responsibility-owner@fixture.test')
  await expect(page.getByTestId('cel-rule-unavailable-unknown-synthetic-control')).toContainText('Rule detail unavailable')
  await expect(page.getByTestId('cel-rule-expression-unknown-synthetic-control')).toHaveCount(0)

  const overviewScreenshot = testInfo.outputPath('owner-rule-overview.png')
  await page.screenshot({ path: overviewScreenshot, fullPage: true })
  await testInfo.attach('owner-rule-overview', { path: overviewScreenshot, contentType: 'image/png' })

  await page.getByTestId('cel-rule-unavailable-unknown-synthetic-control').scrollIntoViewIfNeeded()
  const ruleScreenshot = testInfo.outputPath('rule-detail-unavailable.png')
  await page.screenshot({ path: ruleScreenshot })
  await testInfo.attach('rule-detail-unavailable', { path: ruleScreenshot, contentType: 'image/png' })

  await page.getByTestId('dossier-claim-btn').click()
  const claimModal = page.getByTestId('claim-modal')
  await expect(claimModal.getByText('Assigned Owner', { exact: true })).toBeVisible()
  await expect(page.getByTestId('claim-modal-operator')).toHaveText('operator@fixture.test')
  await expect(claimModal.getByText(/Assigned Owner \/ Operator/i)).toHaveCount(0)

  const modalScreenshot = testInfo.outputPath('claim-owner-operator.png')
  await page.screenshot({ path: modalScreenshot, fullPage: true })
  await testInfo.attach('claim-owner-operator', { path: modalScreenshot, contentType: 'image/png' })
  expect(consoleErrors).toEqual([])
})
