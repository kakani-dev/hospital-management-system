import { describe, expect, it, vi } from 'vitest'
import { ADD_MEMBER_GENERIC_MESSAGE } from './types'
import { ApiClient, ApiError, TENANT_HEADER } from './client'

function jsonResponse(body: unknown, status = 200, headers: Record<string, string> = {}) {
  return new Response(body === undefined ? null : JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...headers } })
}

const emptyPage = { items: [], page: 1, pageSize: 25, totalCount: 0 }

describe('ApiClient', () => {
  it('sends bearer token and never sends a tenant header', async () => {
    const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(emptyPage))
    const client = new ApiClient({ baseUrl: 'https://api.example.test/', getAccessToken: () => 'tkn', fetchImpl })

    await client.patients.list({ pageSize: 25 })

    const [url, init] = fetchImpl.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('https://api.example.test/api/v1/patients?pageSize=25')
    const headers = new Headers(init.headers)
    expect(headers.get('Authorization')).toBe('Bearer tkn')
    expect([...headers.keys()].some((k) => k.toLowerCase().includes('tenant'))).toBe(false)
  })

  it('searches patients with POST /patients/search and keeps the term out of the URL', async () => {
    const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(emptyPage))
    const client = new ApiClient({ baseUrl: 'https://api.example.test', fetchImpl })

    await client.patients.search({ search: 'Doe ALP-0001', pageSize: 25 })

    const [url, init] = fetchImpl.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('https://api.example.test/api/v1/patients/search')
    expect(url).not.toContain('?')
    expect(init.method).toBe('POST')
    expect(JSON.parse(String(init.body))).toEqual({ search: 'Doe ALP-0001', pageSize: 25 })
    expect(new Headers(init.headers).get('Content-Type')).toBe('application/json')
  })

  it('reports the X-Hms-Tenant response header (success and error responses)', async () => {
    const onResolvedTenant = vi.fn()
    const fetchImpl = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse(emptyPage, 200, { [TENANT_HEADER]: 'tenant-a' }))
      .mockResolvedValueOnce(jsonResponse({ title: 'Forbidden' }, 403, { 'x-hms-tenant': ' tenant-b ' }))
      .mockResolvedValueOnce(jsonResponse(emptyPage))
    const client = new ApiClient({ fetchImpl, onResolvedTenant })

    await client.patients.list()
    await expect(client.me()).rejects.toBeInstanceOf(ApiError)
    await client.patients.list()

    expect(onResolvedTenant).toHaveBeenCalledTimes(2)
    expect(onResolvedTenant.mock.calls[0]![0]).toBe('tenant-a')
    expect(onResolvedTenant.mock.calls[1]![0]).toBe('tenant-b')
    expect(typeof onResolvedTenant.mock.calls[0]![1]).toBe('number')
  })

  it('add member returns the generic 202 message body (and tolerates an empty 202)', async () => {
    const fetchImpl = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ message: ADD_MEMBER_GENERIC_MESSAGE }, 202))
      .mockResolvedValueOnce(new Response(null, { status: 202 }))
    const client = new ApiClient({ fetchImpl })

    await expect(client.members.add({ email: 'x@example.test', role: 'nurse' })).resolves.toEqual({ message: ADD_MEMBER_GENERIC_MESSAGE })
    await expect(client.members.add({ email: 'y@example.test', role: 'nurse' })).resolves.toBeUndefined()
    const [url, init] = fetchImpl.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/members')
    expect(init.method).toBe('POST')
  })

  it('lists and accepts invitations', async () => {
    const invitation = {
      membershipId: 'm-1',
      tenantId: 't-1',
      tenantName: 'Demo Beta Clinic',
      branchId: null,
      role: 'doctor',
      invitedAt: '2026-10-06T10:00:00Z',
    }
    const fetchImpl = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse([invitation]))
      .mockResolvedValueOnce(jsonResponse({ items: [invitation] }))
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
    const client = new ApiClient({ fetchImpl })

    await expect(client.invitations.list()).resolves.toEqual([invitation])
    await expect(client.invitations.list()).resolves.toEqual([invitation])
    await expect(client.invitations.accept('m-1')).resolves.toBeUndefined()
    expect(fetchImpl.mock.calls[0]![0]).toBe('/api/v1/me/invitations')
    const [acceptUrl, acceptInit] = fetchImpl.mock.calls[2] as [string, RequestInit]
    expect(acceptUrl).toBe('/api/v1/me/invitations/m-1/accept')
    expect(acceptInit.method).toBe('POST')
  })

  it('throws ApiError with problem details on failure', async () => {
    const fetchImpl = vi.fn().mockResolvedValue(jsonResponse({ title: 'Forbidden', status: 403 }, 403))
    const client = new ApiClient({ fetchImpl })

    await expect(client.me()).rejects.toMatchObject({ name: 'ApiError', status: 403, message: 'Forbidden' })
    await expect(client.me()).rejects.toBeInstanceOf(ApiError)
  })
})
