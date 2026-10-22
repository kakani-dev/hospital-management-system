import { useQuery } from '@tanstack/react-query'
import { apiClient } from '../../lib/api/client'

const YEAR_MS = 366 * 24 * 60 * 60 * 1000

/**
 * Visits for one patient across every branch of the hospital. GET /appointments?patientId= (no
 * branchId) — the list endpoint is already tenant-wide. A year back and a year ahead covers the
 * chart a desk actually opens. The window is taken when the request runs, not during render.
 */
export function usePatientVisits(patientId: string | null) {
  return useQuery({
    queryKey: ['appointments', 'by-patient', patientId] as const,
    queryFn: async () => {
      const now = Date.now()
      return (
        await apiClient.appointments.visits({
          patientId: patientId!,
          from: new Date(now - YEAR_MS).toISOString(),
          to: new Date(now + YEAR_MS).toISOString(),
          page: 1,
          pageSize: 100,
        })
      ).items
    },
    enabled: !!patientId,
  })
}
