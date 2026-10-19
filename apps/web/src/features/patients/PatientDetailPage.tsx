import { useState } from 'react'
import { useForm, useWatch } from 'react-hook-form'
import { Link, useNavigate, useParams } from 'react-router'
import { Badge } from '@tailux/components/ui'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { FormField } from '../../components/ui/FormField'
import { SelectField } from '../../components/ui/SelectField'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { useDeletePatient, usePatient, useUpdatePatient } from '../../lib/api/hooks'
import { ApiError, fieldErrors } from '../../lib/api/client'
import { SEXES, type PatientDetail } from '../../lib/api/types'
import { can } from '../../lib/permissions'
import { rolesAtBranch, useCurrentContext } from '../tenancy/useCurrentContext'
import { createPatientEditSchema, toUpdatePatientRequest, type PatientEditValues } from './patientSchema'
import { useBranchToday, useBranchZonedResolver } from './useBranchZonedResolver'
import { WhatsappFields } from './WhatsappFields'

export function PatientDetailPage() {
  const { patientId = '' } = useParams()
  const patient = usePatient(patientId)
  const { me, branches } = useCurrentContext()
  const [editing, setEditing] = useState(false)
  const [saved, setSaved] = useState(false)

  if (patient.isPending) return <p role="status">Loading patient…</p>
  if (patient.isError) {
    const status = patient.error instanceof ApiError ? patient.error.status : 0
    return (
      <div className="space-y-4">
        <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Patient</h1>
        <div data-testid="patient-not-found">
          <Alert tone="warning">
            {status === 404
              ? 'This patient record does not exist in this hospital or has been deleted.'
              : status === 403
                ? 'Your role in this hospital does not include access to the patient registry.'
                : 'Patient service is unavailable.'}
          </Alert>
        </div>
        <BackLink />
      </div>
    )
  }

  const p = patient.data
  const deleted = !!p.deletedAt
  const branchName = branches.find((b) => b.id === p.registeredBranchId)?.name ?? '—'
  // Writes need the role at the patient's registered branch (tenant_admin is tenant-wide).
  const branchRoles = rolesAtBranch(me.data, p.registeredBranchId)
  const canWrite = can(branchRoles, 'patients.write') && !deleted
  const canDelete = can(branchRoles, 'patients.delete') && !deleted

  return (
    <div className="max-w-3xl space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">
          {p.lastName}, {p.firstName}{' '}
          <span className="font-mono text-base font-normal text-gray-500 dark:text-dark-300">{p.mrn}</span>
        </h1>
        <BackLink />
      </div>
      {deleted && (
        <div data-testid="patient-deleted-flag">
          <Alert tone="warning">This patient record was deleted and is read-only.</Alert>
        </div>
      )}
      {saved && !editing && <Alert tone="info">Changes saved.</Alert>}
      {editing ? (
        <EditPatientForm
          patient={p}
          branches={branches}
          onCancel={() => setEditing(false)}
          onSaved={() => {
            setEditing(false)
            setSaved(true)
          }}
        />
      ) : (
        <Card title="Demographics">
          <dl className="grid gap-x-6 gap-y-2 text-sm sm:grid-cols-2" data-testid="patient-details">
            <Field label="MRN" value={p.mrn} />
            <Field label="Date of birth" value={p.dateOfBirth ?? '—'} />
            <Field label="Sex" value={p.sex} />
            <Field label="Registered branch" value={branchName} />
            <PhoneFields patient={p} />
            <Field label="Email" value={p.email ?? '—'} />
          </dl>
          {(canWrite || canDelete) && (
            <div className="mt-4 flex flex-wrap gap-2">
              {canWrite && (
                <Button
                  onClick={() => {
                    setSaved(false)
                    setEditing(true)
                  }}
                >
                  Edit patient
                </Button>
              )}
              {canDelete && <DeletePatientButton patient={p} />}
            </div>
          )}
        </Card>
      )}
    </div>
  )
}

function BackLink() {
  return (
    <Link to="/patients" className="text-sm font-medium text-primary-600 hover:underline dark:text-primary-400">
      Back to patients
    </Link>
  )
}

/** Phone with a WhatsApp badge when it is also the WhatsApp number, else a separate WhatsApp line. */
function PhoneFields({ patient }: { patient: PatientDetail }) {
  const whatsapp = patient.phones?.find((x) => x.isWhatsapp && !x.isPrimary)
  return (
    <>
      <div>
        <dt className="text-gray-500 dark:text-dark-300">Phone</dt>
        <dd className="flex flex-wrap items-center gap-2 font-medium text-gray-800 dark:text-dark-100" data-testid="patient-phone">
          {patient.phone ?? '—'}
          {patient.phone && patient.whatsappSameAsPhone && (
            <Badge color="success" variant="soft" data-testid="whatsapp-same-badge">
              WhatsApp
            </Badge>
          )}
        </dd>
      </div>
      {whatsapp && <Field label="WhatsApp" value={whatsapp.number} testId="patient-whatsapp" />}
    </>
  )
}

function Field({ label, value, testId }: { label: string; value: string; testId?: string }) {
  return (
    <div>
      <dt className="text-gray-500 dark:text-dark-300">{label}</dt>
      <dd className="font-medium text-gray-800 dark:text-dark-100" data-testid={testId}>
        {value}
      </dd>
    </div>
  )
}

function EditPatientForm({
  patient,
  branches,
  onCancel,
  onSaved,
}: {
  patient: PatientDetail
  branches: { id: string; name: string }[]
  onCancel: () => void
  onSaved: () => void
}) {
  const update = useUpdatePatient(patient.id)
  const [formError, setFormError] = useState<string | null>(null)
  const resolver = useBranchZonedResolver<PatientEditValues>(createPatientEditSchema)
  const {
    register,
    handleSubmit,
    setError,
    control,
    formState: { errors, isSubmitting },
  } = useForm<PatientEditValues>({
    resolver,
    defaultValues: {
      firstName: patient.firstName,
      lastName: patient.lastName,
      dateOfBirth: patient.dateOfBirth ?? '',
      sex: patient.sex,
      registeredBranchId: patient.registeredBranchId,
      phone: patient.phone ?? '',
      email: patient.email ?? '',
      // Reflects the stored state; with no number stored yet, "same" is the default (as on register).
      whatsappSameAsPhone: patient.phones?.length ? !!patient.whatsappSameAsPhone : true,
      whatsappNumber: patient.phones?.find((x) => x.isWhatsapp && !x.isPrimary)?.number ?? '',
    },
  })

  // DOB "today" is the selected branch's date — the API validates in the branch's zone.
  const branchToday = useBranchToday(useWatch({ control, name: 'registeredBranchId' }))

  const onSubmit = async (values: PatientEditValues) => {
    setFormError(null)
    try {
      await update.mutateAsync(toUpdatePatientRequest(values))
      onSaved()
    } catch (error) {
      const fields = fieldErrors(error)
      for (const [field, message] of Object.entries(fields)) {
        const key = field === 'whatsapp' ? 'whatsappNumber' : field
        if (key in values) setError(key as keyof PatientEditValues, { message })
      }
      setFormError(
        error instanceof ApiError && error.status === 403
          ? 'You are not allowed to edit patients at this branch.'
          : error instanceof ApiError && error.status === 404
            ? 'This patient no longer exists (it may have been deleted).'
            : error instanceof ApiError && error.status === 409
              ? 'Someone else changed this patient. Reload and try again.'
              : Object.keys(fields).length
                ? 'Please fix the highlighted fields.'
                : 'Could not save the patient. Try again.',
      )
    }
  }

  return (
    <Card title="Edit patient">
      {formError && (
        <div className="mb-4">
          <Alert tone="error">{formError}</Alert>
        </div>
      )}
      <form noValidate aria-label="Edit patient" onSubmit={handleSubmit(onSubmit)} className="grid gap-4 sm:grid-cols-2">
        <div className="sm:col-span-2 text-sm" data-testid="edit-mrn">
          <span className="text-gray-500 dark:text-dark-300">MRN </span>
          <span className="font-mono font-medium text-gray-800 dark:text-dark-100">{patient.mrn}</span>
          <span className="text-gray-500 dark:text-dark-300"> (assigned by the system, cannot be changed)</span>
        </div>
        <FormField label="First name" autoComplete="off" error={errors.firstName?.message} {...register('firstName')} />
        <FormField label="Last name" autoComplete="off" error={errors.lastName?.message} {...register('lastName')} />
        <FormField label="Date of birth" type="date" min="1900-01-01" max={branchToday} error={errors.dateOfBirth?.message} {...register('dateOfBirth')} />
        <SelectField label="Sex" error={errors.sex?.message} {...register('sex')}>
          {SEXES.map((s) => (
            <option key={s} value={s}>
              {s[0]!.toUpperCase() + s.slice(1)}
            </option>
          ))}
        </SelectField>
        <SelectField label="Registered branch" error={errors.registeredBranchId?.message} {...register('registeredBranchId')}>
          {branches.map((b) => (
            <option key={b.id} value={b.id}>
              {b.name}
            </option>
          ))}
        </SelectField>
        <FormField label="Phone (optional)" type="tel" autoComplete="off" error={errors.phone?.message} {...register('phone')} />
        <FormField label="Email (optional)" type="email" autoComplete="off" error={errors.email?.message} {...register('email')} />
        <WhatsappFields control={control} register={register} errors={errors} />
        <div className="flex gap-2 sm:col-span-2">
          <Button type="submit" disabled={isSubmitting}>
            {isSubmitting ? 'Saving…' : 'Save changes'}
          </Button>
          <Button variant="secondary" onClick={onCancel} disabled={isSubmitting}>
            Cancel
          </Button>
        </div>
      </form>
    </Card>
  )
}

function DeletePatientButton({ patient }: { patient: PatientDetail }) {
  const [open, setOpen] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [reason, setReason] = useState('')
  const remove = useDeletePatient(patient.id)
  const navigate = useNavigate()

  return (
    <>
      <Button variant="danger" onClick={() => setOpen(true)}>
        Delete patient
      </Button>
      {error && <Alert tone="error">{error}</Alert>}
      <ConfirmDialog
        open={open}
        title="Delete this patient?"
        confirmLabel="Delete patient"
        busy={remove.isPending}
        onCancel={() => setOpen(false)}
        onConfirm={async () => {
          setError(null)
          try {
            await remove.mutateAsync(reason)
            navigate('/patients', { replace: true, state: { deleted: patient.mrn } })
          } catch (e) {
            setOpen(false)
            setError(
              e instanceof ApiError && e.status === 403
                ? 'You are not allowed to delete patients registered at this branch.'
                : e instanceof ApiError && e.status === 404
                  ? 'This patient no longer exists (it may already have been deleted).'
                  : e instanceof ApiError && e.status === 409
                    ? 'This patient has open appointments or is in today’s queue. Cancel those first.'
                    : fieldErrors(e).reason ?? 'Could not delete the patient. Try again.',
            )
          }
        }}
      >
        <p>
          {patient.firstName} {patient.lastName} ({patient.mrn}) will be hidden from patient lists, search and booking. The record is
          kept for the audit trail (soft delete) and a tenant admin can restore it.
        </p>
        <div className="mt-3">
          <FormField label="Reason (optional)" maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} />
        </div>
      </ConfirmDialog>
    </>
  )
}
