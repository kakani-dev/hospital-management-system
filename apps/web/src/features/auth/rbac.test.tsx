import { afterEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor } from '@testing-library/react'
import { App } from '../../App'
import { fakeAuthClient, fakeSession, json, meFor, renderWithProviders, stubFetch } from '../../test/fakes'
import { ROLE_PERMISSIONS } from '../../lib/permissions'

afterEach(() => vi.unstubAllGlobals())

const page = { items: [], page: 1, pageSize: 25, totalCount: 0 }
const NAV = ['Patients', 'Appointments', 'Schedules', 'Check-in', 'OPD queue', 'Branches', 'Members', 'Practitioners', 'Working hours', 'Hospital settings'] as const

// RBAC (ADR 0001): the menu each role sees
const EXPECTED: Record<string, readonly (typeof NAV)[number][]> = {
  tenant_admin: NAV,
  receptionist: ['Patients', 'Appointments', 'Schedules', 'Check-in', 'OPD queue'],
  nurse: ['Patients', 'Appointments', 'Schedules', 'Check-in', 'OPD queue'],
  doctor: ['Patients', 'Appointments', 'Schedules', 'OPD queue'],
  billing: ['Patients', 'Appointments', 'Schedules'],
  pharmacist: ['Schedules'],
  lab_technician: ['Schedules'],
  viewer: ['Schedules'],
}

function stub(roles: string[], permissions?: string[]) {
  return stubFetch({
    'GET /api/v1/me': () => json({ ...meFor({ roles }), ...(permissions ? { permissions } : {}) }),
    'GET /api/v1/patients': () => json(page),
    'GET /api/v1/patients/stats': () => json({ total: 0, registeredToday: 0 }),
    'GET /api/v1/appointments': () => json(page),
    'GET /api/v1/queue': () => json([]),
    'GET /health/live': () => json({ status: 'Healthy' }),
  })
}

describe('RBAC menus', () => {
  it.each(Object.keys(EXPECTED))('%s sees only the links its permissions allow', async (role) => {
    stub([role], [...(ROLE_PERMISSIONS[role] ?? [])])
    renderWithProviders(<App />, { path: '/', auth: fakeAuthClient({ session: fakeSession() }) })
    await screen.findByRole('link', { name: 'Dashboard' })
    await waitFor(() => {
      for (const name of NAV) {
        const link = screen.queryByRole('link', { name })
        if (EXPECTED[role]?.includes(name)) expect(link, `${role} should see ${name}`).toBeInTheDocument()
        else expect(link, `${role} should not see ${name}`).not.toBeInTheDocument()
      }
    })
  })

  it('trusts the server permission list over the role names', async () => {
    // role says tenant_admin, but the server granted only patients.view: no admin menu
    stub(['tenant_admin'], ['patients.view'])
    renderWithProviders(<App />, { path: '/', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByRole('link', { name: 'Patients' })).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Members' })).not.toBeInTheDocument()
  })
})

describe('RBAC route guard', () => {
  it.each([
    ['lab_technician', '/patients'],
    ['doctor', '/patients/new'],
    ['viewer', '/appointments'],
    ['billing', '/queue'],
    ['receptionist', '/admin/members'],
    ['nurse', '/admin/hospital'],
  ])('%s opening %s gets the friendly no-access page', async (role, path) => {
    stub([role], [...(ROLE_PERMISSIONS[role] ?? [])])
    renderWithProviders(<App />, { path, auth: fakeAuthClient({ session: fakeSession() }) })
    const page = await screen.findByTestId('forbidden')
    expect(page).toHaveTextContent(/don't have access/i)
    expect(page).toHaveTextContent(role.replace('_', ' '))
    expect(screen.getByRole('link', { name: 'Back to the dashboard' })).toHaveAttribute('href', '/')
  })

  it('a receptionist opens the patient list', async () => {
    stub(['receptionist'], [...(ROLE_PERMISSIONS.receptionist ?? [])])
    renderWithProviders(<App />, { path: '/patients', auth: fakeAuthClient({ session: fakeSession() }) })
    await screen.findByRole('link', { name: 'Patients' })
    expect(screen.queryByTestId('forbidden')).not.toBeInTheDocument()
  })
})
