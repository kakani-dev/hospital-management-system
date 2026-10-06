import { useDeferredValue, useId, useState } from 'react'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { usePatients } from '../../lib/api/hooks'
import { ApiError } from '../../lib/api/client'

export function PatientListPage() {
  const [search, setSearch] = useState('')
  const deferredSearch = useDeferredValue(search)
  const searchId = useId()
  const patients = usePatients(deferredSearch)

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <h1 className="text-2xl font-semibold">Patients</h1>
        <Button disabled title="Patient registration arrives in Sprint 2">
          Register patient
        </Button>
      </div>
      <Card>
        <div className="mb-4 max-w-sm">
          <label htmlFor={searchId} className="block text-sm font-medium text-slate-800">
            Search patients
          </label>
          <input
            id={searchId}
            type="search"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Name or MRN"
            className="mt-1 block w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
          />
        </div>
        {patients.isError && (
          <Alert tone="warning">
            {patients.error instanceof ApiError && patients.error.status === 401
              ? 'You need to sign in with a real account to load patients (Sprint 1).'
              : 'Patient service is unavailable. Showing no records.'}
          </Alert>
        )}
        <div className="mt-4 overflow-x-auto">
          <table className="min-w-full divide-y divide-slate-200 text-sm">
            <caption className="sr-only">Patients in the current hospital</caption>
            <thead className="bg-slate-50 text-left">
              <tr>
                <th scope="col" className="px-3 py-2 font-semibold">MRN</th>
                <th scope="col" className="px-3 py-2 font-semibold">Name</th>
                <th scope="col" className="px-3 py-2 font-semibold">Date of birth</th>
                <th scope="col" className="px-3 py-2 font-semibold">Sex</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {patients.isPending && (
                <tr>
                  <td colSpan={4} className="px-3 py-6 text-center text-slate-600">Loading…</td>
                </tr>
              )}
              {patients.data?.items.map((p) => (
                <tr key={p.id}>
                  <td className="px-3 py-2 font-mono">{p.mrn}</td>
                  <td className="px-3 py-2">{p.lastName}, {p.firstName}</td>
                  <td className="px-3 py-2">{p.dateOfBirth ?? '—'}</td>
                  <td className="px-3 py-2 capitalize">{p.sex}</td>
                </tr>
              ))}
              {!patients.isPending && (patients.data?.items.length ?? 0) === 0 && (
                <tr>
                  <td colSpan={4} className="px-3 py-6 text-center text-slate-600" data-testid="patients-empty">
                    No patients to show.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </Card>
    </div>
  )
}
