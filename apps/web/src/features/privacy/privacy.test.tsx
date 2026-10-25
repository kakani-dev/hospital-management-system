import { afterEach, describe, expect, it, vi } from 'vitest'
import userEvent from '@testing-library/user-event'
import { screen } from '@testing-library/react'
import { App } from '../../App'
import { ROLE_PERMISSIONS } from '../../lib/permissions'
import { fakeAuthClient, fakeSession, json, meFor, renderWithProviders, stubFetch } from '../../test/fakes'

afterEach(() => vi.unstubAllGlobals())

const notice = {
  noticeId: 'n-1',
  version: 1,
  language: 'en',
  title: 'How this hospital uses health information',
  body: 'Alpha Hospital tells you what it uses your health information for. Treatment and billing do not need a separate tick.',
  contentSha256: 'a'.repeat(64),
  publishedAt: '2026-10-25T00:00:00Z',
  purposes: [
    { code: 'reminders', label: 'Appointment and follow-up reminders (WhatsApp/SMS)', required: false },
    { code: 'marketing', label: 'Health camps and offers', required: false },
  ],
}

function signedIn(role: string, extra: Record<string, () => Response> = {}) {
  return stubFetch({
    'GET /api/v1/me': () => json({ ...meFor({ roles: [role] }), permissions: [...(ROLE_PERMISSIONS[role] ?? [])] }),
    'GET /health/live': () => json({ status: 'Healthy' }),
    ...extra,
  })
}

describe('Privacy pages', () => {
  it('lets an admin save a notice draft without a version', async () => {
    const calls = signedIn('tenant_admin', {
      'GET /api/v1/privacy/consent-notices': () => json([]),
      'POST /api/v1/privacy/consent-notices': () => json({ ...notice, publishedAt: null }),
    })
    const user = userEvent.setup()
    renderWithProviders(<App />, { path: '/admin/privacy-notices', auth: fakeAuthClient({ session: fakeSession() }) })
    await user.type(await screen.findByLabelText('Title'), 'How this hospital uses health information')
    await user.type(screen.getByLabelText('Notice'), notice.body)
    await user.click(screen.getByRole('button', { name: 'Save draft' }))
    const posted = calls.find((call) => call.path === '/api/v1/privacy/consent-notices' && call.method === 'POST')
    expect(posted?.body).toMatchObject({ language: 'en', purposes: ['reminders'] })
    expect(posted?.body).not.toHaveProperty('version')
    expect(posted?.headers.get('Idempotency-Key')).toBeTruthy()
    expect(await screen.findByText(/Saved draft version 1/)).toBeInTheDocument()
  })

  it('shows a due-soon request and keeps erasure off the reception desk', async () => {
    signedIn('receptionist', {
      'GET /api/v1/privacy/rights-requests': () => json([
        {
          id: 'r-1',
          code: 'DPR-2026-00001',
          patientId: 'p-1',
          type: 'access',
          details: 'Send me a copy.',
          channel: 'desk',
          status: 'received',
          receivedAt: '2026-10-20T00:00:00Z',
          dueAt: '2026-10-30T00:00:00Z',
          daysRemaining: 5,
        },
      ]),
    })
    renderWithProviders(<App />, { path: '/compliance/requests', auth: fakeAuthClient({ session: fakeSession() }) })
    expect(await screen.findByText('DPR-2026-00001')).toBeInTheDocument()
    expect(screen.getByText('Due soon')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Execute erasure' })).not.toBeInTheDocument()
  })

  it('opens a public consent link without a name or MRN', async () => {
    stubFetch({
      'GET /api/v1/privacy/public/consents/abc': () => json(notice),
    })
    renderWithProviders(<App />, { path: '/privacy/consent/abc', auth: null })
    expect(await screen.findByRole('heading', { name: notice.title })).toBeInTheDocument()
    expect(screen.getByTestId('public-consent')).toBeInTheDocument()
    expect(screen.queryByText(/MRN/)).not.toBeInTheDocument()
    expect(screen.queryByLabelText(/name/i)).not.toBeInTheDocument()
  })
})
