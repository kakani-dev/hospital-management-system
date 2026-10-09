import { useId, useMemo, useState } from 'react'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Link, useLocation } from 'react-router'
import { PATIENT_SEARCH_DEBOUNCE_MS, PATIENT_SEARCH_MAX_LENGTH, PHONE_SEARCH_MIN_DIGITS, usePatients, useRestorePatient } from '../../lib/api/hooks'
import { useDebouncedValue } from '../../lib/useDebouncedValue'
import { ApiError } from '../../lib/api/client'
import { useCurrentContext } from '../tenancy/useCurrentContext'
import { can } from '../../lib/permissions'
import { localToday } from '../../lib/dates'
import { Button } from '../../components/ui/Button'

export function PatientListPage() {
  const [search, setSearch] = useState('')
  const [phone, setPhone] = useState('')
  const [dateOfBirth, setDateOfBirth] = useState('')
  const [includeDeleted, setIncludeDeleted] = useState(false)
  // Memoised so the debounce only restarts when a field actually changes.
  const criteria = useMemo(() => ({ search, phone, dateOfBirth, includeDeleted }), [search, phone, dateOfBirth, includeDeleted])
  // Debounced: one request after typing pauses, not one per keystroke (PHI + rate limit).
  const debouncedCriteria = useDebouncedValue(criteria, PATIENT_SEARCH_DEBOUNCE_MS)
  const searchId = useId()
  const phoneId = useId()
  const dobId = useId()
  const patients = usePatients(debouncedCriteria)
  const { roles, branches } = useCurrentContext()
  const location = useLocation()
  const flash = location.state as { registered?: string; deleted?: string } | null
  const registered = flash?.registered
  const canRegister = can(roles, 'patients.write')
  const canRestore = can(roles, 'patients.restore')
  const restore = useRestorePatient()
  const phoneDigits = phone.replace(/\D/g, '').length
  const phoneTooShort = phoneDigits > 0 && phoneDigits < PHONE_SEARCH_MIN_DIGITS
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
      {flash?.deleted && <Alert tone="info">Patient {flash.deleted} deleted.</Alert>}
      <Card>
        <form role="search" aria-label="Find patients" className="mb-4 grid gap-3 sm:grid-cols-3" onSubmit={(e) => e.preventDefault()}>
          <div>
            <label htmlFor={searchId} className="block text-sm font-medium text-slate-800">
              Search patients
            </label>
            <input
              id={searchId}
              type="search"
              maxLength={PATIENT_SEARCH_MAX_LENGTH}
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Name or MRN"
              className="mt-1 block w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
            />
          </div>
          <div>
            <label htmlFor={phoneId} className="block text-sm font-medium text-slate-800">
              Phone
            </label>
            <input
              id={phoneId}
              type="tel"
              inputMode="tel"
              autoComplete="off"
              maxLength={32}
              value={phone}
              aria-describedby={`${phoneId}-hint`}
              onChange={(e) => setPhone(e.target.value)}
              className="mt-1 block w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
            />
            <p id={`${phoneId}-hint`} className={`mt-1 text-xs ${phoneTooShort ? 'text-amber-800' : 'text-slate-600'}`}>
              Exact match on the last 10 digits (at least {PHONE_SEARCH_MIN_DIGITS} digits).
            </p>
          </div>
          <div>
            <label htmlFor={dobId} className="block text-sm font-medium text-slate-800">
              Date of birth
            </label>
            <input
              id={dobId}
              type="date"
              min="1900-01-01"
              max={localToday()}
              value={dateOfBirth}
              onChange={(e) => setDateOfBirth(e.target.value)}
              className="mt-1 block w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
            />
          </div>
          {canRestore && (
            <label className="flex items-center gap-2 text-sm sm:col-span-3">
              <input type="checkbox" checked={includeDeleted} onChange={(e) => setIncludeDeleted(e.target.checked)} />
              Include deleted patients
            </label>
          )}
        </form>
        {restore.isError && <Alert tone="error">Could not restore the patient. Try again.</Alert>}
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
                {includeDeleted && <th scope="col" className="px-3 py-2 font-semibold">Status</th>}
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {patients.isPending && (
                <tr>
                  <td colSpan={includeDeleted ? 6 : 5} className="px-3 py-6 text-center text-slate-600">Loading…</td>
                </tr>
              )}
              {patients.data?.items.map((p) => (
                <tr key={p.id} data-testid="patient-row" className={p.deletedAt ? 'bg-slate-50 text-slate-500' : undefined}>
                  <td className="px-3 py-2 font-mono">{p.mrn}</td>
                  <td className="px-3 py-2">
                    {p.deletedAt ? (
                      <span>
                        {p.lastName}, {p.firstName}
                      </span>
                    ) : (
                      <Link to={`/patients/${p.id}`} className="text-brand-800 underline" data-testid="patient-link">
                        {p.lastName}, {p.firstName}
                      </Link>
                    )}
                  </td>
                  <td className="px-3 py-2">{p.dateOfBirth ?? '—'}</td>
                  <td className="px-3 py-2 capitalize">{p.sex}</td>
                  <td className="px-3 py-2">{branchName(p.registeredBranchId)}</td>
                  {includeDeleted && (
                    <td className="px-3 py-2">
                      {p.deletedAt ? (
                        <span className="flex items-center gap-2">
                          <span className="rounded bg-red-100 px-2 py-0.5 text-xs font-medium text-red-800" data-testid="patient-deleted-badge">
                            Deleted
                          </span>
                          <Button
                            variant="secondary"
                            className="px-2 py-1 text-xs"
                            disabled={restore.isPending}
                            aria-label={`Restore ${p.mrn}`}
                            onClick={() => restore.mutate(p.id)}
                          >
                            Restore
                          </Button>
                        </span>
                      ) : (
                        'Active'
                      )}
                    </td>
                  )}
                </tr>
              ))}
              {!patients.isPending && (patients.data?.items.length ?? 0) === 0 && (
                <tr>
                  <td colSpan={includeDeleted ? 6 : 5} className="px-3 py-6 text-center text-slate-600" data-testid="patients-empty">
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
