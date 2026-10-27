import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ApiError, apiClient } from '../../lib/api/client'
import type { RecordVitalsRequest, Vitals } from '../../lib/api/types'

export const vitalsKeys = {
  visit: (queueEntryId: string) => ['vitals', 'visit', queueEntryId] as const,
  patient: (patientId: string) => ['vitals', 'patient', patientId] as const,
}

export function useVisitVitals(queueEntryId: string) {
  return useQuery({ queryKey: vitalsKeys.visit(queueEntryId), queryFn: () => apiClient.consultations.vitals({ queueEntryId }), enabled: !!queueEntryId })
}

export function usePatientVitals(patientId: string) {
  return useQuery({ queryKey: vitalsKeys.patient(patientId), queryFn: () => apiClient.consultations.vitals({ patientId }), enabled: !!patientId })
}

export function useRecordVitals() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (body: RecordVitalsRequest) => apiClient.consultations.recordVitals(body),
    onSuccess: (v: Vitals) => {
      void qc.invalidateQueries({ queryKey: vitalsKeys.visit(v.queueEntryId) })
      void qc.invalidateQueries({ queryKey: vitalsKeys.patient(v.patientId) })
    },
  })
}

export function vitalsErrorMessage(e: unknown): string {
  if (!(e instanceof ApiError)) return 'Could not save the vitals. Check your connection and try again.'
  const detail = e.problem?.detail
  switch (e.status) {
    case 400:
      return detail ? `Please fix: ${detail}` : 'Some values are invalid.'
    case 403:
      return 'Your role cannot record vitals for this visit.'
    case 404:
      return 'This visit was not found in this hospital or branch.'
    case 409:
      return detail ? `Not saved: ${detail}.` : 'Vitals cannot be recorded for this visit.'
    default:
      return 'Could not save the vitals. Try again.'
  }
}
