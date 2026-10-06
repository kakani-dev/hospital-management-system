import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { apiClient } from './client'
import type {
  AddMemberRequest,
  CreateBranchRequest,
  CreatePatientRequest,
  SwitchContextRequest,
  UpdateBranchRequest,
  UpdateMemberRequest,
} from './types'
import { ADD_MEMBER_GENERIC_MESSAGE } from './types'

export const queryKeys = {
  health: ['health'] as const,
  me: ['me'] as const,
  invitations: ['me', 'invitations'] as const,
  patients: (search: string) => ['patients', { search }] as const,
  branches: ['branches'] as const,
  members: ['members'] as const,
}

export function useApiHealth() {
  return useQuery({ queryKey: queryKeys.health, queryFn: () => apiClient.health.live(), retry: false, staleTime: 30_000 })
}

export function useMe(enabled = true) {
  return useQuery({ queryKey: queryKeys.me, queryFn: () => apiClient.me(), retry: false, enabled, staleTime: 60_000 })
}

/** Debounced patient search term (ms). */
export const PATIENT_SEARCH_DEBOUNCE_MS = 300

/**
 * A non-empty term goes to POST /api/v1/patients/search (term in the body — names/MRNs are PHI and
 * must never appear in a URL); an empty term pages through GET /api/v1/patients. Callers debounce.
 */
export function usePatients(search: string) {
  const term = search.trim()
  return useQuery({
    queryKey: queryKeys.patients(term),
    queryFn: () => (term ? apiClient.patients.search({ search: term, pageSize: 25 }) : apiClient.patients.list({ pageSize: 25 })),
    retry: false,
  })
}

export function useCreatePatient() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (body: CreatePatientRequest) => apiClient.patients.create(body),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['patients'] }),
  })
}

export interface SwitchContextDeps {
  /** Re-issues the access token so the hook stamps the new tenant. */
  refresh: () => Promise<void>
  /** queryClient.clear() + remount (AuthProvider.resetCache). */
  resetCache: () => void
  /** Tells the tenant guard the new tenant is expected (no "tenant changed" banner). */
  expectTenant: (tenantId: string | null) => void
}

/**
 * Switch tenant/branch: the server validates against memberships and stores the choice, the session
 * is refreshed so the custom access token hook issues a token for the new context, and then the
 * whole query cache (which belonged to the old context) is cleared — every switch, no exceptions.
 */
export function useSwitchContext({ refresh, resetCache, expectTenant }: SwitchContextDeps) {
  return useMutation({
    mutationFn: async (body: SwitchContextRequest) => {
      await apiClient.switchContext(body)
      expectTenant(body.tenantId)
      try {
        await refresh()
      } finally {
        resetCache()
        expectTenant(null)
      }
    },
  })
}

export function useBranches() {
  return useQuery({ queryKey: queryKeys.branches, queryFn: () => apiClient.branches.list(), retry: false })
}

export function useCreateBranch() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (body: CreateBranchRequest) => apiClient.branches.create(body),
    onSuccess: () => Promise.all([qc.invalidateQueries({ queryKey: queryKeys.branches }), qc.invalidateQueries({ queryKey: queryKeys.me })]),
  })
}

export function useUpdateBranch() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, body }: { id: string; body: UpdateBranchRequest }) => apiClient.branches.update(id, body),
    onSuccess: () => Promise.all([qc.invalidateQueries({ queryKey: queryKeys.branches }), qc.invalidateQueries({ queryKey: queryKeys.me })]),
  })
}

export function useMembers() {
  return useQuery({ queryKey: queryKeys.members, queryFn: () => apiClient.members.list(), retry: false })
}

/** Resolves to the API's generic 202 message (never reveals whether the email has an account). */
export function useAddMember() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (body: AddMemberRequest) => {
      const response = await apiClient.members.add(body)
      return response?.message?.trim() || ADD_MEMBER_GENERIC_MESSAGE
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: queryKeys.members }),
  })
}

/** Pending invitations for the signed-in user (GET /api/v1/me/invitations). */
export function useInvitations(enabled = true) {
  return useQuery({ queryKey: queryKeys.invitations, queryFn: () => apiClient.invitations.list(), retry: false, enabled })
}

/** Accepts an invitation, then refetches memberships (/me) and the invitation list. */
export function useAcceptInvitation() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (membershipId: string) => apiClient.invitations.accept(membershipId),
    // ['me'] prefix-matches ['me', 'invitations'], so this refetches both /me and the invitation list.
    onSettled: () => qc.invalidateQueries({ queryKey: queryKeys.me }),
  })
}

export function useUpdateMember() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, body }: { id: string; body: UpdateMemberRequest }) => apiClient.members.update(id, body),
    onSuccess: () => qc.invalidateQueries({ queryKey: queryKeys.members }),
  })
}
