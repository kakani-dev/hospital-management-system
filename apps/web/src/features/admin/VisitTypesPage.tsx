import { useState } from 'react'
import { Card } from '../../components/ui/Card'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { FormField } from '../../components/ui/FormField'
import { useAdminVisitTypes, useUpdateVisitType } from '../../lib/api/hooks'
import { useCurrentContext } from '../tenancy/useCurrentContext'
import { formatPaise, parseRupeesToPaise } from '../billing/money'
import { ApiError, apiClient } from '../../lib/api/client'

/** Hospital visit types. Fees and the follow-up window are copied onto each booking, so editing a row does not change visits already booked. */
export function VisitTypesPage() {
  const { activeBranchId } = useCurrentContext()
  const types = useAdminVisitTypes()
  const update = useUpdateVisitType()
  const [message, setMessage] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const save = async (id: string, fee: string, minutes: string, days: string, branchFee: string, active: boolean) => {
    setMessage(null)
    setError(null)
    const defaultFeePaise = parseRupeesToPaise(fee)
    const durationMinutes = Number(minutes)
    const followUpValidDays = days.trim() === '' ? null : Number(days)
    if (defaultFeePaise == null || !Number.isInteger(durationMinutes) || durationMinutes < 5 || durationMinutes > 240) {
      setError('Enter a fee in rupees and a duration from 5 to 240 minutes.')
      return
    }
    if (followUpValidDays != null && (!Number.isInteger(followUpValidDays) || followUpValidDays < 0 || followUpValidDays > 366)) {
      setError('Follow-up window is 0 to 366 days, or blank for none.')
      return
    }
    const branchFeePaise = branchFee.trim() ? parseRupeesToPaise(branchFee) : null
    if (branchFee.trim() && branchFeePaise == null) {
      setError('Branch fee must be a rupee amount.')
      return
    }
    try {
      await update.mutateAsync({
        id,
        body: {
          defaultFeePaise,
          durationMinutes,
          ...(followUpValidDays == null ? { clearFollowUpWindow: true } : { followUpValidDays }),
          isActive: active,
        },
      })
      if (activeBranchId && branchFeePaise != null) {
        await apiClient.visitTypes.upsertOverride(id, { branchId: activeBranchId, feePaise: branchFeePaise })
      }
      setMessage('Saved. Bookings already made keep their fee and follow-up window.')
    } catch (e) {
      setError(e instanceof ApiError && e.status === 403 ? 'Only tenant admins can edit visit types.' : 'Could not save the visit type.')
    }
  }

  return (
    <div className="space-y-6">
      <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Visit types</h1>
      <p className="text-sm text-gray-600 dark:text-dark-200">
        Each booking stores the fee, length and follow-up window. Changing a type here applies to the next booking only.
      </p>
      {message && <Alert tone="info">{message}</Alert>}
      {error && <Alert tone="error">{error}</Alert>}
      {types.isError && <Alert tone="error">Could not load visit types.</Alert>}
      {(types.data ?? []).map((type) => (
        <Card key={type.id} title={type.name}>
          <form
            className="grid gap-4 sm:grid-cols-4 sm:items-end"
            onSubmit={(e) => {
              e.preventDefault()
              const data = new FormData(e.currentTarget)
              void save(type.id, String(data.get('fee') ?? ''), String(data.get('minutes') ?? ''), String(data.get('days') ?? ''), String(data.get('branchFee') ?? ''), data.get('active') === 'on')
            }}
          >
            <FormField label="Fee (rupees)" name="fee" defaultValue={String(type.defaultFeePaise / 100)} hint={formatPaise(type.effectiveFeePaise)} />
            <FormField label="Minutes" name="minutes" defaultValue={String(type.durationMinutes)} />
            <FormField label="Follow-up days" name="days" defaultValue={type.followUpValidDays ?? ''} hint="Blank means no window. 0 means none." />
            {activeBranchId && <FormField label="This branch fee (rupees)" name="branchFee" hint="Blank keeps the hospital fee. Filled replaces it at this branch." />}
            <label className="flex items-center gap-2 text-sm">
              <input type="checkbox" name="active" defaultChecked={type.isActive} />
              Active
            </label>
            <Button type="submit" disabled={update.isPending}>Save</Button>
          </form>
        </Card>
      ))}
    </div>
  )
}
