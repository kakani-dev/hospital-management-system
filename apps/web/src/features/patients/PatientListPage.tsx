import { useId, useMemo, useState } from 'react'
import { PlusIcon } from '@heroicons/react/20/solid'
import { Badge, Button as TxButton, Checkbox, Input } from '@tailux/components/ui'
import { DataTable, type ColumnDef } from '../../components/table/DataTable'
import { ServerPagination } from '../../components/table/ServerPagination'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Link, useLocation } from 'react-router'
import { PATIENT_SEARCH_DEBOUNCE_MS, PATIENT_SEARCH_MAX_LENGTH, PHONE_SEARCH_MIN_DIGITS, PATIENT_PAGE_SIZE, usePatients, useRestorePatient } from '../../lib/api/hooks'
import { useDebouncedValue } from '../../lib/useDebouncedValue'
import { ApiError } from '../../lib/api/client'
import { useCurrentContext } from '../tenancy/useCurrentContext'
import { can } from '../../lib/permissions'
import { latestToday, localToday } from '../../lib/dates'
import { useBranchTimeZones } from '../../lib/useBranchTimeZone'
import { Button } from '../../components/ui/Button'
import { exactMrnFirst } from './patientLabel'
import type { PatientSummary } from '../../lib/api/types'

export function PatientListPage() {
  const [search, setSearch] = useState('')
  const [phone, setPhone] = useState('')
  const [dateOfBirth, setDateOfBirth] = useState('')
  const [includeDeleted, setIncludeDeleted] = useState(false)
  // Memoised so the debounce only restarts when a field actually changes.
  const criteria = useMemo(() => ({ search, phone, dateOfBirth, includeDeleted }), [search, phone, dateOfBirth, includeDeleted])
  // Debounced: one request after typing pauses, not one per keystroke (PHI + rate limit).
  const debouncedCriteria = useDebouncedValue(criteria, PATIENT_SEARCH_DEBOUNCE_MS)
  // Server-side paging; new criteria start again at page 1 (adjusted during render, no effect).
  const [page, setPage] = useState(1)
  const [pagedCriteria, setPagedCriteria] = useState(debouncedCriteria)
  if (pagedCriteria !== debouncedCriteria) {
    setPagedCriteria(debouncedCriteria)
    setPage(1)
  }
  const searchId = useId()
  const phoneId = useId()
  const dobId = useId()
  const patients = usePatients(debouncedCriteria, { page: pagedCriteria === debouncedCriteria ? page : 1 })
  const { roles, branches } = useCurrentContext()
  // Latest "today" across the user's branches (a branch east of the workstation may already be tomorrow).
  const { zoneFor } = useBranchTimeZones()
  const zones = branches.map((b) => zoneFor(b.id))
  const dobMax =
    zones.length > 0 && zones.every(Boolean)
      ? zones.map((z) => localToday(new Date(), z)).reduce((a, b) => (b > a ? b : a))
      : latestToday()
  const location = useLocation()
  const flash = location.state as { registered?: string; deleted?: string } | null
  const registered = flash?.registered
  const canRegister = can(roles, 'patients.write')
  const canRestore = can(roles, 'patients.restore')
  const restore = useRestorePatient()
  const phoneDigits = phone.replace(/\D/g, '').length
  const phoneTooShort = phoneDigits > 0 && phoneDigits < PHONE_SEARCH_MIN_DIGITS
  const branchName = (id: string) => branches.find((b) => b.id === id)?.name ?? '—'

  const columns: ColumnDef<PatientSummary, unknown>[] = [
    {
      id: 'mrn',
      accessorKey: 'mrn',
      header: 'MRN',
      cell: ({ row }) => (
        <span className="font-mono font-medium text-gray-800 dark:text-dark-100">
          {row.original.mrn}
          {row.original === exact && (
            <Badge color="primary" variant="soft" className="ml-2 font-sans text-tiny" data-testid="exact-mrn-badge">
              Exact MRN
            </Badge>
          )}
        </span>
      ),
    },
    {
      id: 'name',
      accessorFn: (p) => `${p.lastName}, ${p.firstName}`,
      header: 'Name',
      cell: ({ row: { original: p } }) =>
        p.deletedAt ? (
          <span>
            {p.lastName}, {p.firstName}
          </span>
        ) : (
          <Link
            to={`/patients/${p.id}`}
            className="font-medium text-primary-600 hover:underline dark:text-primary-400"
            data-testid="patient-link"
          >
            {p.lastName}, {p.firstName}
          </Link>
        ),
    },
    { id: 'dob', accessorFn: (p) => p.dateOfBirth ?? '', header: 'Date of birth', cell: ({ row }) => row.original.dateOfBirth ?? '—' },
    { id: 'sex', accessorKey: 'sex', header: 'Sex', cell: ({ row }) => <span className="capitalize">{row.original.sex}</span> },
    { id: 'branch', accessorFn: (p) => branchName(p.registeredBranchId), header: 'Branch' },
  ]
  if (includeDeleted) {
    columns.push({
      id: 'status',
      header: 'Status',
      enableSorting: false,
      cell: ({ row: { original: p } }) =>
        p.deletedAt ? (
          <span className="flex items-center gap-2">
            <Badge color="error" variant="soft" data-testid="patient-deleted-badge">
              Deleted
            </Badge>
            <Button
              variant="secondary"
              className="h-7 px-2 text-xs"
              disabled={restore.isPending}
              aria-label={`Restore ${p.mrn}`}
              onClick={() => restore.mutate(p.id)}
            >
              Restore
            </Button>
          </span>
        ) : (
          <Badge color="success" variant="soft">
            Active
          </Badge>
        ),
    })
  }

  const totalCount = patients.data?.totalCount ?? 0
  // Exact-MRN match first (the search box is "Name or MRN"); the rest keep the server's order.
  const { items: rows, exact } = exactMrnFirst(patients.data?.items ?? [], debouncedCriteria.search)

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Patients</h1>
        {canRegister && (
          <TxButton component={Link} to="/patients/new" color="primary" className="h-9 gap-2 px-4 text-sm">
            <PlusIcon className="size-4" aria-hidden="true" />
            Register patient
          </TxButton>
        )}
      </div>
      {registered && <Alert tone="info">Patient {registered} registered.</Alert>}
      {flash?.deleted && <Alert tone="info">Patient {flash.deleted} deleted.</Alert>}
      <Card>
        <form role="search" aria-label="Find patients" className="mb-4 grid gap-4 sm:grid-cols-3" onSubmit={(e) => e.preventDefault()}>
          <Input
            id={searchId}
            label="Search patients"
            classNames={{ label: 'font-medium text-gray-800 dark:text-dark-100' }}
            data-shortcut="patient-search"
            aria-keyshortcuts="/"
            type="search"
            maxLength={PATIENT_SEARCH_MAX_LENGTH}
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Name or MRN"
          />
          <Input
            id={phoneId}
            label="Phone"
            classNames={{ label: 'font-medium text-gray-800 dark:text-dark-100' }}
            type="tel"
            inputMode="tel"
            autoComplete="off"
            maxLength={32}
            value={phone}
            aria-describedby={`${phoneId}-hint`}
            onChange={(e) => setPhone(e.target.value)}
            description={
              <span id={`${phoneId}-hint`} className={phoneTooShort ? 'text-warning-darker dark:text-warning-lighter' : undefined}>
                Exact match on the last 10 digits (at least {PHONE_SEARCH_MIN_DIGITS} digits).
              </span>
            }
          />
          <Input
            id={dobId}
            label="Date of birth"
            classNames={{ label: 'font-medium text-gray-800 dark:text-dark-100' }}
            type="date"
            min="1900-01-01"
            max={dobMax}
            value={dateOfBirth}
            onChange={(e) => setDateOfBirth(e.target.value)}
          />
          {canRestore && (
            <div className="sm:col-span-3">
              <Checkbox
                label="Include deleted patients"
                checked={includeDeleted}
                onChange={(e) => setIncludeDeleted(e.target.checked)}
                classNames={{ labelText: 'text-sm' }}
              />
            </div>
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
        <div className="mt-4">
          <DataTable
            data={rows}
            columns={columns}
            caption="Patients in the current hospital"
            isLoading={patients.isPending}
            isStale={patients.isPlaceholderData}
            isFetching={patients.isFetching}
            empty="No patients to show."
            emptyTestId="patients-empty"
            getRowId={(p) => p.id}
            getRowProps={(row) => ({
              'data-testid': 'patient-row',
              className: row.original.deletedAt ? 'text-gray-400 dark:text-dark-400' : undefined,
            })}
          />
        </div>
        {patients.data && (
          <ServerPagination
            page={patients.data.page || 1}
            pageSize={patients.data.pageSize || PATIENT_PAGE_SIZE}
            totalCount={totalCount}
            onPageChange={setPage}
            summary={
              <span data-testid="patients-total">
                {totalCount} patient{totalCount === 1 ? '' : 's'}
              </span>
            }
          />
        )}
      </Card>
    </div>
  )
}
