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

  it('gets, patches and soft-deletes a patient by id', async () => {
    const { client, call } = setup({})
    await client.patients.get('p 1')
    await client.patients.update('p1', { firstName: 'Asha', phone: null })
    await client.patients.remove('p1')
    expect(call(0)).toMatchObject({ url: 'https://api.example.test/api/v1/patients/p%201', method: 'GET' })
    expect(call(1)).toEqual({ url: 'https://api.example.test/api/v1/patients/p1', method: 'PATCH', body: { firstName: 'Asha', phone: null } })
    expect(call(2)).toMatchObject({ url: 'https://api.example.test/api/v1/patients/p1', method: 'DELETE' })
  })

  it('posts the duplicate check with identifiers in the body (array or {items})', async () => {
    const match = { id: 'p1', matchReasons: ['phone'] }
    const fetchImpl = vi.fn().mockResolvedValueOnce(jsonResponse([match])).mockResolvedValueOnce(jsonResponse({ items: [match] }))
    const client = new ApiClient({ fetchImpl })
    const body = { firstName: 'Asha', lastName: 'S', dateOfBirth: '1990-01-01', phone: '+91 98450 00001' }
    await expect(client.patients.duplicates(body)).resolves.toEqual([match])
    await expect(client.patients.duplicates(body)).resolves.toEqual([match])
    const [url, init] = fetchImpl.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/patients/duplicates')
    expect(init.method).toBe('POST')
    expect(JSON.parse(String(init.body))).toEqual(body)
  })
})

describe('ApiClient — Sprint 2 scheduling and OPD', () => {
  it('lists practitioners and schedules by branch with ids/dates only in the query', async () => {
    const { client, call } = setup([])
    await client.practitioners.list(BRANCH)
    await client.schedules.list({ branchId: BRANCH, from: '2026-10-05', to: '2026-10-11' })
    expect(call(0).url).toBe(`https://api.example.test/api/v1/practitioners?branchId=${BRANCH}`)
    expect(call(1).url).toBe(`https://api.example.test/api/v1/schedules?branchId=${BRANCH}&from=2026-10-05&to=2026-10-11`)
  })

  it('lists appointments (optional practitioner filter dropped when empty) and slots', async () => {
    const { client, call } = setup([])
    await client.appointments.list({ branchId: BRANCH, from: '2026-10-09', to: '2026-10-09', practitionerId: undefined })
    await client.appointments.slots({ branchId: BRANCH, practitionerId: 'd1', date: '2026-10-09' })
    expect(call(0).url).toBe(`https://api.example.test/api/v1/appointments?branchId=${BRANCH}&from=2026-10-09&to=2026-10-09`)
    expect(call(1).url).toBe(`https://api.example.test/api/v1/appointments/slots?branchId=${BRANCH}&practitionerId=d1&date=2026-10-09`)
  })

  it('books and cancels appointments', async () => {
    const { client, call } = setup({})
    const body = { branchId: BRANCH, practitionerId: 'd1', patientId: 'p1', startsAt: '2026-10-09T09:00:00+05:30', endsAt: '2026-10-09T09:15:00+05:30', reason: null }
    await client.appointments.create(body)
    await client.appointments.cancel('a1')
    expect(call(0)).toEqual({ url: 'https://api.example.test/api/v1/appointments', method: 'POST', body })
    expect(call(1)).toMatchObject({ url: 'https://api.example.test/api/v1/appointments/a1/cancel', method: 'POST' })
  })

  it('reads the queue, checks in and moves status', async () => {
    const { client, call } = setup({})
    await client.queue.list({ branchId: BRANCH, date: '2026-10-09' })
    await client.queue.checkIn({ branchId: BRANCH, patientId: 'p1', appointmentId: 'a1' })
    await client.queue.updateStatus('q1', { status: 'in_consult' })
    expect(call(0).url).toBe(`https://api.example.test/api/v1/queue?branchId=${BRANCH}&date=2026-10-09`)
    expect(call(1)).toEqual({ url: 'https://api.example.test/api/v1/queue/check-in', method: 'POST', body: { branchId: BRANCH, patientId: 'p1', appointmentId: 'a1' } })
    expect(call(2)).toEqual({ url: 'https://api.example.test/api/v1/queue/q1/status', method: 'PATCH', body: { status: 'in_consult' } })
  })
})
