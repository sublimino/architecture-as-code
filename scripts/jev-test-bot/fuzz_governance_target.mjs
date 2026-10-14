/**
 * fuzz_governance_target.mjs — Targeted Jev random fuzzer for:
 *   1. /policies?framework=k8s-cis-benchmark
 *   2. /settings?tab=governance
 *
 * Runs stochastic exploratory walks, query parameter mutations, control fuzzing,
 * and API stress testing across both targets using real Chromium.
 */

import { createRequire } from 'node:module'
import { writeFileSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'

const require = createRequire(import.meta.url)
const { chromium } = require('/home/andy/src/cp/osramp-demo/test/acceptance/node_modules/@playwright/test')

const BASE_URL = process.env.BASE_URL || 'https://ftna-signalloom.taild4da3.ts.net'
const REPORT_DIR = '/tmp/jev-governance-report'
mkdirSync(REPORT_DIR, { recursive: true })

const TARGETS = [
  {
    name: 'policies_k8s_cis',
    url: `${BASE_URL}/policies?framework=k8s-cis-benchmark`,
    path: '/policies?framework=k8s-cis-benchmark',
  },
  {
    name: 'settings_governance',
    url: `${BASE_URL}/settings?tab=governance`,
    path: '/settings?tab=governance',
  },
]

const QUERY_FUZZ_CASES = [
  // Policies page variations
  '/policies',
  '/policies?framework=k8s-cis-benchmark',
  '/policies?framework=cis-kubernetes', // alias check
  '/policies?framework=eu-ai-act',
  '/policies?framework=nist-800-53',
  '/policies?framework=cra',
  '/policies?framework=finos-aigf',
  '/policies?framework=nonexistent-framework-xyz',
  '/policies?framework=k8s-cis-benchmark&rule=cis-5.2.6',
  '/policies?framework=k8s-cis-benchmark&rule=cis-999-invalid',
  '/policies?framework=%27%22%3E%3Cscript%3Ealert(1)%3C%2Fscript%3E',
  '/policies?framework=&rule=',

  // Settings page variations
  '/settings?tab=governance',
  '/settings?tab=general',
  '/settings?tab=access',
  '/settings?tab=connectors',
  '/settings?tab=invalid-tab-xyz',
  '/settings?tab=',
  '/settings?tab=%27%22%3E',
]

const results = {
  timestamp: new Date().toISOString(),
  targets_evaluated: TARGETS.map((t) => t.url),
  defects: [],
  console_errors: [],
  page_errors: [],
  api_failures: [],
  mutation_checks: [],
  control_coverage: [],
}

function logDefect(category, message, details = {}) {
  const defect = {
    category,
    message,
    timestamp: new Date().toISOString(),
    details,
  }
  results.defects.push(defect)
  console.error(`[DEFECT][${category}] ${message}`, details)
}

async function run() {
  console.log(`Starting Jev Targeted Governance Fuzzer against ${BASE_URL}...`)

  const profileDir = join(REPORT_DIR, 'browser-profile')
  mkdirSync(profileDir, { recursive: true })

  const context = await chromium.launchPersistentContext(profileDir, {
    headless: true,
    ignoreHTTPSErrors: true,
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-gpu',
      '--disable-gpu-compositing',
      '--disable-gpu-rasterization',
      '--disable-gpu-early-init',
      '--disable-gpu-sandbox',
      '--use-gl=disabled',
      '--disable-software-rasterizer',
      '--disable-dev-shm-usage',
      '--ignore-certificate-errors',
    ],
  })

  // Pre-seed authentication and demo mode
  await context.addInitScript(({ o }) => {
    window.localStorage.setItem('sl_demo_mode', 'true')
    window.localStorage.setItem('signalloom.superadmin', 'true')
    window.localStorage.setItem('sl_onboarding_skipped', JSON.stringify({ skippedAt: Date.now() }))
    window.localStorage.setItem(
      `oidc.user:${o}/dex:signalloom-dashboard`,
      JSON.stringify({
        id_token: 'mock-id-token',
        access_token: 'mock-access-token',
        token_type: 'Bearer',
        scope: 'openid email profile',
        profile: {
          sub: 'user-admin',
          email: 'admin@osramp.acme.local',
          preferred_username: 'admin',
          name: 'Admin User',
          groups: ['signalloom-superadmins', 'signalloom-admins'],
        },
        expires_at: Math.floor(Date.now() / 1000) + 86400,
      }),
    )
  }, { o: new URL(BASE_URL).origin })

  const page = context.pages()[0] || await context.newPage()

  await page.route('**/api/v1/features*', async (route) => {
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({
        tenant_id: 'default',
        flags: {
          core_governance: true,
          audit: true,
          compliance: true,
          page_policies: true,
          page_settings: true,
        },
      }),
    }).catch(() => {})
  })

  page.on('console', (msg) => {
    const type = msg.type()
    const text = msg.text()
    if (type === 'error') {
      if (text.includes('/api/v1/features') || text.includes('401')) return
      results.console_errors.push({ text, location: msg.location(), url: page.url() })
      logDefect('CONSOLE_ERROR', text, { location: msg.location(), url: page.url() })
    }
  })

  page.on('pageerror', (err) => {
    results.page_errors.push({ message: err.message, stack: err.stack, url: page.url() })
    logDefect('PAGE_UNCAUGHT_EXCEPTION', err.message, { stack: err.stack, url: page.url() })
  })

  page.on('response', (res) => {
    const status = res.status()
    const url = res.url()
    if (status >= 400 && !url.includes('/api/telemetry/agents') && !url.includes('/api/v1/features')) {
      results.api_failures.push({ url, status, page_url: page.url() })
      logDefect('API_FAILURE', `HTTP ${status} on ${url}`, { url, status, page_url: page.url() })
    }
  })

  // ═════════════════════════════════════════════════════════════════════════
  // Phase 1: Deep Exploratory Fuzzing of Target 1 (/policies?framework=k8s-cis-benchmark)
  // ═════════════════════════════════════════════════════════════════════════
  console.log('\n--- PHASE 1: Policies Page Targeted Fuzzing ---')
  try {
    await page.goto(`${BASE_URL}/policies?framework=k8s-cis-benchmark`, { waitUntil: 'load', timeout: 15000 })
    await page.waitForTimeout(1500)

    // Check React Crash / Error Boundary
    const crashText = await page.evaluate(() => {
      const b = document.body.innerText
      if (b.includes('Something went wrong') || b.includes('Application Error') || b.includes('Minified React error')) {
        return b.slice(0, 300)
      }
      return null
    })
    if (crashText) {
      logDefect('REACT_CRASH', 'Crash detected on initial load of /policies?framework=k8s-cis-benchmark', { crashText })
    }

    // Inspect Framework Selector in PolicyEditor
    console.log('Locating PolicyEditor framework selector dropdown...')
    const fwSelect = page.locator('select:has(option[value="k8s-cis-benchmark"]), select:has(option[value="eu-ai-act"])').first()
    
    if (await fwSelect.isVisible().catch(() => false)) {
      const options = await fwSelect.locator('option').allInnerTexts()
      const optionValues = await fwSelect.locator('option').evaluateAll((opts) => opts.map((o) => o.value))
      console.log('Framework selector options found:', optionValues)

      for (const val of optionValues) {
        console.log(`Selecting framework in PolicyEditor: "${val}"`)
        await fwSelect.selectOption(val)
        await page.waitForTimeout(600)

        // Verify URL updated or state updated
        const currentUrl = page.url()
        console.log(`  Landed on: ${currentUrl}`)

        const isCrashed = await page.evaluate(() => document.body.innerText.includes('Something went wrong'))
        if (isCrashed) {
          logDefect('REACT_CRASH', `Crash after selecting framework "${val}" in PolicyEditor`)
        }
      }

      // Re-select k8s-cis-benchmark
      await fwSelect.selectOption('k8s-cis-benchmark').catch(() => {})
      await page.waitForTimeout(500)
    } else {
      console.log('Framework selector dropdown not visible or rendered as static badge.')
    }

    // Fuzz Rule Search Input
    const searchInput = page.locator('[data-testid="rule-search-input"]')
    if (await searchInput.isVisible().catch(() => false)) {
      console.log('Fuzzing rule search input...')
      const searchTerms = ['cis-5.2', 'root', 'privilege', 'nonexistent-xyz', '<script>', '']
      for (const term of searchTerms) {
        await searchInput.fill(term)
        await page.waitForTimeout(300)
      }
      await searchInput.fill('')
    }

    // Click rule buttons / chips
    const ruleButtons = page.locator('[data-testid="rule-chips-container"] button, button:has-text("CIS 5.")')
    const count = await ruleButtons.count().catch(() => 0)
    console.log(`Found ${count} rule buttons in PolicyEditor.`)

    for (let i = 0; i < Math.min(count, 8); i++) {
      const btn = ruleButtons.nth(i)
      const btnText = await btn.innerText().catch(() => `Rule ${i}`)
      console.log(`Clicking rule ${i + 1}/${count}: "${btnText.slice(0, 40)}"`)
      await btn.click().catch(() => {})
      await page.waitForTimeout(400)
    }

    // Fuzz Prettify Button
    const prettifyBtn = page.locator('[data-testid="prettify-cel-btn"]')
    if (await prettifyBtn.isVisible().catch(() => false)) {
      console.log('Clicking Prettify CEL button...')
      await prettifyBtn.click().catch(() => {})
      await page.waitForTimeout(300)
    }

    // Fuzz CEL Code Textarea
    const celTextarea = page.locator('[data-testid="cel-code-textarea"]')
    if (await celTextarea.isVisible().catch(() => false)) {
      console.log('Fuzzing CEL Code Textarea with edge cases and malformed expressions...')
      const celInputs = [
        'object.spec.containers.all(c, c.securityContext.runAsNonRoot == true)',
        'broken ??? syntax ::: error',
        'has(agent.guardrails) && agent.guardrails.prompt_injection_filter == true',
        '',
        'true',
        'request.tool_call.action in ["exec"] ? false : true',
        '1 / 0 == 0', // Division by zero check
        'agent.undefined_field_xyz > 100', // Undefined field
      ]
      for (const cel of celInputs) {
        await celTextarea.fill(cel).catch(() => {})
        await page.waitForTimeout(300)

        // Check if diagnostic rendered cleanly
        const diagValid = await page.locator('[data-testid="cel-diagnostic-valid"]').isVisible().catch(() => false)
        const diagError = await page.locator('[data-testid="cel-diagnostic-error"]').isVisible().catch(() => false)
        console.log(`  CEL: "${cel.slice(0, 30)}" -> Valid: ${diagValid}, Error: ${diagError}`)
      }
    }

    // Fuzz Version History Drawer Toggle
    const historyBtn = page.locator('[data-testid="toggle-version-history-btn"]')
    if (await historyBtn.isVisible().catch(() => false)) {
      console.log('Opening Version History Drawer...')
      await historyBtn.click().catch(() => {})
      await page.waitForTimeout(500)

      const historyDrawer = page.locator('[data-testid="version-history-drawer"]')
      const drawerVisible = await historyDrawer.isVisible().catch(() => false)
      console.log(`  History Drawer visible: ${drawerVisible}`)

      // Close history drawer
      await page.keyboard.press('Escape')
      await page.waitForTimeout(300)
    }

    // Fuzz Copy Shareable Link Button
    const copyLinkBtn = page.locator('[data-testid="copy-shareable-link-btn"]')
    if (await copyLinkBtn.isVisible().catch(() => false)) {
      console.log('Clicking Copy Shareable Link button...')
      await copyLinkBtn.click().catch(() => {})
      await page.waitForTimeout(300)
    }

    // Test Save Button (dry or real save)
    const saveBtn = page.locator('[data-testid="save-policy-btn"]')
    if (await saveBtn.isVisible().catch(() => false)) {
      console.log('Checking Save Policy button state...')
      const isEnabled = await saveBtn.isEnabled().catch(() => false)
      console.log(`  Save button enabled: ${isEnabled}`)
    }
  } catch (err) {
    logDefect('EXPLORATION_ERROR', err.message, { stack: err.stack, phase: 'Phase 1' })
  }

  // ═════════════════════════════════════════════════════════════════════════
  // Phase 2: Deep Exploratory Fuzzing of Target 2 (/settings?tab=governance)
  // ═════════════════════════════════════════════════════════════════════════
  console.log('\n--- PHASE 2: Settings Governance Tab Targeted Fuzzing ---')
  try {
    await page.goto(`${BASE_URL}/settings?tab=governance`, { waitUntil: 'load', timeout: 15000 })
    await page.waitForTimeout(1500)

    // Verify Governance tab is active
    const activeTab = await page.$eval('[role="tab"][aria-selected="true"]', (el) => el.innerText).catch(() => null)
    console.log('Active tab on /settings?tab=governance:', activeTab)
    if (!activeTab || !activeTab.includes('Governance')) {
      logDefect('TAB_ROUTING_MISMATCH', `Expected Governance tab to be selected, but found: "${activeTab}"`)
    }

    // Inspect Framework cards in Governance tab
    const fwCards = page.locator('#settings-tabpanel-governance [data-testid*="framework-card-"]')
    const cardCount = await fwCards.count().catch(() => 0)
    console.log(`Found ${cardCount} framework cards in Governance panel.`)

    // Inspect switches inside the governance tabpanel
    const switches = page.locator('#settings-tabpanel-governance button[role="switch"]')
    const switchCount = await switches.count().catch(() => 0)
    console.log(`Found ${switchCount} framework switches in Governance panel.`)

    // Toggle framework switches to exercise PATCH /tenant/settings/frameworks
    for (let i = 0; i < switchCount; i++) {
      const sw = switches.nth(i)
      const isChecked = await sw.getAttribute('aria-checked')
      console.log(`Toggling switch ${i + 1}/${switchCount} (initial state: ${isChecked})...`)
      
      await sw.click().catch((e) => console.log('Toggle click failed:', e.message))
      await page.waitForTimeout(600)

      // Check if toast error appeared
      const toast = await page.$eval('[role="alert"], .toast, .alert', (el) => el.innerText).catch(() => null)
      if (toast) {
        console.log(`Toast message after toggle: "${toast}"`)
        if (toast.toLowerCase().includes('failed') || toast.toLowerCase().includes('error')) {
          logDefect('SETTINGS_TOAST_ERROR', toast, { switchIndex: i })
        }
      }

      // Re-toggle back
      await sw.click().catch(() => {})
      await page.waitForTimeout(400)
    }

    // Check "Edit in Editor ↗" links
    const editLinks = page.locator('#settings-tabpanel-governance a[href*="/policies?framework="]')
    const editLinkCount = await editLinks.count().catch(() => 0)
    console.log(`Found ${editLinkCount} "Edit in Editor" links in Governance panel.`)
    for (let i = 0; i < editLinkCount; i++) {
      const href = await editLinks.nth(i).getAttribute('href')
      console.log(`  Link ${i + 1}: ${href}`)
    }
  } catch (err) {
    logDefect('EXPLORATION_ERROR', err.message, { stack: err.stack, phase: 'Phase 2' })
  }

  // ═════════════════════════════════════════════════════════════════════════
  // Phase 3: Systematic Query Parameter Mutation Matrix
  // ═════════════════════════════════════════════════════════════════════════
  console.log('\n--- PHASE 3: Systematic Query Parameter Mutation Matrix ---')
  for (const qcase of QUERY_FUZZ_CASES) {
    const fullUrl = `${BASE_URL}${qcase}`
    console.log(`Testing parameter mutation: ${qcase}`)
    try {
      const response = await page.goto(fullUrl, { waitUntil: 'load', timeout: 10000 })
      const status = response ? response.status() : 0
      await page.waitForTimeout(600)

      const crashed = await page.evaluate(() => {
        const t = document.body.innerText
        return t.includes('Something went wrong') || t.includes('Minified React error')
      })

      results.mutation_checks.push({
        path: qcase,
        status,
        crashed,
        url_after: page.url(),
      })

      if (crashed) {
        logDefect('MUTATION_CRASH', `React crash on URL parameter mutation: ${qcase}`, { qcase, fullUrl })
      }
      if (status >= 400) {
        logDefect('HTTP_ERROR', `Status ${status} on URL parameter mutation: ${qcase}`, { qcase, status })
      }
    } catch (err) {
      logDefect('NAVIGATION_TIMEOUT_OR_FAILURE', err.message, { qcase })
    }
  }

  await page.close()
  await context.close()

  // Write final detailed JSON report
  const reportPath = join(REPORT_DIR, 'targeted-governance-fuzz-report.json')
  writeFileSync(reportPath, JSON.stringify(results, null, 2) + '\n')
  console.log(`\nFuzz run complete! Report written to ${reportPath}`)
  console.log(`Summary: ${results.defects.length} defects detected across ${QUERY_FUZZ_CASES.length + 2} test suites.`)
}

run().catch((err) => {
  console.error('Fatal fuzzer error:', err)
  process.exit(1)
})
