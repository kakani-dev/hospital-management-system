import { useId, useMemo, useState } from 'react'
import { Link, useParams } from 'react-router'
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { Card } from '../../components/ui/Card'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { apiClient } from '../../lib/api/client'
import type { PharmacyPrescription, PharmacyRxLine, StockItem } from '../../lib/api/types'
import { useCurrentContext } from '../tenancy/useCurrentContext'
import { problemText, StatusBadge } from './pharmacyUi'

const selectClass = 'mt-1 min-h-11 w-full rounded-lg border border-gray-300 bg-white px-3 py-2 text-sm dark:border-dark-500 dark:bg-dark-700'
const DISPENSING_STORES = new Set(['op_pharmacy', 'ip_pharmacy'])

interface Draft { qty: string; complete: boolean; itemId: string; reason: string }

/** True when giving `qty` now would take the line past what was prescribed (#187). */
function overPrescribed(l: PharmacyRxLine, qty: number): boolean {
  return l.prescribedBase != null && Number.isFinite(qty) && l.dispensedBase + qty > l.prescribedBase
}

/** Prescription detail and dispense action (#106). Stock is taken FEFO by the server. */
export function DispensePage() {
  const { id = '' } = useParams()
  const { has } = useCurrentContext()
  const canDispense = has('pharmacy.dispense')
  const qc = useQueryClient()
  const storeFieldId = useId()
  const noteId = useId()
  const [chosenStore, setStoreId] = useState('')
  const [drafts, setDrafts] = useState<Record<number, Draft>>({})
  const [note, setNote] = useState('')
  const [key, setKey] = useState(() => crypto.randomUUID())
  const [done, setDone] = useState<string | null>(null)
  const [formError, setFormError] = useState<string | null>(null)

  const stores = useQuery({ queryKey: ['inventory', 'stores'], queryFn: () => apiClient.inventory.stores() })
  const items = useQuery({ queryKey: ['inventory', 'items'], queryFn: () => apiClient.inventory.items() })
  const [rxBranch, setRxBranch] = useState<string | null>(null)
  const branchStores = useMemo(
    () => (stores.data ?? []).filter((s) => s.isActive && DISPENSING_STORES.has(s.storeKind) && s.branchId === rxBranch),
    [stores.data, rxBranch],
  )
  // One pharmacy at the branch: pick it so availability shows straight away.
  const storeId = chosenStore || (branchStores.length === 1 ? branchStores[0]!.id : '')
  const rx = useQuery({
    queryKey: ['pharmacy', 'rx', id, storeId],
    queryFn: async () => {
      const r = await apiClient.pharmacy.prescription(id, storeId || undefined)
      setRxBranch(r.branchId)
      return r
    },
    enabled: !!id,
    placeholderData: keepPreviousData,
  })

  const dispense = useMutation({
    mutationFn: (body: Parameters<typeof apiClient.pharmacy.dispense>[1]) => apiClient.pharmacy.dispense(key, body),
    onSuccess: (data) => {
      qc.setQueryData(['pharmacy', 'rx', id, storeId], data)
      void qc.invalidateQueries({ queryKey: ['pharmacy', 'queue'] })
      setDrafts({})
      setNote('')
      setKey(crypto.randomUUID())
      setDone(data.status === 'dispensed' ? 'Dispensed. The prescription is complete.' : 'Dispensed. Some medicines are still open.')
    },
  })

  if (rx.isPending) return <LoadingBlock />
  if (rx.isError) return <Alert tone="error">{problemText(rx.error)}</Alert>
  const data: PharmacyPrescription = rx.data

  const draftFor = (l: PharmacyRxLine): Draft => drafts[l.lineNo] ?? { qty: '', complete: true, itemId: l.inventoryItemId ?? '', reason: '' }
  const setDraft = (l: PharmacyRxLine, patch: Partial<Draft>) =>
    setDrafts((d) => ({ ...d, [l.lineNo]: { ...draftFor(l), ...patch } }))

  function submit() {
    setDone(null)
    setFormError(null)
    if (!storeId) return setFormError('Choose the pharmacy store to dispense from.')
    const lines: { lineNo: number; itemId?: string; qtyBase: number; complete: boolean; overrideReason?: string }[] = []
    for (const l of data.lines) {
      if (l.complete) continue
      const d = draftFor(l)
      if (!d.qty.trim()) continue
      const qty = Number(d.qty)
      if (!Number.isInteger(qty) || qty < 1) return setFormError(`Line ${l.lineNo}: enter a whole quantity of at least 1.`)
      if (!d.itemId) return setFormError(`Line ${l.lineNo}: choose the stock item to give.`)
      const over = overPrescribed(l, qty)
      const reason = d.reason.trim()
      if (over && (reason.length < 10 || reason.length > 300))
        return setFormError(`Line ${l.lineNo}: ${qty} is more than prescribed (${l.prescribedBase} prescribed, ${l.dispensedBase} given). Give less or enter a reason of 10 to 300 characters.`)
      lines.push({
        lineNo: l.lineNo,
        qtyBase: qty,
        complete: d.complete,
        ...(l.inventoryItemId ? {} : { itemId: d.itemId }),
        ...(over ? { overrideReason: reason } : {}),
      })
    }
    if (lines.length === 0) return setFormError('Enter a quantity for at least one medicine.')
    dispense.mutate({ consultationId: data.id, storeId, lines, ...(note.trim() ? { note: note.trim() } : {}) })
  }

  const drugs: StockItem[] = (items.data?.items ?? []).filter((i) => i.isActive)

  return (
    <div className="space-y-4" data-testid="pharmacy-dispense-page">
      <Link to="/pharmacy/dispense" className="text-sm text-primary-600 underline dark:text-primary-400">Back to the queue</Link>
      <div className="flex flex-wrap items-center gap-3">
        <h1 className="text-xl font-semibold text-gray-900 dark:text-dark-50">{data.patientName} ({data.patientMrn})</h1>
        <StatusBadge status={data.status} />
      </div>
      <p className="text-sm text-gray-600 dark:text-dark-200" data-testid="rx-meta">
        {data.doctorName} · {new Date(data.finalizedOn).toLocaleString('en-IN', { dateStyle: 'medium', timeStyle: 'short' })}
      </p>
      {data.superseded && <Alert tone="warning">This prescription was revised. Dispense from the newer version.</Alert>}

      <Card title="Medicines">
        {canDispense && (
          <label htmlFor={storeFieldId} className="mb-3 block max-w-sm text-sm font-medium text-gray-800 dark:text-dark-100">
            Dispense from
            <select id={storeFieldId} data-testid="dispense-store" className={selectClass} value={storeId} onChange={(e) => setStoreId(e.target.value)}>
              <option value="">Choose a pharmacy store</option>
              {branchStores.map((s) => (
                <option key={s.id} value={s.id}>{s.name}</option>
              ))}
            </select>
          </label>
        )}
        <div className="overflow-x-auto">
          <table className="w-full text-left text-sm" data-testid="rx-lines">
            <thead>
              <tr className="border-b border-gray-200 dark:border-dark-500">
                <th className="py-2 pr-3">#</th>
                <th className="py-2 pr-3">Medicine</th>
                <th className="py-2 pr-3">Directions</th>
                <th className="py-2 pr-3">Prescribed</th>
                <th className="py-2 pr-3">Given</th>
                <th className="py-2 pr-3">In stock</th>
                {canDispense && <th className="py-2 pr-3">Give now</th>}
              </tr>
            </thead>
            <tbody>
              {data.lines.map((l) => {
                const d = draftFor(l)
                return (
                  <tr key={l.id} className="border-b border-gray-100 align-top dark:border-dark-600" data-testid="rx-line" data-complete={l.complete}>
                    <td className="py-2 pr-3">{l.lineNo}</td>
                    <td className="py-2 pr-3">{l.medicineName}{l.strength ? ` ${l.strength}` : ''}</td>
                    <td className="py-2 pr-3">{l.dose}, {l.frequency}, {l.durationDays} days{l.instructions ? ` (${l.instructions})` : ''}</td>
                    <td className="py-2 pr-3" data-testid="rx-line-prescribed">{l.prescribedBase ?? '—'}</td>
                    <td className="py-2 pr-3" data-testid="rx-line-dispensed">{l.dispensedBase}{l.complete ? ' (done)' : ''}</td>
                    <td className="py-2 pr-3" data-testid="rx-line-available">{l.availableBase ?? '—'}</td>
                    {canDispense && (
                      <td className="py-2 pr-3">
                        {l.complete ? (
                          <span className="text-gray-500">Done</span>
                        ) : (
                          <div className="space-y-2">
                            {!l.inventoryItemId && (
                              <select
                                aria-label={`Stock item for line ${l.lineNo}`}
                                data-testid="rx-line-item"
                                className={selectClass}
                                value={d.itemId}
                                onChange={(e) => setDraft(l, { itemId: e.target.value })}
                              >
                                <option value="">Choose an item</option>
                                {drugs.map((i) => (
                                  <option key={i.id} value={i.id}>{i.brandName} ({i.genericName})</option>
                                ))}
                              </select>
                            )}
                            <input
                              aria-label={`Quantity for line ${l.lineNo}`}
                              data-testid="rx-line-qty"
                              inputMode="numeric"
                              className="min-h-11 w-24 rounded-lg border border-gray-300 bg-white px-3 py-2 text-sm dark:border-dark-500 dark:bg-dark-700"
                              value={d.qty}
                              onChange={(e) => setDraft(l, { qty: e.target.value })}
                            />
                            {overPrescribed(l, Number(d.qty)) && d.qty.trim() !== '' && (
                              <div className="space-y-1">
                                <p className="text-xs text-amber-700 dark:text-amber-400" data-testid="rx-line-over-warning">
                                  More than prescribed ({l.prescribedBase}). Enter why to continue.
                                </p>
                                <input
                                  aria-label={`Reason for giving more than prescribed on line ${l.lineNo}`}
                                  data-testid="rx-line-override-reason"
                                  maxLength={300}
                                  className={selectClass}
                                  value={d.reason}
                                  onChange={(e) => setDraft(l, { reason: e.target.value })}
                                />
                              </div>
                            )}
                            <label className="flex items-center gap-2 text-xs">
                              <input
                                type="checkbox"
                                data-testid="rx-line-complete"
                                checked={d.complete}
                                onChange={(e) => setDraft(l, { complete: e.target.checked })}
                              />
                              Line finished
                            </label>
                          </div>
                        )}
                      </td>
                    )}
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
        {canDispense && data.status !== 'dispensed' && !data.superseded && (
          <div className="mt-4 space-y-3">
            <label htmlFor={noteId} className="block max-w-lg text-sm font-medium text-gray-800 dark:text-dark-100">
              Note (optional)
              <input id={noteId} data-testid="dispense-note" maxLength={500} className={selectClass} value={note} onChange={(e) => setNote(e.target.value)} />
            </label>
            {formError && <Alert tone="error">{formError}</Alert>}
            {dispense.isError && <Alert tone="error">{problemText(dispense.error)}</Alert>}
            <Button data-testid="dispense-submit" onClick={submit} disabled={dispense.isPending}>
              {dispense.isPending ? 'Dispensing…' : 'Dispense'}
            </Button>
          </div>
        )}
        {done && <div className="mt-3"><Alert tone="info">{done}</Alert></div>}
      </Card>

      {data.dispenses.length > 0 && (
        <Card title="Dispensed so far">
          <ul className="space-y-2 text-sm" data-testid="rx-dispenses">
            {data.dispenses.map((d) => (
              <li key={d.id}>
                {new Date(d.createdOn).toLocaleString('en-IN', { dateStyle: 'medium', timeStyle: 'short' })}:{' '}
                {d.lines.map((x) => `${x.brandName} ${x.qtyBase} (batch ${x.batchNo}, exp ${x.expiryDate})${x.overrideReason ? ` — over prescription: ${x.overrideReason}` : ''}`).join('; ')}
                {d.note ? ` (${d.note})` : ''}
              </li>
            ))}
          </ul>
        </Card>
      )}
    </div>
  )
}
