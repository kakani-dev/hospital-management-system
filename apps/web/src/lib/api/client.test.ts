import { describe, expect, it, vi } from 'vitest'
import { ApiClient, ApiError, TENANT_HEADER } from './client'

function jsonResponse(body: unknown, status = 200, headers: Record<string, string> = {}) {
  return new Response(body === undefined ? null : JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...headers } })
}

const emptyPage = { items: [], page: 1, pageSize: 25, totalCount: 0 }

describe('ApiClient', () => {
  it('sends bearer token and never sends a tenant header', async () => {
    const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(emptyPage))
    const client = new ApiClient({ baseUrl: 'https://api.example.test/', getAccessToken: () => 'tkn', fetchImpl })

    await client.patients.list({ search: 'doe', pageSize: 25 })

    const [url, init] = fetchImpl.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('https://api.example.test/api/v1/patients?pageSize=25&search=doe')
    const headers = new Headers(init.headers)
    expect(headers.get('Authorization')).toBe('Bearer tkn')
    expect([...headers.keys()].some((k) => k.toLowerCase().includes('tenant'))).toBe(false)
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

  it('throws ApiError with problem details on failure', async () => {
    const fetchImpl = vi.fn().mockResolvedValue(jsonResponse({ title: 'Forbidden', status: 403 }, 403))
    const client = new ApiClient({ fetchImpl })

    await expect(client.me()).rejects.toMatchObject({ name: 'ApiError', status: 403, message: 'Forbidden' })
    await expect(client.me()).rejects.toBeInstanceOf(ApiError)
  })
})
