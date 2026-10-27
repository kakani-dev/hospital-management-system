import { useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router'
import { useQueryClient } from '@tanstack/react-query'
import { Textarea } from '@tailux/components/ui'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { Card } from '../../components/ui/Card'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { FormField } from '../../components/ui/FormField'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { SelectField } from '../../components/ui/SelectField'
import { ApiError, apiClient } from '../../lib/api/client'
import type { Consultation, FoodTiming, PrescriptionLine } from '../../lib/api/types'
import { FOOD_LABEL, emptyLine, toDraft, validateLines, type Draft } from './consultationModel'
import { useCurrentContext } from '../tenancy/useCurrentContext'
import {
  clinicalErrorMessage,
  consultationKeys,
  useConsultation,
  useFinalizeConsultation,
  useReviseConsultation,
  useSaveConsultation,
} from './consultationApi'

const blank = (v: string) => (v.trim() === '' ? null : v)

export function ConsultationPage() {
  const { consultationId = '' } = useParams()
  const consultation = useConsultation(consultationId)
  const { has } = useCurrentContext()
  const canWrite = has('clinical.write')

  if (consultation.isPending) return <LoadingBlock label="Loading the consultation" />
  if (consultation.isError) {
    const status = consultation.error instanceof ApiError ? consultation.error.status : 0
    return (
      <div className="space-y-4" data-testid="consultation-unavailable">
        <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Consultation</h1>
        <Alert tone="warning">
          {status === 404
            ? 'This consultation does not exist in this hospital or branch.'
            : status === 403
              ? 'Your role does not include access to consultations.'
              : 'Consultations are unavailable right now.'}
        </Alert>
      </div>
    )
  }
  const c = consultation.data
  return c.status === 'draft' && canWrite ? <Editor key={c.id} consultation={c} /> : <ReadOnly consultation={c} canWrite={canWrite} />
}

function Header({ c }: { c: Consultation }) {
  return (
    <div className="flex flex-wrap items-center justify-between gap-3">
      <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">
        Consultation <span className="text-base font-normal text-gray-500 dark:text-dark-300">v{c.version} · {c.practitionerName}</span>
      </h1>
      <span
        data-testid="consultation-status"
        className={`rounded px-2 py-0.5 text-xs font-semibold uppercase ${c.status === 'draft' ? 'bg-warning/15 text-warning-darker' : 'bg-success/15 text-success-darker'}`}
      >
        {c.status === 'draft' ? 'Draft' : 'Finalized'}
      </span>
      <Link className="text-sm text-primary-600 underline dark:text-primary-400" to={`/patients/${c.patientId}`}>
        Back to patient
      </Link>
    </div>
  )
}

function Editor({ consultation: c }: { consultation: Consultation }) {
  const qc = useQueryClient()
  const save = useSaveConsultation(c.id)
  const finalize = useFinalizeConsultation(c.id)
  const [draft, setDraft] = useState<Draft>(() => toDraft(c))
  const [errors, setErrors] = useState<Record<string, string>>({})
  const [message, setMessage] = useState<{ tone: 'info' | 'error'; text: string } | null>(null)
  const [confirm, setConfirm] = useState(false)
  const busy = save.isPending || finalize.isPending

  const set = <K extends keyof Draft>(k: K, v: Draft[K]) => setDraft((d) => ({ ...d, [k]: v }))
  const setLine = (i: number, patch: Partial<PrescriptionLine>) =>
    setDraft((d) => ({ ...d, lines: d.lines.map((l, j) => (j === i ? { ...l, ...patch } : l)) }))

  const fail = (e: unknown, action: string) => {
    setMessage({ tone: 'error', text: clinicalErrorMessage(e, action) })
    // stale or finalized elsewhere: replace the form with the server's current state (no silent overwrite)
    if (e instanceof ApiError && e.status === 409)
      void qc
        .fetchQuery({ queryKey: consultationKeys.one(c.id), queryFn: () => apiClient.consultations.get(c.id), staleTime: 0 })
        .then((fresh) => setDraft(toDraft(fresh)))
        .catch(() => undefined)
  }

  const persist = async (announce = false): Promise<Consultation | null> => {
    const lineErrors = validateLines(draft.lines)
    setErrors(lineErrors)
    if (Object.keys(lineErrors).length > 0) {
      setMessage({ tone: 'error', text: 'Fix the highlighted prescription lines.' })
      return null
    }
    setMessage(null)
    try {
      const saved = await save.mutateAsync({ ...draft, rowVersion: c.rowVersion })
      if (announce) setMessage({ tone: 'info', text: 'Draft saved.' })
      return saved
    } catch (e) {
      fail(e, 'save the consultation')
      return null
    }
  }

  const doFinalize = async () => {
    if (busy) return // double-submit guard
    const saved = await persist()
    if (!saved) return setConfirm(false)
    try {
      await finalize.mutateAsync(saved.rowVersion)
    } catch (e) {
      fail(e, 'finalize the consultation')
    }
    setConfirm(false)
  }

  return (
    <form
      className="max-w-4xl space-y-6"
      aria-label="Consultation"
      onSubmit={(e) => {
        e.preventDefault()
        if (!busy) void persist(true)
      }}
    >
      <Header c={c} />
      {message && <Alert tone={message.tone}>{message.text}</Alert>}
      <Card title="Assessment">
        <div className="grid gap-4 sm:grid-cols-2">
          <Textarea data-testid="clinical-consultation-chief-complaint" label="Chief complaint" rows={2} value={draft.chiefComplaint ?? ''} onChange={(e) => set('chiefComplaint', blank(e.target.value))} />
          <Textarea data-testid="clinical-consultation-notes" label="Notes" rows={2} value={draft.notes ?? ''} onChange={(e) => set('notes', blank(e.target.value))} />
          <FormField data-testid="clinical-consultation-diagnosis" label="Diagnosis" value={draft.diagnosisText ?? ''} onChange={(e) => set('diagnosisText', blank(e.target.value))} />
          <FormField data-testid="clinical-consultation-diagnosis-code" label="Diagnosis code (optional)" hint="e.g. ICD-10" value={draft.diagnosisCode ?? ''} onChange={(e) => set('diagnosisCode', blank(e.target.value))} />
        </div>
      </Card>
      <Card title="Prescription">
        <ol className="space-y-4" data-testid="prescription-lines">
          {draft.lines.map((l, i) => (
            <li key={i} className="grid gap-3 rounded border border-gray-200 p-3 sm:grid-cols-4 dark:border-dark-500" aria-label={`Line ${i + 1}`}>
              <FormField data-testid="clinical-prescription-medicine-name" label={`Medicine ${i + 1}`} value={l.medicineName} error={errors[`line-${i}-medicineName`]} onChange={(e) => setLine(i, { medicineName: e.target.value })} />
              <FormField data-testid="clinical-prescription-strength" label="Strength" value={l.strength ?? ''} onChange={(e) => setLine(i, { strength: blank(e.target.value) })} />
              <FormField data-testid="clinical-prescription-dose" label="Dose" value={l.dose ?? ''} onChange={(e) => setLine(i, { dose: blank(e.target.value) })} />
              <FormField data-testid="clinical-prescription-frequency" label="Frequency" hint="e.g. 1-0-1" value={l.frequency} error={errors[`line-${i}-frequency`]} onChange={(e) => setLine(i, { frequency: e.target.value })} />
              <FormField data-testid="clinical-prescription-duration-days"
                label="Duration (days)"
                type="number"
                min={1}
                max={365}
                value={l.durationDays ?? ''}
                error={errors[`line-${i}-durationDays`]}
                onChange={(e) => setLine(i, { durationDays: e.target.value === '' ? null : Number(e.target.value) })}
              />
              <FormField data-testid="clinical-prescription-route" label="Route" hint="e.g. oral" value={l.route ?? ''} onChange={(e) => setLine(i, { route: blank(e.target.value) })} />
              <SelectField data-testid="clinical-prescription-food-timing" label="Food" value={l.foodTiming ?? ''} onChange={(e) => setLine(i, { foodTiming: (e.target.value || null) as FoodTiming | null })}>
                <option value="">—</option>
                {Object.entries(FOOD_LABEL).map(([v, label]) => (
                  <option key={v} value={v}>
                    {label}
                  </option>
                ))}
              </SelectField>
              <FormField data-testid="clinical-prescription-instructions" label="Instructions" value={l.instructions ?? ''} onChange={(e) => setLine(i, { instructions: blank(e.target.value) })} />
              <div className="sm:col-span-4">
                <Button variant="ghost" className="px-2 py-1 text-xs" aria-label={`Remove line ${i + 1}`} onClick={() => set('lines', draft.lines.filter((_, j) => j !== i))}>
                  Remove
                </Button>
              </div>
            </li>
          ))}
        </ol>
        <Button variant="secondary" className="mt-3" onClick={() => set('lines', [...draft.lines, emptyLine()])}>
          Add medicine
        </Button>
      </Card>
      <Card title="Follow-up">
        <div className="grid gap-4 sm:grid-cols-2">
          <FormField data-testid="clinical-consultation-follow-up-date" label="Follow-up date" type="date" value={draft.followUpDate ?? ''} onChange={(e) => set('followUpDate', blank(e.target.value))} />
          <Textarea data-testid="clinical-consultation-advice" label="Advice" rows={2} value={draft.advice ?? ''} onChange={(e) => set('advice', blank(e.target.value))} />
        </div>
      </Card>
      <div className="flex flex-wrap gap-2">
        <Button type="submit" variant="secondary" disabled={busy}>
          {save.isPending && !confirm ? 'Saving…' : 'Save draft'}
        </Button>
        <Button disabled={busy} onClick={() => setConfirm(true)}>
          Finalize
        </Button>
      </div>
      <ConfirmDialog open={confirm} title="Finalize this prescription?" confirmLabel="Finalize" busy={busy} onCancel={() => setConfirm(false)} onConfirm={() => void doFinalize()}>
        <p>A finalized prescription cannot be edited. Corrections create a new version.</p>
      </ConfirmDialog>
    </form>
  )
}

function ReadOnly({ consultation: c, canWrite }: { consultation: Consultation; canWrite: boolean }) {
  const navigate = useNavigate()
  const revise = useReviseConsultation(c.id)
  const [error, setError] = useState<string | null>(null)
  const finalized = c.status === 'finalized'
  return (
    <div className="max-w-4xl space-y-6">
      <Header c={c} />
      {!finalized && <Alert tone="info">This is a draft. Only the treating doctor can edit it, and it cannot be printed until it is finalized.</Alert>}
      {finalized && !c.isLatest && <Alert tone="warning">A newer version of this prescription exists.</Alert>}
      {error && <Alert tone="error">{error}</Alert>}
      <ConsultationSummary c={c} />
      {finalized && (
        <div className="flex flex-wrap gap-2">
          <Link to={`/consultations/${c.id}/print`} className="text-sm font-medium text-primary-600 underline dark:text-primary-400">
            Print prescription
          </Link>
          {canWrite && c.isLatest && (
            <Button
              variant="secondary"
              disabled={revise.isPending}
              onClick={async () => {
                setError(null)
                try {
                  const next = await revise.mutateAsync()
                  navigate(`/consultations/${next.id}`)
                } catch (e) {
                  setError(clinicalErrorMessage(e, 'start a correction'))
                }
              }}
            >
              Revise (new version)
            </Button>
          )}
        </div>
      )}
    </div>
  )
}

export function ConsultationSummary({ c }: { c: Consultation }) {
  const row = (label: string, value: string | null) => (
    <div>
      <dt className="text-xs text-gray-500 dark:text-dark-300">{label}</dt>
      <dd className="text-sm">{value ?? '—'}</dd>
    </div>
  )
  return (
    <div className="space-y-4" data-testid="consultation-summary">
      <dl className="grid gap-3 sm:grid-cols-2">
        {row('Chief complaint', c.chiefComplaint)}
        {row('Notes', c.notes)}
        {row('Diagnosis', c.diagnosisText ? `${c.diagnosisText}${c.diagnosisCode ? ` (${c.diagnosisCode})` : ''}` : null)}
        {row('Follow-up', c.followUpDate)}
        {row('Advice', c.advice)}
      </dl>
      <PrescriptionTable lines={c.lines} />
    </div>
  )
}

export function PrescriptionTable({ lines }: { lines: PrescriptionLine[] }) {
  if (lines.length === 0) return <p className="text-sm text-gray-600 dark:text-dark-200">No medicines prescribed.</p>
  return (
    <table className="w-full text-left text-sm" data-testid="prescription-table">
      <thead>
        <tr className="border-b border-gray-200 dark:border-dark-500">
          <th className="py-1">#</th>
          <th>Medicine</th>
          <th>Dose</th>
          <th>Frequency</th>
          <th>Days</th>
          <th>Route</th>
          <th>Food</th>
          <th>Instructions</th>
        </tr>
      </thead>
      <tbody>
        {lines.map((l, i) => (
          <tr key={i} className="border-b border-gray-100 dark:border-dark-600">
            <td className="py-1">{i + 1}</td>
            <td>
              {l.medicineName}
              {l.strength ? ` ${l.strength}` : ''}
            </td>
            <td>{l.dose ?? '—'}</td>
            <td>{l.frequency}</td>
            <td>{l.durationDays ?? '—'}</td>
            <td>{l.route ?? '—'}</td>
            <td>{l.foodTiming ? FOOD_LABEL[l.foodTiming] : '—'}</td>
            <td>{l.instructions ?? '—'}</td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}
