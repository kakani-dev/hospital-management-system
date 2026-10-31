import { useState, type FormEvent } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { Illustration } from '../../components/ui/Illustration'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { ApiError, apiClient } from '../../lib/api/client'
import type { DayCloseMethod, DayCloseSession, DayCloseSummary } from '../../lib/api/types'
import { localToday } from '../../lib/dates'
import { useCurrentContext } from '../tenancy/useCurrentContext'
import { useBranchSelection } from '../tenancy/useBranchSelection'
import { formatPaise, parseRupeesToPaise } from './money'

const input = 'rounded border border-gray-300 px-2 py-1 text-sm dark:border-dark-500 dark:bg-dark-700'
const small = 'px-2 py-1 text-xs'

const BLOCKER_TEXT: Record<string, string> = {
  open_sessions: 'A cash drawer is still open.',
  unsettled_methods: 'Enter the settled amount for every card, UPI and bank line.',
  stale_settlements: 'Payments came in after a settlement was entered. Save the settlements again.',
}

const methodKey = (m: { mode: string; paymentAccountId: string | null }) => `${m.mode}|${m.paymentAccountId ?? ''}`
const rupees = (paise: number) => (paise / 100).toFixed(2)
const errorText = (e: unknown, fallback: string) => (e instanceof ApiError ? e.message : fallback)

/**
 * #65: day-end close on one screen. Cash per drawer (count, reason, handover to the next shift),
 * card / UPI / bank (incl. cheque) settled per account against expected, advances and refunds,
 * and the supervisor sign-off that locks the day.
 */
export function DayEndPage() {
  const { has } = useCurrentContext()
  const { branchId, timeZone, timeZoneReady } = useBranchSelection()
  const today = timeZoneReady ? localToday(new Date(), timeZone) : ''
  const [picked, setPicked] = useState('')
  const date = picked || today
  const qc = useQueryClient()
  const key = ['billing', 'day-close', branchId, date]
  const report = useQuery({
    queryKey: key,
    queryFn: () => apiClient.billing.dayClose(branchId!, date),
    enabled: !!branchId && !!date,
  })
  const refresh = () => qc.invalidateQueries({ queryKey: ['billing', 'day-close'] })
  const day = report.data
  const labels = day?.methodLabels ?? {}
  const label = (mode: string) => labels[mode] ?? mode.toUpperCase()

  return (
    <div className="mx-auto max-w-4xl space-y-4 p-4 sm:p-6" data-testid="day-close">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Day end close</h1>
        <label className="text-sm">
          Business date
          <input data-testid="billing-day-end-date" type="date" aria-label="Business date" className={`ml-2 ${input}`}
            value={date} onChange={(e) => setPicked(e.target.value)} />
        </label>
      </div>
      {report.isPending && <LoadingBlock label="Loading the day" />}
      {report.isError && <Alert tone="error">{errorText(report.error, 'Could not load the day.')}</Alert>}
      {day && (
        <>
          <Totals day={day} />
          {day.signoff && (
            <Alert tone={day.signoff.changedSince ? 'warning' : 'info'}>
              <span data-testid="day-close-signed">
                Signed off {new Date(day.signoff.signedAt).toLocaleString('en-IN')}
                {day.signoff.note ? ` · ${day.signoff.note}` : ''}
                {day.signoff.changedSince ? ' · Payments changed after sign-off: tell accounts.' : ''}
              </span>
            </Alert>
          )}
          <section aria-labelledby="dc-cash" className="space-y-2">
            <h2 id="dc-cash" className="text-sm font-semibold text-gray-700 dark:text-dark-100">{label('cash')} drawers</h2>
            {day.sessions.length === 0 && (
              <div className="py-4 text-center">
                <Illustration name="file" size={72} className="mx-auto" />
                <p className="mt-2 text-sm text-gray-500">No counters opened this day.</p>
              </div>
            )}
            <ul className="space-y-2">
              {day.sessions.map((s) => (
                <DrawerRow key={s.sessionId} session={s} reasons={day.varianceReasons ?? []} locked={!!day.signoff}
                  canClose={has('billing.collect') && (s.mine || has('billing.reconcile'))}
                  canReceive={has('billing.collect') && !s.mine} canReconcile={has('billing.reconcile')} onDone={refresh} />
              ))}
            </ul>
          </section>
          <Settlements day={day} label={label} canEdit={has('billing.collect') && !day.signoff} onSaved={(d) => qc.setQueryData(key, d)} />
          <Flow day={day} label={label} />
          {has('billing.reconcile') && !day.signoff && <SignOff day={day} onSigned={(d) => qc.setQueryData(key, d)} />}
        </>
      )}
    </div>
  )
}

function Totals({ day }: { day: DayCloseSummary }) {
  const cell = 'rounded-lg border border-gray-200 p-3 dark:border-dark-500'
  return (
    <div className="grid grid-cols-2 gap-2 text-sm sm:grid-cols-4">
      <div className={cell}>Expected (all methods)<p className="font-semibold" data-testid="dc-expected-total">{formatPaise(day.expectedTotalPaise)}</p></div>
      <div className={cell}>Cash counted<p className="font-semibold">{formatPaise(day.cash.countedPaise)}</p></div>
      <div className={cell}>Cash variance<p className="font-semibold" data-testid="dc-cash-variance">{formatPaise(day.cash.variancePaise)}</p></div>
      <div className={cell}>Card/UPI/bank variance<p className="font-semibold" data-testid="dc-other-variance">{formatPaise(day.otherVariancePaise)}</p></div>
    </div>
  )
}

function DrawerRow({ session: s, reasons, locked, canClose, canReceive, canReconcile, onDone }: {
  session: DayCloseSession; reasons: string[]; locked: boolean; canClose: boolean; canReceive: boolean; canReconcile: boolean; onDone: () => void
}) {
  const [counted, setCounted] = useState('')
  const [handover, setHandover] = useState('')
  const [reason, setReason] = useState('')
  const countedPaise = counted.trim() === '' ? null : parseRupeesToPaise(counted)
  const handoverPaise = handover.trim() === '' ? 0 : parseRupeesToPaise(handover)
  const variance = countedPaise == null ? null : countedPaise - s.expectedCashPaise
  const close = useMutation({
    mutationFn: () => apiClient.billing.closeDrawer(s.sessionId, {
      countedCashPaise: countedPaise!, handoverPaise: handoverPaise ?? 0, reason: variance ? reason.trim() : undefined }),
    onSuccess: onDone,
  })
  const receive = useMutation({ mutationFn: (id: string) => apiClient.billing.receiveHandover(id), onSuccess: onDone })
  const reconcile = useMutation({ mutationFn: () => apiClient.billing.reconcile(s.sessionId), onSuccess: onDone })
  const invalid = countedPaise == null || handoverPaise == null || handoverPaise > countedPaise || (!!variance && reason.trim() === '')
  const submit = (e: FormEvent) => {
    e.preventDefault()
    if (!invalid) close.mutate()
  }
  const h = s.handover
  return (
    <li className="rounded-lg border border-gray-200 p-3 text-sm dark:border-dark-500" data-testid="day-end-session" data-session-id={s.sessionId}>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p>
          <span className="font-medium">{s.counterName ?? 'Counter'}</span>
          {s.mine && <span className="ml-1 text-xs text-primary-600">(you)</span>}
          {' · '}<span className="capitalize" data-testid="session-status">{s.status === 'stale' ? 'stale (earlier day)' : s.status}</span>
        </p>
        <p className="text-gray-600 dark:text-dark-200">
          Float {formatPaise(s.openingFloatPaise)} · <span data-testid="session-expected">Expected {formatPaise(s.expectedCashPaise)}</span>
          {s.countedCashPaise != null && ` · Counted ${formatPaise(s.countedCashPaise)}`}
          {s.variancePaise != null && <> · <span data-testid="session-variance">Variance {formatPaise(s.variancePaise)}</span></>}
          {canReconcile && s.status === 'closed' && !locked && (
            <Button className={`ml-2 ${small}`} variant="secondary" disabled={reconcile.isPending} onClick={() => reconcile.mutate()}>Reconcile</Button>
          )}
        </p>
      </div>
      {s.varianceReason && <p className="mt-1 text-xs text-gray-500" data-testid="session-reason">Reason: {s.varianceReason}</p>}
      {h && (
        <p className="mt-1 flex flex-wrap items-center gap-2 text-xs" data-testid="session-handover">
          Handed over {formatPaise(h.amountPaise)}{h.note ? ` (${h.note})` : ''}
          {h.receivedAt ? ` · received ${new Date(h.receivedAt).toLocaleTimeString('en-IN')}` : ' · awaiting the next cashier'}
          {!h.receivedAt && canReceive && !locked && (
            <Button className={small} variant="secondary" data-testid="receive-handover" disabled={receive.isPending}
              onClick={() => receive.mutate(h.id)}>Receive {formatPaise(h.amountPaise)}</Button>
          )}
        </p>
      )}
      {receive.isError && <Alert tone="error">{errorText(receive.error, 'Could not receive the handover.')}</Alert>}
      {(s.status === 'open' || s.status === 'stale') && canClose && !locked && (
        <form noValidate onSubmit={submit} className="mt-2 flex flex-wrap items-end gap-2" data-testid="close-drawer-form">
          <label className="text-xs">Counted ₹
            <input className={`ml-1 w-28 ${input}`} inputMode="decimal" data-testid="close-counted" value={counted}
              placeholder={rupees(s.expectedCashPaise)} onChange={(e) => setCounted(e.target.value)} />
          </label>
          <Button className={small} variant="ghost" data-testid="close-counted-match" onClick={() => setCounted(rupees(s.expectedCashPaise))}>
            = expected
          </Button>
          <label className="text-xs">Hand over ₹
            <input className={`ml-1 w-24 ${input}`} inputMode="decimal" data-testid="close-handover" value={handover}
              placeholder="0" onChange={(e) => setHandover(e.target.value)} />
          </label>
          {variance != null && variance !== 0 && (
            <label className="text-xs">
              <span data-testid="close-variance">{formatPaise(variance)}</span> reason
              <input className={`ml-1 w-48 ${input}`} list={`dc-reasons-${s.sessionId}`} data-testid="close-reason" value={reason}
                maxLength={200} onChange={(e) => setReason(e.target.value)} />
              <datalist id={`dc-reasons-${s.sessionId}`}>{reasons.map((r) => <option key={r} value={r} />)}</datalist>
            </label>
          )}
          <Button type="submit" className={small} data-testid="close-drawer" disabled={invalid || close.isPending}>Close drawer</Button>
        </form>
      )}
      {close.isError && <Alert tone="error">{errorText(close.error, 'Could not close the drawer.')}</Alert>}
    </li>
  )
}

function Settlements({ day, label, canEdit, onSaved }: {
  day: DayCloseSummary; label: (m: string) => string; canEdit: boolean; onSaved: (d: DayCloseSummary) => void
}) {
  const [draft, setDraft] = useState<Record<string, { settled?: string; reason?: string }>>({})
  const value = (m: DayCloseMethod) => draft[methodKey(m)]?.settled ?? rupees(m.settledPaise ?? m.expectedPaise)
  const reasonOf = (m: DayCloseMethod) => draft[methodKey(m)]?.reason ?? m.reason ?? ''
  const rows = day.methods.map((m) => {
    const settled = parseRupeesToPaise(value(m))
    return { m, settled, variance: settled == null ? null : settled - m.expectedPaise }
  })
  const invalid = rows.some((r) => r.settled == null || (!!r.variance && reasonOf(r.m).trim() === ''))
  const save = useMutation({
    mutationFn: () => apiClient.billing.saveSettlements(day.branchId, day.date, rows.map((r) => ({
      mode: r.m.mode, paymentAccountId: r.m.paymentAccountId, settledPaise: r.settled!,
      reason: r.variance ? reasonOf(r.m).trim() : undefined }))),
    onSuccess: (d) => { setDraft({}); onSaved(d) },
  })
  const set = (m: DayCloseMethod, patch: { settled?: string; reason?: string }) =>
    setDraft((d) => ({ ...d, [methodKey(m)]: { ...d[methodKey(m)], ...patch } }))
  return (
    <section aria-labelledby="dc-other" className="space-y-2">
      <h2 id="dc-other" className="text-sm font-semibold text-gray-700 dark:text-dark-100">Card, UPI and bank / cheque</h2>
      {rows.length === 0 ? <p className="text-sm text-gray-500" data-testid="dc-no-methods">No card, UPI or bank receipts this day.</p> : (
        <form noValidate onSubmit={(e) => { e.preventDefault(); if (!invalid) save.mutate() }}>
          <table className="w-full text-sm">
            <thead><tr className="text-left text-xs text-gray-500">
              <th className="py-1">Method</th><th>Expected</th><th>Settled ₹</th><th>Variance</th><th>Reason</th>
            </tr></thead>
            <tbody>
              {rows.map(({ m, variance }) => (
                <tr key={methodKey(m)} data-testid="dc-method" data-mode={m.mode} className="border-t border-gray-100 dark:border-dark-600">
                  <td className="py-1">
                    {label(m.mode)}{m.label && m.label !== 'Unassigned' ? ` · ${m.label}` : ''}
                    <span className="block text-xs text-gray-500">{m.count} txn{m.refundedPaise ? ` · refunds ${formatPaise(m.refundedPaise)}` : ''}</span>
                    {m.stale && <span className="text-xs text-amber-600" data-testid="dc-stale">changed since saved</span>}
                  </td>
                  <td data-testid="dc-method-expected">{formatPaise(m.expectedPaise)}</td>
                  <td><input className={`w-28 ${input}`} inputMode="decimal" aria-label={`${label(m.mode)} settled`} data-testid="dc-settled"
                    disabled={!canEdit} value={value(m)} onChange={(e) => set(m, { settled: e.target.value })} /></td>
                  <td data-testid="dc-method-variance">{variance == null ? '—' : formatPaise(variance)}</td>
                  <td>{variance ? (
                    <input className={`w-44 ${input}`} list="dc-method-reasons" aria-label={`${label(m.mode)} reason`} data-testid="dc-reason"
                      disabled={!canEdit} maxLength={200} value={reasonOf(m)} onChange={(e) => set(m, { reason: e.target.value })} />
                  ) : '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <datalist id="dc-method-reasons">{(day.varianceReasons ?? []).map((r) => <option key={r} value={r} />)}</datalist>
          {canEdit && (
            <div className="mt-2 flex justify-end">
              <Button type="submit" className={small} data-testid="dc-save-settlements" disabled={invalid || save.isPending}>Save settlements</Button>
            </div>
          )}
          {save.isError && <Alert tone="error">{errorText(save.error, 'Could not save the settlements.')}</Alert>}
        </form>
      )}
    </section>
  )
}

function Flow({ day, label }: { day: DayCloseSummary; label: (m: string) => string }) {
  const modes = Object.entries(day.flowByMode ?? {})
  return (
    <section aria-label="Advances and refunds" className="rounded-lg border border-gray-200 p-3 text-sm dark:border-dark-500" data-testid="dc-flow">
      <p>
        Advances {day.advances.count} · {formatPaise(day.advances.amountPaise)}
        {' · '}Refunds {day.refunds.count} · {formatPaise(day.refunds.amountPaise)}
        {' · '}{label('credit')} {day.credit.count} · {formatPaise(day.credit.amountPaise)}
      </p>
      {modes.length > 0 && (
        <p className="mt-1 text-xs text-gray-500">
          {modes.map(([mode, v]) => `${label(mode)}: +${formatPaise(v.advancePaise)} / −${formatPaise(v.refundPaise)}`).join(' · ')}
        </p>
      )}
    </section>
  )
}

function SignOff({ day, onSigned }: { day: DayCloseSummary; onSigned: (d: DayCloseSummary) => void }) {
  const [note, setNote] = useState('')
  const sign = useMutation({ mutationFn: () => apiClient.billing.signOffDay(day.branchId, day.date, note.trim() || undefined), onSuccess: onSigned })
  const blocked = day.blockers.length > 0
  return (
    <section aria-label="Supervisor sign-off" className="space-y-2 rounded-lg border border-gray-200 p-3 dark:border-dark-500" data-testid="dc-signoff">
      {blocked && (
        <ul className="list-disc pl-5 text-sm text-amber-700" data-testid="dc-blockers">
          {day.blockers.map((b) => <li key={b}>{BLOCKER_TEXT[b] ?? b}</li>)}
        </ul>
      )}
      <form noValidate className="flex flex-wrap items-end gap-2" onSubmit={(e) => { e.preventDefault(); if (!blocked) sign.mutate() }}>
        <label className="grow text-xs">Note
          <input className={`ml-1 w-full max-w-md ${input}`} maxLength={500} data-testid="dc-signoff-note" value={note} onChange={(e) => setNote(e.target.value)} />
        </label>
        <Button type="submit" className={small} data-testid="dc-signoff-submit" disabled={blocked || sign.isPending}>Sign off day</Button>
      </form>
      {sign.isError && <Alert tone="error">{errorText(sign.error, 'Could not sign off the day.')}</Alert>}
    </section>
  )
}
