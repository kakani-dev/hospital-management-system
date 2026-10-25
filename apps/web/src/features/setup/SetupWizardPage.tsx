import { useState } from 'react'
import { Navigate, useNavigate } from 'react-router'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { ApiError } from '../../lib/api/client'
import { useAdvanceSetup, useCurrentTenant, useSetupState } from '../../lib/api/hooks'
import { BranchesPage } from '../admin/BranchesPage'
import { HospitalSettingsPage } from '../admin/HospitalSettingsPage'
import { MembersPage } from '../admin/MembersPage'
import { WorkingHoursPage } from '../admin/WorkingHoursPage'
import { NoAccess } from '../auth/RequireCapability'
import { useCurrentContext } from '../tenancy/useCurrentContext'
import { SetupStepper } from './SetupStepper'
import { clearDeferredSetup, deferSetup, isSetupStep, setupIsOpen, type SetupStep } from './setupState'

/**
 * Short setup for a new hospital. The four forms are the existing admin forms.
 * Finish later keeps this browser tab on the dashboard; the server still remembers the step.
 */
export function SetupWizardPage() {
  const navigate = useNavigate()
  const { roles, me, has } = useCurrentContext()
  const admin = has('admin.settings')
  const tenant = useCurrentTenant(admin)
  const open = setupIsOpen(tenant.data)
  const setup = useSetupState(admin && open)
  const advance = useAdvanceSetup()
  const [picked, setPicked] = useState<SetupStep | null>(null)
  const [error, setError] = useState<string | null>(null)
  const serverStep: SetupStep = isSetupStep(tenant.data?.setupStep) ? tenant.data.setupStep : 'profile'
  const step = picked ?? serverStep

  if (me.isPending || (admin && tenant.isLoading)) return <p role="status">Loading…</p>
  if (!admin) return <NoAccess roles={roles} />
  if (tenant.isError || !tenant.data) return <Alert tone="error">Could not load hospital setup.</Alert>
  if (!open && picked !== 'done') return <Navigate to="/" replace />
  const tenantId = tenant.data.id

  const go = async (next: SetupStep) => {
    setError(null)
    try {
      const saved = await advance.mutateAsync(next)
      if (saved.step === 'done') {
        clearDeferredSetup(tenantId)
        navigate('/')
        return
      }
      if (isSetupStep(saved.step)) setPicked(saved.step)
    } catch (caught) {
      const problem = caught instanceof ApiError ? caught.problem : null
      setError(problem?.detail ?? 'Could not save your progress.')
    }
  }

  const later = () => {
    deferSetup(tenantId)
    navigate('/')
  }

  return (
    <div className="mx-auto max-w-3xl space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Set up your hospital</h1>
        <Button variant="secondary" onClick={later} data-testid="finish-later">
          Finish later
        </Button>
      </div>
      <SetupStepper current={step} />
      {error && <Alert tone="error">{error}</Alert>}
      {step === 'profile' && (
        <HospitalSettingsPage
          embedded
          showCountryCode
          allowUnchanged
          submitLabel="Save and continue"
          onSaved={() => void go('branch')}
        />
      )}
      {step === 'branch' && (
        <BranchesPage
          wizard
          documentPrefix={setup.data?.documentPrefix}
          preferredBranchId={setup.data?.branchId}
          onSaved={() => void go('staff')}
        />
      )}
      {step === 'staff' && (
        <div className="space-y-4">
          <p className="text-sm text-gray-600 dark:text-dark-200">Inviting staff is optional. You can do it later from Members.</p>
          <MembersPage embedded hideDirectory />
          <Button onClick={() => void go('schedule')}>Continue</Button>
        </div>
      )}
      {step === 'schedule' && (
        <div className="space-y-4">
          <p className="text-sm text-gray-600 dark:text-dark-200">
            A weekly schedule lets the front desk book this doctor. You can skip it and add hours later.
          </p>
          <WorkingHoursPage embedded />
          <Button variant="secondary" onClick={() => setPicked('done')}>
            Skip
          </Button>
        </div>
      )}
      {step === 'done' && (
        <div className="space-y-4">
          <p className="text-sm text-gray-600 dark:text-dark-200">The hospital is ready for its first booking.</p>
          <Button onClick={() => void go('done')}>Go to the dashboard</Button>
        </div>
      )}
    </div>
  )
}
