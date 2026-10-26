import { useState } from 'react'
import { useNavigate } from 'react-router'
import { Button } from '../../components/ui/Button'
import { clinicalErrorMessage, useStartConsultation } from './consultationApi'

/** Opens (or reopens: the server is idempotent) the consultation for a checked-in queue entry. */
export function StartConsultationButton({ queueEntryId, tokenNo, onError }: { queueEntryId: string; tokenNo: number; onError: (message: string) => void }) {
  const navigate = useNavigate()
  const start = useStartConsultation()
  const [busy, setBusy] = useState(false)
  return (
    <Button
      className="mt-2 px-3 py-1 text-xs"
      disabled={busy}
      aria-label={`Open consultation for token ${tokenNo}`}
      onClick={async () => {
        if (busy) return
        setBusy(true)
        try {
          const c = await start.mutateAsync({ queueEntryId })
          navigate(`/consultations/${c.id}`)
        } catch (e) {
          onError(clinicalErrorMessage(e, 'open the consultation'))
          setBusy(false)
        }
      }}
    >
      Open consultation
    </Button>
  )
}
