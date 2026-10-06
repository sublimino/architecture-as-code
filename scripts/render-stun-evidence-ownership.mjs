#!/usr/bin/env node
import { readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'

const root = resolve(import.meta.dirname, '..')
const source = resolve(root, 'docs/signalloom/stun-evidence-ownership.json')
const destination = resolve(root, 'docs/signalloom/stun-evidence-ownership.md')
const check = process.argv.includes('--check')
const report = JSON.parse(readFileSync(source, 'utf8'))
const columns = [
  'store',
  'physical location',
  'writing process',
  'managedFields manager observed on the live cluster',
  'inside-or-outside the reconciled set',
  'what deletes or reverts it',
  'worst-case lifetime',
  'evidence class',
]

const cell = value => String(value).replaceAll('|', '\\|').replaceAll('\n', '<br>')
const table = [
  `| ${columns.join(' | ')} |`,
  `| ${columns.map(() => '---').join(' | ')} |`,
  ...report.rows.map(row => `| ${columns.map(column => cell(row[column])).join(' | ')} |`),
].join('\n')
const sections = report.sections.map(({ heading, body }) => `## ${heading}\n\n${body}`).join('\n\n')
const rendered = `# Signal Loom containment-evidence ownership\n\n` +
  `Generated from [stun-evidence-ownership.json](stun-evidence-ownership.json) by ` +
  '`node scripts/render-stun-evidence-ownership.mjs` — do not hand-edit this file.\n\n' +
  `${report.introduction}\n\n## Classification\n\n${table}\n\n${sections}\n`

if (check) {
  if (readFileSync(destination, 'utf8') !== rendered) {
    console.error(`${destination} is not generated from ${source}`)
    process.exit(1)
  }
} else {
  writeFileSync(destination, rendered)
}
