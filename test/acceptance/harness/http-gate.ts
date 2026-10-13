// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * Shared RFC 9110 HTTP method gate, OPTIONS preflight, HEAD body suppression,
 * and request body draining helpers for acceptance test harness servers.
 */

const DEFAULT_CORS_HEADERS: Record<string, string> = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'Authorization, Content-Type',
}

/**
 * Normalize a route's allowed methods into a canonical `Allow` header value.
 * Ensures `HEAD` is advertised whenever `GET` is allowed, and `OPTIONS` is
 * always included for RFC 9110 OPTIONS / 405 parity.
 */
export function normalizeAllow(methods: readonly string[]): string {
  const result: string[] = []
  const add = (m: string) => {
    const upper = m.trim().toUpperCase()
    if (upper && !result.includes(upper)) {
      result.push(upper)
    }
  }
  for (const m of methods) {
    add(m)
    if (m.trim().toUpperCase() === 'GET') {
      add('HEAD')
    }
  }
  add('OPTIONS')
  return result.join(', ')
}

/**
 * Safely drain and discard any unread request body on error, preflight,
 * or bodyless-method paths so keep-alive connections remain clean.
 */
export async function drainRequestBody(req: Request): Promise<void> {
  if (!req.body || req.bodyUsed) return
  try {
    await req.arrayBuffer()
  } catch {
    // Ignore stream framing errors during best-effort drain in test harnesses.
  }
}

/**
 * Strip the response payload when answering a `HEAD` request while preserving
 * status code and response headers.
 */
export function suppressHeadBody(req: Request | undefined, response: Response): Response {
  if (req?.method !== 'HEAD') return response
  return new Response(null, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  })
}

/**
 * Build a JSON response with automatic `HEAD` body suppression.
 */
export function jsonResponse(
  body: unknown,
  status = 200,
  req?: Request,
  extraHeaders: Record<string, string> = {},
): Response {
  const headers: Record<string, string> = {
    'content-type': 'application/json',
    'cache-control': 'no-store',
    ...extraHeaders,
  }
  if (req?.method === 'HEAD' || status === 204 || status === 205 || status === 304) {
    return new Response(null, { status, headers })
  }
  return new Response(JSON.stringify(body), { status, headers })
}

/**
 * Build a non-JSON response (HTML, JS, CSS, SSE) with `HEAD` body suppression.
 */
export function staticResponse(
  req: Request,
  body: BodyInit | null,
  status = 200,
  headers: Record<string, string> = {},
): Response {
  return new Response(req.method === 'HEAD' ? null : body, { status, headers })
}

/**
 * Build an RFC 9110 `204 No Content` response for `OPTIONS` preflight with
 * `Allow` header parity and CORS preflight headers.
 */
export function optionsResponse(
  allowedMethods: readonly string[],
  extraHeaders: Record<string, string> = {},
): Response {
  const allow = normalizeAllow(allowedMethods)
  return new Response(null, {
    status: 204,
    headers: {
      ...DEFAULT_CORS_HEADERS,
      'access-control-allow-methods': allow,
      Allow: allow,
      ...extraHeaders,
    },
  })
}

/**
 * Build an RFC 9110 `405 Method Not Allowed` JSON response with a canonical
 * `Allow` header and `HEAD` body suppression.
 */
export function methodNotAllowedResponse(
  req: Request,
  allowedMethods: readonly string[],
  extraHeaders: Record<string, string> = {},
): Response {
  const allow = normalizeAllow(allowedMethods)
  return jsonResponse({ detail: 'Method Not Allowed' }, 405, req, {
    ... extraHeaders,
    Allow: allow,
  })
}

/**
 * Gate a matched route by HTTP method:
 * - Answers `OPTIONS` with `204 No Content` and `Allow` header parity after draining the body.
 * - Answers disallowed methods with `405 Method Not Allowed` and `Allow` header after draining the body.
 * - Drains any unexpected body on `GET` / `HEAD`.
 * - Returns `null` when the request method is permitted so the route handler can proceed.
 */
export async function gateMethod(
  req: Request,
  allowedMethods: readonly string[],
  extraHeaders: Record<string, string> = {},
): Promise<Response | null> {
  const allow = normalizeAllow(allowedMethods)
  const allowedSet = new Set(allow.split(', '))
  const method = req.method.toUpperCase()

  if (method === 'OPTIONS') {
    await drainRequestBody(req)
    return optionsResponse(allowedMethods, extraHeaders)
  }

  if (!allowedSet.has(method)) {
    await drainRequestBody(req)
    return methodNotAllowedResponse(req, allowedMethods, extraHeaders)
  }

  if (method === 'GET' || method === 'HEAD') {
    await drainRequestBody(req)
  }

  return null
}

/**
 * Drain any request body and return a `404 Not Found` JSON response with `HEAD`
 * body suppression.
 */
export async function notFoundResponse(
  req: Request,
  detail: string,
  extraHeaders: Record<string, string> = {},
): Promise<Response> {
  await drainRequestBody(req)
  return jsonResponse({ detail }, 404, req, extraHeaders)
}
