import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ApiError, apiClient } from '../../lib/api/client'
import type { Consultation, SaveConsultationRequest } from '../../lib/api/types'

export const consultationKeys = {
  one: (id: string) => ['consultations', id] as const,
  print: (id: string) => ['consultations', id, 'print'] as const,
  preview: (id: string) => ['consultations', id, 'print-preview'] as const,
  patient: (patientId: string) => ['consultations', 'patient', patientId] as const,
}

export function useConsultation(id: string) {
  return useQuery({ queryKey: consultationKeys.one(id), queryFn: () => apiClient.consultations.get(id), enabled: !!id })
}

export function usePatientConsultations(patientId: string, enabled = true) {
  return useQuery({ queryKey: consultationKeys.patient(patientId), queryFn: () => apiClient.consultations.forPatient(patientId), enabled: enabled && !!patientId })
}

export function useConsultationPrint(id: string) {
  // a 409 (draft) is final: no retry
  return useQuery({ queryKey: consultationKeys.print(id), queryFn: () => apiClient.consultations.print(id), enabled: !!id, retry: false })
}

function useStore() {
  const qc = useQueryClient()
  return (c: Consultation) => {
    qc.setQueryData(consultationKeys.one(c.id), c)
    void qc.invalidateQueries({ queryKey: consultationKeys.patient(c.patientId) })
  }
}

export function useStartConsultation() {
  const store = useStore()
  return useMutation({ mutationFn: apiClient.consultations.start, onSuccess: store })
}

export function useSaveConsultation(id: string) {
  const store = useStore()
  return useMutation({ mutationFn: (body: SaveConsultationRequest) => apiClient.consultations.save(id, body), onSuccess: store })
}

export function useFinalizeConsultation(id: string) {
  const store = useStore()
  return useMutation({ mutationFn: (rowVersion: number) => apiClient.consultations.finalize(id, rowVersion), onSuccess: store })
}

export function useReviseConsultation(id: string) {
  const store = useStore()
  return useMutation({ mutationFn: () => apiClient.consultations.revise(id), onSuccess: store })
}

/** One user-facing sentence for a clinical write error. */
export function clinicalErrorMessage(e: unknown, action: string): string {
  if (!(e instanceof ApiError)) return `Could not ${action}. Check your connection and try again.`
  const detail = e.problem?.detail
  switch (e.status) {
    case 400:
      return detail ? `Please fix: ${detail}` : 'Some details are invalid.'
    case 403:
      return 'Only the treating doctor can change this consultation.'
    case 404:
      return 'This consultation or patient is no longer available.'
    case 409:
      return detail ?? 'This consultation was changed elsewhere. It has been reloaded.'
    default:
      return detail ?? `Could not ${action}.`
  }
}

/** Header data for the live preview on the consultation screen (works for drafts). */
export function useConsultationPrintPreview(id: string) {
  return useQuery({ queryKey: consultationKeys.preview(id), queryFn: () => apiClient.consultations.printPreview(id), enabled: !!id, retry: false, staleTime: 5 * 60_000 })
}
