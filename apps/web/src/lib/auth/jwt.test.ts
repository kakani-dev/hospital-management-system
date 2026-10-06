import { describe, expect, it } from 'vitest'
import { decodeJwtClaims, tenantFromAccessToken } from './jwt'
import { ALPHA, BETA, fakeJwt } from '../../test/fakes'

describe('tenantFromAccessToken', () => {
  it('reads the tenant_id claim stamped by the access token hook', () => {
    expect(tenantFromAccessToken(fakeJwt({ tenant_id: ALPHA }))).toBe(ALPHA)
  })

  it('falls back to app_metadata.tenant_id', () => {
    expect(tenantFromAccessToken(fakeJwt({ app_metadata: { tenant_id: BETA } }))).toBe(BETA)
  })

  it('handles base64url payloads with non-ASCII claims', () => {
    expect(decodeJwtClaims(fakeJwt({ tenant_id: ALPHA, name: 'Dr. Ünal' }))).toMatchObject({ name: 'Dr. Ünal' })
  })

  it.each([null, undefined, '', 'opaque-token', 'a.!!!.c', fakeJwt({ tenant_id: '' }), fakeJwt({ tenant_id: 42 })])(
    'returns null for %s',
    (token) => {
      expect(tenantFromAccessToken(token as string | null | undefined)).toBeNull()
    },
  )
})
