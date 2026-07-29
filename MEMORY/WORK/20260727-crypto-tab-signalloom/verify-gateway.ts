// Verify the Dex login flow through the Envoy Ingress Gateway (port 18443).
import { spawn } from 'node:child_process'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const PORT = 9227
const userDir = mkdtempSync(join(tmpdir(), 'cdp-gw-'))
const GW = 'https://dashboard.osramp.acme.local:18443'
const chrome = spawn('/opt/google/chrome/chrome', [
  '--headless=new', '--no-sandbox', '--disable-gpu', `--remote-debugging-port=${PORT}`,
  `--user-data-dir=${userDir}`, '--no-first-run', '--no-default-browser-check',
  '--ignore-certificate-errors', '--hide-scrollbars', '--window-size=1440,1200',
  `--host-resolver-rules=MAP dashboard.osramp.acme.local 127.0.0.1`,
], { stdio: 'ignore' })
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms))
let nextId = 1; const pending = new Map<number, (v: any) => void>()

async function wsUrl() {
  for (let i = 0; i < 40; i++) {
    try { const r = await fetch(`http://localhost:${PORT}/json/new?about:blank`, { method: 'PUT' }); if (r.ok) return (await r.json()).webSocketDebuggerUrl } catch {}
    await sleep(250)
  }
  throw new Error('no cdp')
}

async function main() {
  const ws = new WebSocket(await wsUrl()); await new Promise(res => ws.addEventListener('open', res, { once: true }))
  ws.addEventListener('message', e => { const m = JSON.parse(e.data as string); if (m.id && pending.has(m.id)) { pending.get(m.id)!(m); pending.delete(m.id) } })
  const send = (method: string, params: any = {}) => new Promise<any>((res, rej) => { const id = nextId++; pending.set(id, m => m.error ? rej(new Error(JSON.stringify(m.error))) : res(m.result)); ws.send(JSON.stringify({ id, method, params })) })
  const ev = async (x: string) => (await send('Runtime.evaluate', { expression: x, returnByValue: true, awaitPromise: true })).result?.value
  await send('Page.enable'); await send('Runtime.enable')

  // Navigate to Gateway URL — should redirect to Dex login
  await send('Page.navigate', { url: `${GW}/cryptography` }); await sleep(4000)
  let loc = String(await ev('document.location.href'))
  console.log('[gw] initial url:', loc)

  const hasDexForm = loc.includes('/dex')
  if (hasDexForm) {
    console.log('[gw] Dex login form detected, authenticating...')
    await ev(`(() => { const l=document.querySelector('input[name=login]'); const p=document.querySelector('input[name=password]'); if(l)l.value='demo-user@signalloom.local'; if(p)p.value='demo-user'; const b=document.querySelector('#submit-login'); if(b)b.click(); })()`)
    await sleep(5000)
  }

  // After auth, navigate to /cryptography through the gateway
  await send('Page.navigate', { url: `${GW}/cryptography` })
  let heading = ''
  for (let i = 0; i < 20; i++) {
    await sleep(700)
    heading = await ev(`document.querySelector('h1') ? document.querySelector('h1').textContent : ''`)
    if (heading && heading.includes('Cryptography')) break
  }

  const nav = String(await ev(`(() => { const n=document.querySelector('nav'); return n? n.innerText : '' })()`))
  const body = String(await ev('document.body ? document.body.innerText : ""'))
  const finalUrl = await ev('document.location.href')

  const shot = await send('Page.captureScreenshot', { format: 'png' })
  await Bun.write('/tmp/gateway-cryptography.png', Buffer.from(shot.data, 'base64'))

  const report = {
    gateway: GW,
    dexLoginDetected: hasDexForm,
    finalUrl,
    heading,
    authenticated: heading === 'Cryptography',
    sidebarTabs: ['Agents', 'Compliance', 'Audit Trail', 'Cryptography', 'Federated Services', 'Collusion & Access', 'Settings'].filter(t => nav.includes(t)),
    sampleContent: body.includes('Cluster Root of Trust'),
    screenshot: '/tmp/gateway-cryptography.png',
  }
  console.log('GATEWAY_REPORT=' + JSON.stringify(report, null, 2))
  chrome.kill(); process.exit(report.authenticated ? 0 : 1)
}
main().catch(e => { console.error('GATEWAY_ERROR', e); chrome.kill(); process.exit(1) })
