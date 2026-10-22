import { useDeferredValue, useEffect, useState } from 'react'
import { Link, useLocation, useNavigate } from 'react-router'
import { Badge } from '@tailux/components/ui'
import { Drawer } from '@tailux/components/shared/Drawer'
import { Illustration } from '../../components/ui/Illustration'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { FormField } from '../../components/ui/FormField'
import { SelectField } from '../../components/ui/SelectField'
import { DataTable, type ColumnDef } from '../../components/table/DataTable'
import { useHospitalRequests, usePlatformTenants } from '../../lib/api/hooks'
import type { HospitalApproved, PlatformTenant } from '../../lib/api/types'
import { InviteLinkNotice } from '../invitations/InviteLinkNotice'
import { CreateTenantForm } from './CreateTenantForm'
import { formatUtc, statusColor } from './platformFormat'

/** Platform console home: every hospital (metadata and counts only), search, status filter, create. */
export function PlatformHospitalsPage() {
  const [search, setSearch] = useState('')
  const [status, setStatus] = useState('')
  const deferredSearch = useDeferredValue(search.trim())
  const tenants = usePlatformTenants({ search: deferredSearch || undefined, status: status || undefined })
  const pending = useHospitalRequests('pending')
  const location = useLocation()
  const navigate = useNavigate()
  const openFromSearch = Boolean((location.state as { openCreate?: boolean } | null)?.openCreate)
  const [creating, setCreating] = useState(openFromSearch)
  if (openFromSearch && !creating) setCreating(true)
  useEffect(() => {
    if (!openFromSearch) return
    navigate(`${location.pathname}${location.search}`, { replace: true, state: null })
  }, [openFromSearch, location.pathname, location.search, navigate])
  const [created, setCreated] = useState<{ result: HospitalApproved; name: string; email: string } | null>(null)

  const columns: ColumnDef<PlatformTenant, unknown>[] = [
    {
      id: 'name',
      accessorKey: 'name',
      header: 'Hospital',
      cell: ({ row: { original: t } }) => (
        <Link to={`/platform/hospitals/${t.id}`} className="font-medium text-primary-600 underline dark:text-primary-400">
          {t.name}
        </Link>
      ),
    },
    { id: 'code', accessorKey: 'code', header: 'Code', cell: ({ getValue }) => <span className="font-mono text-xs">{String(getValue())}</span> },
    {
      id: 'status',
      accessorKey: 'status',
      header: 'Status',
      cell: ({ row: { original: t } }) => (
        <Badge color={statusColor(t.status)} variant="soft" className="capitalize">
          {t.status}
        </Badge>
      ),
    },
    { id: 'zone', accessorKey: 'timeZone', header: 'Time zone' },
    { id: 'branches', accessorKey: 'branchCount', header: 'Branches' },
    { id: 'users', accessorKey: 'userCount', header: 'Users' },
    { id: 'invites', accessorKey: 'pendingInvites', header: 'Open invites' },
    { id: 'created', accessorKey: 'createdOn', header: 'Created', cell: ({ getValue }) => formatUtc(getValue() as string) },
  ]

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Hospitals</h1>
        <div className="flex flex-wrap gap-2">
          <Link
            to="/platform/requests"
            className="inline-flex h-9 items-center rounded-lg border border-gray-300 px-4 text-sm font-medium text-gray-800 hover:bg-gray-100 dark:border-dark-450 dark:text-dark-100 dark:hover:bg-dark-600"
          >
            Hospital requests{pending.data ? ` (${pending.data.length} pending)` : ''}
          </Link>
          <Button
            onClick={() => {
              setCreated(null)
              setCreating(true)
            }}
          >
            Create hospital
          </Button>
        </div>
      </div>
      <p className="text-sm text-gray-600 dark:text-dark-200">
        Platform console: hospital metadata and counts only. Operators have no access to patients, appointments or other hospital data.
      </p>
      {created && (
        <Card title={`${created.name} was created`}>
          <InviteLinkNotice invite={created.result.invite} email={created.email} />
        </Card>
      )}
      {creating && (
        <Drawer open onClose={() => setCreating(false)} title="Create hospital" closeLabel="Close" testId="create-tenant-drawer" className="max-w-xl!">
          <CreateTenantForm
            onCancel={() => setCreating(false)}
            onCreated={(result, values) => {
              setCreating(false)
              setCreated({ result, name: values.name, email: values.adminEmail })
            }}
          />
        </Drawer>
      )}
      <Card>
        <div className="mb-4 flex flex-wrap items-end gap-4">
          <div className="w-72">
            <FormField label="Search hospitals" type="search" placeholder="Name or code" value={search} onChange={(e) => setSearch(e.target.value)} />
          </div>
          <div className="w-48">
            <SelectField label="Status" value={status} onChange={(e) => setStatus(e.target.value)}>
              <option value="">All statuses</option>
              <option value="active">Active</option>
              <option value="suspended">Suspended</option>
              <option value="archived">Archived</option>
            </SelectField>
          </div>
        </div>
        {tenants.isError && <Alert tone="error">Could not load hospitals.</Alert>}
        <DataTable
          data={tenants.data ?? []}
          columns={columns}
          caption="Hospitals on the platform"
          isLoading={tenants.isPending}
          isStale={tenants.isPlaceholderData}
          empty={
            search || status ? (
              'No hospitals match.'
            ) : (
              <span className="inline-flex flex-col items-center gap-2">
                <Illustration name="lab" size={72} />
                No hospitals yet.
              </span>
            )
          }
          getRowId={(t) => t.id}
          getRowProps={(row) => ({ 'data-testid': 'platform-tenant-row', 'data-status': row.original.status })}
        />
      </Card>
    </div>
  )
}
