import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { toast } from 'sonner'
import { apiClient } from '../../lib/api/client'
import type { PatientSummary } from '../../lib/api/types'
import { useCurrentContext } from '../tenancy/useCurrentContext'
import { ConsentStep } from './ConsentStep'
import { RegisterPatientPage } from '../patients/RegisterPatientPage'

/** Current published notice, shown on registration when this role may record consent. */
export function useRegistrationConsent() {
  const { has } = useCurrentContext()
  const enabled = has('privacy.consent')
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
