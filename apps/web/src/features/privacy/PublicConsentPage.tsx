import { useState } from 'react'
import { useParams } from 'react-router'
import { useMutation, useQuery } from '@tanstack/react-query'
import { Alert } from '../../components/ui/Alert'
import { Button } from '../../components/ui/Button'
import { LoadingBlock } from '../../components/ui/LoadingBlock'
import { ApiError, apiClient } from '../../lib/api/client'
import { PublicLayout } from '../onboarding/PublicLayout'
import { ConsentStep } from './ConsentStep'
import { problemText } from './problem'

/** Anonymous consent page. The token is the only identifier. No name and no MRN. */
export function PublicConsentPage() {
  const { token = '' } = useParams()
  const [choices, setChoices] = useState<Record<string, boolean>>({})
  const [saved, setSaved] = useState(false)
  const preview = useQuery({
    queryKey: ['privacy', 'public', token],
    queryFn: () => apiClient.privacy.publicConsent(token),
    enabled: !!token,
    retry: false,
  })
  const submit = useMutation({
    mutationFn: () =>
      apiClient.privacy.submitPublicConsent(
        token,
        (preview.data?.purposes ?? []).map((purpose) => ({
          purposeCode: purpose.code,
          granted: choices[purpose.code] ?? !!purpose.granted,
        })),
      ),
    onSuccess: () => setSaved(true),
  })

  const expired = preview.error instanceof ApiError && preview.error.status === 410
  return (
    <PublicLayout title="Your choices" subtitle="MediCore" illustration={saved ? 'tick' : 'file'}>
      {preview.isPending && <LoadingBlock label="Opening the notice" />}
      {expired && <Alert tone="error">This link has expired. Ask the hospital for a new one.</Alert>}
      {preview.isError && !expired && <Alert tone="error">This link is not available.</Alert>}
      {preview.data && !saved && (
        <form
          className="space-y-3"
          data-testid="public-consent"
          onSubmit={(event) => {
            event.preventDefault()
            submit.mutate()
          }}
        >
          <h2 className="text-lg font-medium">{preview.data.title}</h2>
          <p className="whitespace-pre-wrap text-sm">{preview.data.body}</p>
          <ConsentStep
            purposes={preview.data.purposes}
            value={Object.fromEntries(preview.data.purposes.map((purpose) => [purpose.code, choices[purpose.code] ?? !!purpose.granted]))}
            onChange={(code, granted) => setChoices((prev) => ({ ...prev, [code]: granted }))}
          />
          {submit.isError && <Alert tone="error">{problemText(submit.error)}</Alert>}
          <Button type="submit" disabled={submit.isPending}>Save my choices</Button>
        </form>
      )}
      {saved && <p data-testid="consent-saved">Saved. You can close this page.</p>}
    </PublicLayout>
  )
}
