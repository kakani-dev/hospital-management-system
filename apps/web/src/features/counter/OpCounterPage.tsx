import { useEffect, useMemo, useRef, useState } from 'react'
import { Link } from 'react-router'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { BranchPicker } from '../../components/scheduling/BranchPicker'
import { apiClient } from '../../lib/api/client'
import { localToday } from '../../lib/dates'
import { can } from '../../lib/permissions'
import type { BillDocument, PatientSummary, Sex } from '../../lib/api/types'
import { rolesAtBranch, useCurrentContext } from '../tenancy/useCurrentContext'
import { useBranchSelection } from '../tenancy/useBranchSelection'
import { useBookablePractitionersState } from '../scheduling/useBookablePractitioners'
import { planTenders, type TenderMode } from '../billing/collect'
import { formatPaise, parseRupeesToPaise } from '../billing/money'
import { UpiQr } from '../billing/UpiQr'
import { changeDue, errorText, classifySearch, collectionByMode, quickTenders, rememberedBranch, waitingCount, waitingToPay } from './counter'

const MODES: { mode: TenderMode; label: string; key: string }[] = [
  { mode: 'cash', label: 'Cash', key: 'F5' },
  { mode: 'upi', label: 'UPI', key: 'F6' },
  { mode: 'card', label: 'Card', key: 'F7' },
  { mode: 'split', label: 'Cash + UPI', key: 'F8' },
]
const MODE_LABEL: Record<string, string> = { cash: 'Cash', upi: 'UPI', card: 'Card', bank: 'Bank', advance: 'Advance', credit: 'Credit' }
const chip = 'h-7 rounded-full border px-3 text-xs font-medium focus:outline-2 focus:outline-primary-500 disabled:opacity-50'
const chipOn = 'border-primary-600 bg-primary-600 text-white'
const chipOff = 'border-gray-300 text-gray-700 hover:bg-gray-100 dark:border-dark-450 dark:text-dark-100 dark:hover:bg-dark-600'
const input = 'h-8 rounded-md border border-gray-300 px-2 text-sm dark:border-dark-450 dark:bg-dark-700'
const err = errorText

/** One-screen OP counter: find/register, token (auto-bills), discount, collect, print — keyboard first. */
export function OpCounterPage() {
  const { me, activeBranchId } = useCurrentContext()
  const qc = useQueryClient()
  const sel = useBranchSelection()
  const userId = me.data?.userId
  // The header's branch (saved on the server) is the counter's branch. Only when the header is on
  // "All my branches" does the counter pick one itself, remembered on this workstation.
  const params = new URLSearchParams(window.location.search)
  const remembered = rememberedBranch.get(userId)
  const fallback = remembered && sel.branches.some((b) => b.id === remembered) ? remembered : sel.branchId
  const headerBranch = activeBranchId && sel.branches.some((b) => b.id === activeBranchId) ? activeBranchId : null
  const branchId = params.get('branch') ? sel.branchId : (headerBranch ?? fallback)
  const setBranch = (id: string) => {
    rememberedBranch.set(userId, id)
    sel.setBranchId(id)
  }

  const roles = rolesAtBranch(me.data, branchId)
  const canToken = can(roles, 'queue.checkIn') && can(roles, 'billing.bill')
  const canRegister = can(roles, 'patients.write')
  const canCollect = can(roles, 'billing.collect')
  const canDiscount = can(roles, 'billing.discount')
  const today = sel.timeZoneReady ? localToday(new Date(), sel.timeZone) : null

  const searchRef = useRef<HTMLInputElement>(null)
  const [term, setTerm] = useState('')
  const [debounced, setDebounced] = useState('')
  const [active, setActive] = useState(0)
  const [patient, setPatient] = useState<PatientSummary | null>(null)
  const [bill, setBill] = useState<BillDocument | null>(null)
  const [token, setToken] = useState<number | null>(null)
  const [mode, setMode] = useState<TenderMode>('cash')
  const [received, setReceived] = useState('')
  const [upiPart, setUpiPart] = useState('')
  const [discount, setDiscount] = useState('')
  const [qr, setQr] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [printId, setPrintId] = useState<string | null>(null)
  const [reg, setReg] = useState<{ firstName: string; lastName: string; phone: string; sex: Sex; ageYears: string } | null>(null)

  useEffect(() => {
    const t = setTimeout(() => setDebounced(term), 250)
    return () => clearTimeout(t)
  }, [term])
  const query = classifySearch(debounced)
  const results = useQuery({
    queryKey: ['counter', 'search', query],
    queryFn: () => apiClient.patients.search({ ...query!, pageSize: 8 }),
    enabled: !!query && !patient,
    retry: false,
  })
  const found = results.data?.items ?? []

  const refresh = branchId && today ? 15_000 : false
  const queue = useQuery({
    queryKey: ['counter', 'queue', branchId, today],
    queryFn: () => apiClient.queue.list({ branchId: branchId!, date: today! }),
    enabled: !!branchId && !!today,
    refetchInterval: refresh,
    retry: false,
  })
  const drafts = useQuery({
    queryKey: ['billing', 'bills', 'draft', branchId, 'counter'],
    queryFn: () => apiClient.billing.list({ status: 'draft', branchId: branchId! }),
    enabled: !!branchId && canCollect,
    refetchInterval: refresh,
    retry: false,
  })
  const totals = useQuery({
    queryKey: ['counter', 'totals', branchId, today],
    queryFn: () => apiClient.billing.dayEndAccounts(branchId!, today!),
    enabled: !!branchId && !!today && can(roles, 'billing.view'),
    refetchInterval: refresh,
    retry: false,
  })
  const doctors = useBookablePractitionersState(canToken ? branchId : null)
  const visitTypes = useQuery({
    queryKey: ['counter', 'visit-types', branchId],
    queryFn: () => apiClient.visitTypes.list(branchId!),
    enabled: !!branchId && canToken,
    retry: false,
  })
  const baseFee = visitTypes.data?.find((v) => v.isActive)?.effectiveFeePaise ?? null
  // Per-doctor fee for this patient (free / reduced revisit within the follow-up window).
  const suggestions = useQuery({
    queryKey: ['counter', 'suggest', branchId, patient?.id, doctors.practitioners.map((d) => d.id).join()],
    queryFn: async () => {
      const startsAt = new Date().toISOString()
      const list = await Promise.all(
        doctors.practitioners.map((d) =>
          apiClient.visitTypes.suggestion({ branchId: branchId!, practitionerId: d.id, patientId: patient!.id, startsAt }).then((s) => [d.id, s] as const, () => [d.id, null] as const),
        ),
      )
      return Object.fromEntries(list)
    },
    enabled: !!patient && !!branchId && canToken && !bill && doctors.practitioners.length > 0,
    retry: false,
  })
  const pending = useMemo(() => waitingToPay(drafts.data ?? [], queue.data ?? []), [drafts.data, queue.data])
  const byMode = collectionByMode(totals.data?.accounts ?? [])

  const reset = (message: string | null = null) => {
    setPatient(null); setBill(null); setToken(null); setTerm(''); setDebounced(''); setActive(0)
    setReceived(''); setUpiPart(''); setDiscount(''); setQr(null); setMode('cash'); setReg(null); setError(null); setNotice(message)
    setTimeout(() => searchRef.current?.focus(), 0)
  }
  const invalidate = () => {
    void qc.invalidateQueries({ queryKey: ['counter'] })
    void qc.invalidateQueries({ queryKey: ['billing', 'bills'] })
  }
  const act = async (label: string, fn: () => Promise<void>) => {
    setBusy(label); setError(null)
    try { await fn() } catch (e) { setError(err(e)) } finally { setBusy(null) }
  }

  const pick = (p: PatientSummary) => {
    setPatient(p); setNotice(null); setError(null)
    // An open bill for this patient goes straight to collection.
    const open = pending.find((x) => x.bill.patientId === p.id)
    if (open) void act('load', async () => { setBill(await apiClient.billing.bill(open.bill.id)); setToken(open.token) })
  }
  const openPending = (billId: string, tok: number | null) =>
    act('load', async () => {
      const b = await apiClient.billing.bill(billId)
      const p = await apiClient.patients.get(b.patientId)
      setPatient(p); setBill(b); setToken(tok); setNotice(null)
    })

  const issueToken = (practitionerId: string) =>
    act('token', async () => {
      if (!patient || !branchId) return
      const res = await apiClient.queue.walkIn({ branchId, patientId: patient.id, practitionerId })
      setToken(res.tokenNo)
      // Token auto-creates the consult bill (doctor + fee filled by the server).
      setBill(await apiClient.billing.ensureWalkInDraft(res.queueEntryId))
      invalidate()
    })

  const register = () =>
    act('register', async () => {
      if (!reg || !branchId) return
      const age = reg.ageYears.trim() ? Number(reg.ageYears) : null
      const created = await apiClient.patients.create({
        firstName: reg.firstName.trim(), lastName: reg.lastName.trim(), sex: reg.sex, registeredBranchId: branchId,
        phone: reg.phone.trim() || null, ageYears: age,
      })
      setReg(null)
      pick(created as unknown as PatientSummary)
    })

  const applyDiscount = () =>
    act('discount', async () => {
      if (!bill) return
      const paise = parseRupeesToPaise(discount)
      if (paise == null || paise <= 0) throw new Error('Enter the discount in rupees.')
      const res = await apiClient.billing.discount(bill.id, { kind: 'flat_paise', value: paise, reasonCode: 'courtesy' })
      setDiscount('')
      if ('lines' in res) setBill(res)
      else setNotice('This discount is above your limit and was sent for approval.')
    })

  const showQr = () =>
    act('qr', async () => {
      if (!bill || !branchId) return
      const session = await apiClient.billing.findSession(branchId).catch(() => null)
      const link = await apiClient.billing.paymentLink(bill.id, { channel: 'qr', ...(session?.id ? { counterSessionId: session.id } : {}) })
      if (!link.upiUri) throw new Error('No UPI account is set up for this branch.')
      setQr(link.upiUri)
    })

  const collect = () =>
    act('collect', async () => {
      if (!bill || !branchId) return
      const current = await apiClient.billing.bill(bill.id)
      if (current.duePaise <= 0) { reset('This bill is already paid.'); return }
      const plan = planTenders(mode, current.duePaise, received, upiPart, '')
      if ('error' in plan) throw new Error(plan.error)
      const session = await apiClient.billing.ensureSession(branchId)
      if (!session.id) throw new Error('Open a counter session before taking money.')
      const receipt = await apiClient.billing.pay(crypto.randomUUID(), {
        accountId: bill.accountId, kind: 'payment', counterSessionId: session.id, tenders: plan.tenders,
        allocations: [{ billId: bill.id, amountPaise: plan.totalPaise }],
      })
      let next = await apiClient.billing.bill(bill.id)
      if (next.status === 'draft' && next.duePaise <= 0) next = await apiClient.billing.finalize(bill.id)
      const change = mode === 'cash' ? changeDue(current.duePaise, parseRupeesToPaise(received)) : 0
      setPrintId(receipt.id)
      invalidate()
      if (next.duePaise > 0) {
        setBill(next); setReceived(''); setUpiPart('')
        setNotice(`Collected ${formatPaise(plan.totalPaise)}. ${formatPaise(next.duePaise)} still due.`)
      } else {
        reset(`Collected ${formatPaise(plan.totalPaise)}${change ? ` · give back ${formatPaise(change)}` : ''}${token ? ` · token ${token}` : ''}. Printing.`)
      }
    })

  // F2 search, F5–F8 modes, Esc clears, Enter collects (when the bill is shown).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'F2') { e.preventDefault(); searchRef.current?.focus(); searchRef.current?.select() }
      const m = MODES.find((x) => x.key === e.key)
      if (m && bill) { e.preventDefault(); setMode(m.mode); if (m.mode === 'upi' && !qr) void showQr() }
      if (e.key === 'Escape' && (patient || term)) { e.preventDefault(); reset() }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  })
  // Watch the bill while the QR is up so a scanned payment shows without a click.
  const polled = useQuery({
    queryKey: ['billing', 'bill', bill?.id, 'counter-qr'],
    queryFn: () => apiClient.billing.bill(bill!.id),
    enabled: !!qr && !!bill,
    refetchInterval: 3_000,
  })
  const live = polled.data && bill && polled.data.id === bill.id && polled.data.duePaise < bill.duePaise ? polled.data : bill
  // Keyboard flow: after a patient is picked focus the first doctor; once a bill shows, the amount box.
  const stage = live ? `bill:${live.id}` : patient ? 'doctor' : reg ? 'reg' : 'search'
  useEffect(() => {
    const id = stage.startsWith('bill') ? 'opc-received' : stage === 'reg' ? 'opc-reg-first' : stage === 'doctor' ? null : 'opc-search'
    const el = id ? document.querySelector<HTMLElement>(`[data-testid="${id}"]`) : document.querySelector<HTMLElement>('[data-testid^="opc-doctor-"]')
    el?.focus()
  }, [stage, doctors.practitioners.length])

  const due = live?.duePaise ?? 0
  const receivedPaise = received.trim() ? parseRupeesToPaise(received) : null
  const change = mode === 'cash' ? changeDue(due, receivedPaise) : 0

  return (
    <div className="grid gap-4 lg:grid-cols-[1fr_18rem]" data-testid="op-counter">
      <section className="space-y-4">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">OP counter</h1>
          {!headerBranch && <BranchPicker branches={sel.branches} value={branchId} onChange={setBranch} />}
        </div>
        {notice && <Alert tone="info"><span data-testid="opc-notice">{notice}</span></Alert>}
        {error && <Alert tone="error"><span data-testid="opc-error">{error}</span></Alert>}

        <div className="relative">
          <label htmlFor="opc-search" className="mb-1 block text-xs text-gray-500">Phone, name, MRN or ABHA <kbd className="rounded border px-1">F2</kbd></label>
          <input
            id="opc-search" ref={searchRef} data-testid="opc-search" className={`${input} w-full`} autoComplete="off"
            value={patient ? `${patient.firstName} ${patient.lastName} · ${patient.mrn}` : term}
            readOnly={!!patient}
            onChange={(e) => { setTerm(e.target.value); setActive(0) }}
            onKeyDown={(e) => {
              if (patient) return
              if (e.key === 'ArrowDown') { e.preventDefault(); setActive((a) => Math.min(a + 1, found.length - 1)) }
              if (e.key === 'ArrowUp') { e.preventDefault(); setActive((a) => Math.max(a - 1, 0)) }
              if (e.key === 'Enter' && found[active]) { e.preventDefault(); pick(found[active]) }
            }}
          />
          {!patient && query && (
            <ul className="mt-1 divide-y rounded-md border border-gray-200 dark:divide-dark-500 dark:border-dark-500" data-testid="opc-results" role="listbox">
              {found.map((p, i) => (
                <li key={p.id}>
                  <button type="button" role="option" aria-selected={i === active} data-testid={`opc-result-${i}`} onClick={() => pick(p)}
                    className={`w-full px-3 py-1.5 text-left text-sm ${i === active ? 'bg-this/10' : ''}`}>
                    {p.firstName} {p.lastName} <span className="text-xs text-gray-500">· {p.mrn}{p.phone ? ` · ${p.phone}` : ''}</span>
                  </button>
                </li>
              ))}
              {results.isFetched && found.length === 0 && (
                <li className="flex items-center justify-between px-3 py-1.5 text-sm text-gray-600">
                  No patient found.
                  {canRegister && !reg && (
                    <Button className="h-7 px-2 text-xs" variant="secondary" data-testid="opc-register-open"
                      onClick={() => {
                        const digits = query.phone ? query.phone : ''
                        const [f = '', ...l] = query.search ? query.search.split(/\s+/) : []
                        setReg({ firstName: f, lastName: l.join(' '), phone: digits, sex: 'unknown', ageYears: '' })
                      }}>
                      Register new
                    </Button>
                  )}
                </li>
              )}
            </ul>
          )}
        </div>

        {reg && (
          <form className="flex flex-wrap items-end gap-2 rounded-md border border-gray-200 p-3 dark:border-dark-500" data-testid="opc-register"
            onSubmit={(e) => { e.preventDefault(); void register() }}>
            <input aria-label="First name" placeholder="First name" className={input} data-testid="opc-reg-first" value={reg.firstName} onChange={(e) => setReg({ ...reg, firstName: e.target.value })} />
            <input aria-label="Last name" placeholder="Last name" className={input} data-testid="opc-reg-last" value={reg.lastName} onChange={(e) => setReg({ ...reg, lastName: e.target.value })} />
            <input aria-label="Mobile" placeholder="Mobile" inputMode="tel" className={`${input} w-32`} data-testid="opc-reg-phone" value={reg.phone} onChange={(e) => setReg({ ...reg, phone: e.target.value })} />
            <input aria-label="Age (years)" placeholder="Age" inputMode="numeric" className={`${input} w-16`} data-testid="opc-reg-age" value={reg.ageYears} onChange={(e) => setReg({ ...reg, ageYears: e.target.value })} />
            <select aria-label="Sex" className={input} data-testid="opc-reg-sex" value={reg.sex} onChange={(e) => setReg({ ...reg, sex: e.target.value as Sex })}>
              <option value="female">Female</option><option value="male">Male</option><option value="other">Other</option><option value="unknown">Unknown</option>
            </select>
            <Button type="submit" className="h-8 px-3" data-testid="opc-reg-save" disabled={!!busy}>Register</Button>
            <Link to="/patients/new" className="text-xs text-this underline">Full form</Link>
          </form>
        )}

        {patient && !bill && canToken && !pending.some((x) => x.bill.patientId === patient.id) && (
          <div className="space-y-2" data-testid="opc-doctors">
            <p className="text-xs text-gray-500">Issue a token (creates the bill)</p>
            <div className="flex flex-wrap gap-2">
              {doctors.practitioners.map((d) => {
                const s = suggestions.data?.[d.id]
                const fee = s?.feePaise ?? baseFee
                const free = s?.suggested && s.feePaise === 0
                return (
                  <button key={d.id} type="button" className={`${chip} ${chipOff} h-auto py-1 text-left`} data-testid={`opc-doctor-${d.id}`}
                    disabled={!!busy} onClick={() => void issueToken(d.id)}>
                    <span className="block">{d.displayName}</span>
                    <span className="block text-[11px] text-gray-500">
                      {fee != null ? formatPaise(fee) : '—'} · {waitingCount(queue.data ?? [], d.id)} waiting
                      {free && <span className="ml-1 rounded bg-green-100 px-1 text-green-800" data-testid="opc-free-revisit">Free revisit</span>}
                      {s?.suggested && !free && s.reason && <span className="ml-1">· {s.reason}</span>}
                    </span>
                  </button>
                )
              })}
              {doctors.status === 'ready' && doctors.practitioners.length === 0 && <p className="text-sm text-gray-500">No doctors at this branch.</p>}
            </div>
          </div>
        )}
        {patient && !bill && !canToken && !busy && (
          <p className="text-sm text-gray-600" data-testid="opc-no-open-bill">No bill waiting for this patient. Reception issues the token.</p>
        )}

        {live && (
          <div className="space-y-3 rounded-md border border-gray-200 p-3 dark:border-dark-500" data-testid="opc-bill">
            <div className="flex items-baseline justify-between">
              <p className="text-sm">{token != null && <span className="mr-2 font-semibold" data-testid="opc-token">Token {token}</span>}{live.lines.map((l) => l.name).join(', ')}</p>
              <p className="text-lg font-semibold" data-testid="opc-due">{formatPaise(due)}</p>
            </div>
            {live.discountPaise > 0 && <p className="text-xs text-gray-500" data-testid="opc-discounted">Discount {formatPaise(live.discountPaise)}</p>}
            {canDiscount && due > 0 && (
              <div className="flex items-center gap-2">
                <input aria-label="Discount (₹)" placeholder="Discount ₹" inputMode="decimal" className={`${input} w-28`} data-testid="opc-discount" value={discount}
                  onChange={(e) => setDiscount(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); void applyDiscount() } }} />
                <Button variant="secondary" className="h-7 px-2 text-xs" data-testid="opc-discount-apply" disabled={!!busy || !discount} onClick={() => void applyDiscount()}>Apply</Button>
              </div>
            )}
            {canCollect && due > 0 && (
              <>
                <div className="flex flex-wrap gap-2" role="radiogroup" aria-label="Payment mode">
                  {MODES.map((m) => (
                    <button key={m.mode} type="button" role="radio" aria-checked={mode === m.mode} data-testid={`opc-mode-${m.mode}`}
                      className={`${chip} ${mode === m.mode ? chipOn : chipOff}`}
                      onClick={() => { setMode(m.mode); if (m.mode === 'upi' && !qr) void showQr() }}>
                      {m.label} <kbd className="ml-1 opacity-70">{m.key}</kbd>
                    </button>
                  ))}
                </div>
                <form className="flex flex-wrap items-center gap-2" onSubmit={(e) => { e.preventDefault(); void collect() }}>
                  <input aria-label={mode === 'split' ? 'Cash (₹)' : 'Received (₹)'} placeholder={(due / 100).toFixed(2)} inputMode="decimal" className={`${input} w-28`}
                    data-testid="opc-received" value={received} onChange={(e) => setReceived(e.target.value)} />
                  {mode === 'split' && (
                    <input aria-label="UPI (₹)" placeholder="UPI ₹" inputMode="decimal" className={`${input} w-24`} data-testid="opc-upi-part" value={upiPart} onChange={(e) => setUpiPart(e.target.value)} />
                  )}
                  {mode === 'cash' && quickTenders(due).map((r) => (
                    <button key={r} type="button" className={`${chip} ${chipOff}`} data-testid={`opc-quick-${r}`} onClick={() => setReceived(String(r))}>₹{r}</button>
                  ))}
                  {change > 0 && <span className="text-sm font-semibold text-amber-700" data-testid="opc-change">Change {formatPaise(change)}</span>}
                  <Button type="submit" className="ml-auto h-8 px-3" data-testid="opc-collect" disabled={!!busy}>
                    {busy === 'collect' ? 'Collecting…' : 'Collect & print Token + Receipt'} <kbd className="ml-1 opacity-70">Enter</kbd>
                  </Button>
                </form>
                {mode === 'upi' && qr && <div data-testid="opc-qr"><UpiQr uri={qr} /></div>}
              </>
            )}
            {due <= 0 && <p className="text-sm text-gray-600">Nothing due on this bill.</p>}
          </div>
        )}
        {(patient || term) && <button type="button" className="text-xs text-gray-500 underline" data-testid="opc-clear" onClick={() => reset()}>Clear (Esc)</button>}
      </section>

      <aside className="space-y-4 text-sm" data-testid="opc-side">
        {canCollect && (
          <div>
            <h2 className="mb-1 font-semibold">Waiting to pay</h2>
            <ul className="divide-y rounded-md border border-gray-200 dark:divide-dark-500 dark:border-dark-500" data-testid="opc-waiting">
              {pending.length === 0 && <li className="px-3 py-1.5 text-gray-500">No one waiting.</li>}
              {pending.slice(0, 12).map(({ bill: b, token: t }) => (
                <li key={b.id}>
                  <button type="button" className="flex w-full justify-between px-3 py-1.5 text-left hover:bg-gray-50 dark:hover:bg-dark-600" data-testid={`opc-waiting-${b.id}`}
                    onClick={() => void openPending(b.id, t)}>
                    <span>{t != null ? `#${t} ` : ''}{b.patientName ?? b.patientMrn ?? '—'}</span>
                    <span className="font-mono">{formatPaise(b.duePaise ?? 0)}</span>
                  </button>
                </li>
              ))}
            </ul>
          </div>
        )}
        {totals.data && (
          <div>
            <h2 className="mb-1 font-semibold">Today’s collection</h2>
            <dl className="grid grid-cols-[1fr_auto] gap-x-3 gap-y-0.5" data-testid="opc-totals">
              {byMode.length === 0 && <dd className="col-span-2 text-gray-500">Nothing yet.</dd>}
              {byMode.map((m) => (
                <div key={m.mode} className="contents" data-testid={`opc-total-${m.mode}`}>
                  <dt>{MODE_LABEL[m.mode] ?? m.mode} <span className="text-xs text-gray-500">({m.count})</span></dt>
                  <dd className="text-right font-mono">{formatPaise(m.netPaise)}</dd>
                </div>
              ))}
              <dt className="border-t font-semibold">Total</dt>
              <dd className="border-t text-right font-mono font-semibold" data-testid="opc-total">{formatPaise(byMode.reduce((s, m) => s + m.netPaise, 0))}</dd>
            </dl>
          </div>
        )}
      </aside>
      {printId && (
        <iframe key={printId} title="Receipt print" aria-hidden="true" tabIndex={-1} className="pointer-events-none fixed -left-[10000px] top-0 h-[900px] w-[700px]" data-testid="opc-print-frame" src={`/billing/receipts/${encodeURIComponent(printId)}?print=1`}
          onLoad={() => setTimeout(() => searchRef.current?.focus(), 500)} />
      )}
    </div>
  )
}
