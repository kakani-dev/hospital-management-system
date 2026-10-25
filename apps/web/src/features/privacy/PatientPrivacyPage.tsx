import { useState } from 'react'
import { useNavigate, useParams } from 'react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { Card } from '../../components/ui/Card'
import { FormField } from '../../components/ui/FormField'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { apiClient } from '../../lib/api/client'
import type { PatientSummary } from '../../lib/api/types'
import { PatientPicker } from '../patients/PatientPicker'
import { useCurrentContext } from '../tenancy/useCurrentContext'
import { ConsentStep } from './ConsentStep'
import { problemText } from './problem'

/** Consent for one person. The patient id comes from the route, never from a tenant field. */
export function PatientPrivacyPage() {
  const { patientId } = useParams()
  const navigate = useNavigate()
  const { has } = useCurrentContext()
  const qc = useQueryClient()
  const [picked, setPicked] = useState<PatientSummary | null>(null)
  const [minor, setMinor] = useState(false)
  const [guardian, setGuardian] = useState('')
  const [choices, setChoices] = useState<Record<string, boolean>>({})
  const [link, setLink] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [note, setNote] = useState<string | null>(null)

  const notice = useQuery({
    queryKey: ['privacy', 'current-notice'],
    queryFn: () => apiClient.privacy.currentNotice('en'),
    enabled: !!patientId && has('privacy.consent'),
  })
  const consents = useQuery({
    queryKey: ['privacy', 'consents', patientId],
    queryFn: () => apiClient.privacy.consents(patientId!),
    enabled: !!patientId,
  })

  const record = useMutation({
    mutationFn: () =>
      apiClient.privacy.recordConsents(crypto.randomUUID(), patientId!, {
        noticeId: notice.data!.noticeId,
        channel: 'tablet',
        givenBy: minor ? 'guardian' : 'self',
        subjectIsMinor: minor,
        guardianName: minor ? guardian : undefined,
        choices: (notice.data?.purposes ?? []).map((purpose) => ({
          purposeCode: purpose.code,
          granted: !!choices[purpose.code],
        })),
      }),
    onSuccess: async () => {
      setNote('Saved. A receipt is queued. It is not sent until a messenger is connected.')
      setError(null)
      await qc.invalidateQueries({ queryKey: ['privacy', 'consents', patientId] })
    },
    onError: (err) => setError(problemText(err)),
  })

  const withdraw = useMutation({
    mutationFn: (purpose: string) => apiClient.privacy.withdraw(crypto.randomUUID(), patientId!, purpose),
    onSuccess: async () => {
      setError(null)
      await qc.invalidateQueries({ queryKey: ['privacy', 'consents', patientId] })
    },
    onError: (err) => setError(problemText(err)),
  })

  const share = useMutation({
    mutationFn: () => apiClient.privacy.consentLink(patientId!),
    onSuccess: (row) => setLink(row.path),
    onError: (err) => setError(problemText(err)),
  })

  if (!patientId) {
    return (
      <div className="space-y-4 p-4 sm:p-6">
        <h1 className="text-xl font-medium text-gray-900 dark:text-dark-50">Consent</h1>
        <Card title="Find the person">
          <PatientPicker
            value={picked}
            onChange={(patient) => {
              setPicked(patient)
              if (patient) navigate(`/patients/${patient.id}/privacy`)
            }}
          />
        </Card>
      </div>
    )
  }

  return (
    <div className="space-y-4 p-4 sm:p-6">
      <h1 className="text-xl font-medium text-gray-900 dark:text-dark-50">Consent</h1>
      {note && <Alert>{note}</Alert>}
      {error && <Alert tone="error">{error}</Alert>}
      {consents.isPending && <LoadingBlock label="Loading consent" />}
      {consents.data && (
        <Card title="What is allowed now">
          <ul className="space-y-2 text-sm">
            {consents.data.current.map((row) => (
              <li key={row.purposeCode} className="flex flex-wrap items-center justify-between gap-2">
                <span>{row.label}: {row.granted ? 'yes' : 'no'}</span>
                {has('privacy.consent') && row.granted && (
                  <Button variant="secondary" onClick={() => withdraw.mutate(row.purposeCode)}>Withdraw</Button>
                )}
              </li>
            ))}
            {consents.data.current.length === 0 && <li>Nothing recorded yet.</li>}
          </ul>
        </Card>
      )}
      {has('privacy.consent') && notice.data && (
        <Card title={notice.data.title}>
          <p className="mb-3 whitespace-pre-wrap text-sm">{notice.data.body}</p>
          <form
            className="space-y-3"
            onSubmit={(event) => {
              event.preventDefault()
              record.mutate()
            }}
          >
            <label className="flex items-center gap-2 text-sm">
              <input type="checkbox" checked={minor} onChange={(event) => setMinor(event.target.checked)} />
              This person is under 18
            </label>
            {minor && <FormField label="Parent or guardian" value={guardian} onChange={(event) => setGuardian(event.target.value)} required />}
            <ConsentStep
              purposes={notice.data.purposes}
              value={choices}
              onChange={(code, granted) => setChoices((prev) => ({ ...prev, [code]: granted }))}
            />
            <Button type="submit" disabled={record.isPending}>Save consent</Button>
          </form>
          <div className="mt-4">
            <Button variant="secondary" onClick={() => share.mutate()} disabled={share.isPending}>Send a link</Button>
            {link && <p className="mt-2 font-mono text-sm">{link}</p>}
          </div>
        </Card>
      )}
    </div>
  )
}
