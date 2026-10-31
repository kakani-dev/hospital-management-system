import { afterEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, screen } from '@testing-library/react'
import { fakeAuthClient, fakeSession, json, meFor, renderWithProviders, stubFetch } from '../../test/fakes'
import { GlExportPanel } from './GlExportPanel'

afterEach(() => vi.unstubAllGlobals())

const day = (offset: number) => new Date(Date.now() + offset * 86_400_000).toISOString().slice(0, 10)
const from = day(-10)
const to = day(0)

function preview(overrides: Record<string, unknown> = {}) {
  return {
    from, to, branchId: null,
    counts: { sales: 3, credit_note: 1, receipt: 2, refund: 1 },
    vouchers: 7, debitPaise: 4_250_00, unbalanced: 0, skippedZero: 1,
    ledgers: [
      { name: 'Patient Receivables', group: 'Sundry Debtors', isDefault: true, unmapped: false, debitPaise: 100, creditPaise: 50 },
    ],
    lastExport: null,
    ...overrides,
  }
}

const ledgers = {
  ledgers: [
    { key: 'company', name: 'company', group: null, isDefault: true, hint: 'Tally company name (optional)' },
    { key: 'round_off', name: 'Round Off', group: 'Indirect Expenses', isDefault: true },
    { key: 'gst:cgst', name: 'Output CGST @ {rate}%', group: 'Duties & Taxes', isDefault: false },
  ],
  lastExport: null,
}

function render(routes: Parameters<typeof stubFetch>[0]) {
  const calls = stubFetch({ 'GET /api/v1/me': () => json(meFor({ timeZone: 'Asia/Kolkata' })), ...routes })
  renderWithProviders(<GlExportPanel from={from} to={to} branchId={null} />, { path: '/billing/earnings', auth: fakeAuthClient({ session: fakeSession() }) })
  return calls
}

describe('GL / Tally export panel (#62)', () => {
  it('previews the period on its own and downloads Tally vouchers with one click', async () => {
    const calls = render({
      'GET /api/v1/billing-reports/gl/preview': () => json(preview()),
      'GET /api/v1/billing-reports/gl/export': () =>
        new Response('<ENVELOPE/>', { status: 200, headers: { 'Content-Type': 'application/xml', 'Content-Disposition': 'attachment; filename="tally-vouchers.xml"' } }),
    })
    const saved: string[] = []
    vi.stubGlobal('URL', Object.assign(URL, { createObjectURL: () => 'blob:x', revokeObjectURL: () => undefined }))
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(function (this: HTMLAnchorElement) { saved.push(this.download) })
    expect(await screen.findByTestId('gl-count-sales')).toHaveTextContent('3')
    expect(screen.getByTestId('gl-count-credit-note')).toHaveTextContent('1')
    expect(screen.getByTestId('gl-skipped-zero')).toHaveTextContent('1 zero-value')
    expect(screen.queryByTestId('gl-repeat-warning')).not.toBeInTheDocument()
    fireEvent.click(screen.getByTestId('gl-export-vouchers-xml'))
    await vi.waitFor(() => expect(saved).toEqual(['tally-vouchers.xml']))
    const exportCall = calls.find((c) => c.path.endsWith('/gl/export'))!
    expect(exportCall.url).toContain('kind=vouchers')
    expect(exportCall.url).toContain('format=xml')
    expect(exportCall.url).toContain(`from=${from}`)
    expect(exportCall.url).not.toContain('tenant')
    click.mockRestore()
  })

  it('warns on a re-export, flags unmapped ledgers, and blocks unbalanced or empty periods', async () => {
    render({
      'GET /api/v1/billing-reports/gl/preview': () => json(preview({
        unbalanced: 1,
        lastExport: { from: day(-3), to: day(-1), format: 'xml', vouchers: 4, at: `${day(-1)}T10:00:00Z` },
        ledgers: [{ name: 'party:insurer', group: null, isDefault: true, unmapped: true, debitPaise: 1, creditPaise: 0 }],
      })),
    })
    expect(await screen.findByTestId('gl-repeat-warning')).toHaveTextContent('4 vouchers')
    expect(screen.getByTestId('gl-unmapped')).toHaveTextContent('party:insurer')
    expect(screen.getByTestId('gl-export-vouchers-xml')).toBeDisabled()
    expect(screen.getByTestId('gl-export-csv')).toBeDisabled()
  })

  it('shows an empty period without export buttons', async () => {
    render({ 'GET /api/v1/billing-reports/gl/preview': () => json(preview({ counts: {}, vouchers: 0, debitPaise: 0, skippedZero: 0 })) })
    expect(await screen.findByTestId('gl-preview-empty')).toBeInTheDocument()
    expect(screen.getByTestId('gl-export-masters-xml')).toBeDisabled()
  })

  it('shows a retryable message when the network fails', async () => {
    render({ 'GET /api/v1/billing-reports/gl/preview': () => json({ title: 'Unavailable' }, 503) })
    expect(await screen.findByText(/could not be loaded/, {}, { timeout: 8000 })).toBeInTheDocument()
  })

  it('edits ledger names inline and saves only what changed', async () => {
    const calls = render({
      'GET /api/v1/billing-reports/gl/preview': () => json(preview()),
      'GET /api/v1/billing-reports/gl/ledgers': () => json(ledgers),
      'PUT /api/v1/billing-reports/gl/ledgers': () => json({ ...ledgers, ledgers: ledgers.ledgers.map((l) => (l.key === 'round_off' ? { ...l, name: 'Rounding Off', isDefault: false } : l)) }),
    })
    fireEvent.click(await screen.findByTestId('gl-ledger-map-toggle'))
    const name = await screen.findByTestId('gl-ledger-name-round-off')
    expect(screen.getByTestId('gl-ledger-map-save')).toBeDisabled()
    expect(screen.getByTestId('gl-ledger-row-gst-cgst')).toHaveTextContent('custom')
    expect(screen.queryByTestId('gl-ledger-group-company')).not.toBeInTheDocument()
    fireEvent.change(name, { target: { value: 'Rounding Off' } })
    fireEvent.click(screen.getByTestId('gl-ledger-map-save'))
    expect(await screen.findByTestId('gl-ledger-map-saved')).toBeInTheDocument()
    const put = calls.find((c) => c.method === 'PUT')!
    expect(put.body).toEqual({ ledgers: [{ key: 'round_off', name: 'Rounding Off', group: 'Indirect Expenses' }] })
    expect(screen.getByTestId('gl-ledger-name-round-off')).toHaveValue('Rounding Off')
  })
})
