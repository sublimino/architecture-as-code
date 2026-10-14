// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * Scripted HTTP server and React component bundler for User Administration
 * and Feature Flag Suppression acceptance tests.
 *
 * Implements authoritative in-memory state for:
 *   - /api/v1/me
 *   - /api/v1/admin/users (GET, POST /invite, PATCH /:id, DELETE /:id)
 *   - /api/v1/features (tenant-scoped OpenFeature flag dictionary)
 *   - /api/v1/tenants
 */
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { gateMethod, jsonResponse, notFoundResponse, staticResponse } from './http-gate'

const HERE = dirname(fileURLToPath(import.meta.url))
const ACCEPTANCE_DIR = join(HERE, '..')
const DASHBOARD_DIR = join(ACCEPTANCE_DIR, '..', '..', 'd2-signalloom', 'apps', 'dashboard-signalloom')
const GLOBAL_CSS = join(DASHBOARD_DIR, 'src', 'styles', 'global.css')

export interface PlatformUser {
  id: string
  tenant_id: string
  email: string
  display_name: string | null
  role: 'admin' | 'editor' | 'viewer'
  status: 'active' | 'suspended' | 'invited' | 'deactivated'
  department: string | null
  title: string | null
  is_superadmin: boolean
  created_at: string
  updated_at: string
}

export interface FeatureFlagDetail {
  enabled: boolean
  config: Record<string, unknown>
}

export interface FeaturesResponse {
  tenant_id: string
  flags: Record<string, boolean>
  details?: Record<string, FeatureFlagDetail>
}

const INITIAL_USERS: PlatformUser[] = [
  {
    id: 'usr-demo-001',
    tenant_id: 'tenant-demo',
    email: 'demo-user@signalloom.local',
    display_name: 'Platform Superadmin',
    role: 'admin',
    status: 'active',
    department: 'Platform Engineering',
    title: 'Superadmin Operator',
    is_superadmin: true,
    created_at: '2026-10-01T00:00:00Z',
    updated_at: '2026-10-01T00:00:00Z',
  },
  {
    id: 'usr-kusari-002',
    tenant_id: 'kusari',
    email: 'admin@kusari.demo',
    display_name: 'Kusari Admin',
    role: 'admin',
    status: 'active',
    department: 'Security Operations',
    title: 'Design Partner Lead',
    is_superadmin: true,
    created_at: '2026-10-02T00:00:00Z',
    updated_at: '2026-10-02T00:00:00Z',
  },
  {
    id: 'usr-acme-003',
    tenant_id: 'tenant-acme',
    email: 'operator@acme.demo',
    display_name: 'Acme Operator',
    role: 'viewer',
    status: 'active',
    department: 'Security',
    title: 'Auditor',
    is_superadmin: false,
    created_at: '2026-10-03T00:00:00Z',
    updated_at: '2026-10-03T00:00:00Z',
  },
]

export interface FeaturePreset {
  id: string
  name: string
  description: string
  flags: Record<string, boolean>
}

const FEATURE_PRESETS: FeaturePreset[] = [
  {
    id: 'eap_pilot',
    name: 'EAP Pilot',
    description: 'Enterprise pilot preset: all core governance, audit, and compliance views active; experimental demo labs disabled.',
    flags: {
      core_governance: true,
      audit: true,
      compliance: true,
      demos_fleet: false,
      supercred: false,
      rbac_analysis: false,
      collusion_access: false,
      page_discovery: true,
      page_agents: true,
      page_topology: true,
      page_weave: true,
      page_signals: true,
      page_risk: true,
      page_policies: true,
      page_compliance: true,
      page_audit: true,
      page_federated_services: true,
      page_cryptography: true,
      page_credential_inventory: true,
      page_signal_store: false,
      page_feeds: false,
      page_network_tests: false,
      page_agentmaxxing: false,
    },
  },
  {
    id: 'full_demo',
    name: 'Full Platform Demo',
    description: 'All 23 platform capabilities, demo surfaces, and telemetry feeds enabled.',
    flags: {
      core_governance: true,
      audit: true,
      compliance: true,
      demos_fleet: true,
      supercred: true,
      rbac_analysis: true,
      collusion_access: true,
      page_discovery: true,
      page_agents: true,
      page_topology: true,
      page_weave: true,
      page_signals: true,
      page_risk: true,
      page_policies: true,
      page_compliance: true,
      page_audit: true,
      page_federated_services: true,
      page_cryptography: true,
      page_credential_inventory: true,
      page_signal_store: true,
      page_feeds: true,
      page_network_tests: true,
      page_agentmaxxing: true,
    },
  },
  {
    id: 'minimal_governance',
    name: 'Minimal Governance',
    description: 'Minimal boundary view: agents registry, policy compliance, and audit trail only.',
    flags: {
      core_governance: true,
      audit: true,
      compliance: false,
      demos_fleet: false,
      supercred: false,
      rbac_analysis: false,
      collusion_access: false,
      page_discovery: false,
      page_agents: true,
      page_topology: false,
      page_weave: false,
      page_signals: false,
      page_risk: false,
      page_policies: false,
      page_compliance: false,
      page_audit: true,
      page_federated_services: false,
      page_cryptography: false,
      page_credential_inventory: false,
      page_signal_store: false,
      page_feeds: false,
      page_network_tests: false,
      page_agentmaxxing: false,
    },
  },
]

const TENANT_FLAGS: Record<string, Record<string, boolean>> = {
  'tenant-demo': {
    core_governance: true,
    audit: true,
    compliance: true,
    demos_fleet: true,
    supercred: true,
    rbac_analysis: true,
    collusion_access: true,
    page_discovery: true,
    page_agents: true,
    page_topology: true,
    page_weave: true,
    page_signals: true,
    page_risk: true,
    page_policies: true,
    page_compliance: true,
    page_audit: true,
    page_federated_services: true,
    page_cryptography: true,
    page_credential_inventory: true,
    page_signal_store: true,
    page_feeds: true,
    page_network_tests: true,
    page_agentmaxxing: true,
  },
  'kusari': {
    core_governance: true,
    audit: true,
    compliance: true,
    demos_fleet: false,
    supercred: false,
    rbac_analysis: false,
    collusion_access: false,
    page_discovery: true,
    page_agents: true,
    page_topology: true,
    page_weave: true,
    page_signals: true,
    page_risk: true,
    page_policies: true,
    page_compliance: true,
    page_audit: true,
    page_federated_services: true,
    page_cryptography: true,
    page_credential_inventory: true,
    page_signal_store: false,
    page_feeds: false,
    page_network_tests: false,
    page_agentmaxxing: false,
  },
  'tenant-acme': {
    core_governance: true,
    audit: true,
    compliance: true,
    demos_fleet: false,
    supercred: false,
    rbac_analysis: false,
    collusion_access: false,
    page_discovery: true,
    page_agents: true,
    page_topology: true,
    page_weave: true,
    page_signals: true,
    page_risk: true,
    page_policies: true,
    page_compliance: true,
    page_audit: true,
    page_federated_services: true,
    page_cryptography: true,
    page_credential_inventory: true,
    page_signal_store: false,
    page_feeds: false,
    page_network_tests: false,
    page_agentmaxxing: false,
  },
}

let cachedBundle: string | null = null

async function bundle(): Promise<string> {
  if (cachedBundle) return cachedBundle
  const built = await Bun.build({
    entrypoints: [join(HERE, 'user-admin-flags-entry.tsx')],
    target: 'browser',
    define: {
      'process.env.NODE_ENV': '"development"',
      'import.meta.env': JSON.stringify({
        NODE_ENV: 'development',
        DEV: true,
        PROD: false,
        MODE: 'development',
        VITE_SL_ENV: 'development',
        VITE_API_BASE_URL: '',
        VITE_CONSENT_MODAL_ENABLED: 'false',
      }),
    },
    plugins: [
      {
        name: 'redirect-auth-and-resolve',
        setup(build) {
          build.onResolve({ filter: /auth\/oidc$/ }, () => ({
            path: join(HERE, 'user-admin-flags-auth-stub.tsx'),
          }))
          build.onResolve({ filter: /\?raw$/ }, (args) => {
            const cleanPath = args.path.replace(/\?raw$/, '')
            const resolved = Bun.resolveSync(cleanPath, args.importer ? dirname(args.importer) : HERE)
            return { path: resolved, namespace: 'raw-file' }
          })
          build.onLoad({ filter: /.*/, namespace: 'raw-file' }, async (args) => {
            const content = await Bun.file(args.path).text()
            return {
              contents: `export default ${JSON.stringify(content)};`,
              loader: 'js',
            }
          })
          build.onLoad({ filter: /\.md$/ }, async (args) => {
            const content = await Bun.file(args.path).text()
            return {
              contents: `export default ${JSON.stringify(content)};`,
              loader: 'js',
            }
          })
          build.onResolve({ filter: /^[^./]/ }, (args) => {
            try {
              return { path: Bun.resolveSync(args.path, join(DASHBOARD_DIR, 'node_modules')) }
            } catch {
              try {
                return { path: Bun.resolveSync(args.path, join(ACCEPTANCE_DIR, 'node_modules')) }
              } catch {
                return undefined
              }
            }
          })
        },
      },
    ],
  })

  if (!built.success) {
    const logs = built.logs.map((l) => l.message).join('\n')
    throw new Error(`user-admin-flags bundle failed:\n${logs}`)
  }
  const text = await built.outputs[0].text()
  cachedBundle = text
  return text
}

const INDEX_HTML = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Signal Loom — User Administration & Feature Flags</title>
    <link rel="stylesheet" href="/global.css" />
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/user-admin-flags-harness.js"></script>
  </body>
</html>
`

const TENANT_SETTINGS: Record<string, {
  tenant_id: string
  org_name: string
  plan_tier: string
  agent_count: number
  billing_tier: string | null
  api_key_status: string
  selected_frameworks: string[]
  consent_required: boolean
  preferred_scan_cadence_hours: number
  alert_email: string | null
  alert_threshold: number
}> = {
  'tenant-demo': {
    tenant_id: 'tenant-demo',
    org_name: 'Signal Loom Demo',
    plan_tier: 'enterprise',
    agent_count: 12,
    billing_tier: 'enterprise',
    api_key_status: 'active',
    selected_frameworks: ['eu-ai-act'],
    consent_required: false,
    preferred_scan_cadence_hours: 24,
    alert_email: null,
    alert_threshold: 1,
  },
  'kusari': {
    tenant_id: 'kusari',
    org_name: 'Kusari Pilot Corp',
    plan_tier: 'enterprise',
    agent_count: 8,
    billing_tier: 'enterprise',
    api_key_status: 'active',
    selected_frameworks: ['eu-ai-act'],
    consent_required: false,
    preferred_scan_cadence_hours: 24,
    alert_email: null,
    alert_threshold: 1,
  },
  'tenant-acme': {
    tenant_id: 'tenant-acme',
    org_name: 'Acme Corporation',
    plan_tier: 'growth',
    agent_count: 3,
    billing_tier: null,
    api_key_status: 'active',
    selected_frameworks: [],
    consent_required: false,
    preferred_scan_cadence_hours: 24,
    alert_email: null,
    alert_threshold: 1,
  },
}

const CORS_HEADERS: Record<string, string> = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store',
  'access-control-allow-origin': '*',
}

function json(
  data: unknown,
  status = 200,
  req?: Request,
  extraHeaders: Record<string, string> = {},
): Response {
  return jsonResponse(data, status, req, { ...CORS_HEADERS, ...extraHeaders })
}

function resolveTenant(request: Request): string {
  const url = new URL(request.url)
  const qTenant = url.searchParams.get('tenant_id') || url.searchParams.get('tenant')
  if (qTenant) return qTenant

  const authHeader = request.headers.get('authorization') ?? ''
  if (authHeader.startsWith('Bearer ')) {
    const token = authHeader.slice(7)
    try {
      const parts = token.split('.')
      if (parts.length >= 2) {
        const payload = JSON.parse(Buffer.from(parts[1], 'base64').toString('utf8'))
        const tid = payload['https://signalloom.ai/tenant_id'] || payload['tenant_id']
        if (typeof tid === 'string' && tid) return tid
      }
    } catch {}
  }
  if (authHeader.includes('kusari')) return 'kusari'
  if (authHeader.includes('tenant-acme')) return 'tenant-acme'
  return 'tenant-demo'
}

export function startUserAdminFlagsHarness(options: { port?: number } = {}): HarnessServer {
  let users: PlatformUser[] = JSON.parse(JSON.stringify(INITIAL_USERS))
  let currentFlags: Record<string, Record<string, boolean>> = JSON.parse(JSON.stringify(TENANT_FLAGS))
  let tenantSettings: Record<string, any> = JSON.parse(JSON.stringify(TENANT_SETTINGS))
  const requestLog: Array<{ method: string; path: string; tenant?: string; timestamp: string }> = []

  const server = Bun.serve({
    port: options.port ?? 0,
    idleTimeout: 60,
    async fetch(request) {
      const url = new URL(request.url)
      const path = url.pathname

      // ─── Static assets ──────────────────────────────────────────────────
      if (path === '/' || path === '/index.html' || path.startsWith('/admin') || path.startsWith('/fleet') || path.startsWith('/agents') || path.startsWith('/compliance') || path.startsWith('/policies') || path.startsWith('/audit') || path.startsWith('/settings') || path.startsWith('/federated-services') || path.startsWith('/collusion-access') || path.startsWith('/rbac') || path.startsWith('/supercred') || path.startsWith('/demos')) {
        const gate = await gateMethod(request, ['GET', 'HEAD'])
        if (gate) return gate
        return staticResponse(request, INDEX_HTML, 200, { 'content-type': 'text/html; charset=utf-8' })
      }

      if (path === '/user-admin-flags-harness.js') {
        const gate = await gateMethod(request, ['GET', 'HEAD'])
        if (gate) return gate
        return staticResponse(request, request.method === 'HEAD' ? null : await bundle(), 200, {
          'content-type': 'text/javascript; charset=utf-8',
          'cache-control': 'no-store',
        })
      }

      if (path === '/global.css') {
        const gate = await gateMethod(request, ['GET', 'HEAD'])
        if (gate) return gate
        const css = Bun.file(GLOBAL_CSS)
        if (!(await css.exists())) {
          return staticResponse(request, `/* ${GLOBAL_CSS} not found */`, 404, {
            'content-type': 'text/css; charset=utf-8',
          })
        }
        return staticResponse(request, css, 200, {
          'content-type': 'text/css; charset=utf-8',
          'cache-control': 'no-store',
        })
      }

      // Log API requests
      const authHeader = request.headers.get('authorization') ?? ''
      requestLog.push({
        method: request.method,
        path,
        tenant: url.searchParams.get('tenant_id') ?? undefined,
        timestamp: new Date().toISOString(),
      })

      // ─── Control plane ─────────────────────────────────────────────────
      if (path === '/harness/reset') {
        const gate = await gateMethod(request, ['POST'])
        if (gate) return gate
        users = JSON.parse(JSON.stringify(INITIAL_USERS))
        currentFlags = JSON.parse(JSON.stringify(TENANT_FLAGS))
        tenantSettings = JSON.parse(JSON.stringify(TENANT_SETTINGS))
        requestLog.length = 0
        return json({ ok: true, users: users.length }, 200, request)
      }

      if (path === '/harness/requests') {
        const gate = await gateMethod(request, ['GET', 'HEAD'])
        if (gate) return gate
        return json(requestLog, 200, request)
      }

      if (path === '/harness/state') {
        const gate = await gateMethod(request, ['GET', 'HEAD'])
        if (gate) return gate
        return json({ users, flags: currentFlags }, 200, request)
      }

      // ─── Identity: /api/v1/me ──────────────────────────────────────────
      if (path === '/api/v1/me') {
        const gate = await gateMethod(request, ['GET', 'HEAD'])
        if (gate) return gate
        const tenant = resolveTenant(request)

        if (tenant === 'tenant-acme') {
          return json({
            subject: 'usr-acme-003',
            tenant: 'tenant-acme',
            email: 'operator@acme.demo',
            superadmin: false,
          }, 200, request)
        }

        if (tenant === 'kusari') {
          return json({
            subject: 'usr-kusari-002',
            tenant: 'kusari',
            email: 'admin@kusari.demo',
            superadmin: true,
          }, 200, request)
        }

        return json({
          subject: 'usr-demo-001',
          tenant: 'tenant-demo',
          email: 'demo-user@signalloom.local',
          superadmin: true,
        }, 200, request)
      }

      // ─── Feature Flags: /api/v1/features ───────────────────────────────
      if (path === '/api/v1/features') {
        const gate = await gateMethod(request, ['GET', 'HEAD'])
        if (gate) return gate
        const requestedTenant = resolveTenant(request)
        const flags = currentFlags[requestedTenant] ?? currentFlags['tenant-demo']
        const details: Record<string, FeatureFlagDetail> = Object.fromEntries(
          Object.entries(flags).map(([key, enabled]) => [key, { enabled, config: {} }])
        )

        return json({
          tenant_id: requestedTenant,
          flags,
          details,
        }, 200, request)
      }

      // ─── Admin Feature Flags: /api/v1/admin/features ───────────────────
      if (path === '/api/v1/admin/features/presets') {
        const gate = await gateMethod(request, ['GET', 'HEAD'])
        if (gate) return gate
        return json({ presets: FEATURE_PRESETS }, 200, request)
      }

      if (path === '/api/v1/admin/features') {
        if (request.method === 'GET' || request.method === 'HEAD') {
          const requestedTenant = resolveTenant(request)
          const flags = currentFlags[requestedTenant] ?? currentFlags['tenant-demo']
          const details: Record<string, FeatureFlagDetail> = Object.fromEntries(
            Object.entries(flags).map(([key, enabled]) => [key, { enabled, config: {} }])
          )
          return json({
            tenant_id: requestedTenant,
            flags,
            details,
          }, 200, request)
        }

        if (request.method === 'PUT') {
          const body = (await request.json().catch(() => ({}))) as {
            tenant_id?: string
            preset?: string
            flags?: Record<string, boolean>
          }
          const targetTenant = body.tenant_id || resolveTenant(request)
          if (!currentFlags[targetTenant]) {
            currentFlags[targetTenant] = { ...(currentFlags['tenant-demo'] ?? {}) }
          }

          if (body.preset) {
            const foundPreset = FEATURE_PRESETS.find((p) => p.id === body.preset)
            if (foundPreset) {
              currentFlags[targetTenant] = {
                ...currentFlags[targetTenant],
                ...foundPreset.flags,
              }
            }
          }

          if (body.flags) {
            currentFlags[targetTenant] = {
              ...currentFlags[targetTenant],
              ...body.flags,
            }
          }

          const flags = currentFlags[targetTenant]
          const details: Record<string, FeatureFlagDetail> = Object.fromEntries(
            Object.entries(flags).map(([key, enabled]) => [key, { enabled, config: {} }])
          )

          return json({
            tenant_id: targetTenant,
            flags,
            details,
          }, 200, request)
        }
      }

      const singleFlagMatch = path.match(/^\/api\/v1\/admin\/features\/([^/]+)$/)
      if (singleFlagMatch) {
        if (request.method === 'PUT') {
          const flagKey = decodeURIComponent(singleFlagMatch[1])
          const targetTenant = resolveTenant(request)
          const body = (await request.json().catch(() => ({}))) as {
            enabled?: boolean
            config_json?: Record<string, unknown>
          }

          if (!currentFlags[targetTenant]) {
            currentFlags[targetTenant] = { ...(currentFlags['tenant-demo'] ?? {}) }
          }

          if (typeof body.enabled === 'boolean') {
            currentFlags[targetTenant][flagKey] = body.enabled
          }

          const flags = currentFlags[targetTenant]
          const details: Record<string, FeatureFlagDetail> = Object.fromEntries(
            Object.entries(flags).map(([key, enabled]) => [key, { enabled, config: {} }])
          )

          return json({
            tenant_id: targetTenant,
            flags,
            details,
          }, 200, request)
        }
      }

      // ─── Tenant Settings: /api/tenant/settings & /tenant/settings ───────
      if (path === '/api/tenant/settings' || path === '/tenant/settings') {
        const gate = await gateMethod(request, ['GET', 'HEAD'])
        if (gate) return gate
        const requestedTenant = resolveTenant(request)
        const s = tenantSettings[requestedTenant] ?? {
          tenant_id: requestedTenant,
          org_name: `${requestedTenant} Org`,
          plan_tier: 'growth',
          agent_count: 4,
          billing_tier: null,
          api_key_status: 'active',
          selected_frameworks: [],
          consent_required: false,
          preferred_scan_cadence_hours: 24,
          alert_email: null,
          alert_threshold: 1,
        }
        return json(s, 200, request)
      }

      if (
        path === '/api/tenant/settings/organization' ||
        path === '/tenant/settings/organization' ||
        path === '/api/tenant/settings/org-name' ||
        path === '/tenant/settings/org-name'
      ) {
        const gate = await gateMethod(request, ['PATCH'])
        if (gate) return gate
        const requestedTenant = resolveTenant(request)
        const body = (await request.json().catch(() => ({}))) as { org_name?: string }
        if (!tenantSettings[requestedTenant]) {
          tenantSettings[requestedTenant] = {
            tenant_id: requestedTenant,
            org_name: body.org_name || `${requestedTenant} Org`,
            plan_tier: 'growth',
            agent_count: 4,
            billing_tier: null,
            api_key_status: 'active',
            selected_frameworks: [],
            consent_required: false,
            preferred_scan_cadence_hours: 24,
            alert_email: null,
            alert_threshold: 1,
          }
        } else if (body.org_name) {
          tenantSettings[requestedTenant].org_name = body.org_name
        }
        return json(tenantSettings[requestedTenant], 200, request)
      }

      // ─── Tenants: /api/v1/tenants ───────────────────────────────────────
      if (path === '/api/v1/tenants') {
        const gate = await gateMethod(request, ['GET', 'HEAD'])
        if (gate) return gate
        return json([
          { id: 'tenant-demo', name: 'Demo Tenant' },
          { id: 'kusari', name: 'Kusari Pilot' },
          { id: 'tenant-acme', name: 'Acme Corporation' },
        ], 200, request)
      }

      // ─── User Administration: /api/v1/admin/users ───────────────────────
      if (path === '/api/v1/admin/users') {
        const gate = await gateMethod(request, ['GET', 'HEAD'])
        if (gate) return gate
        const tenantFilter = url.searchParams.get('tenant_id')
        const searchFilter = (url.searchParams.get('search') ?? '').toLowerCase()
        const roleFilter = url.searchParams.get('role')
        const statusFilter = url.searchParams.get('status')

        let result = [...users]
        if (tenantFilter && tenantFilter !== 'all') {
          result = result.filter((u) => u.tenant_id === tenantFilter)
        }
        if (roleFilter && roleFilter !== 'all') {
          result = result.filter((u) => u.role === roleFilter)
        }
        if (statusFilter && statusFilter !== 'all') {
          result = result.filter((u) => u.status === statusFilter)
        }
        if (searchFilter) {
          result = result.filter(
            (u) =>
              u.email.toLowerCase().includes(searchFilter) ||
              (u.display_name && u.display_name.toLowerCase().includes(searchFilter)) ||
              u.role.toLowerCase().includes(searchFilter),
          )
        }

        return json({
          users: result,
          total: result.length,
          page: 1,
          limit: 50,
        }, 200, request)
      }

      if (path === '/api/v1/admin/users/invite') {
        const gate = await gateMethod(request, ['POST'])
        if (gate) return gate
        const body = (await request.json().catch(() => ({}))) as Partial<PlatformUser>
        if (!body.email) {
          return json({ detail: 'email is required' }, 422, request)
        }

        const newUser: PlatformUser = {
          id: `usr-${Math.random().toString(36).slice(2, 10)}`,
          tenant_id: body.tenant_id || 'tenant-demo',
          email: body.email,
          display_name: body.display_name || body.email.split('@')[0],
          role: body.role || 'editor',
          status: 'invited',
          department: body.department || null,
          title: body.title || null,
          is_superadmin: Boolean(body.is_superadmin),
          created_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        }

        users.push(newUser)
        return json(newUser, 201, request)
      }

      const userMatch = path.match(/^\/api\/v1\/admin\/users\/([^/]+)$/)
      if (userMatch) {
        const gate = await gateMethod(request, ['PATCH', 'DELETE'])
        if (gate) return gate
        const userId = decodeURIComponent(userMatch[1])
        const targetIndex = users.findIndex((u) => u.id === userId)

        if (targetIndex === -1) {
          return json({ detail: `User not found: ${userId}` }, 404, request)
        }

        if (request.method === 'PATCH') {
          const body = (await request.json().catch(() => ({}))) as Partial<PlatformUser>
          const existing = users[targetIndex]
          const updated: PlatformUser = {
            ...existing,
            ...body,
            id: existing.id, // Immutable
            updated_at: new Date().toISOString(),
          }
          users[targetIndex] = updated
          return json(updated, 200, request)
        }

        if (request.method === 'DELETE') {
          const existing = users[targetIndex]
          const deactivated: PlatformUser = {
            ...existing,
            status: 'deactivated',
            updated_at: new Date().toISOString(),
          }
          users[targetIndex] = deactivated
          return json(deactivated, 200, request)
        }
      }

      return notFoundResponse(request, `Unhandled route: ${request.method} ${path}`, CORS_HEADERS)
    },
  })

  return {
    url: `http://127.0.0.1:${server.port}`,
    port: server.port,
    async close() {
      await server.stop(true)
    },
  }
}

if (import.meta.main) {
  const argv = Bun.argv.slice(2)
  const portFlag = argv.indexOf('--port')
  const port = portFlag >= 0 ? Number(argv[portFlag + 1]) : 0

  await bundle()
  const harness = startUserAdminFlagsHarness({ port })
  console.log(`USER_ADMIN_FLAGS_HARNESS_READY ${harness.url}`)
}
