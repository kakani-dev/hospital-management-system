import { describe, expect, it, vi } from 'vitest'
import { ApiClient } from './client'

function jsonResponse(body: unknown, status = 200) {
  return new Response(body === undefined ? null : JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}

function setup(body: unknown = [], status = 200) {
  const fetchImpl = vi.fn(async () => jsonResponse(body, status))
  const client = new ApiClient({ baseUrl: 'https://api.example.test', fetchImpl })
  const call = (i = 0) => {
    const [url, init] = fetchImpl.mock.calls[i] as unknown as [string, RequestInit]
    return { url, method: init.method ?? 'GET', body: init.body ? JSON.parse(String(init.body)) : undefined }
  }
  return { client, call, fetchImpl }
}

const BRANCH = 'a1111111-0000-4000-8000-000000000001'

describe('ApiClient — Sprint 2 patients', () => {
  it('searches by phone and DOB in the POST body, never the URL', async () => {
    const { client, call } = setup({ items: [], page: 1, pageSize: 25, totalCount: 0 })
    await client.patients.search({ phone: '98450', dateOfBirth: '1990-01-01', pageSize: 25 })
    expect(call()).toEqual({
      url: 'https://api.example.test/api/v1/patients/search',
      method: 'POST',
      body: { phone: '98450', dateOfBirth: '1990-01-01', pageSize: 25 },
    })
  })

  it('gets, patches, soft-deletes (optional audited reason) and restores a patient by id', async () => {
    const { client, call } = setup({})
    await client.patients.get('p 1')
    await client.patients.update('p1', { firstName: 'Asha', phone: null })
    await client.patients.remove('p1')
    await client.patients.remove('p1', { reason: 'Duplicate registration' })
    await client.patients.restore('p1')
    expect(call(0)).toMatchObject({ url: 'https://api.example.test/api/v1/patients/p%201', method: 'GET' })
    expect(call(1)).toEqual({ url: 'https://api.example.test/api/v1/patients/p1', method: 'PATCH', body: { firstName: 'Asha', phone: null } })
    expect(call(2)).toEqual({ url: 'https://api.example.test/api/v1/patients/p1', method: 'DELETE', body: undefined })
    expect(call(3)).toEqual({ url: 'https://api.example.test/api/v1/patients/p1', method: 'DELETE', body: { reason: 'Duplicate registration' } })
    expect(call(4)).toMatchObject({ url: 'https://api.example.test/api/v1/patients/p1/restore', method: 'POST' })
  })

  it('posts the duplicate check with identifiers in the body and unwraps {candidates}', async () => {
    const match = { id: 'p1', matchReasons: ['phone'] }
    const fetchImpl = vi.fn(async () => jsonResponse({ candidates: [match] }))
    const client = new ApiClient({ fetchImpl })
    const body = { firstName: 'Asha', lastName: 'S', dateOfBirth: '1990-01-01', phone: '+91 98450 00001' }
    await expect(client.patients.duplicates(body)).resolves.toEqual([match])
    const [url, init] = fetchImpl.mock.calls[0] as unknown as [string, RequestInit]
    expect(url).toBe('/api/v1/patients/duplicates')
    expect(init.method).toBe('POST')
    expect(JSON.parse(String(init.body))).toEqual(body)
  })
})

describe('ApiClient — Sprint 2 scheduling and OPD', () => {
  it('lists active practitioners, branch schedules and free slots (ids/dates only in the query)', async () => {
    const { client, call } = setup([])
    await client.practitioners.list()
    await client.schedules.list({ branchId: BRANCH })
    await client.slots({ branchId: BRANCH, from: '2026-10-09', to: '2026-10-09', practitionerId: 'd1' })
    expect(call(0).url).toBe('https://api.example.test/api/v1/practitioners?activeOnly=true')
    expect(call(1).url).toBe(`https://api.example.test/api/v1/schedules?branchId=${BRANCH}`)
    expect(call(2).url).toBe(`https://api.example.test/api/v1/slots?branchId=${BRANCH}&from=2026-10-09&to=2026-10-09&practitionerId=d1`)
    // Visit-length aware slots: durationMinutes is sent only when given
    await client.slots({ branchId: BRANCH, from: '2026-10-09', to: '2026-10-09', practitionerId: 'd1', durationMinutes: 30 })
    expect(call(3).url).toBe(`https://api.example.test/api/v1/slots?branchId=${BRANCH}&from=2026-10-09&to=2026-10-09&practitionerId=d1&durationMinutes=30`)
    // API v2: practitioners working at a branch
    await client.practitioners.list({ branchId: BRANCH })
    expect(call(4).url).toBe(`https://api.example.test/api/v1/practitioners?activeOnly=true&branchId=${BRANCH}`)
  })

  it('lists appointments by instant range (optional filters dropped when empty)', async () => {
    const { client, call } = setup({ items: [], page: 1, pageSize: 100, totalCount: 0 })
    await client.appointments.list({ branchId: BRANCH, from: '2026-10-08T18:30:00.000Z', to: '2026-10-09T18:30:00.000Z', practitionerId: undefined, pageSize: 100 })
    expect(call(0).url).toBe(
      `https://api.example.test/api/v1/appointments?branchId=${BRANCH}&from=2026-10-08T18%3A30%3A00.000Z&to=2026-10-09T18%3A30%3A00.000Z&pageSize=100`,
    )
  })

  it('books, cancels and checks in appointments', async () => {
    const { client, call } = setup({})
    const body = { branchId: BRANCH, practitionerId: 'd1', patientId: 'p1', startsAt: '2026-10-09T03:30:00Z', endsAt: '2026-10-09T03:45:00Z' }
    await client.appointments.create(body)
    await client.appointments.cancel('a1', { reason: 'Patient called' })
    await client.appointments.checkIn('a1')
    expect(call(0)).toEqual({ url: 'https://api.example.test/api/v1/appointments', method: 'POST', body })
    expect(call(1)).toEqual({ url: 'https://api.example.test/api/v1/appointments/a1/cancel', method: 'POST', body: { reason: 'Patient called' } })
    expect(call(2)).toMatchObject({ url: 'https://api.example.test/api/v1/appointments/a1/check-in', method: 'POST' })
  })

  it('reads the queue, registers walk-ins and moves status with PATCH /queue/{id}', async () => {
    const { client, call } = setup({})
    await client.queue.list({ branchId: BRANCH, date: '2026-10-09' })
    await client.queue.walkIn({ branchId: BRANCH, patientId: 'p1' })
    await client.queue.updateStatus('q1', { status: 'in_consultation' })
    expect(call(0).url).toBe(`https://api.example.test/api/v1/queue?branchId=${BRANCH}&date=2026-10-09`)
    expect(call(1)).toEqual({ url: 'https://api.example.test/api/v1/queue/walk-in', method: 'POST', body: { branchId: BRANCH, patientId: 'p1' } })
    expect(call(2)).toEqual({ url: 'https://api.example.test/api/v1/queue/q1', method: 'PATCH', body: { status: 'in_consultation' } })
  })
})
