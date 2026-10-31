import { Link, useParams } from 'react-router'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { ApiError } from '../../lib/api/client'
import { formatDayLabel } from '../../lib/dates'
import { ageOn } from '../patients/patientLabel'
import { useConsultationPrint } from './consultationApi'
import { rxLineText, followUpLabel, vitalsLine } from './rxPrintModel'
import { useVisitVitals } from './vitalsApi'

const SEX_LABEL: Record<string, string> = { female: 'Female', male: 'Male', other: 'Other' }

/** "36 y · Female". Age is on the prescription date; unknown values print as "—" (#128). */
function ageSexLabel(dateOfBirth: string | null | undefined, sex: string | null | undefined, onDate: string): string {
  const age = ageOn(dateOfBirth ?? null, onDate)
  return `${age ?? 'Age —'} · ${(sex && SEX_LABEL[sex]) || 'Sex —'}`
}

/** Printable prescription. The server refuses drafts (409), so a draft never reaches paper. */
export function ConsultationPrintPage() {
  const { consultationId = '' } = useParams()
  const print = useConsultationPrint(consultationId)
  const vitals = useVisitVitals(print.data?.queueEntryId ?? '')
  if (print.isPending) return <LoadingBlock label="Preparing the prescription" />
  if (print.isError) {
    const status = print.error instanceof ApiError ? print.error.status : 0
    return (
      <div className="space-y-4" data-testid="print-unavailable">
        <Alert tone="warning">
          {status === 409
            ? 'This prescription is still a draft. Finalize it before printing.'
            : status === 404
              ? 'This prescription does not exist in this hospital or branch.'
              : status === 403
                ? 'Your role cannot print prescriptions.'
                : 'The prescription could not be loaded.'}
        </Alert>
        <Link className="text-sm text-primary-600 underline dark:text-primary-400" to={`/consultations/${consultationId}`}>
          Back to consultation
        </Link>
      </div>
    )
  }
  const p = print.data
  const onDate = (p.finalizedOn ?? new Date().toISOString()).slice(0, 10)
  const regNo = p.doctor?.registrationNumber?.trim() || null
  const paper = p.paperSize
  const latest = vitals.data?.length ? vitals.data[vitals.data.length - 1] : null
  const vitalsText = latest ? vitalsLine(latest) : null
  const diagnosis = p.diagnosisText ? `${p.diagnosisText}${p.diagnosisCode ? ` (${p.diagnosisCode})` : ''}` : null
  return (
    <>
      {/* Page size comes from the hospital's setting (paperSize), never from code. */}
      {paper && <style data-testid="print-page-size">{`@media print { @page { size: ${paper}; margin: 8mm; } }`}</style>}
      {!regNo && (
        <div className="print:hidden mx-auto max-w-3xl" data-testid="print-missing-reg">
          <Alert tone="warning">
            This prescription has no doctor registration number, which an Indian prescription must show. Ask an admin to add it under Administration → Practitioners; new prescriptions can't be finalized without it.
          </Alert>
        </div>
      )}
      <div className="mx-auto mb-3 flex max-w-3xl items-center gap-3 print:hidden">
        <Button onClick={() => window.print()} data-testid="print-rx-button">Print</Button>
        {paper && <span className="text-xs text-gray-600 dark:text-dark-200" data-testid="print-paper-size">Paper: {paper}</span>}
        <Link className="text-sm text-primary-600 underline dark:text-primary-400" to={`/consultations/${consultationId}`}>Back to consultation</Link>
      </div>
      <article
        className="rx-print mx-auto max-w-3xl space-y-2 bg-white p-6 text-[13px] leading-snug text-gray-900 print:max-w-none print:p-0 print:text-[11px]"
        data-testid="prescription-print"
        data-print-area
        data-paper={paper ?? undefined}
      >
        <header className="border-b-2 border-gray-800 pb-1">
          <p className="text-base font-semibold" data-testid="print-hospital">{[p.tenantName, p.branch?.name].filter((x, i, all) => x && all.indexOf(x) === i).join(' — ')}</p>
          {p.branch?.address && <p className="text-xs">{p.branch.address}</p>}
        </header>
        <section className="flex justify-between gap-4 border-b border-gray-300 pb-1">
          <div data-testid="print-doctor">
            <p className="font-semibold">{p.doctor?.name ?? p.practitionerName}</p>
            {p.doctor?.qualifications && <p>{p.doctor.qualifications}</p>}
            {regNo && (
              <p data-testid="print-doctor-reg">
                Reg. no. {regNo}
                {p.doctor?.council ? ` (${p.doctor.council})` : ''}
              </p>
            )}
          </div>
          <div data-testid="print-patient" className="text-right">
            <p className="font-semibold">{p.patient?.name}</p>
            <p data-testid="print-patient-age-sex">{ageSexLabel(p.patient?.dateOfBirth, p.patient?.sex, onDate)}</p>
            <p>MRN {p.patient?.mrn}</p>
            {p.finalizedOn && <p>Date {formatDayLabel(p.finalizedOn.slice(0, 10))}</p>}
          </div>
        </section>
        {vitalsText && <p data-testid="print-vitals"><span className="font-semibold">Vitals:</span> {vitalsText}</p>}
        {p.chiefComplaint && <p data-testid="print-complaint"><span className="font-semibold">C/o:</span> {p.chiefComplaint}</p>}
        {diagnosis && <p data-testid="print-diagnosis"><span className="font-semibold">Diagnosis:</span> {diagnosis}</p>}
        <div>
          <p className="text-lg font-bold leading-none" aria-label="Prescription">℞</p>
          {p.lines.length === 0 ? (
            <p>No medicines prescribed.</p>
          ) : (
            <ol className="mt-1 list-decimal space-y-0.5 pl-5" data-testid="print-rx-lines">
              {p.lines.map((l, i) => (
                <li key={i} className="break-inside-avoid">{rxLineText(l)}</li>
              ))}
            </ol>
          )}
        </div>
        {p.advice && <p data-testid="print-advice"><span className="font-semibold">Advice:</span> {p.advice}</p>}
        {p.followUpDate && <p data-testid="print-follow-up"><span className="font-semibold">Review on:</span> {followUpLabel(p.followUpDate)}</p>}
        <footer className="flex break-inside-avoid justify-end pt-8" data-testid="print-signature">
          <div className="w-48 border-t border-gray-800 pt-1 text-center text-xs">
            <p>Signature &amp; stamp</p>
            <p className="font-semibold">{p.doctor?.name ?? p.practitionerName}</p>
          </div>
        </footer>
      </article>
    </>
  )
}
