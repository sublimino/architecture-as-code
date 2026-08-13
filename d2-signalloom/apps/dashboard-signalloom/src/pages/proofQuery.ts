/**
 * Proof material assembled from a response the page actually received — and
 * from nothing else.
 *
 * ProofConsole's contract is that `command` is literally re-runnable and
 * `detail` is what that command printed. A page that hands it a plausible
 * command it never issued has produced something a reader cannot tell apart
 * from a fabrication, which is the one failure this product cannot afford:
 * network reachability in this repo already has a history of probes reporting a
 * verdict they had not earned. So the only proof this module can build is a jq
 * PROJECTION over an endpoint the client really called — the command names that
 * endpoint and the fields it selects, and the detail is those fields rendered
 * the way jq renders them.
 *
 * Three details are what make that byte-exact rather than nearly-exact, and
 * each of them is a way the output would otherwise have quietly diverged from
 * the command above it.
 *
 * 1. jq's object-construction shorthand emits `null` for a key the input does
 *    not carry. So an `undefined` on our side becomes `null` here rather than a
 *    dropped key — dropping it would print a shorter object than the command
 *    does. This is also why the projections built on top of this are restricted
 *    to fields whose client-side parse maps a missing value to `undefined`:
 *    a field parsed with a `?? 0` or `?? []` default would read as 0 where jq
 *    reads null, and there is no honest way to show that under a jq command.
 *
 * 2. `.array[] | select(...)` is a STREAM, not a single value. Two matches
 *    print two objects one after another with no separator, so `jqOutput` takes
 *    every match rather than only the row that was clicked. One truthful object
 *    under a command that prints two is still a misleading proof.
 *
 * 3. A value interpolated into the filter has to survive both quoting layers —
 *    jq's own string literal and the single-quoted shell word the filter sits
 *    inside. Kubernetes names cannot contain either character today, which is
 *    exactly why it would go unnoticed the day something else can.
 */

export type JsonValue = string | number | boolean | null | JsonValue[] | { [key: string]: JsonValue }

/**
 * One projected match, as written in the jq object construction.
 *
 * `unknown` rather than `JsonValue` because the values come straight off the
 * typed API responses, and a TypeScript `interface` (unlike a type alias) has
 * no index signature, so `NetworkTestEndpoint` is not assignable to
 * `{ [key: string]: JsonValue }` however JSON-shaped it actually is. Widening
 * here beats re-declaring every wire type or spreading each nested object into
 * a fresh literal — the latter loses the wire's own key order, which is the one
 * property that makes the printed object match what jq prints.
 *
 * The contract is still JSON-serialisable; `JSON.stringify` is what enforces
 * it, exactly as it would at the top of the pipe.
 */
export type JqRecord = Record<string, unknown>

/**
 * A jq string literal for `value`, safe to paste into a filter.
 *
 * JSON.stringify is the right escaper here and not an approximation of one:
 * jq's string syntax is JSON's.
 */
export function jqString(value: string): string {
  return JSON.stringify(value)
}

/**
 * Wrap `filter` as a single-quoted shell word.
 *
 * `'\''` is the only way to get a literal single quote inside single quotes in
 * POSIX sh — close, escape, reopen. Without it a name carrying an apostrophe
 * would produce a command that does not parse, which is worse than no proof:
 * it looks checkable and is not.
 */
export function shellQuote(filter: string): string {
  return `'${filter.replace(/'/g, `'\\''`)}'`
}

export interface CurlJqOptions {
  /** Request path exactly as the client calls it, e.g. `/network-tests`. */
  path: string
  /** The jq filter, unquoted. */
  filter: string
  /** Whether the client sends `Authorization: Bearer` on this route. */
  bearer?: boolean
}

/** The literal shell pipeline that reproduces a projection of one response. */
export function curlPipeJq({ path, filter, bearer = false }: CurlJqOptions): string {
  const auth = bearer ? ` -H "Authorization: Bearer $TOKEN"` : ''
  return `curl -s${auth} ${path} | jq ${shellQuote(filter)}`
}

/** `undefined` is not a JSON value; jq prints the absent key as null. */
function normalise(record: JqRecord): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(record)) {
    out[key] = value === undefined ? null : value
  }
  return out
}

/**
 * Exactly what jq prints for a stream of object constructions.
 *
 * Two spaces of indent, one object after another, no separator and no
 * surrounding array — jq's default pretty output. Zero matches print nothing,
 * which ProofConsole already renders as "(no output)".
 */
export function jqOutput(matches: JqRecord[]): string {
  return matches.map((match) => JSON.stringify(normalise(match), null, 2)).join('\n')
}
