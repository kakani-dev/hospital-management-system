import { Link, useParams } from 'react-router'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { ApiError } from '../../lib/api/client'
import { useConsultationPrint } from './consultationApi'
import { RxSheet } from './RxSheet'
import { useVisitVitals } from './vitalsApi'

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
  const regNo = p.doctor?.registrationNumber?.trim() || null
  const paper = p.paperSize
  const latest = vitals.data?.length ? vitals.data[vitals.data.length - 1] : null
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
      <RxSheet p={p} vitals={latest} printArea className="mx-auto max-w-3xl p-6" />
    </>
  )
}
