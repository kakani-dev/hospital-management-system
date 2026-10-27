import { useEffect } from 'react'
import { useSearchParams } from 'react-router'
import { useQuery } from '@tanstack/react-query'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { ApiError, apiClient } from '../../lib/api/client'
import type { EarningsCard, EarningsMove, EarningsReport } from '../../lib/api/types'
import { localToday } from '../../lib/dates'
import { useBranchTimeZones } from '../../lib/useBranchTimeZone'
import { useCurrentContext } from '../tenancy/useCurrentContext'
import { formatPaise } from './money'

const GRAINS = ['day', 'week', 'month'] as const

/** One page: hospital totals, one card per branch, and the accounts registers a CA exports. */
export function EarningsPage() {
  const { branches } = useCurrentContext()
  const zones = useBranchTimeZones()
  const [params, setParams] = useSearchParams()
  const from = params.get('from') ?? ''
  const to = params.get('to') ?? ''
  const branch = params.get('branch') ?? ''
  const grain = params.get('grain') ?? ''
  const fy = params.get('fy') ?? ''
  const quarter = params.get('quarter') ?? ''
  const tab = params.get('tab') === 'accounts' ? 'accounts' : 'overview'

  useEffect(() => {
    if ((from && to) || fy || !zones.defaultZone) return
    const today = localToday(new Date(), zones.defaultZone)
    const next = new URLSearchParams(params)
    next.set('from', `${today.slice(0, 8)}01`)
    next.set('to', today)
    setParams(next, { replace: true })
  }, [from, to, fy, zones.defaultZone, params, setParams])

  const query = useQuery({
    queryKey: ['billing', 'earnings', from, to, branch, grain, fy, quarter],
    queryFn: () =>
      apiClient.billing.earnings({
        from: fy ? undefined : from,
        to: fy ? undefined : to,
        branchId: branch || undefined,
        grain: grain || undefined,
        fy: fy || undefined,
        quarter: quarter || undefined,
      }),
    enabled: Boolean((from && to) || fy),
  })

  function write(patch: Record<string, string | null>) {
    const next = new URLSearchParams(params)
    for (const [key, value] of Object.entries(patch)) {
      if (value) next.set(key, value)
      else next.delete(key)
    }
    setParams(next)
  }

  const report = query.data
  const focus = report?.focus

  return (
    <div className="mx-auto max-w-6xl space-y-4 p-4 sm:p-6">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Earnings</h1>
          <p className="text-sm text-gray-500">Hospital totals, each branch, and the accounts a CA can export.</p>
        </div>
        <div className="flex gap-2">
          <Button variant={tab === 'overview' ? 'primary' : 'secondary'} onClick={() => write({ tab: null })}>
            Overview
          </Button>
          <Button variant={tab === 'accounts' ? 'primary' : 'secondary'} onClick={() => write({ tab: 'accounts' })}>
            Accounts
          </Button>
        </div>
      </div>

      <div className="flex flex-wrap gap-3">
        <label className="text-sm">
          From
          <input
            type="date"
            aria-label="From"
            className="mt-1 block rounded-lg border border-gray-300 px-3 py-2 dark:border-dark-500 dark:bg-dark-700"
            value={from}
            onChange={(e) => write({ from: e.target.value, fy: null, quarter: null })}
          />
        </label>
        <label className="text-sm">
          To
          <input
            type="date"
            aria-label="To"
            className="mt-1 block rounded-lg border border-gray-300 px-3 py-2 dark:border-dark-500 dark:bg-dark-700"
            value={to || report?.to || ''}
            onChange={(e) => write({ to: e.target.value, fy: null, quarter: null })}
          />
        </label>
        <label className="text-sm">
          Grain
          <select
            aria-label="Grain"
            className="mt-1 block rounded-lg border border-gray-300 px-3 py-2 dark:border-dark-500 dark:bg-dark-700"
            value={grain}
            onChange={(e) => write({ grain: e.target.value || null })}
          >
            <option value="">Automatic</option>
            {GRAINS.map((g) => (
              <option key={g} value={g}>{g}</option>
            ))}
          </select>
        </label>
        <label className="text-sm">
          Financial year
          <select
            aria-label="Financial year"
            className="mt-1 block rounded-lg border border-gray-300 px-3 py-2 dark:border-dark-500 dark:bg-dark-700"
            value={fy}
            onChange={(e) => {
              const year = e.target.value
              if (!year) {
                write({ fy: null, quarter: null })
                return
              }
              const start = Number(year)
              const range = quarterRange(start, quarter || null)
              write({ fy: year, from: range.from, to: range.to })
            }}
          >
            <option value="">Custom dates</option>
            {[0, 1, 2].map((offset) => {
              const year = new Date().getFullYear() - offset
              return <option key={year} value={year}>{year}–{String(year + 1).slice(2)}</option>
            })}
          </select>
        </label>
        <label className="text-sm">
          Quarter
          <select
            aria-label="Quarter"
            className="mt-1 block rounded-lg border border-gray-300 px-3 py-2 dark:border-dark-500 dark:bg-dark-700"
            value={quarter}
            disabled={!fy}
            onChange={(e) => {
              const q = e.target.value
              const range = quarterRange(Number(fy), q || null)
              write({ quarter: q || null, from: range.from, to: range.to })
            }}
          >
            <option value="">Full year</option>
            <option value="1">Q1 Apr–Jun</option>
            <option value="2">Q2 Jul–Sep</option>
            <option value="3">Q3 Oct–Dec</option>
            <option value="4">Q4 Jan–Mar</option>
          </select>
        </label>
      </div>

      {query.isError && <Alert tone="error">{query.error instanceof ApiError ? 'The earnings report could not be loaded.' : 'Something went wrong.'}</Alert>}
      {query.isPending && <LoadingBlock />}
      {report && focus && tab === 'overview' && <Overview report={report} focus={focus} branch={branch} branches={branches} onBranch={(id) => write({ branch: id, fy: null, quarter: null })} />}
      {report && tab === 'accounts' && <Accounts report={report} />}
    </div>
  )
}

function Overview({
  report, focus, branch, branches, onBranch,
}: {
  report: EarningsReport
  focus: EarningsCard
  branch: string
  branches: { id: string; name: string }[]
  onBranch: (id: string | null) => void
}) {
  const max = Math.max(1, ...report.trend.map((p) => p.grossBilledPaise))
  return (
    <>
      <p className="text-sm text-gray-500">{report.level === 'tenant' ? 'All branches' : 'One branch'} · {report.from} to {report.to}</p>
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Kpi testId="earnings-gross" label="Gross billed" amount={focus.grossBilledPaise} move={focus.deltas.grossBilled} />
        <Kpi label="Collected" amount={focus.collectedPaise} move={focus.deltas.collected} />
        <Kpi label="Net earnings" amount={focus.netEarningsPaise} move={focus.deltas.netEarnings} />
        <Kpi label="Outstanding" amount={focus.outstandingPaise} />
        <Kpi label="Refunds" amount={focus.refundsPaise} move={focus.deltas.refunds} />
        <Kpi label="GST" amount={focus.cgstPaise + focus.sgstPaise + focus.igstPaise} hint={`CGST ${formatPaise(focus.cgstPaise)} · SGST ${formatPaise(focus.sgstPaise)} · IGST ${formatPaise(focus.igstPaise)}`} />
        <Kpi label="Bills" text={String(focus.billCount)} move={focus.deltas.billCount} hint={focus.averageBillPaise == null ? undefined : `Average ${formatPaise(focus.averageBillPaise)}`} />
        <Kpi label="Collection" text={focus.collectionEfficiencyPct == null ? '—' : `${focus.collectionEfficiencyPct}%`} move={focus.deltas.collectionEfficiency} />
      </div>
      <div className="flex flex-wrap gap-2">
        <button type="button" data-testid="earnings-branch" className={chip(!branch)} onClick={() => onBranch(null)}>All branches</button>
        {(report.branches.length ? report.branches : branches.map((b) => ({ branchId: b.id, name: b.name, direction: 'flat' as const, sharePct: 0, grossBilledPaise: 0, rank: 0, gstin: '' }))).map((b) => (
          <button key={b.branchId} type="button" data-testid="earnings-branch" className={chip(branch === b.branchId)} onClick={() => onBranch(b.branchId)}>
            {b.name} · {formatPaise(b.grossBilledPaise)} · {arrow(b.direction)} {b.sharePct}%
          </button>
        ))}
      </div>
      <ul className="space-y-1 text-sm">
        {report.insights.map((line) => (
          <li key={line} data-testid="earnings-insight">{line}</li>
        ))}
      </ul>
      <svg data-testid="earnings-trend" viewBox={`0 0 ${Math.max(report.trend.length, 1) * 24} 80`} className="h-24 w-full" role="img" aria-label="Gross billed trend">
        {report.trend.map((point, i) => (
          <rect key={point.bucket} x={i * 24 + 4} y={76 - (point.grossBilledPaise / max) * 72} width="16" height={(point.grossBilledPaise / max) * 72} className="fill-primary-600" />
        ))}
      </svg>
      <div className="grid gap-4 lg:grid-cols-2">
        <SimpleTable title="Ageing" rows={[
          ['0–30', formatPaise(report.ageing.b0To30Paise)],
          ['31–60', formatPaise(report.ageing.b31To60Paise)],
          ['61–90', formatPaise(report.ageing.b61To90Paise)],
          ['90+', formatPaise(report.ageing.b90PlusPaise)],
        ]} />
        <SimpleTable title="Payment modes" rows={report.paymentModes.map((m) => [m.mode, formatPaise(m.collectedPaise)])} />
      </div>
    </>
  )
}

function Accounts({ report }: { report: EarningsReport }) {
  return (
    <div className="space-y-4">
      {report.truncated && <Alert tone="warning">A register was cut at 500 rows. Narrow the dates to export the rest.</Alert>}
      <div className="flex flex-wrap gap-2">
        <ExportButton report={report} section="sales" label="Sales register CSV" format="csv" />
        <ExportButton report={report} section="sales" label="Sales register Excel" format="xlsx" />
        <ExportButton report={report} section="credits" label="Credit notes CSV" format="csv" />
        <ExportButton report={report} section="refunds" label="Refund register CSV" format="csv" />
        <ExportButton report={report} section="receipts" label="Receipts CSV" format="csv" />
        <ExportButton report={report} section="cash" label="Day-end cash CSV" format="csv" />
        <ExportButton report={report} section="gst" label="GST summary CSV" format="csv" />
        <ExportButton report={report} section="hsn" label="HSN summary CSV" format="csv" />
        <ExportButton report={report} section="ageing" label="Ageing CSV" format="csv" />
        <ExportButton report={report} section={undefined} label="All accounts Excel" format="xlsx" />
      </div>
      <section data-testid="gst-summary">
        <h2 className="mb-2 font-medium">GST summary</h2>
        <div className="overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead>
              <tr>{['GSTIN', 'Month', 'B2C taxable', 'B2B taxable', 'CGST', 'SGST', 'IGST', 'Credit notes'].map((h) => <th key={h} className="px-2 py-1">{h}</th>)}</tr>
            </thead>
            <tbody>
              {report.gstr1.map((row, i) => (
                <tr key={i} data-testid="billing-earnings-gst-row">
                  <td className="px-2 py-1" data-testid="billing-earnings-gst-gstin">{String(row.gstin)}</td>
                  <td className="px-2 py-1" data-testid="billing-earnings-gst-month">{String(row.month)}</td>
                  <td className="px-2 py-1">{formatPaise(Number(row.b2cTaxablePaise))}</td>
                  <td className="px-2 py-1">{formatPaise(Number(row.b2bTaxablePaise))}</td>
                  <td className="px-2 py-1">{formatPaise(Number(row.b2cCgstPaise) + Number(row.b2bCgstPaise))}</td>
                  <td className="px-2 py-1">{formatPaise(Number(row.b2cSgstPaise) + Number(row.b2bSgstPaise))}</td>
                  <td className="px-2 py-1">{formatPaise(Number(row.b2cIgstPaise) + Number(row.b2bIgstPaise))}</td>
                  <td className="px-2 py-1">{String(row.creditNoteCount)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
      <section data-testid="sales-register">
        <h2 className="mb-2 font-medium">Sales register</h2>
        <div className="overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead>
              <tr>{['Invoice number', 'Date', 'Party', 'Taxable value', 'Tax', 'Total'].map((h) => <th key={h} className="px-2 py-1">{h}</th>)}</tr>
            </thead>
            <tbody>
              {report.sales.map((row, i) => (
                <tr key={i}>
                  <td className="px-2 py-1">{String(row.invoiceNumber)}</td>
                  <td className="px-2 py-1">{String(row.date)}</td>
                  <td className="px-2 py-1">{String(row.party)}</td>
                  <td className="px-2 py-1">{formatPaise(Number(row.taxablePaise))}</td>
                  <td className="px-2 py-1">{formatPaise(Number(row.taxPaise))}</td>
                  <td className="px-2 py-1">{formatPaise(Number(row.totalPaise))}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  )
}

function ExportButton({ report, section, label, format }: { report: EarningsReport; section?: string; label: string; format: 'csv' | 'xlsx' }) {
  return (
    <Button
      variant="secondary"
      data-testid={`billing-earnings-export-${section ?? 'all'}-${format}`}
      onClick={() => {
        void apiClient.billing.earningsExport({
          from: report.financialYear ? undefined : report.from,
          to: report.financialYear ? undefined : report.to,
          fy: report.financialYear ? String(report.financialYear) : undefined,
          quarter: report.quarter ? String(report.quarter) : undefined,
          branchId: report.branchId ?? undefined,
          grain: report.grain,
          format,
          section,
        }).then(({ blob, filename }) => {
          const url = URL.createObjectURL(blob)
          const a = document.createElement('a')
          a.href = url
          a.download = filename
          a.click()
          URL.revokeObjectURL(url)
        })
      }}
    >
      {label}
    </Button>
  )
}

function Kpi({ label, amount, text, move, hint, testId }: { label: string; amount?: number; text?: string; move?: EarningsMove; hint?: string; testId?: string }) {
  return (
    <div className="rounded-xl border border-gray-200 p-3 dark:border-dark-500" data-testid={testId}>
      <div className="text-xs text-gray-500">{label}</div>
      <div className="text-lg font-semibold">{text ?? (amount == null ? '—' : formatPaise(amount))}</div>
      {move && <div className="text-xs">{move.direction === 'new' ? 'new' : `${arrow(move.direction)} ${move.pct ?? ''}${move.pct == null ? '' : '%'}`}</div>}
      {hint && <div className="text-xs text-gray-500">{hint}</div>}
    </div>
  )
}

function SimpleTable({ title, rows }: { title: string; rows: string[][] }) {
  return (
    <section>
      <h2 className="mb-2 font-medium">{title}</h2>
      <table className="w-full text-left text-sm">
        <tbody>
          {rows.map((row) => (
            <tr key={row.join('|')}><td className="py-1">{row[0]}</td><td className="py-1 text-right">{row[1]}</td></tr>
          ))}
        </tbody>
      </table>
    </section>
  )
}

function arrow(direction: string) {
  if (direction === 'up') return '↑'
  if (direction === 'down') return '↓'
  if (direction === 'new') return 'new'
  return '–'
}

function chip(active: boolean) {
  return `rounded-full border px-3 py-1 text-sm ${active ? 'border-primary-600 bg-primary-50' : 'border-gray-300'}`
}

function quarterRange(year: number, quarter: string | null) {
  if (!quarter) return { from: `${year}-04-01`, to: `${year + 1}-03-31` }
  if (quarter === '1') return { from: `${year}-04-01`, to: `${year}-06-30` }
  if (quarter === '2') return { from: `${year}-07-01`, to: `${year}-09-30` }
  if (quarter === '3') return { from: `${year}-10-01`, to: `${year}-12-31` }
  return { from: `${year + 1}-01-01`, to: `${year + 1}-03-31` }
}
