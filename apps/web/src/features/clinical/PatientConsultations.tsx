import { Link } from 'react-router'
import { Alert } from '../../components/ui/Alert'
import { Card } from '../../components/ui/Card'
import { ApiError } from '../../lib/api/client'
import { usePatientConsultations } from './consultationApi'

/** Prescription history on the patient page (clinical.view only: billing never sees it). */
export function PatientConsultations({ patientId }: { patientId: string }) {
  const list = usePatientConsultations(patientId)
  const rows = [...(list.data ?? [])].sort((a, b) => b.createdOn.localeCompare(a.createdOn))
  return (
    <Card title="Prescriptions">
      <div data-testid="prescription-history">
        {list.isPending && <p role="status">Loading prescriptions…</p>}
        {list.isError && (
          <Alert tone="warning">{list.error instanceof ApiError && list.error.status === 403 ? 'Your role cannot view prescriptions.' : 'Prescription history is unavailable.'}</Alert>
        )}
        {list.data && rows.length === 0 && <p className="text-sm text-gray-600 dark:text-dark-200">No prescriptions yet.</p>}
        {rows.length > 0 && (
          <ul className="divide-y divide-gray-200 dark:divide-dark-500">
            {rows.map((c) => (
              <li key={c.id} className="flex flex-wrap items-baseline justify-between gap-2 py-2 text-sm" data-testid="prescription-row">
                <span>
                  {c.createdOn.slice(0, 10)} · {c.practitionerName} · {c.diagnosisText ?? 'No diagnosis'} · {c.lines.length} medicine{c.lines.length === 1 ? '' : 's'}
                </span>
                <span className="flex gap-3">
                  <span className="text-xs uppercase">{c.status === 'draft' ? 'Draft' : `v${c.version}${c.isLatest ? '' : ' (superseded)'}`}</span>
                  <Link className="text-primary-600 underline dark:text-primary-400" to={`/consultations/${c.id}`}>
                    Open
                  </Link>
                </span>
              </li>
            ))}
          </ul>
        )}
      </div>
    </Card>
  )
}
