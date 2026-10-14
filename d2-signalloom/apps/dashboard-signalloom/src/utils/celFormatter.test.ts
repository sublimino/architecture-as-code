import { describe, it, expect } from 'vitest'
import { prettifyCel } from './celFormatter'
import { parse } from '@marcbachmann/cel-js'

describe('prettifyCel utility', () => {
  it('returns empty string or comments untouched', () => {
    expect(prettifyCel('')).toBe('')
    expect(prettifyCel('   ')).toBe('   ')
    expect(prettifyCel('/* Cluster audit comment */')).toBe('/* Cluster audit comment */')
  })

  it('keeps short atomic expressions on one line', () => {
    const expr = 'object.spec.automountServiceAccountToken == false'
    expect(prettifyCel(expr)).toBe('object.spec.automountServiceAccountToken == false')
  })

  it('splits long expressions joined by logical AND (&&) across lines with 2-space indentation', () => {
    const expr =
      '(!has(object.spec.hostPID) || object.spec.hostPID == false) && (!has(object.spec.hostIPC) || object.spec.hostIPC == false) && (!has(object.spec.hostNetwork) || object.spec.hostNetwork == false)'
    const prettified = prettifyCel(expr)
    expect(prettified).toContain('\n  && ')
    expect(prettified.split('\n').length).toBeGreaterThanOrEqual(3)

    // Verify parsed AST still parses without syntax error
    expect(() => parse(prettified)).not.toThrow()
  })

  it('formats ternary expressions with ? and : on separate lines', () => {
    const expr =
      "request.tool_call.action in ['exec', 'write_file'] ? (has(request.context.claims) && request.context.claims.exists(c, c.valid == true)) : true"
    const prettified = prettifyCel(expr)
    expect(prettified).toContain('\n  ? ')
    expect(prettified).toContain('\n  : true')
    expect(() => parse(prettified)).not.toThrow()
  })

  it('is idempotent on already-formatted code', () => {
    const expr =
      '(!has(object.spec.hostPID) || object.spec.hostPID == false) && (!has(object.spec.hostIPC) || object.spec.hostIPC == false)'
    const pass1 = prettifyCel(expr)
    const pass2 = prettifyCel(pass1)
    expect(pass2).toBe(pass1)
  })

  it('preserves string literals with spaces and quotes', () => {
    const expr = 'has(request.peer.spiffe_id) && request.peer.spiffe_id.startsWith("spiffe://signalloom.demo/ns/")'
    const prettified = prettifyCel(expr)
    expect(prettified).toContain('"spiffe://signalloom.demo/ns/"')
  })
})
