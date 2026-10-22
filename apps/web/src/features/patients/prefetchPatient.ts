import type { QueryClient } from '@tanstack/react-query'
import { apiClient } from '../../lib/api/client'
import { queryKeys } from '../../lib/api/hooks'

/** Warm the patient-context chunk (kept out of the entry bundle) and the patient record. */
export function prefetchPatientWorkspace() {
  void import('./PatientContextDrawer')
}

export function prefetchPatientRecord(qc: QueryClient, id: string) {
  prefetchPatientWorkspace()
  void qc.prefetchQuery({ queryKey: queryKeys.patient(id), queryFn: () => apiClient.patients.get(id) })
}
