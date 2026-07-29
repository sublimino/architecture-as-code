// Headless-Chrome CDP verifier for the Cryptography page (Interceptor not on Linux).
// Launches Chrome, drives the Dex OIDC login with demo creds, and screenshots
// the authenticated /cryptography route.
import { spawn } from 'node:child_process'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const URL = 'http://localhost:5173/cryptography'
const OUT = process.argv[2] ?? '/tmp/cryptography.png'
const PORT = 9224
const userDir = mkdtempSync(join(tmpdir(), 'cdp-'))

const chrome = spawn('/opt/google/chrome/chrome', [
  '--headless=new', '--no-sandbox', '--disable-gpu', `--remote-debugging-port=${PORT}`,
  `--user-data-dir=${userDir}`, '--no-first-run', '--no-default-browser-check',
  '--hide-scrollbars', '--window-size=1440,2400',
], { stdio: 'ignore' })

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

async function wsUrl(): Promise<string> {
  for (let i = 0; i < 40; i++) {
    try {
      const r = await fetch(`http://localhost:${PORT}/json/new?about:blank`, { method: 'PUT' })
      if (r.ok) return (await r.json()).webSocketDebuggerUrl
    } catch { /* not up yet */ }
    await sleep(250)
  }
  throw new Error('CDP endpoint never came up')
}

let nextId = 1
const pending = new Map<number, (v: any) => void>()

function makeClient(ws: WebSocket) {
  ws.addEventListener('message', (e) => {
    const msg = JSON.parse(e.data as string)
    if (msg.id && pending.has(msg.id)) { pending.get(msg.id)!(msg); pending.delete(msg.id) }
  })
  return (method: string, params: any = {}) =>
    new Promise<any>((res, rej) => {
      const id = nextId++
      pending.set(id, (m) => (m.error ? rej(new Error(method + ': ' + JSON.stringify(m.error))) : res(m.result)))
      ws.send(JSON.stringify({ id, method, params }))
    })
}

async function evalJs(send: any, expression: string) {
  const r = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true })
  return r.result?.value
}

async function main() {
  const url = await wsUrl()
  const ws = new WebSocket(url)
  await new Promise((res) => ws.addEventListener('open', res, { once: true }))
  const send = makeClient(ws)
  await send('Page.enable'); await send('Runtime.enable')

  await send('Page.navigate', { url: URL })
  await sleep(3500)

  // Handle Dex login if we landed on it.
  let loc = await evalJs(send, 'document.location.href')
  if (String(loc).includes('/dex')) {
    console.log('[verify] on Dex login:', loc)
    await evalJs(send, `(() => {
      const l = document.querySelector('input[name=login]'); const p = document.querySelector('input[name=password]');
      if (l) l.value = 'demo-user@signalloom.local'; if (p) p.value = 'demo-user';
      const b = document.querySelector('#submit-login') || document.querySelector('button[type=submit]');
      if (b) b.click(); else if (l && l.form) l.form.submit();
    })()`)
    await sleep(4000)
    // Possible Dex consent/grant screen.
    loc = await evalJs(send, 'document.location.href')
    const grant = await evalJs(send, `(() => { const b=[...document.querySelectorAll('button,input[type=submit]')].find(x=>/grant|approve|access/i.test(x.textContent||x.value||'')); if(b){b.click();return true} return false })()`)
    if (grant) { console.log('[verify] clicked Dex grant'); await sleep(3000) }
  }

  // Ensure we are on /cryptography (onSigninCallback forces /agents).
  await send('Page.navigate', { url: URL })
  // Poll for the page heading to render.
  let heading = ''
  for (let i = 0; i < 30; i++) {
    await sleep(700)
    heading = await evalJs(send, `document.querySelector('h1') ? document.querySelector('h1').textContent : ''`)
    if (heading && heading.includes('Cryptography')) break
  }
  const bodyText = await evalJs(send, 'document.body ? document.body.innerText : ""')
  const navText = await evalJs(send, `(() => { const n=document.querySelector('nav'); return n? n.innerText : '' })()`)
  const height = await evalJs(send, 'Math.min(document.body.scrollHeight, 3000)')
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: Math.max(900, height), deviceScaleFactor: 1, mobile: false })
  const shot = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true })
  await Bun.write(OUT, Buffer.from(shot.data, 'base64'))

  const sections = ['Cluster Root of Trust', 'OpenBao Bootstrap', 'SPIFFE / SPIRE Bootstrap', 'Cipher Discovery (PQC)', 'OAuth2 / MCP Proxies']
  const report = {
    finalUrl: await evalJs(send, 'document.location.href'),
    heading,
    navHasCryptography: String(navText).includes('Cryptography'),
    sectionsPresent: sections.filter((s) => String(bodyText).includes(s)),
    sampleSvid: String(bodyText).includes('spiffe://signalloom.svc.cluster.local'),
    sealStatus: String(bodyText).includes('unsealed'),
    screenshot: OUT,
  }
  console.log('VERIFY_REPORT=' + JSON.stringify(report, null, 2))
  chrome.kill()
  process.exit(0)
}

main().catch((e) => { console.error('VERIFY_ERROR', e); chrome.kill(); process.exit(1) })
