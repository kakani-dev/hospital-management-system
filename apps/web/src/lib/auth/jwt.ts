/**
 * Reads (does NOT verify) the claims of a JWT. Only used for UX consistency checks — e.g. "is the
 * tenant in my fresh token the one on screen?". Authorization is always decided server-side.
 */
export function decodeJwtClaims(token: string | null | undefined): Record<string, unknown> | null {
  const payload = token?.split('.')[1]
  if (!payload) return null
  try {
    const base64 = payload.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(payload.length / 4) * 4, '=')
    const json = new TextDecoder().decode(Uint8Array.from(atob(base64), (c) => c.charCodeAt(0)))
    const claims: unknown = JSON.parse(json)
    return claims && typeof claims === 'object' ? (claims as Record<string, unknown>) : null
  } catch {
    return null
  }
}

/**
 * Tenant stamped by identity.custom_access_token_hook (`tenant_id`, falling back to
 * `app_metadata.tenant_id` like identity.active_tenant_claim()). Null when the hook is not enabled.
 */
export function tenantFromAccessToken(token: string | null | undefined): string | null {
  const claims = decodeJwtClaims(token)
  if (!claims) return null
  const appMetadata = claims.app_metadata as Record<string, unknown> | undefined
  const tenant = claims.tenant_id ?? appMetadata?.tenant_id
  return typeof tenant === 'string' && tenant !== '' ? tenant : null
}
