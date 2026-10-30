import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { toast } from 'sonner'
import { Link } from 'react-router'
import { ApiError, apiClient } from '../../lib/api/client'
import { Alert } from '../../components/ui/Alert'
import type { PatientSummary } from '../../lib/api/types'
import { useCurrentContext } from '../tenancy/useCurrentContext'
import { ConsentStep } from './ConsentStep'
import { RegisterPatientPage } from '../patients/RegisterPatientPage'

/** Current published notice, shown on registration when this role may record consent. */
export function useRegistrationConsent() {
  const { has } = useCurrentContext()
  const enabled = has('privacy.consent')
  const canPublish = has('privacy.notice')
  const notice = useQuery({
    queryKey: ['privacy', 'current-notice', 'register'],
    queryFn: () => apiClient.privacy.currentNotice('en'),
    enabled,
    retry: false,
  })
  const [choices, setChoices] = useState<Record<string, boolean>>({})
  const published = notice.data

  const slot = published ? (
    <ConsentStep
      purposes={published.purposes}
      value={choices}
      onChange={(code, granted) => setChoices((current) => ({ ...current, [code]: granted }))}
    />
  ) : !enabled || notice.isPending ? null : notice.error instanceof ApiError && notice.error.status === 404 ? (
    // #129: no published notice. Say so instead of silently hiding consent.
    <div data-testid="consent-no-notice">
      <Alert tone="warning">
        No privacy notice is published, so consent cannot be recorded for this patient.{' '}
        {canPublish ? (
          <Link className="underline" to="/admin/privacy-notices" data-testid="consent-publish-link">
            Publish a privacy notice in Admin › Privacy notices.
          </Link>
        ) : (
          'Ask an administrator to publish one in Admin › Privacy notices.'
        )}
      </Alert>
    </div>
  ) : notice.isError ? (
    <div data-testid="consent-notice-error">
      <Alert tone="error">
        The privacy notice could not be loaded, so consent will not be recorded.{' '}
        <button type="button" className="underline" onClick={() => void notice.refetch()} data-testid="consent-notice-retry">
          Try again
        </button>
      </Alert>
    </div>
  ) : null

  const record = async (patient: PatientSummary) => {
    if (!published) return
    try {
      await apiClient.privacy.recordConsents(crypto.randomUUID(), patient.id, {
        noticeId: published.noticeId,
        channel: 'tablet',
        givenBy: 'self',
        subjectIsMinor: false,
        choices: published.purposes.map((purpose) => ({
          purposeCode: purpose.code,
          granted: !!choices[purpose.code],
        })),
      })
    } catch {
      if (typeof toast.error === 'function') toast.error('Patient registered. Consent was not saved.')
    }
  }

  return { slot, record }
}

/** Registration route: the form stays unchanged when there is no published notice. */
export function RegisterPatientWithConsent() {
  const consent = useRegistrationConsent()
  return <RegisterPatientPage consent={consent.slot} afterSave={consent.record} />
}
