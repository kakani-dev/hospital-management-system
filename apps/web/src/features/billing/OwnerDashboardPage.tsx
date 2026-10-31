import { useSearchParams } from 'react-router'
import { useQuery } from '@tanstack/react-query'
import { Alert } from '../../components/ui/Alert'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { ApiError, apiClient } from '../../lib/api/client'
import type { OwnerKpiDay } from '../../lib/api/types'
import { addDays, localToday } from '../../lib/dates'
import { useBranchTimeZones } from '../../lib/useBranchTimeZone'
import { useCurrentContext } from '../tenancy/useCurrentContext'
import { formatPaise } from './money'

type Preset = 'today' | 'yesterday' | '7d' | 'month'
const PRESETS: { id: Preset; label: string }[] = [
  { id: 'today', label: 'Today' },
  { id: 'yesterday', label: 'Yesterday' },
  { id: '7d', label: 'Last 7 days' },
  { id: 'month', label: 'This month' },
]
const MODE_LABEL: Record<string, string> = { cash: 'Cash', upi: 'UPI', card: 'Card', bank: 'Bank transfer', credit: 'Credit' }

export function rangeFor(preset: Preset, today: string): { from: string; to: string } {
  switch (preset) {
    case 'yesterday':
      return { from: addDays(today, -1), to: addDays(today, -1) }
    case '7d':
      return { from: addDays(today, -6), to: today }
    case 'month':
      return { from: `${today.slice(0, 8)}01`, to: today }
    default:
      return { from: today, to: today }
  }
}

const chip = (on: boolean) =>
  `rounded-full px-2.5 py-1 text-xs font-medium ${on ? 'bg-primary-600 text-white' : 'bg-gray-100 text-gray-700 hover:bg-gray-200 dark:bg-dark-600 dark:text-dark-100'}`

function Tile({ label, value, testId, hint, tone }: { label: string; value: string; testId: string; hint?: string; tone?: 'warn' | 'bad' }) {
  const color = tone === 'bad' ? 'text-red-700 dark:text-red-300' : tone === 'warn' ? 'text-amber-700 dark:text-amber-300' : 'text-gray-900 dark:text-dark-50'
  return (
    <div className="rounded-lg border border-gray-200 bg-white p-3 dark:border-dark-500 dark:bg-dark-700">
      <p className="text-xs text-gray-600 dark:text-dark-200">{label}</p>
      <p className={`mt-1 text-lg font-semibold ${color}`} data-testid={testId}>
        {value}
      </p>
      {hint && <p className="text-xs text-gray-500 dark:text-dark-300">{hint}</p>}
    </div>
  )
}

export function OwnerDashboardPage() {
  const { branches, has } = useCurrentContext()
  const zones = useBranchTimeZones()
  const [params, setParams] = useSearchParams()
  const preset = (PRESETS.find((p) => p.id === params.get('range'))?.id ?? 'today') as Preset
  const branchId = branches.some((b) => b.id === params.get('branch')) ? params.get('branch') : null
  // Wait for the branch time zone: before it loads, localToday would use the browser's zone and
  // ask for the wrong day around midnight.
  const zone = zones.zoneFor(branchId ?? branches[0]?.id)
  const today = localToday(new Date(), zone)
  const { from, to } = rangeFor(preset, today)
  const set = (k: string, v: string | null) => {
    const next = new URLSearchParams(params)
    if (v) next.set(k, v)
    else next.delete(k)
    setParams(next, { replace: true })
  }

  const kpis = useQuery({
    queryKey: ['owner-kpis', from, to, branchId],
    queryFn: () => apiClient.billing.ownerKpis({ from, to, branchId: branchId ?? undefined }),
    enabled: zone !== undefined,
  })
  const canStock = has('stock.view')
  const alerts = useQuery({
    queryKey: ['inventory', 'alerts', branchId ?? 'all'],
    queryFn: () => apiClient.inventory.alerts(branchId ?? undefined),
    enabled: canStock,
  })

  const t = kpis.data?.totals
  const modes = Object.entries(kpis.data?.byMode ?? {}).filter(([, v]) => v !== 0)
  // Net of collections (after refunds) against billed. A negative net means more money came in
  // than was billed in the range (advances/deposits, or payments on older bills): that is not
  // "negative dues", so dues show 0 and the surplus is shown as collected ahead of billing.
  const net = t ? t.billedPaise - t.collectedPaise + t.refundPaise : 0
  const outstanding = Math.max(0, net)
  const ahead = Math.max(0, -net)

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h1 className="text-xl font-semibold text-gray-900 dark:text-dark-50">Owner dashboard</h1>
        <p className="text-xs text-gray-500" data-testid="owner-range">
          {from === to ? from : `${from} to ${to}`} · read-only
        </p>
      </div>
      <div className="flex flex-wrap gap-1.5" role="group" aria-label="Date range">
        {PRESETS.map((p) => (
          <button key={p.id} type="button" className={chip(p.id === preset)} aria-pressed={p.id === preset} onClick={() => set('range', p.id === 'today' ? null : p.id)} data-testid={`owner-range-${p.id}`}>
            {p.label}
          </button>
        ))}
        {branches.length > 1 && (
          <>
            <span className="mx-1 w-px bg-gray-200 dark:bg-dark-500" aria-hidden />
            <button type="button" className={chip(!branchId)} aria-pressed={!branchId} onClick={() => set('branch', null)} data-testid="owner-branch-all">
              All branches
            </button>
            {branches.map((b) => (
              <button key={b.id} type="button" className={chip(branchId === b.id)} aria-pressed={branchId === b.id} onClick={() => set('branch', b.id)} data-testid={`owner-branch-${b.id}`}>
                {b.name}
              </button>
            ))}
          </>
        )}
      </div>

      {kpis.isPending && <LoadingBlock label="Loading figures" />}
      {kpis.error && (
        <Alert tone="error">{kpis.error instanceof ApiError ? kpis.error.message : 'Could not load the figures. Try again.'}</Alert>
      )}
      {t && (
        <>
          <section aria-label="Patients" className="grid grid-cols-2 gap-3 sm:grid-cols-4">
            <Tile label="OPD visits" value={String(t.opdVisits)} testId="kpi-opd-visits" />
            <Tile label="New patients" value={String(t.newPatients)} testId="kpi-new-patients" />
            <Tile label="No-shows" value={String(t.noShows)} testId="kpi-no-shows" tone={t.noShows > 0 ? 'warn' : undefined} />
            <Tile label="Pharmacy sales" value={formatPaise(t.pharmacySalesPaise)} hint={`${t.pharmacySales} dispensed (MRP)`} testId="kpi-pharmacy" />
          </section>
          <section aria-label="Money" className="grid grid-cols-2 gap-3 sm:grid-cols-4">
            <Tile label="Billed" value={formatPaise(t.billedPaise)} hint="Final bills, after credit notes" testId="kpi-billed" />
            <Tile label="Collected" value={formatPaise(t.collectedPaise)} hint="Payments and advances" testId="kpi-collected" />
            <Tile
              label="Billed not collected"
              value={formatPaise(outstanding)}
              hint={ahead > 0 ? `${formatPaise(ahead)} collected ahead of billing (advances or older bills)` : undefined}
              testId="kpi-outstanding"
              tone={outstanding > 0 ? 'warn' : undefined}
            />
            <Tile
              label="Refunds and discounts"
              value={formatPaise(t.refundPaise + t.discountPaise)}
              hint={`Refunds ${formatPaise(t.refundPaise)} · Discounts ${formatPaise(t.discountPaise)}`}
              testId="kpi-refunds-discounts"
            />
          </section>
          <div className="grid gap-3 lg:grid-cols-3">
            <section aria-label="Collections by method" className="rounded-lg border border-gray-200 bg-white p-3 dark:border-dark-500 dark:bg-dark-700">
              <h2 className="mb-2 text-sm font-medium">Collections by method (net of refunds)</h2>
              {modes.length === 0 ? (
                <p className="text-sm text-gray-500">No payments in this period.</p>
              ) : (
                <ul className="space-y-1 text-sm">
                  {modes.map(([mode, paise]) => (
                    <li key={mode} className="flex justify-between" data-testid={`kpi-mode-${mode}`}>
                      <span>{MODE_LABEL[mode] ?? mode}</span>
                      <span className="font-medium">{formatPaise(paise)}</span>
                    </li>
                  ))}
                </ul>
              )}
            </section>
            {canStock && (
              <section aria-label="Stock alerts" className="rounded-lg border border-gray-200 bg-white p-3 dark:border-dark-500 dark:bg-dark-700">
                <h2 className="mb-2 text-sm font-medium">Stock alerts (now)</h2>
                {alerts.data ? (
                  <ul className="space-y-1 text-sm" data-testid="kpi-stock-alerts">
                    <li className="flex justify-between"><span>Expired on shelf</span><span className="font-medium text-red-700">{alerts.data.counts.expired}</span></li>
                    <li className="flex justify-between"><span>Expiring in {alerts.data.nearExpiryDays} days</span><span className="font-medium text-amber-700">{alerts.data.counts.nearExpiry}</span></li>
                    <li className="flex justify-between"><span>Below reorder level</span><span className="font-medium">{alerts.data.counts.lowStock}</span></li>
                  </ul>
                ) : alerts.error ? (
                  <p className="text-sm text-gray-500">Unavailable</p>
                ) : (
                  <p className="text-sm text-gray-500">—</p>
                )}
              </section>
            )}
          </div>
          {kpis.data && kpis.data.days.length > 1 && <DailyTable days={kpis.data.days} />}
        </>
      )}
    </div>
  )
}

function DailyTable({ days }: { days: OwnerKpiDay[] }) {
  return (
    <section aria-label="Day by day" className="overflow-x-auto rounded-lg border border-gray-200 bg-white p-3 dark:border-dark-500 dark:bg-dark-700">
      <h2 className="mb-2 text-sm font-medium">Day by day</h2>
      <table className="w-full text-left text-sm">
        <thead>
          <tr className="text-gray-500">
            <th className="py-1 pr-3 font-medium">Date</th>
            <th className="py-1 pr-3 font-medium">OPD</th>
            <th className="py-1 pr-3 font-medium">New</th>
            <th className="py-1 pr-3 font-medium">No-shows</th>
            <th className="py-1 pr-3 font-medium">Billed</th>
            <th className="py-1 pr-3 font-medium">Collected</th>
            <th className="py-1 font-medium">Pharmacy</th>
          </tr>
        </thead>
        <tbody>
          {[...days].reverse().map((d) => (
            <tr key={d.date} className="border-t border-gray-100 dark:border-dark-500" data-testid="kpi-day">
              <td className="py-1 pr-3">{d.date}</td>
              <td className="py-1 pr-3">{d.opdVisits}</td>
              <td className="py-1 pr-3">{d.newPatients}</td>
              <td className="py-1 pr-3">{d.noShows}</td>
              <td className="py-1 pr-3">{formatPaise(d.billedPaise)}</td>
              <td className="py-1 pr-3">{formatPaise(d.collectedPaise)}</td>
              <td className="py-1">{formatPaise(d.pharmacySalesPaise)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  )
}
