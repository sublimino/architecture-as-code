import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

// jev browser loop, /distance-latency: "Run Act N" -> POST
// /demo-api/distancelatency/runs -> 404. The deployed dashboard serves
// /demo-api/ through nginx (location /demo-api/ -> demo runner); the vite dev
// server had no proxy for it, so vite itself answered 404 — a response the
// product never gives. Every demo-runner client base must be dev-proxied the
// same way nginx proxies it.
//
// vite.config.ts is read as text: importing it pulls vite and its plugins into
// the jsdom test environment, which esbuild refuses to run in.
const APP = join(__dirname, '..')
const DEMO_CLIENTS = ['src/api/distanceLatencyDemo.ts', 'src/api/signalFusionDemo.ts', 'src/api/demoRunner.ts']

function demoBases(): string[] {
  const bases = new Set<string>()
  for (const rel of DEMO_CLIENTS) {
    const src = readFileSync(join(APP, rel), 'utf8')
    for (const m of src.matchAll(/['`](\/demo-api)(?:\/[a-z]*)?['`/]/g)) bases.add(m[1])
  }
  return [...bases]
}

function viteProxy(): Record<string, string> {
  const cfg = readFileSync(join(APP, 'vite.config.ts'), 'utf8')
  const block = cfg.match(/proxy:\s*\{([\s\S]*?)\n\s*\},/)
  expect(block, 'server.proxy block in vite.config.ts').not.toBeNull()
  const out: Record<string, string> = {}
  for (const m of block![1].matchAll(/^\s*'([^']+)':\s*'([^']+)'/gm)) out[m[1]] = m[2]
  return out
}

describe('vite dev proxy parity with nginx', () => {
  it('nginx proxies /demo-api/ and the demo clients call it', () => {
    const nginx = readFileSync(join(APP, 'nginx.conf'), 'utf8')
    expect(nginx).toMatch(/location \/demo-api\/ \{[\s\S]*?proxy_pass/)
    expect(demoBases()).toEqual(['/demo-api'])
  })

  it('the vite dev server proxies every demo-runner base to the same upstream as /api', () => {
    const proxy = viteProxy()
    expect(proxy['/api']).toMatch(/^http:\/\//)
    for (const base of demoBases()) {
      expect(Object.keys(proxy), base).toContain(base)
      expect(proxy[base], base).toBe(proxy['/api'])
    }
  })
})
