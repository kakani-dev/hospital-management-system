import type { ConsultationPrint, Vitals } from '../../lib/api/types'
import { formatDayLabel, localToday } from '../../lib/dates'
import { ageOn } from '../patients/patientLabel'
import { followUpLabel, rxLineText, vitalsLine } from './rxPrintModel'

const SEX_LABEL: Record<string, string> = { female: 'Female', male: 'Male', other: 'Other' }

/** "36 y · Female". Age is on the prescription date; unknown values print as "—" (#128). */
export function ageSexLabel(dateOfBirth: string | null | undefined, sex: string | null | undefined, onDate: string): string {
  const age = ageOn(dateOfBirth ?? null, onDate)
  return `${age ?? 'Age —'} · ${(sex && SEX_LABEL[sex]) || 'Sex —'}`
}

/** What the sheet needs: the print payload, possibly with unsaved draft edits overlaid (live preview). */
export type RxSheetData = Omit<ConsultationPrint, 'paperSize'> & { paperSize?: 'A5' | 'A4' | null }

/**
 * The one prescription layout (#296), shared by the printable page and the consultation screen's live
 * preview, so what the doctor sees while writing is exactly what prints.
 */
export function RxSheet({
  p,
  vitals,
  printArea = false,
  className = '',
  testId = 'prescription-print',
}: {
  p: RxSheetData
  vitals?: Vitals | null
  printArea?: boolean
  className?: string
  testId?: string
}) {
  // The Rx date is the hospital's calendar day (not the UTC day: 00:00–05:30 IST would show yesterday).
  const zone = p.timeZone ?? undefined
  const onDate = p.finalizedOn && p.finalizedOn.length === 10 ? p.finalizedOn : localToday(p.finalizedOn ? new Date(p.finalizedOn) : new Date(), zone)
  const regNo = p.doctor?.registrationNumber?.trim() || null
  const vitalsText = vitals ? vitalsLine(vitals) : null
  const diagnosis = p.diagnosisText ? `${p.diagnosisText}${p.diagnosisCode ? ` (${p.diagnosisCode})` : ''}` : null
  const lines = p.lines.filter((l) => l.medicineName.trim())
  return (
    <article
      className={`${printArea ? 'rx-print ' : ''}${className} space-y-2 bg-white text-[13px] leading-snug text-gray-900 print:max-w-none print:p-0 print:text-[11px]`}
      data-testid={testId}
      data-print-area={printArea ? '' : undefined}
      data-paper={p.paperSize ?? undefined}
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
          <p>Date {formatDayLabel(onDate)}</p>
        </div>
      </section>
      {vitalsText && <p data-testid="print-vitals"><span className="font-semibold">Vitals:</span> {vitalsText}</p>}
      {p.chiefComplaint && <p data-testid="print-complaint"><span className="font-semibold">C/o:</span> {p.chiefComplaint}</p>}
      {diagnosis && <p data-testid="print-diagnosis"><span className="font-semibold">Diagnosis:</span> {diagnosis}</p>}
      <div>
        <p className="text-lg font-bold leading-none" aria-label="Prescription">℞</p>
        {lines.length === 0 ? (
          <p>No medicines prescribed.</p>
        ) : (
          <ol className="mt-1 list-decimal space-y-0.5 pl-5" data-testid="print-rx-lines">
            {lines.map((l, i) => (
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
  )
}
