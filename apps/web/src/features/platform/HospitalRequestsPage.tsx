import { useState } from 'react'
import { Link } from 'react-router'
import { Badge, Checkbox, Textarea } from '@tailux/components/ui'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { FormField } from '../../components/ui/FormField'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { DataTable, type ColumnDef } from '../../components/table/DataTable'
import { useApproveHospitalRequest, useHospitalRequests, useRejectHospitalRequest } from '../../lib/api/hooks'
import { ApiError, fieldErrors, problemCode } from '../../lib/api/client'
import { codeFromName } from '../../lib/timeZones'
import type { HospitalApproved, HospitalRequest } from '../../lib/api/types'
import { InviteLinkNotice } from '../invitations/InviteLinkNotice'
import { tenantCodeSchema } from '../onboarding/onboardingSchemas'
import { formatUtc, statusColor } from './platformFormat'

const TABS = [
  { id: 'pending', label: 'Pending' },
  { id: 'approved', label: 'Approved' },
  { id: 'rejected', label: 'Rejected' },
  { id: '', label: 'All' },
] as const

/** Approval queue for the public "Register your hospital" requests. */
export function HospitalRequestsPage() {
  const [status, setStatus] = useState<string>('pending')
  const requests = useHospitalRequests(status || undefined)
  const approve = useApproveHospitalRequest()
  const reject = useRejectHospitalRequest()
  const [approving, setApproving] = useState<HospitalRequest | null>(null)
  const [rejecting, setRejecting] = useState<HospitalRequest | null>(null)
  const [code, setCode] = useState('')
  const [reason, setReason] = useState('')
  const [fieldError, setFieldError] = useState<string | null>(null)
  const [ackDuplicate, setAckDuplicate] = useState(false)
  const [confirmDuplicate, setConfirmDuplicate] = useState(false)
  const [message, setMessage] = useState<{ tone: 'info' | 'error'; text: string } | null>(null)
  const [approved, setApproved] = useState<{ result: HospitalApproved; request: HospitalRequest } | null>(null)
  const approvingNow = approving ? (requests.data?.find((r) => r.id === approving.id) ?? approving) : null
  const mustConfirm = Boolean(approvingNow?.possibleDuplicate) || confirmDuplicate

  const close = () => {
    setApproving(null)
    setRejecting(null)
    setFieldError(null)
    setAckDuplicate(false)
    setConfirmDuplicate(false)
    setReason('')
  }

  const onApprove = () => {
    if (!approving) return
    const parsed = tenantCodeSchema.safeParse(code)
    if (!parsed.success) {
      setFieldError(parsed.error.issues[0]?.message ?? 'Invalid code')
      return
    }
    if (mustConfirm && !ackDuplicate) {
      setFieldError('Confirm that you reviewed the possible duplicate.')
      return
    }
    const request = approvingNow ?? approving
    approve.mutate(
      { id: request.id, tenantCode: parsed.data, acknowledgeDuplicate: mustConfirm },
      {
        onSuccess: (result) => {
          setApproved({ result, request })
          setMessage({ tone: 'info', text: `${request.hospitalName} was approved and created in ${request.timeZone}.` })
          close()
        },
        onError: (e) => {
          if (problemCode(e) === 'possible_duplicate') {
            setConfirmDuplicate(true)
            setFieldError('This request may duplicate an existing hospital. Confirm to approve it.')
            return
          }
          if (fieldErrors(e).tenantCode) return setFieldError(fieldErrors(e).tenantCode!)
          if (problemCode(e) === 'conflict') return setFieldError('A hospital with this code already exists. Choose another code.')
          setMessage({ tone: 'error', text: problemCode(e) === 'invalid_state' ? 'This request was already decided.' : 'Could not approve the request.' })
          close()
        },
      },
    )
  }

  const onReject = () => {
    if (!rejecting) return
    if (reason.trim().length < 3) return setFieldError('Give a reason (at least 3 characters).')
    const request = rejecting
    reject.mutate(
      { id: request.id, reason: reason.trim() },
      {
        onSuccess: () => setMessage({ tone: 'info', text: `${request.hospitalName} was rejected.` }),
        onError: (e) =>
          setMessage({ tone: 'error', text: e instanceof ApiError && e.status === 409 ? 'This request was already decided.' : 'Could not reject the request.' }),
        onSettled: close,
      },
    )
  }

  const columns: ColumnDef<HospitalRequest, unknown>[] = [
    {
      id: 'hospital',
      accessorKey: 'hospitalName',
      header: 'Hospital',
      cell: ({ row: { original: r } }) => (
        <div>
          <p className="font-medium text-gray-800 dark:text-dark-50">{r.hospitalName}</p>
          <p className="text-xs text-gray-600 dark:text-dark-200">
            {r.city} · {r.timeZone}
          </p>
          {r.possibleDuplicate && (
            <div className="mt-1">
              <Badge color="warning" variant="soft" data-testid="possible-duplicate">
                Possible duplicate
              </Badge>
              {r.matchedHospitals.length > 0 && (
                <p className="mt-1 text-xs text-gray-600 dark:text-dark-200">Matches {r.matchedHospitals.join(', ')}</p>
              )}
            </div>
          )}
        </div>
      ),
    },
    {
      id: 'contact',
      accessorKey: 'contactName',
      header: 'Contact',
      cell: ({ row: { original: r } }) => (
        <div className="text-sm">
          <p>{r.contactName}</p>
          <p className="text-xs text-gray-600 dark:text-dark-200">
            {r.contactEmail} · {r.phone}
          </p>
        </div>
      ),
    },
    { id: 'received', accessorKey: 'createdOn', header: 'Received', cell: ({ getValue }) => formatUtc(getValue() as string) },
    {
      id: 'status',
      accessorKey: 'status',
      header: 'Status',
      cell: ({ row: { original: r } }) => (
        <div>
          <Badge color={statusColor(r.status)} variant="soft" className="capitalize">
            {r.status}
          </Badge>
          {r.decisionReason && <p className="mt-1 max-w-56 text-xs text-gray-600 dark:text-dark-200">{r.decisionReason}</p>}
          {r.tenantId && (
            <Link to={`/platform/hospitals/${r.tenantId}`} className="mt-1 block text-xs text-primary-600 underline dark:text-primary-400">
              Open {r.tenantCode}
            </Link>
          )}
        </div>
      ),
    },
    {
      id: 'actions',
      enableSorting: false,
      header: () => <span className="sr-only">Actions</span>,
      cell: ({ row: { original: r } }) =>
        r.status === 'pending' ? (
          <div className="flex justify-end gap-2">
            <Button
              className="h-8"
              aria-label={`Approve ${r.hospitalName}`}
              onClick={() => {
                setMessage(null)
                setApproved(null)
                setAckDuplicate(false)
                setConfirmDuplicate(false)
                setFieldError(null)
                setCode(codeFromName(r.hospitalName))
                setApproving(r)
              }}
            >
              Approve
            </Button>
            <Button
              variant="secondary"
              className="h-8"
              aria-label={`Reject ${r.hospitalName}`}
              onClick={() => {
                setMessage(null)
                setRejecting(r)
              }}
            >
              Reject
            </Button>
          </div>
        ) : null,
    },
  ]

  return (
    <div className="space-y-6">
      <nav aria-label="Breadcrumb" className="text-sm">
        <Link to="/platform" className="text-primary-600 underline dark:text-primary-400">
          Hospitals
        </Link>{' '}
        / Hospital requests
      </nav>
      <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Hospital requests</h1>
      {message && <Alert tone={message.tone}>{message.text}</Alert>}
      {approved && (
        <Card title={`First admin invite for ${approved.request.hospitalName}`}>
          <InviteLinkNotice invite={approved.result.invite} email={approved.request.contactEmail} />
        </Card>
      )}
      <Card>
        <div role="group" aria-label="Filter by status" className="mb-4 flex flex-wrap gap-2">
          {TABS.map((tab) => (
            <Button key={tab.id || 'all'} variant={status === tab.id ? 'primary' : 'secondary'} className="h-8" aria-pressed={status === tab.id} onClick={() => setStatus(tab.id)}>
              {tab.label}
            </Button>
          ))}
        </div>
        {requests.isError && <Alert tone="error">Could not load hospital requests.</Alert>}
        <DataTable
          data={requests.data ?? []}
          columns={columns}
          caption="Hospital registration requests"
          isLoading={requests.isPending}
          empty={status === 'pending' ? 'No pending requests.' : 'No requests.'}
          getRowId={(r) => r.id}
          getRowProps={(row) => ({ 'data-testid': 'hospital-request-row', 'data-status': row.original.status })}
        />
      </Card>
      <ConfirmDialog
        open={approving !== null}
        title={approvingNow ? `Approve ${approvingNow.hospitalName}?` : 'Approve'}
        confirmLabel="Approve and create"
        busy={approve.isPending}
        onCancel={close}
        onConfirm={onApprove}
      >
        {approvingNow && (
          <div className="space-y-3">
            <p>
              Creates the hospital in <strong>{approvingNow.timeZone}</strong> with one branch, and emails a one-time tenant-admin invite link to{' '}
              {approvingNow.contactEmail}.
            </p>
            {mustConfirm && (
              <div className="space-y-2">
                <Alert tone="warning">
                  {approvingNow.matchedHospitals.length > 0
                    ? `This may duplicate ${approvingNow.matchedHospitals.join(', ')}. Approve only if it is a different hospital.`
                    : 'This request may duplicate an existing hospital. Confirm to approve it.'}
                </Alert>
                <Checkbox
                  label="I have reviewed the possible duplicate"
                  checked={ackDuplicate}
                  onChange={(e) => {
                    setAckDuplicate(e.target.checked)
                    setFieldError(null)
                  }}
                  classNames={{ labelText: 'text-sm' }}
                />
              </div>
            )}
            <FormField
              label="Hospital code"
              value={code}
              error={fieldError ?? undefined}
              onChange={(e) => {
                setCode(e.target.value)
                setFieldError(null)
              }}
            />
          </div>
        )}
      </ConfirmDialog>
      <ConfirmDialog
        open={rejecting !== null}
        title={rejecting ? `Reject ${rejecting.hospitalName}?` : 'Reject'}
        confirmLabel="Reject request"
        busy={reject.isPending}
        onCancel={close}
        onConfirm={onReject}
      >
        <div className="space-y-3">
          <p>The reason is stored with the request. No hospital is created.</p>
          <Textarea
            label="Reason"
            rows={3}
            value={reason}
            error={fieldError ?? undefined}
            onChange={(e) => {
              setReason(e.target.value)
              setFieldError(null)
            }}
          />
        </div>
      </ConfirmDialog>
    </div>
  )
}
