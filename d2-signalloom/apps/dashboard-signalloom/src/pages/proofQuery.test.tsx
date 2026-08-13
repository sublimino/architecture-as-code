import { describe, it, expect } from 'vitest'
import { curlPipeJq, jqOutput, jqString, shellQuote } from './proofQuery'

describe('proofQuery', () => {
  describe('jqOutput', () => {
    it('prints one match the way jq pretty-prints an object', () => {
      expect(jqOutput([{ name: 'a', port: 8000 }])).toBe('{\n  "name": "a",\n  "port": 8000\n}')
    })

    it('renders an absent field as null, because that is what jq does', () => {
      // A dropped key would print a SHORTER object than the command above it
      // prints, which is the quiet divergence this module exists to prevent.
      expect(jqOutput([{ name: 'a', lastRun: undefined }])).toContain('"lastRun": null')
    })

    it('prints every match, not only the first', () => {
      // `.array[] | select(...)` is a stream. Showing one object under a
      // command that emits two is a truthful object under an untruthful claim.
      const out = jqOutput([{ n: 1 }, { n: 2 }])
      expect(out).toBe('{\n  "n": 1\n}\n{\n  "n": 2\n}')
    })

    it('prints nothing when nothing matched', () => {
      expect(jqOutput([])).toBe('')
    })

    it('preserves the key order the projection was written in', () => {
      const out = jqOutput([{ z: 1, a: 2 }])
      expect(out.indexOf('"z"')).toBeLessThan(out.indexOf('"a"'))
    })

    it('keeps nested objects and arrays intact', () => {
      const out = jqOutput([{ src: { namespace: 'ns', name: 'pod' }, verbs: ['get', 'list'] }])
      expect(out).toContain('"namespace": "ns"')
      expect(out).toContain('"get"')
    })
  })

  describe('quoting', () => {
    it('escapes a jq string literal as JSON, because jq strings are JSON strings', () => {
      expect(jqString('a"b')).toBe('"a\\"b"')
    })

    it('survives an apostrophe inside a single-quoted shell word', () => {
      // A command that does not parse is worse than no proof: it looks
      // checkable and is not.
      expect(shellQuote(`it's`)).toBe(`'it'\\''s'`)
    })
  })

  describe('curlPipeJq', () => {
    it('names the endpoint the client calls and the filter it applies', () => {
      expect(curlPipeJq({ path: '/network-tests', filter: '.tests[]', bearer: true })).toBe(
        `curl -s -H "Authorization: Bearer $TOKEN" /network-tests | jq '.tests[]'`,
      )
    })

    it('omits the bearer header on routes the client calls unauthenticated', () => {
      expect(curlPipeJq({ path: '/afm/clusters', filter: 'length' })).toBe(
        `curl -s /afm/clusters | jq 'length'`,
      )
    })
  })
})
