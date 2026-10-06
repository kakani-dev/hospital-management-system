import { useQuery } from '@tanstack/react-query'
import { apiClient } from './client'

export const queryKeys = {
  health: ['health'] as const,
  patients: (search: string) => ['patients', { search }] as const,
}

export function useApiHealth() {
  return useQuery({
    queryKey: queryKeys.health,
    queryFn: () => apiClient.health.live(),
    retry: false,
    staleTime: 30_000,
  })
}

export function usePatients(search: string) {
  return useQuery({
    queryKey: queryKeys.patients(search),
    queryFn: () => apiClient.patients.list({ search: search || undefined, pageSize: 25 }),
    retry: false,
  })
}
