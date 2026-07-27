// Decodes the tenant_id claim from an Auth0 access token without a full JWT
// verification (verification already happened server-side; this is purely
// for client-side scoping like namespacing localStorage keys).
export function getTenantIdFromToken(token: string): string | null {
  try {
    const b64 = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')
    const payload = JSON.parse(atob(b64)) as Record<string, unknown>
    return (payload['https://signalloom.ai/tenant_id'] as string | undefined) ?? null
  } catch {
    return null
  }
}
