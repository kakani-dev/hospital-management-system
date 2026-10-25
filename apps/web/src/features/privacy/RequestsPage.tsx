import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { Card } from '../../components/ui/Card'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { apiClient } from '../../lib/api/client'
import type { PatientSummary } from '../../lib/api/types'
import { PatientPicker } from '../patients/PatientPicker'
import { useCurrentContext } from '../tenancy/useCurrentContext'
import { isDueSoon } from './due'
import { problemText } from './problem'

const TYPES = [
  { value: 'access', label: 'Access' },
  { value: 'correction', label: 'Correction' },
  { value: 'erasure', label: 'Erasure' },
  { value: 'grievance', label: 'Grievance' },
  { value: 'nomination', label: 'Nomination' },
] as const

/** Desk for data-principal requests. Erasure still needs a second approver. */
export function RequestsPage() {
  const { has } = useCurrentContext()
  const qc = useQueryClient()
  const requests = useQuery({ queryKey: ['privacy', 'requests'], queryFn: () => apiClient.privacy.requests() })
  const [patient, setPatient] = useState<PatientSummary | null>(null)
  const [type, setType] = useState<(typeof TYPES)[number]['value']>('access')
  const [details, setDetails] = useState('')
  const [response, setResponse] = useState('We have completed this request.')
  const [error, setError] = useState<string | null>(null)
  const [note, setNote] = useState<string | null>(null)

  const refresh = async () => {
    await qc.invalidateQueries({ queryKey: ['privacy', 'requests'] })
  }
  const fail = (err: unknown) => setError(problemText(err))

  const create = useMutation({
    mutationFn: () =>
      apiClient.privacy.createRequest(crypto.randomUUID(), {
        patientId: patient!.id,
        type,
        details,
        channel: 'desk',
      }),
    onSuccess: async (row) => {
      setNote(`${row.code} is due ${new Date(row.dueAt).toLocaleDateString()}.`)
      setError(null)
      setDetails('')
      await refresh()
    },
    onError: fail,
  })
  const act = useMutation({
    mutationFn: (run: () => Promise<unknown>) => run(),
    onSuccess: async () => {
      setError(null)
      await refresh()
    },
    onError: fail,
  })

  return (
    <div className="space-y-4 p-4 sm:p-6">
      <h1 className="text-xl font-medium text-gray-900 dark:text-dark-50">Data requests</h1>
      <p className="text-sm text-gray-600 dark:text-dark-200">
        A request is due in 90 days. Erasure needs two different people, and an open visit holds it.
      </p>
      {note && <Alert>{note}</Alert>}
      {error && <Alert tone="error">{error}</Alert>}
      {has('privacy.request') && (
        <Card title="New request">
          <form
            className="space-y-3"
            onSubmit={(event) => {
              event.preventDefault()
              if (patient) create.mutate()
            }}
          >
            <PatientPicker value={patient} onChange={setPatient} label="Person" />
            <label className="block text-sm font-medium">
              What they asked for
              <select className="mt-1 min-h-11 w-full rounded-lg border border-gray-300 bg-white px-3 py-2 text-sm dark:border-dark-500 dark:bg-dark-700" value={type} onChange={(event) => setType(event.target.value as typeof type)}>
                {TYPES.map((item) => (
                  <option key={item.value} value={item.value}>{item.label}</option>
                ))}
              </select>
            </label>
            <label className="block text-sm font-medium">
              In their words
              <textarea className="mt-1 min-h-24 w-full rounded-lg border border-gray-300 bg-white px-3 py-2 text-sm dark:border-dark-500 dark:bg-dark-700" value={details} onChange={(event) => setDetails(event.target.value)} required />
            </label>
            <Button type="submit" disabled={!patient || create.isPending}>Save request</Button>
          </form>
        </Card>
      )}
      {requests.isPending && <LoadingBlock label="Loading requests" />}
      {requests.data && (
        <Card title="Open and recent">
          <ul className="space-y-4">
            {requests.data.map((row) => (
              <li key={row.id} className="space-y-2 border-b border-gray-200 pb-3 text-sm last:border-0 dark:border-dark-500">
                <p>
                  <span className="font-mono">{row.code}</span> · {row.type} · {row.status}
                  {isDueSoon(row.dueAt) && <span className="ml-2 font-medium">Due soon</span>}
                </p>
                <p>{row.details}</p>
                <div className="flex flex-wrap gap-2">
                  {has('privacy.fulfil') && row.status === 'received' && (
                    <Button variant="secondary" onClick={() => act.mutate(() => apiClient.privacy.verifyRequest(row.id))}>Verify identity</Button>
                  )}
                  {has('privacy.fulfil') && row.status === 'verified' && row.type !== 'erasure' && (
                    <Button variant="secondary" onClick={() => act.mutate(() => apiClient.privacy.fulfilRequest(row.id, response))}>Fulfil</Button>
                  )}
                  {has('privacy.erase') && row.type === 'erasure' && row.status === 'verified' && (
                    <>
                      <Button variant="secondary" onClick={() => act.mutate(() => apiClient.privacy.approveErasure(row.id))}>Approve erasure</Button>
                      <Button variant="danger" onClick={() => act.mutate(() => apiClient.privacy.executeErasure(crypto.randomUUID(), row.id))}>Execute erasure</Button>
                    </>
                  )}
                  {has('privacy.fulfil') && row.status === 'fulfilled' && (
                    <Button variant="secondary" onClick={() => act.mutate(() => apiClient.privacy.closeRequest(row.id, response))}>Close</Button>
                  )}
                </div>
              </li>
            ))}
            {requests.data.length === 0 && <li>No requests.</li>}
          </ul>
          {has('privacy.fulfil') && (
            <label className="mt-3 block text-sm font-medium">
              Reply to the person
              <textarea className="mt-1 min-h-16 w-full rounded-lg border border-gray-300 bg-white px-3 py-2 text-sm dark:border-dark-500 dark:bg-dark-700" value={response} onChange={(event) => setResponse(event.target.value)} />
            </label>
          )}
        </Card>
      )}
    </div>
  )
}
