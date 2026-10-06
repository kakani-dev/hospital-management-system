import { describe, expect, it, vi } from 'vitest'
import { ApiClient, ApiError } from './client'

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}

describe('ApiClient', () => {
  it('sends bearer token and never sends a tenant header', async () => {
    const fetchImpl = vi.fn().mockResolvedValue(jsonResponse({ items: [], page: 1, pageSize: 25, totalCount: 0 }))
    const client = new ApiClient({ baseUrl: 'https://api.example.test/', getAccessToken: () => 'tkn', fetchImpl })

    await client.patients.list({ search: 'doe', pageSize: 25 })

    const [url, init] = fetchImpl.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('https://api.example.test/api/v1/patients?pageSize=25&search=doe')
    const headers = new Headers(init.headers)
    expect(headers.get('Authorization')).toBe('Bearer tkn')
    expect([...headers.keys()].some((k) => k.toLowerCase().includes('tenant'))).toBe(false)
  })

  it('throws ApiError with problem details on failure', async () => {
    const fetchImpl = vi.fn().mockResolvedValue(jsonResponse({ title: 'Forbidden', status: 403 }, 403))
    const client = new ApiClient({ fetchImpl })

    await expect(client.me()).rejects.toMatchObject({ name: 'ApiError', status: 403, message: 'Forbidden' })
    await expect(client.me()).rejects.toBeInstanceOf(ApiError)
  })
})
