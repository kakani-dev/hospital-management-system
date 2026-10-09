import { expect, test } from '@playwright/test'
import { bearer, ids, tokenFor, users } from './helpers'

/** Attacks through the real gateway (via the web origin's /api proxy) with real signed tokens. */
test.describe('cross-tenant attacks', () => {
  test('another tenant\'s patient id is 404 (no existence leak)', async ({ request }) => {
    const token = await tokenFor(request, users.alphaAdmin)
    const own = await request.get(`/api/v1/patients/${ids.alphaPatient}`, { headers: bearer(token) })
    expect(own.status()).toBe(200)
    const foreign = await request.get(`/api/v1/patients/${ids.betaPatient}`, { headers: bearer(token) })
    expect(foreign.status()).toBe(404)
  })

  test('spoofed tenant/branch headers are ignored', async ({ request }) => {
    const token = await tokenFor(request, users.alphaAdmin)
    const headers = { ...bearer(token), 'X-Tenant-Id': ids.beta, 'X-Branch-Id': ids.betaMain, 'X-Hms-Tenant': ids.beta }
    const list = await request.get('/api/v1/patients?pageSize=100', { headers })
    expect(list.status()).toBe(200)
    const body = await list.json()
    expect(body.items.length).toBeGreaterThan(0)
    expect(body.items.some((p: { lastName: string }) => p.lastName === 'Synthetic-Beta')).toBe(false)
    expect((await request.get(`/api/v1/patients/${ids.betaPatient}`, { headers })).status()).toBe(404)
  })

  test('switching to a tenant without membership is refused server-side', async ({ request }) => {
    const token = await tokenFor(request, users.alphaAdmin)
    const response = await request.post('/api/v1/me/context', { headers: bearer(token), data: { tenantId: ids.beta } })
    expect(response.status()).toBe(403)
    const me = await (await request.get('/api/v1/me', { headers: bearer(token) })).json()
    expect(me.activeTenantId).toBe(ids.alpha)
  })

  test('tampered token (tenant claim edited, signature kept) is rejected', async ({ request }) => {
    const token = await tokenFor(request, users.alphaAdmin)
    const [header, payload, signature] = token.split('.')
    const claims = JSON.parse(Buffer.from(payload!, 'base64url').toString())
    claims.tenant_id = ids.beta
    const forged = `${header}.${Buffer.from(JSON.stringify(claims)).toString('base64url')}.${signature}`
    expect((await request.get('/api/v1/patients', { headers: bearer(forged) })).status()).toBe(401)
  })

  test('unsigned and missing tokens are rejected', async ({ request }) => {
    const b64 = (o: object) => Buffer.from(JSON.stringify(o)).toString('base64url')
    const none = `${b64({ alg: 'none', typ: 'JWT' })}.${b64({ sub: '0a000000-0000-4000-8000-000000000001', role: 'authenticated', aud: 'authenticated', exp: Math.floor(Date.now() / 1000) + 600 })}.`
    expect((await request.get('/api/v1/patients', { headers: bearer(none) })).status()).toBe(401)
    expect((await request.get('/api/v1/patients')).status()).toBe(401)
  })

  test('creating a patient in another tenant\'s branch is refused', async ({ request }) => {
    const token = await tokenFor(request, users.alphaAdmin)
    const response = await request.post('/api/v1/patients', {
      headers: bearer(token),
      data: { mrn: 'XT-0001', firstName: 'Cross', lastName: 'Tenant', registeredBranchId: ids.betaMain, tenantId: ids.beta },
    })
    expect(response.status()).toBe(404)
  })

  test('admin endpoints cannot touch another tenant\'s branch', async ({ request }) => {
    const token = await tokenFor(request, users.alphaAdmin)
    const response = await request.patch(`/api/v1/branches/${ids.betaMain}`, { headers: bearer(token), data: { name: 'Hijacked' } })
    expect(response.status()).toBe(404)
  })
})
