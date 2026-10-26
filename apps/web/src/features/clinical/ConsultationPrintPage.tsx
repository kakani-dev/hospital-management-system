import { Link, useParams } from 'react-router'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { ApiError } from '../../lib/api/client'
import { formatDayLabel } from '../../lib/dates'
import { useConsultationPrint } from './consultationApi'
import { ConsultationSummary } from './ConsultationPage'

/** Printable prescription. The server refuses drafts (409), so a draft never reaches paper. */
export function ConsultationPrintPage() {
  const { consultationId = '' } = useParams()
  const print = useConsultationPrint(consultationId)
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
  return (
    <article className="mx-auto max-w-3xl space-y-4 bg-white p-6 text-gray-900" data-testid="prescription-print">
      <header className="border-b border-gray-300 pb-3">
        <p className="text-lg font-semibold">{p.branch?.name ?? p.tenantName}</p>
        {p.branch?.address && <p className="text-sm">{p.branch.address}</p>}
      </header>
      <section className="flex flex-wrap justify-between gap-4 text-sm">
        <div data-testid="print-doctor">
          <p className="font-semibold">{p.doctor?.name ?? p.practitionerName}</p>
          {p.doctor?.qualifications && <p>{p.doctor.qualifications}</p>}
          <p>
            Reg. no. {p.doctor?.registrationNumber ?? '—'}
            {p.doctor?.council ? ` (${p.doctor.council})` : ''}
          </p>
        </div>
        <div data-testid="print-patient" className="text-right">
          <p className="font-semibold">{p.patient?.name}</p>
          <p>MRN {p.patient?.mrn}</p>
          {p.finalizedOn && <p>Date {formatDayLabel(p.finalizedOn.slice(0, 10))}</p>}
          <p>Version {p.version}</p>
        </div>
      </section>
      <ConsultationSummary c={p} />
      <div className="print:hidden">
        <Button onClick={() => window.print()}>Print</Button>
      </div>
    </article>
  )
}
