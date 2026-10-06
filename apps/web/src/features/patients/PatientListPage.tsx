import { useId, useState } from 'react'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Link, useLocation } from 'react-router'
import { PATIENT_SEARCH_DEBOUNCE_MS, usePatients } from '../../lib/api/hooks'
import { useDebouncedValue } from '../../lib/useDebouncedValue'
import { ApiError } from '../../lib/api/client'
import { useCurrentContext } from '../tenancy/useCurrentContext'

const WRITE_ROLES = ['tenant_admin', 'doctor', 'nurse', 'receptionist']

export function PatientListPage() {
  const [search, setSearch] = useState('')
  // Debounced: one request after typing pauses, not one per keystroke (PHI + rate limit).
  const debouncedSearch = useDebouncedValue(search, PATIENT_SEARCH_DEBOUNCE_MS)
  const searchId = useId()
  const patients = usePatients(debouncedSearch)
  const { roles, branches } = useCurrentContext()
  const location = useLocation()
  const registered = (location.state as { registered?: string } | null)?.registered
  const canRegister = roles.some((r) => WRITE_ROLES.includes(r))
  const branchName = (id: string) => branches.find((b) => b.id === id)?.name ?? '—'

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <h1 className="text-2xl font-semibold">Patients</h1>
        {canRegister && (
          <Link
            to="/patients/new"
            className="inline-flex items-center rounded-md bg-brand-700 px-4 py-2 text-sm font-medium text-white hover:bg-brand-800"
          >
            Register patient
          </Link>
        )}
      </div>
      {registered && <Alert tone="info">Patient {registered} registered.</Alert>}
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
            {patients.error instanceof ApiError && patients.error.status === 403
              ? 'Your role in this hospital does not include access to the patient registry.'
              : patients.error instanceof ApiError && patients.error.status === 401
                ? 'Your session has expired. Sign in again.'
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
                <th scope="col" className="px-3 py-2 font-semibold">Branch</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {patients.isPending && (
                <tr>
                  <td colSpan={5} className="px-3 py-6 text-center text-slate-600">Loading…</td>
                </tr>
              )}
              {patients.data?.items.map((p) => (
                <tr key={p.id} data-testid="patient-row">
                  <td className="px-3 py-2 font-mono">{p.mrn}</td>
                  <td className="px-3 py-2">{p.lastName}, {p.firstName}</td>
                  <td className="px-3 py-2">{p.dateOfBirth ?? '—'}</td>
                  <td className="px-3 py-2 capitalize">{p.sex}</td>
                  <td className="px-3 py-2">{branchName(p.registeredBranchId)}</td>
                </tr>
              ))}
              {!patients.isPending && (patients.data?.items.length ?? 0) === 0 && (
                <tr>
                  <td colSpan={5} className="px-3 py-6 text-center text-slate-600" data-testid="patients-empty">
                    No patients to show.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
        {patients.data && (
          <p className="mt-3 text-xs text-slate-600" data-testid="patients-total">
            {patients.data.totalCount} patient{patients.data.totalCount === 1 ? '' : 's'}
          </p>
        )}
      </Card>
    </div>
  )
}
