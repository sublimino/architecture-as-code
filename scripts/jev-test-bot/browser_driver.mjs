/**
 * browser_driver.mjs — the Jev exploratory bot, in a real browser.
 *
 * WHY THIS EXISTS
 *
 * `bot.py` fetches each route with urllib and never executes JavaScript. The
 * dashboard is a single-page app: every path answers the same `index.html`
 * shell with HTTP 200, including paths that are not routes at all. So the
 * fetch-mode claim "44/44 routes visited" means 44 routes ANSWERED, and
 * `loop_report.py` was right to publish `console_errors_observable: false` —
 * there was no console to observe, no runtime error to catch, no React error
 * boundary to read, and no control to click. Every bug oracle the README
 * promises except the HTTP ones was structurally unreachable.
 *
 * This driver closes that gap. One Chromium context per iteration, driven
 * through the Playwright runtime `test/acceptance` already installs (no new
 * browser dependency), navigating each derived route, waiting for the SPA to
 * mount, running the repo's own `snapshot.js` in-page to extract the indexed
 * action space, and performing up to TURNS typed actions chosen by the same
 * Jev decision model `bot.py` uses — reached over stdin/stdout JSON lines via
 * `decide_server.py`, or its calibrated simulator ported to JS behind the same
 * `--mock` flag.
 *
 * WHAT IT RECORDS, PER ROUTE
 *
 *   rendered + render_reason   did the SPA actually paint, or merely answer
 *   final_url / redirected_to  where the router actually landed
 *   console_errors             console.error from the page's own code
 *   page_errors                uncaught exceptions / unhandled rejections
 *   api_failures               4xx/5xx on same-origin requests the app made
 *   boundary_text              React error-boundary / crash-card text
 *   dead_controls              a control clicked twice with no DOM or URL change
 *   actions                    the typed actions executed, with their effect
 *
 * The report is written in `bot.py`'s own shape (`area_scope`, `path_status`,
 * `defects`, `passed`, …) with those fields ADDED, so `loop_report.py`
 * aggregates a browser iteration and a fetch iteration through one code path.
 *
 * HONEST LIMITS, kept here rather than in a commit message:
 *
 *   * The session is SEEDED, not negotiated. An unauthenticated visit calls
 *     `signinRedirect` at a Dex issuer that does not exist offline, so every
 *     protected route would sit on the "Signing in" loader for ever. The
 *     driver pre-seeds the `oidc.user:…` entry `auth/oidc.tsx` reads from
 *     localStorage. The OIDC handshake itself is therefore NOT exercised —
 *     the same boundary `routes.py` already draws by excluding /login and
 *     /callback.
 *   * `--no-backend` exists because a locally started vite serves the app but
 *     proxies /api to nothing. Those same-origin 5xx are recorded, and
 *     classified `BACKEND_ABSENT` rather than counted as application defects.
 *     Without the flag — against a real deployment — every same-origin 4xx/5xx
 *     is a defect.
 *   * A dead control is REPORTED but does not fail the run unless
 *     `--fail-on-dead-control` is given. A no-op refresh button and a broken
 *     one look identical from outside, and a false defect on a 44-route walk
 *     costs more than a missed one.
 *
 * USAGE
 *
 *   browser_driver.mjs --base URL --routes FILE --out-dir DIR [options]
 *
 *     --turns N               typed actions per route (default 4)
 *     --timeout SEC           budget per route, navigation included (default 30)
 *     --mock                  decide with the JS-ported calibrated simulator
 *     --decider js|python     default: js with --mock, python otherwise
 *     --profile-dir DIR       isolated browser profile (default
 *                             $JEV_BROWSER_PROFILE_DIR, else a temp dir)
 *     --no-backend            see above
 *     --fail-on-dead-control  promote dead controls to defects
 *     --stop-on-error         stop the walk at the first defect
 *     --channel NAME          Playwright channel (default: bundled chromium)
 *     --check-runtime         probe Playwright + Chromium and exit
 *
 *   Test-only fault injection, for proving the oracles are wired:
 *     --fault-route ROUTE / $JEV_FAULT_ROUTE
 *     --fault-kind console|pageerror / $JEV_FAULT_KIND
 *   Inert unless a route is named. It injects into the PAGE from the driver;
 *   no application source carries a test hook.
 */

import { createRequire } from 'node:module'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { tmpdir } from 'node:os'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = resolve(HERE, '..', '..')

// ── The destructive guard ──────────────────────────────────────────────────
//
// Exported, and tested directly, because the whole point of a guard is that
// the dangerous case must not have to occur for the guard to be proven. A
// walk that never happens to meet a sign-out button proves nothing about what
// would happen if it did.
//
// Matched on the accessible name, which is what the action space carries.
// Kept deliberately wider than "sign out": on this dashboard a wandering bot
// can revoke a credential, quarantine an agent or reset a demo, and every one
// of those mutates shared state that another suite may be asserting on.
const DESTRUCTIVE_PATTERNS = [
  /\bsign\s*-?\s*out\b/i,
  /\blog\s*-?\s*out\b/i,
  /\bsignout\b/i,
  /\blogout\b/i,
  /\bdelete\b/i,
  /\bremove\b/i,
  /\brevoke\b/i,
  /\bdestroy\b/i,
  /\bpurge\b/i,
  /\bwipe\b/i,
  /\breset\b/i,
  /\bterminate\b/i,
  /\bdeactivate\b/i,
  /\bdisable\b/i,
  /\bquarantine\b/i,
  /\bstun\b/i,
  /\bunclaim\b/i,
]

export function isDestructive(name) {
  if (!name) return false
  return DESTRUCTIVE_PATTERNS.some((re) => re.test(String(name)))
}

// ── Deterministic PRNG ─────────────────────────────────────────────────────
//
// Mulberry32 32-bit state generator. Produces deterministic, pseudo-random
// floats in [0, 1) from an integer seed for reproducible chaos walks.
export function createPrng(seed) {
  let s = (Math.floor(seed) >>> 0) || 1
  return function next() {
    s = (s + 0x6D2B79F5) | 0
    let t = Math.imul(s ^ (s >>> 15), 1 | s)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

// ── Fuzz Payloads ──────────────────────────────────────────────────────────
let _CACHED_PAYLOADS = null
export function loadFuzzPayloads() {
  if (_CACHED_PAYLOADS) return _CACHED_PAYLOADS
  const candidate = join(HERE, 'fuzz_payloads.json')
  if (existsSync(candidate)) {
    try {
      _CACHED_PAYLOADS = JSON.parse(readFileSync(candidate, 'utf8'))
      return _CACHED_PAYLOADS
    } catch {
      /* fallback below */
    }
  }
  _CACHED_PAYLOADS = {
    unicode: ['\u202Ereversed\u202D', '\u0000null_byte', '\ud83d\udd25\ud83d\udca5\ud83d\ude80'],
    numbers: ['0', '-1', 'NaN', 'Infinity', '9007199254740991'],
    injection: ['<script>alert(1)</script>', "' OR '1'='1", '{{7*7}}'],
    lengths: ['A'.repeat(1000)],
    json_malformed: ['{"unclosed":', 'null', '{}'],
  }
  return _CACHED_PAYLOADS
}

export function sampleFuzzPayload(payloads = null, prng = Math.random, category = null) {
  const dict = payloads || loadFuzzPayloads()
  let pool = []
  if (category && dict[category]) {
    pool = dict[category]
  } else {
    for (const cat of Object.keys(dict)) {
      if (Array.isArray(dict[cat])) pool.push(...dict[cat])
    }
  }
  if (pool.length === 0) return 'jev-fuzz-probe'
  const idx = Math.floor(prng() * pool.length)
  return pool[idx]
}

const STORMABLE_PATTERNS = [
  /\bscan\b/i,
  /\brefresh\b/i,
  /\bretry\b/i,
  /\btest\b/i,
  /\btoggle\b/i,
  /\bfilter\b/i,
  /\bnext\b/i,
  /\bprev\b/i,
  /\bpage\b/i,
  /\bapply\b/i,
  /\bsearch\b/i,
  /\bsort\b/i,
  /\bload\b/i,
]

export function isStormable(name) {
  if (!name) return false
  return STORMABLE_PATTERNS.some((re) => re.test(String(name)))
}

// ── The calibrated simulator, ported & enhanced ────────────────────────────
//
// A port and extension of `bot.py`'s `_heuristic_mock_decide` with:
// - Softmax / Boltzmann exploration over temperature T
// - Input fuzzing selection for textboxes / search filters
// - Seeded PRNG for deterministic reproducibility
export function heuristicDecide({
  elements,
  areaScope,
  recentActions = [],
  visitedUrls = new Set(),
  url = '',
  prng = Math.random,
  temperature = 1.0,
  fuzzInputs = false,
  fuzzPayloads = null,
}) {
  const clickable = elements.filter((e) => (e.operations || ['CLICK']).includes('CLICK'))
  const inputs = elements.filter(
    (e) => (e.operations || []).includes('TYPE_TEXT') || e.role === 'textbox' || e.role === 'searchbox',
  )
  if (clickable.length === 0 && inputs.length === 0) {
    return { operation: 'DONE', target: null, confidence: 1.0, mock: true }
  }

  const candidatePool = fuzzInputs && inputs.length > 0 ? [...clickable, ...inputs] : clickable
  let safe = candidatePool.filter((e) => !isDestructive(e.name))
  if (safe.length === 0) safe = candidatePool.length > 0 ? candidatePool : clickable

  const areaClean = String(areaScope || '').split('?')[0].replace(/^\/+|\/+$/g, '')
  if (areaClean) {
    const inScope = safe.filter(
      (e) => !e.href || e.href.includes(areaClean) || e.href.startsWith(`/${areaClean}`),
    )
    if (inScope.length > 0) safe = inScope
  }

  // Softmax base scores: tabs, switches, inputs, buttons, and in-scope links
  const scores = safe.map((e) => {
    let score = 1.0
    if (e.role === 'tab' || e.role === 'switch') score = 3.6
    else if (e.role === 'textbox' || e.role === 'searchbox') score = 3.2
    else if (e.role === 'button') score = 2.8
    else if (e.href) {
      const clean = e.href.split('?')[0].replace(/\/+$/, '') || '/'
      const isUnvisited = !visitedUrls.has(clean) && !visitedUrls.has(`${String(url).replace(/\/+$/, '')}${clean}`)
      if (isUnvisited) score = 2.2
      else score = 1.2
    }
    return score
  })

  // Boltzmann / Softmax exploration with temperature
  const temp = Math.max(0.05, Number(temperature) || 1.0)
  const maxScore = Math.max(...scores)
  const expWeights = scores.map((s) => Math.exp((s - maxScore) / temp))
  const sumWeights = expWeights.reduce((a, b) => a + b, 0)
  const probs = expWeights.map((w) => w / sumWeights)

  // Sample using PRNG
  const r = prng()
  let cumulative = 0
  let chosenIndex = 0
  for (let i = 0; i < probs.length; i++) {
    cumulative += probs[i]
    if (r <= cumulative) {
      chosenIndex = i
      break
    }
  }
  const chosen = safe[chosenIndex] || safe[0]
  const isInput = chosen.role === 'textbox' || chosen.role === 'searchbox' || (chosen.operations || []).includes('TYPE_TEXT')
  const operation = isInput ? 'TYPE_TEXT' : 'CLICK'
  const confidence = Math.round((0.84 + prng() * 0.12) * 100) / 100
  const payload = isInput ? sampleFuzzPayload(fuzzPayloads, prng) : undefined

  return { operation, target: chosen, confidence, payload, mock: true }
}

// ── Playwright resolution ─────────────────────────────────────────────────
//
// Resolved against the node_modules test/acceptance already installs, rather
// than adding a dependency anywhere. $JEV_PLAYWRIGHT_MODULE_DIR overrides, so
// a CI image that installs it elsewhere needs no code change.
const PLAYWRIGHT_CANDIDATES = [
  process.env.JEV_PLAYWRIGHT_MODULE_DIR,
  join(REPO_ROOT, 'test', 'acceptance', 'node_modules'),
  join(REPO_ROOT, 'node_modules'),
  join(REPO_ROOT, 'd2-signalloom', 'apps', 'dashboard-signalloom', 'node_modules'),
].filter(Boolean)

async function loadChromium() {
  const tried = []
  for (const dir of PLAYWRIGHT_CANDIDATES) {
    try {
      const req = createRequire(join(dir, '__jev_resolver__.cjs'))
      const mod = req('@playwright/test')
      if (mod?.chromium) return { chromium: mod.chromium, from: dir }
    } catch (err) {
      tried.push(`${dir}: ${err?.code ?? err?.message ?? err}`)
    }
  }
  throw new Error(
    '@playwright/test could not be resolved. Install it the way the acceptance ' +
      'suite does: `cd test/acceptance && bun install`. Tried:\n  ' +
      tried.join('\n  '),
  )
}

async function checkRuntime() {
  const { chromium, from } = await loadChromium()
  let execPath
  try {
    execPath = chromium.executablePath()
  } catch (err) {
    throw new Error(`Playwright resolved from ${from} but reports no Chromium: ${err?.message ?? err}`)
  }
  if (!execPath || !existsSync(execPath)) {
    throw new Error(
      `no Chromium build at ${execPath || '<unset>'} — install it with ` +
        '`cd test/acceptance && bunx playwright install chromium`',
    )
  }
  return `playwright from ${from}, chromium at ${execPath}`
}

// ── The in-page helpers ───────────────────────────────────────────────────

// EVERY in-page probe below is a real JavaScript FUNCTION, never a string, and
// that is load-bearing rather than stylistic.
//
// Playwright's `evaluate` accepts a string, and a string that LOOKS like an
// arrow function is still evaluated as an EXPRESSION: `page.evaluate("() => {
// return {k:1} }")` produces a function object in the page, which is
// unserialisable, and the call resolves to `undefined`. Measured here.
//
// That failure is not loud. `waitForFunction("() => …")` evaluates the same
// expression, gets a truthy function object, and resolves IMMEDIATELY — so a
// render gate written as a string reports "rendered" for a blank page, on
// every route, and the suite that was supposed to catch an unrendered page
// goes green. The only safe forms are a real function (serialised via
// toString) or an explicit IIFE expression; strings that merely look callable
// are the trap.
//
// `snapshot.js` is read from disk, so it cannot be a literal function here. It
// is already an IIFE EXPRESSION, which is the one string form Playwright
// evaluates correctly — measured: wrapping it with `new Function` and relying
// on `toString` returns `undefined`, because the serialised body opens with
// the file's JSDoc block. So the file is passed through as an expression, and
// the shape that makes that work is asserted rather than assumed: if someone
// turns snapshot.js into a declaration or a module, this must say so and
// stop, not return undefined on every route.
function snapshotExpression() {
  const src = readFileSync(join(HERE, 'snapshot.js'), 'utf8').trim().replace(/;$/, '')
  if (!/\)\s*\(\s*\)$/.test(src)) {
    throw new Error(
      'snapshot.js must remain a self-invoking expression ending in `})()`: it is handed to ' +
        'page.evaluate() as an expression, and any other shape evaluates to undefined silently.',
    )
  }
  return src
}

// What "the page changed" means. Deliberately coarse and deliberately biased
// toward reporting change: a false "it changed" loses one dead-control
// finding, a false "it did not" invents a defect on a working button.
const FINGERPRINT_FN = () => {
  const root = document.getElementById('root')
  const text = (document.body && document.body.innerText) || ''
  let hash = 0
  for (let i = 0; i < Math.min(text.length, 4000); i++) {
    hash = ((hash << 5) - hash + text.charCodeAt(i)) | 0
  }
  return {
    url: window.location.href,
    rootChildren: root ? root.children.length : -1,
    nodes: document.querySelectorAll('*').length,
    interactive: document.querySelectorAll('[data-jev-idx]').length,
    textLength: text.length,
    textHash: hash,
    dialogs: document.querySelectorAll('[role="dialog"], dialog[open], [aria-modal="true"]').length,
  }
}

const RENDER_FN = () => {
  const root = document.getElementById('root')
  if (!root) return { rendered: false, reason: 'no #root element in the document' }
  if (root.children.length === 0) {
    return { rendered: false, reason: '#root has no children — the SPA did not mount' }
  }
  const text = (document.body.innerText || '').trim()
  if (text.length < 40) {
    return { rendered: false, reason: `rendered tree carries only ${text.length} characters of text` }
  }
  // The offline failure mode that matters: ProtectedRoute parks on a
  // PixelLoader labelled "Signing in" when the OIDC issuer is unreachable.
  // A page showing nothing but a loading gate answered and did not render.
  if (/^(signing in|loading)[.\s]*$/i.test(text)) {
    return { rendered: false, reason: `stuck on a loading gate: ${text.slice(0, 60)}` }
  }
  return { rendered: true, reason: '', textLength: text.length }
}

// React's own boundary copy, react-router's default error element, and the
// crash cards this dashboard renders itself (views/AuditTrail.tsx,
// views/Settings.tsx, views/Compliance.tsx, pages/FrameworkDetailPage.tsx).
const BOUNDARY_FN = () => {
  const text = document.body.innerText || ''
  const needles = [
    'Something went wrong',
    'Unexpected Application Error',
    'Application error',
    'A client-side exception has occurred',
    'The above error occurred in',
    'Error boundary caught',
  ]
  for (const needle of needles) {
    const at = text.indexOf(needle)
    if (at >= 0) return text.slice(at, at + 240).replace(/\s+/g, ' ')
  }
  return null
}

// ── Session seeding ───────────────────────────────────────────────────────
//
// See the limits note in the header: this makes the app renderable offline, it
// does not test authentication.
function sessionSeedScript(origin) {
  return ({ o }) => {
    try {
      const now = Math.floor(Date.now() / 1000)
      window.localStorage.setItem('sl_demo_mode', 'true')
      // The superadmin-only pages (RBAC Analysis, Cryptography, Federated
      // Services, Collusion & Access, the AgentMaxxing console) are a real
      // part of the route surface; without this they redirect and the walk
      // reports them as answered-not-rendered for a reason that is the
      // harness's fault rather than the app's.
      window.localStorage.setItem('signalloom.superadmin', 'true')
      window.localStorage.setItem('sl_onboarding_skipped', JSON.stringify({ skippedAt: Date.now() }))
      window.localStorage.setItem(
        `oidc.user:${o}/dex:signalloom-dashboard`,
        JSON.stringify({
          id_token: 'jev.exploratory.bot',
          access_token: 'jev.exploratory.bot',
          token_type: 'Bearer',
          scope: 'openid profile email groups',
          profile: {
            sub: 'demo-user',
            email: 'demo-user@signalloom.local',
            preferred_username: 'demo-user',
            name: 'demo-user',
            groups: ['superadmin', 'signalloom-superadmins', 'signalloom-admins'],
          },
          expires_at: now + 86400,
        }),
      )
    } catch {
      /* storage unavailable: the run will report the routes as unrendered,
         which is the honest outcome rather than a silent pass */
    }
  }
}

function faultScript() {
  return ({ kind }) => {
    if (kind === 'pageerror') {
      setTimeout(() => {
        throw new Error('JEV_PLANTED_PAGE_FAULT: synthetic uncaught exception for oracle verification')
      }, 50)
    } else {
      // Deferred one tick so it lands after the page's own console wiring,
      // which is where a real runtime error would come from too.
      setTimeout(() => {
        console.error('JEV_PLANTED_CONSOLE_FAULT: synthetic console error for oracle verification')
      }, 50)
    }
  }
}

// ── Decision transport ────────────────────────────────────────────────────

class PythonDecider {
  constructor({ script, mock }) {
    this.script = script
    this.mock = mock
    this.proc = null
    this.queue = []
    this.buffer = ''
    this.nextId = 1
  }

  async start() {
    const { spawn } = await import('node:child_process')
    const args = [this.script]
    if (this.mock) args.push('--mock')
    this.proc = spawn('python3', args, { stdio: ['pipe', 'pipe', 'inherit'] })
    this.proc.stdout.setEncoding('utf8')
    this.proc.stdout.on('data', (chunk) => this._consume(chunk))
    this.proc.on('exit', (code) => {
      const err = new Error(`decide_server.py exited with code ${code}`)
      while (this.queue.length > 0) this.queue.shift().reject(err)
    })
  }

  _consume(chunk) {
    this.buffer += chunk
    let newline
    while ((newline = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, newline).trim()
      this.buffer = this.buffer.slice(newline + 1)
      if (!line) continue
      const waiter = this.queue.shift()
      if (!waiter) continue
      try {
        const parsed = JSON.parse(line)
        if (parsed.error) waiter.reject(new Error(parsed.error))
        else waiter.resolve(parsed)
      } catch (err) {
        waiter.reject(err)
      }
    }
  }

  decide(request) {
    const id = this.nextId++
    const payload = JSON.stringify({ ...request, id }) + '\n'
    return new Promise((resolve_, reject) => {
      this.queue.push({ resolve: resolve_, reject })
      this.proc.stdin.write(payload)
    })
  }

  async stop() {
    if (!this.proc) return
    this.proc.stdin.end()
    await new Promise((r) => setTimeout(r, 50))
    this.proc.kill('SIGTERM')
  }
}

// ── Reporting helpers ─────────────────────────────────────────────────────

function routeSlug(route) {
  if (route === '/') return 'root'
  return route.replace(/^\//, '').replace(/[^A-Za-z0-9._-]/g, '_')
}

function normalisePath(raw) {
  let path = String(raw || '/')
  if (/^https?:\/\//.test(path)) {
    try {
      path = new URL(path).pathname
    } catch {
      /* leave as-is */
    }
  }
  path = path.split('?')[0].split('#')[0]
  path = path.replace(/\/+$/, '')
  return path || '/'
}

function defect(category, message, url, details) {
  return { category, message, url, timestamp: Date.now() / 1000, details: details || {} }
}

// ── The walk ──────────────────────────────────────────────────────────────

async function exploreRoute({ context, base, route, opts, decider, snapshotFn, prng = Math.random, fuzzPayloads = null }) {
  const baseOrigin = new URL(base).origin
  const started = Date.now()
  const deadline = started + opts.timeout * 1000

  const consoleErrors = []
  const consoleNetworkEchoes = []
  const pageErrors = []
  const apiFailures = []
  const backendAbsent = []
  const actions = []
  const deadControls = []
  const visitedUrls = new Set()

  const page = await context.newPage()

  const syntheticAborts = new Set()
  if (opts.networkJitter || opts.chaos) {
    await page.route('**', async (routeObj) => {
      const req = routeObj.request()
      const url = req.url()
      const resourceType = req.resourceType()
      // Only jitter API and data endpoints, never core HTML, CSS, images, icons, or JS bundle/module loads
      const isStatic = (
        resourceType === 'image' ||
        resourceType === 'font' ||
        resourceType === 'stylesheet' ||
        resourceType === 'script' ||
        url.includes('/assets/') ||
        url.includes('/icons/') ||
        url.includes('/brand/') ||
        url.endsWith('.svg') ||
        url.endsWith('.png') ||
        url.endsWith('.jpg') ||
        url.endsWith('.js') ||
        url.endsWith('.css') ||
        url.includes('/src/') ||
        url.includes('/node_modules/') ||
        url.includes('/@')
      )
      if (
        !isStatic &&
        (resourceType === 'fetch' || resourceType === 'xhr') &&
        (
          url.includes('/api/') ||
          url.includes('/v1/') ||
          url.includes('/compliance/') ||
          url.includes('/afm/') ||
          url.includes('/fleet-api/')
        )
      ) {
        const roll = prng()
        if (roll < 0.05) {
          // 5% simulated offline network drop
          syntheticAborts.add(url)
          return routeObj.abort('failed').catch(() => {})
        } else if (roll < 0.10) {
          // 5% simulated rate limit
          return routeObj.fulfill({
            status: 429,
            headers: { 'x-jev-chaos': 'synthetic-fault' },
            contentType: 'application/json',
            body: JSON.stringify({ error: 'rate_limited', message: 'Rate limit exceeded (synthetic chaos)' }),
          }).catch(() => {})
        } else if (roll < 0.35) {
          // 25% latency delay
          const delay = Math.floor(prng() * 800) + 200
          await new Promise((r) => setTimeout(r, delay))
        }
      }
      return routeObj.continue().catch(() => {})
    })
  }

  if (opts.mock) {
    await page.route('**/api/v1/features*', async (routeObj) => {
      await routeObj.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          tenant_id: 'default',
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
        }),
      }).catch(() => {})
    })
    await page.route('**/api/v1/me*', async (routeObj) => {
      await routeObj.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          subject: 'demo-user',
          tenant: 'default',
          email: 'demo-user@signalloom.local',
          superadmin: true,
        }),
      }).catch(() => {})
    })
    await page.route('**/api/agents/*', async (routeObj) => {
      const url = routeObj.request().url()
      const seg = url.split('/api/agents/')[1]?.split('?')[0] || 'agent-cardvault'
      await routeObj.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          id: seg,
          name: seg,
          status: 'active',
          lifecycle_state: 'active',
          record_class: 'discovered',
          namespace: 'fe-signalloom-agents',
          service_account: `${seg}-sa`,
          identity: {
            spiffe_id: `spiffe://cluster.local/ns/fe-signalloom-agents/sa/${seg}-sa`,
          },
          compliance: {
            score: 92,
            frameworks: ['k8s-cis-benchmark', 'soc2'],
          },
          compliance_summary: {
            total_controls: 10,
            passing: 8,
            failing: 1,
            pending: 1,
            posture_score: 85,
          },
          runtime: {
            pod_name: `${seg}-1d5f7`,
            namespace: 'fe-signalloom-agents',
            node: 'worker-node-1',
          },
          violations: [],
        }),
      }).catch(() => {})
    })
    await page.route('**/api/audit*', async (routeObj) => {
      await routeObj.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ events: [], total: 0 }),
      }).catch(() => {})
    })
    await page.route('**/api/compliance/posture*', async (routeObj) => {
      await routeObj.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ agents: [], overall_score: 95 }),
      }).catch(() => {})
    })
    await page.route('**/api/telemetry/**', async (routeObj) => {
      await routeObj.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ observations: [] }),
      }).catch(() => {})
    })
  }

  if (opts.faultRoute && normalisePath(opts.faultRoute) === normalisePath(route)) {
    await page.addInitScript(faultScript(), { kind: opts.faultKind })
  }

  page.on('console', (msg) => {
    if (msg.type() !== 'error') return
    const text = msg.text().slice(0, 400)
    const entry = { text, location: msg.location?.()?.url || '', url: page.url() }
    // Chromium itself logs `Failed to load resource: the server responded
    // with a status of NNN` for every failed request. That is the NETWORK
    // layer talking, not the application's code, and the `response` handler
    // below already records the same event with its method, status and URL.
    // Counting the echo as a console error would (a) double-count every
    // network failure and (b) attribute the harness's missing backend to the
    // app — measured: a first full run reported 48 CONSOLE_ERRORs that were
    // 48 echoes of the 48 responses already classified BACKEND_ABSENT. The
    // console oracle is for the app's own console.error; these are kept and
    // reported separately so nothing is dropped.
    if (/^Failed to load resource\b/.test(text)) {
      consoleNetworkEchoes.push(entry)
      return
    }
    // Filter expected 401 unauthenticated errors when running under synthetic offline bot token
    if (/status code 401\b/i.test(text) || /\b401 (?:Unauthorized)?\b/i.test(text)) {
      consoleNetworkEchoes.push(entry)
      return
    }
    consoleErrors.push(entry)
  })
  page.on('pageerror', (err) => {
    pageErrors.push({ message: String(err?.message ?? err).slice(0, 400), url: page.url() })
  })
  page.on('response', (response) => {
    const status = response.status()
    if (status < 400) return
    const headers = response.headers()
    if (headers['x-jev-chaos'] === 'synthetic-fault') {
      // Injected by network jitter to test client-side resilience; not an application defect
      return
    }
    // Seeded offline exploration bot uses a synthetic non-JWT token; 401s from real auth-gated endpoints are expected
    if (status === 401) return
    const url = response.url()
    let origin
    try {
      origin = new URL(url).origin
    } catch {
      return
    }
    if (origin !== baseOrigin) return
    const entry = {
      url,
      status,
      method: response.request().method(),
      resource_type: response.request().resourceType(),
      from_route: route,
    }
    // A locally started dashboard proxies /api to a backend that is not
    // running, so these 5xx are an artefact of the harness. Recorded either
    // way; only counted as an application defect when a backend was supposed
    // to be there. 4xx is never excused: a 404 from the app's own API is a
    // finding whether or not a backend is attached.
    if (opts.noBackend && status >= 500) backendAbsent.push(entry)
    else apiFailures.push(entry)
  })
  page.on('requestfailed', (request) => {
    const url = request.url()
    if (syntheticAborts.has(url)) return
    const resourceType = request.resourceType()
    if (resourceType === 'image' || resourceType === 'font' || resourceType === 'stylesheet') return
    let origin
    try {
      origin = new URL(url).origin
    } catch {
      return
    }
    if (origin !== baseOrigin) return
    const failure = request.failure()?.errorText || 'unknown'
    // ERR_ABORTED is what a navigation away from an in-flight request looks
    // like, which an exploratory walk causes constantly by design.
    if (/ERR_ABORTED/.test(failure)) return
    const entry = { url, status: 0, method: request.method(), resource_type: resourceType, failure, from_route: route }
    if (opts.noBackend) backendAbsent.push(entry)
    else apiFailures.push(entry)
  })

  const target = `${base.replace(/\/+$/, '')}${route}`
  let navStatus = 0
  let navError = null
  try {
    const response = await page.goto(target, { waitUntil: 'domcontentloaded', timeout: opts.navTimeout })
    navStatus = response ? response.status() : 0
  } catch (err) {
    navError = String(err?.message ?? err).slice(0, 300)
  }

  await page.waitForLoadState('load', { timeout: Math.min(opts.navTimeout, 20000) }).catch(() => {})
  // Not `networkidle`: the agents dashboard holds a telemetry event-stream
  // open, so idle never arrives once telemetry is wired. Best-effort, then
  // the explicit render predicate below, which is the real gate.
  await page.waitForLoadState('networkidle', { timeout: 3000 }).catch(() => {})

  // Polled rather than handed to `waitForFunction`, because RENDER_FN returns
  // a REASON as well as a verdict and is therefore always truthy —
  // `waitForFunction(RENDER_FN)` would resolve on the first tick whatever the
  // page looked like. Writing the predicate twice (once boolean for the wait,
  // once detailed for the report) is the other option, and two copies of a
  // render definition drift apart silently. So: one definition, polled.
  let render = {
    rendered: false,
    reason: navError ? `navigation failed: ${navError}` : 'render predicate never satisfied',
  }
  const renderDeadline = Date.now() + opts.renderTimeout
  for (;;) {
    try {
      render = await page.evaluate(RENDER_FN)
    } catch (err) {
      render = { rendered: false, reason: `render probe failed: ${String(err?.message ?? err).slice(0, 160)}` }
    }
    if (render.rendered || Date.now() >= renderDeadline) break
    await page.waitForTimeout(250)
  }

  const finalUrl = page.url()
  const finalPath = normalisePath(finalUrl)
  const redirectedTo = finalPath === normalisePath(route) ? null : finalPath

  let boundaryText = null
  let actionSpaceSize = 0

  if (render.rendered) {
    boundaryText = await page.evaluate(BOUNDARY_FN).catch(() => null)

    visitedUrls.add(normalisePath(route))
    visitedUrls.add(finalPath)

    for (let turn = 1; turn <= opts.turns; turn++) {
      if (Date.now() > deadline) {
        actions.push({ turn, operation: 'ABORT', reason: 'per-route time budget exhausted' })
        break
      }

      // Markov random navigation step: stochastic history jump or refresh
      if ((opts.markov || opts.chaos) && turn > 1 && prng() < 0.15) {
        if (prng() < 0.5) {
          await page.goBack({ timeout: 5000 }).catch(() => {})
          actions.push({ turn, operation: 'MARKOV_BACK', target: { name: 'history.back' } })
          continue
        } else {
          await page.reload({ timeout: 5000 }).catch(() => {})
          actions.push({ turn, operation: 'MARKOV_RELOAD', target: { name: 'page.reload' } })
          continue
        }
      }

      let snapshot
      try {
        snapshot = await page.evaluate(snapshotFn)
      } catch (err) {
        actions.push({ turn, operation: 'ABORT', reason: `snapshot failed: ${String(err?.message ?? err).slice(0, 160)}` })
        break
      }
      actionSpaceSize = Math.max(actionSpaceSize, snapshot.elements.length)
      if (snapshot.elements.length === 0) {
        actions.push({ turn, operation: 'DONE', reason: 'no interactive elements in the action space' })
        break
      }

      let decision
      if (decider) {
        decision = await decider
          .decide({
            snapshot: {
              url: snapshot.url,
              title: snapshot.title,
              text: snapshot.text,
              status_code: navStatus,
              elements: snapshot.elements,
            },
            intent: `Explore ${route} in a rendered browser and verify page health`,
            area: route,
            recent_actions: actions.slice(-5),
            visited_urls: [...visitedUrls],
            temperature: opts.temperature,
            seed: opts.seed,
          })
          .catch((err) => ({ operation: 'DONE', target: null, confidence: 0, error: String(err?.message ?? err) }))
      } else {
        decision = heuristicDecide({
          elements: snapshot.elements,
          areaScope: route,
          recentActions: actions,
          visitedUrls,
          url: snapshot.url,
          prng,
          temperature: opts.temperature,
          fuzzInputs: opts.fuzzInputs || opts.chaos,
          fuzzPayloads,
        })
      }

      if (decision.operation === 'DONE' || !decision.target) {
        actions.push({ turn, operation: 'DONE', confidence: decision.confidence ?? null, error: decision.error })
        break
      }

      // The guard is applied HERE as well as inside the decision model. The
      // live model is a remote service: a driver that trusts whatever it
      // returns has no guard at all.
      if (isDestructive(decision.target.name)) {
        actions.push({
          turn,
          operation: 'SKIP_DESTRUCTIVE',
          target: decision.target,
          confidence: decision.confidence ?? null,
        })
        continue
      }

      const effect = await actOn(page, decision, opts, prng, fuzzPayloads)
      actions.push({ turn, ...effect, target: decision.target, confidence: decision.confidence ?? null })
      visitedUrls.add(normalisePath(page.url()))

      if (effect.changed === false && effect.operation !== 'WAIT') {
        // Once is a quiet page; twice is a dead control. Retried immediately
        // and deterministically, because nothing moved — the same element is
        // still there under the same index.
        const retry = await actOn(page, decision, opts, prng, fuzzPayloads)
        actions.push({ turn, ...retry, target: decision.target, confidence: decision.confidence ?? null, retry: true })
        if (retry.changed === false) {
          deadControls.push({
            route,
            url: page.url(),
            role: decision.target.role,
            name: decision.target.name,
            href: decision.target.href ?? null,
            attempts: 2,
          })
        }
      }

      if (!boundaryText) {
        boundaryText = await page.evaluate(BOUNDARY_FN).catch(() => null)
      }
    }
  }

  await page.close().catch(() => {})

  const defects = []
  for (const entry of consoleErrors) {
    defects.push(defect('CONSOLE_ERROR', entry.text, entry.url, { location: entry.location }))
  }
  for (const entry of pageErrors) {
    defects.push(defect('PAGE_ERROR', entry.message, entry.url, {}))
  }
  for (const entry of apiFailures) {
    const category = entry.status === 0 ? 'REQUEST_FAILED' : entry.status >= 500 ? 'API_5XX' : 'API_4XX'
    defects.push(
      defect(category, `${entry.method} ${entry.url} → ${entry.status || entry.failure}`, entry.url, entry),
    )
  }
  if (boundaryText) {
    defects.push(defect('ERROR_BOUNDARY', boundaryText, finalUrl, {}))
  }
  if (!render.rendered) {
    defects.push(defect('ROUTE_NOT_RENDERED', render.reason || 'route answered but did not render', finalUrl, { navStatus }))
  }
  if (navStatus >= 500) {
    defects.push(defect('HTTP_5XX_SERVER_ERROR', `HTTP ${navStatus} on the document request`, target, { status_code: navStatus }))
  }
  if (opts.failOnDeadControl) {
    for (const entry of deadControls) {
      defects.push(defect('DEAD_CONTROL', `${entry.role} "${entry.name}" produced no DOM or URL change in two clicks`, entry.url, entry))
    }
  }

  const pathStatus = {}
  pathStatus[normalisePath(route)] = navStatus
  if (redirectedTo) pathStatus[redirectedTo] = navStatus

  return {
    // bot.py's report shape, so loop_report.py needs no second code path.
    target_url: base,
    area_scope: route,
    seed: opts.seed,
    temperature: opts.temperature,
    chaos: Boolean(opts.chaos),
    turns_executed: actions.filter((a) => a.operation !== 'ABORT').length,
    duration_seconds: Math.round(((Date.now() - started) / 1000) * 100) / 100,
    visited_urls: [...visitedUrls],
    visited_paths: [normalisePath(route)],
    path_status: pathStatus,
    defects_count: defects.length,
    defects,
    passed: defects.length === 0,
    mode: opts.mock ? 'browser_simulated_jev' : 'browser_live_jev',
    // ── browser-only fields ──
    rendered: Boolean(render.rendered),
    render_reason: render.rendered ? '' : render.reason || '',
    final_url: finalUrl,
    redirected_to: redirectedTo,
    document_status: navStatus,
    console_errors: consoleErrors,
    console_network_echoes: consoleNetworkEchoes,
    console_errors_observable: true,
    page_errors: pageErrors,
    api_failures: apiFailures,
    backend_absent: backendAbsent,
    boundary_text: boundaryText,
    dead_controls: deadControls,
    actions,
    actions_executed: actions.filter((a) => a.operation === 'CLICK' || a.operation === 'TYPE_TEXT' || a.operation === 'SELECT').length,
    action_space_size: actionSpaceSize,
  }
}

async function actOn(page, decision, opts, prng = Math.random, fuzzPayloads = null) {
  const before = await page.evaluate(FINGERPRINT_FN).catch(() => null)
  const selector = `[data-jev-idx="${decision.target.index}"]`
  const operation = decision.operation === 'TYPE_TEXT' || decision.operation === 'SELECT' ? decision.operation : 'CLICK'

  let error = null
  let payloadUsed = null
  try {
    const locator = page.locator(selector).first()
    if (operation === 'TYPE_TEXT') {
      const payload = decision.payload != null ? decision.payload : sampleFuzzPayload(fuzzPayloads, prng)
      payloadUsed = String(payload)
      await locator.fill(payloadUsed, { timeout: opts.actionTimeout })
    } else if (operation === 'SELECT') {
      await locator.selectOption({ index: 1 }, { timeout: opts.actionTimeout })
    } else {
      if ((opts.clickStorm || opts.chaos) && isStormable(decision.target.name)) {
        const stormCount = Math.floor(prng() * 3) + 3 // 3 to 5 rapid burst clicks
        for (let i = 0; i < stormCount; i++) {
          await locator.click({ timeout: opts.actionTimeout, noWaitAfter: true }).catch(() => {})
          await new Promise((r) => setTimeout(r, 30))
        }
      } else {
        // `noWaitAfter` keeps a click that triggers a navigation from being
        // charged the full navigation timeout here; the settle below is what
        // waits, and it waits the same amount whatever the click did.
        await locator.click({ timeout: opts.actionTimeout, noWaitAfter: true })
      }
    }
  } catch (err) {
    error = String(err?.message ?? err).split('\n')[0].slice(0, 200)
  }

  await page.waitForTimeout(opts.settleMs)
  await page.waitForLoadState('domcontentloaded', { timeout: 5000 }).catch(() => {})
  const after = await page.evaluate(FINGERPRINT_FN).catch(() => null)

  // No fingerprint means the page is mid-navigation or gone — treat as
  // changed. Calling that "no change" would invent a dead control out of a
  // control that worked so well the page went away.
  let changed = true
  if (before && after) {
    changed =
      before.url !== after.url ||
      before.rootChildren !== after.rootChildren ||
      before.nodes !== after.nodes ||
      before.textLength !== after.textLength ||
      before.textHash !== after.textHash ||
      before.dialogs !== after.dialogs
  }

  return { operation, changed, error, payload: payloadUsed, url_before: before?.url ?? null, url_after: after?.url ?? null }
}

// ── Entry point ───────────────────────────────────────────────────────────

function parseArgs(argv) {
  const opts = {
    base: '',
    routes: '',
    outDir: '',
    turns: 4,
    timeout: 30,
    navTimeout: 30000,
    renderTimeout: 20000,
    actionTimeout: 5000,
    settleMs: 500,
    seed: null,
    temperature: 1.0,
    duration: 0,
    chaos: false,
    fuzzInputs: false,
    clickStorm: false,
    networkJitter: false,
    markov: false,
    mock: false,
    decider: '',
    profileDir: process.env.JEV_BROWSER_PROFILE_DIR || '',
    noBackend: false,
    failOnDeadControl: false,
    stopOnError: false,
    channel: '',
    faultRoute: process.env.JEV_FAULT_ROUTE || '',
    faultKind: process.env.JEV_FAULT_KIND || 'console',
    checkRuntime: false,
  }
  const numeric = {
    '--turns': 'turns',
    '--timeout': 'timeout',
    '--duration': 'duration',
    '--nav-timeout': 'navTimeout',
    '--render-timeout': 'renderTimeout',
    '--action-timeout': 'actionTimeout',
    '--settle-ms': 'settleMs',
    '--seed': 'seed',
    '--temperature': 'temperature',
  }
  const strings = {
    '--base': 'base',
    '--routes': 'routes',
    '--out-dir': 'outDir',
    '--decider': 'decider',
    '--profile-dir': 'profileDir',
    '--channel': 'channel',
    '--fault-route': 'faultRoute',
    '--fault-kind': 'faultKind',
  }
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg in numeric) {
      opts[numeric[arg]] = Number(argv[++i])
      continue
    }
    if (arg in strings) {
      opts[strings[arg]] = argv[++i]
      continue
    }
    switch (arg) {
      case '--chaos': opts.chaos = true; break
      case '--fuzz-inputs': opts.fuzzInputs = true; break
      case '--click-storm': opts.clickStorm = true; break
      case '--network-jitter': opts.networkJitter = true; break
      case '--markov': opts.markov = true; break
      case '--mock': opts.mock = true; break
      case '--no-backend': opts.noBackend = true; break
      case '--fail-on-dead-control': opts.failOnDeadControl = true; break
      case '--stop-on-error': opts.stopOnError = true; break
      case '--check-runtime': opts.checkRuntime = true; break
      case '-h':
      case '--help': opts.help = true; break
      default:
        throw new Error(`unknown option '${arg}'`)
    }
  }
  if (!opts.decider) opts.decider = opts.mock ? 'js' : 'python'
  if (opts.chaos) {
    opts.fuzzInputs = true
    opts.clickStorm = true
    opts.networkJitter = true
    opts.markov = true
  }
  return opts
}

export async function main(argv) {
  let opts
  try {
    opts = parseArgs(argv)
  } catch (err) {
    process.stderr.write(`browser_driver: ${err.message}\n`)
    return 2
  }

  if (opts.help) {
    process.stdout.write(readFileSync(fileURLToPath(import.meta.url), 'utf8').split('*/')[0] + '\n')
    return 0
  }

  if (opts.checkRuntime) {
    try {
      process.stdout.write((await checkRuntime()) + '\n')
      return 0
    } catch (err) {
      process.stdout.write(`${err.message}\n`)
      return 1
    }
  }

  if (!opts.base || !opts.routes || !opts.outDir) {
    process.stderr.write('browser_driver: --base, --routes and --out-dir are all required\n')
    return 2
  }

  const routes = readFileSync(opts.routes, 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#'))
  if (routes.length === 0) {
    process.stderr.write(`browser_driver: empty route list ${opts.routes}\n`)
    return 2
  }

  const seed = opts.seed != null ? opts.seed : (process.env.JEV_SEED ? Number(process.env.JEV_SEED) : Math.floor(Date.now() % 1000000))
  opts.seed = seed
  const prng = createPrng(seed)
  const fuzzPayloads = loadFuzzPayloads()
  process.stderr.write(
    `[jev-browser] seed=${seed} temp=${opts.temperature} chaos=${opts.chaos} ` +
      `jitter=${opts.networkJitter} inputs=${opts.fuzzInputs} storm=${opts.clickStorm} markov=${opts.markov}\n`,
  )

  const { chromium } = await loadChromium()
  const profileDir = opts.profileDir || join(tmpdir(), `jev-browser-${process.pid}`)
  mkdirSync(profileDir, { recursive: true })
  mkdirSync(opts.outDir, { recursive: true })

  // One persistent context per iteration, rooted in the run's own profile
  // directory, so a run never reads or writes a developer's Chrome profile and
  // two concurrent runs cannot share cookies or localStorage.
  const context = await chromium.launchPersistentContext(profileDir, {
    headless: true,
    ignoreHTTPSErrors: true,
    permissions: ['clipboard-read', 'clipboard-write'],
    ...(opts.channel ? { channel: opts.channel } : {}),
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
  await context.addInitScript(sessionSeedScript(), { o: new URL(opts.base).origin })

  let decider = null
  if (opts.decider === 'python') {
    decider = new PythonDecider({ script: join(HERE, 'decide_server.py'), mock: opts.mock })
    await decider.start()
  }

  const snapshotFn = snapshotExpression()
  let index = 0
  let defectTotal = 0
  let rendered = 0
  const notRendered = []

  const startTime = Date.now()
  const durationMs = opts.duration ? Number(opts.duration) * 1000 : null

  try {
    let routeIdx = 0
    while (routeIdx < routes.length) {
      if (durationMs && (Date.now() - startTime) >= durationMs) {
        process.stderr.write(`[jev-browser] duration limit of ${opts.duration}s reached\n`)
        break
      }
      const route = routes[routeIdx]
      routeIdx += 1
      index += 1
      const report = await exploreRoute({ context, base: opts.base, route, opts, decider, snapshotFn, prng, fuzzPayloads })
      const out = join(opts.outDir, `${String(index).padStart(3, '0')}-${routeSlug(route)}.json`)
      writeFileSync(out, JSON.stringify(report, null, 2) + '\n')
      defectTotal += report.defects_count
      if (report.rendered) rendered += 1
      else notRendered.push(`${route} (${report.render_reason})`)
      const elapsedSec = Math.round((Date.now() - startTime) / 1000)
      process.stderr.write(
        `[jev-browser] [${elapsedSec}s] ${route} → ${report.rendered ? 'RENDERED' : 'NOT RENDERED'} ` +
          `status=${report.document_status} controls=${report.action_space_size} ` +
          `acted=${report.actions_executed} defects=${report.defects_count}` +
          `${report.redirected_to ? ` redirected→${report.redirected_to}` : ''}\n`,
      )
      if (opts.stopOnError && defectTotal > 0) {
        process.stderr.write('[jev-browser] stopping: --stop-on-error and a defect was recorded\n')
        break
      }
      if (routeIdx >= routes.length && durationMs && (Date.now() - startTime) < durationMs) {
        routeIdx = 0 // continuous walk across surface until duration is reached
      }
    }
  } finally {
    if (decider) await decider.stop()
    await context.close().catch(() => {})
  }

  process.stderr.write(
    `[jev-browser] ${rendered}/${routes.length} routes rendered, ${defectTotal} defect(s)\n`,
  )
  if (notRendered.length > 0) {
    process.stderr.write(`[jev-browser] answered but not rendered:\n  ${notRendered.join('\n  ')}\n`)
  }
  // 0 clean, 1 defects found. The caller aggregates; a non-zero here must not
  // stop the loop from reporting what it saw.
  return defectTotal > 0 ? 1 : 0
}

// Importable without side effects, so the destructive guard and the ported
// heuristic can be unit-tested without a browser or a Playwright install.
if (
  process.argv[1] &&
  resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))
) {
  process.exitCode = await main(process.argv.slice(2))
}
