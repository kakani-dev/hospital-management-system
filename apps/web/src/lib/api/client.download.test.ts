import { describe, expect, it, vi } from 'vitest'
import { ApiClient, earningsExportName, filenameFromDisposition } from './client'

describe('filenameFromDisposition (#90)', () => {
  it.each([
    // What ASP.NET Results.File sends: bare filename plus RFC 5987 filename*.
    ["attachment; filename=earnings-sales-2026-10-01-2026-10-31.xlsx; filename*=UTF-8''earnings-sales-2026-10-01-2026-10-31.xlsx", 'earnings-sales-2026-10-01-2026-10-31.xlsx'],
    ['attachment; filename="earnings-gst-2026-10-01-2026-10-31.csv"', 'earnings-gst-2026-10-01-2026-10-31.csv'],
    ['attachment; filename=earnings-sales-a-b.csv', 'earnings-sales-a-b.csv'],
    ["attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.csv", 'résumé.csv'],
    ['attachment; filename="../../evil.csv"', '.._.._evil.csv'],
  ])('%s → %s', (header, name) => expect(filenameFromDisposition(header)).toBe(name))

  it.each([null, '', 'attachment', 'attachment; filename=""'])('no name in %j → null', (header) =>
    expect(filenameFromDisposition(header)).toBeNull(),
  )
})

describe('earningsExportName fallback (#90)', () => {
  it('names each register and keeps the right extension', () => {
    expect(earningsExportName({ from: '2026-10-01', to: '2026-10-31', format: 'csv', section: 'sales' })).toBe('earnings-sales-2026-10-01-2026-10-31.csv')
    expect(earningsExportName({ from: '2026-10-01', to: '2026-10-31', format: 'xlsx', section: 'gst' })).toBe('earnings-gst-2026-10-01-2026-10-31.xlsx')
    expect(earningsExportName({ from: '2026-10-01', to: '2026-10-31', format: 'xlsx' })).toBe('earnings-accounts-2026-10-01-2026-10-31.xlsx')
    expect(earningsExportName({ fy: '2026', quarter: '3', format: 'xlsx', section: 'sales' })).toBe('earnings-sales-FY2026-Q3.xlsx')
  })
})

describe('ApiClient.download names files from the server (#90)', () => {
  const setup = (headers: Record<string, string>) => {
    const fetchImpl = vi.fn(async () => new Response('PK', { status: 200, headers }))
    return new ApiClient({ baseUrl: 'https://api.example.test', fetchImpl })
  }

  it('uses the server file name for an Excel export, not earnings.csv', async () => {
    const client = setup({ 'Content-Disposition': "attachment; filename=earnings-sales-a-b.xlsx; filename*=UTF-8''earnings-sales-a-b.xlsx" })
    const { filename } = await client.billing.earningsExport({ from: 'a', to: 'b', format: 'xlsx', section: 'sales' })
    expect(filename).toBe('earnings-sales-a-b.xlsx')
  })

  it('falls back to a register-specific name when the header is hidden', async () => {
    const client = setup({})
    const xlsx = await client.billing.earningsExport({ from: '2026-10-01', to: '2026-10-31', format: 'xlsx' })
    const csv = await client.billing.earningsExport({ from: '2026-10-01', to: '2026-10-31', format: 'csv', section: 'gst' })
    expect(xlsx.filename).toBe('earnings-accounts-2026-10-01-2026-10-31.xlsx')
    expect(csv.filename).toBe('earnings-gst-2026-10-01-2026-10-31.csv')
  })
})
