import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { apiClient } from './client'
import type {
  AddMemberRequest,
  AppointmentRangeQuery,
  CheckInRequest,
  CreateAppointmentRequest,
  CreateBranchRequest,
  CreatePatientRequest,
  QueueStatus,
  UpdatePatientRequest,
  SwitchContextRequest,
  UpdateBranchRequest,
  UpdateMemberRequest,
} from './types'
import { ADD_MEMBER_GENERIC_MESSAGE } from './types'

export const queryKeys = {
  health: ['health'] as const,
  me: ['me'] as const,
  invitations: ['me', 'invitations'] as const,
  patients: (criteria: PatientSearchCriteria) => ['patients', criteria] as const,
  patient: (id: string) => ['patients', 'detail', id] as const,
  practitioners: (branchId: string) => ['practitioners', branchId] as const,
  schedules: (branchId: string, from: string, to: string) => ['schedules', branchId, from, to] as const,
  appointments: (q: AppointmentRangeQuery) => ['appointments', q] as const,
  slots: (branchId: string, practitionerId: string, date: string) => ['appointments', 'slots', branchId, practitionerId, date] as const,
  queue: (branchId: string, date: string) => ['queue', branchId, date] as const,
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
/** API cap for POST /api/v1/patients/search (longer terms are a 400). */
export const PATIENT_SEARCH_MAX_LENGTH = 100

export interface PatientSearchCriteria {
  search?: string
  phone?: string
  dateOfBirth?: string
}

/** Trimmed, capped criteria with empty fields dropped (so they never reach the request body or query key). */
export function normalizePatientCriteria(input: string | PatientSearchCriteria): PatientSearchCriteria {
  const raw = typeof input === 'string' ? { search: input } : input
  const out: PatientSearchCriteria = {}
  const search = raw.search?.trim().slice(0, PATIENT_SEARCH_MAX_LENGTH)
  const phone = raw.phone?.trim().slice(0, 32)
  const dateOfBirth = raw.dateOfBirth?.trim()
  if (search) out.search = search
  if (phone) out.phone = phone
  if (dateOfBirth && /^\d{4}-\d{2}-\d{2}$/.test(dateOfBirth)) out.dateOfBirth = dateOfBirth
  return out
}

/**
 * Any criterion goes to POST /api/v1/patients/search (in the body — names, MRNs, phones and DOBs
 * are PHI and must never appear in a URL); no criteria pages through GET /api/v1/patients.
 * Callers debounce.
 */
export function usePatients(input: string | PatientSearchCriteria, { enabled = true }: { enabled?: boolean } = {}) {
  const criteria = normalizePatientCriteria(input)
  const hasCriteria = Object.keys(criteria).length > 0
  return useQuery({
    queryKey: queryKeys.patients(criteria),
    queryFn: () => (hasCriteria ? apiClient.patients.search({ ...criteria, pageSize: 25 }) : apiClient.patients.list({ pageSize: 25 })),
    retry: false,
    enabled,
  })
}

export function usePatient(id: string) {
  return useQuery({ queryKey: queryKeys.patient(id), queryFn: () => apiClient.patients.get(id), retry: false })
}

export function useUpdatePatient(id: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (body: UpdatePatientRequest) => apiClient.patients.update(id, body),
    onSuccess: (patient) => {
      qc.setQueryData(queryKeys.patient(id), patient)
      return qc.invalidateQueries({ queryKey: ['patients'], predicate: (q) => q.queryKey[1] !== 'detail' })
    },
  })
}

/** Soft delete; afterwards the record is gone from every patient list, search and the detail cache. */
export function useDeletePatient(id: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: () => apiClient.patients.remove(id),
    onSuccess: () => {
      qc.removeQueries({ queryKey: queryKeys.patient(id) })
      return qc.invalidateQueries({ queryKey: ['patients'] })
    },
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

// ----------------------------------------------------------------- Sprint 2: scheduling + OPD

export function usePractitioners(branchId: string | null) {
  return useQuery({
    queryKey: queryKeys.practitioners(branchId ?? ''),
    queryFn: () => apiClient.practitioners.list(branchId!),
    enabled: !!branchId,
    retry: false,
    staleTime: 60_000,
  })
}

export function useSchedules(branchId: string | null, from: string, to: string) {
  return useQuery({
    queryKey: queryKeys.schedules(branchId ?? '', from, to),
    queryFn: () => apiClient.schedules.list({ branchId: branchId!, from, to }),
    enabled: !!branchId,
    retry: false,
  })
}

export function useAppointments(query: AppointmentRangeQuery | null, options: { refetchInterval?: number } = {}) {
  return useQuery({
    queryKey: queryKeys.appointments(query ?? { branchId: '', from: '', to: '' }),
    queryFn: () => apiClient.appointments.list(query!),
    enabled: !!query?.branchId,
    retry: false,
    refetchInterval: options.refetchInterval,
  })
}

export function useSlots(branchId: string | null, practitionerId: string, date: string) {
  return useQuery({
    queryKey: queryKeys.slots(branchId ?? '', practitionerId, date),
    queryFn: () => apiClient.appointments.slots({ branchId: branchId!, practitionerId, date }),
    enabled: !!branchId && !!practitionerId && !!date,
    retry: false,
  })
}

export function useCreateAppointment() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (body: CreateAppointmentRequest) => apiClient.appointments.create(body),
    // Refetch on conflicts too: the slot list is stale either way.
    onSettled: () => qc.invalidateQueries({ queryKey: ['appointments'] }),
  })
}

export function useCancelAppointment() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => apiClient.appointments.cancel(id),
    onSettled: () => qc.invalidateQueries({ queryKey: ['appointments'] }),
  })
}

/** OPD queue board refresh interval: "live-ish" polling (no websockets yet). */
export const QUEUE_REFRESH_MS = 10_000

export function useQueue(branchId: string | null, date: string, { refetchInterval = QUEUE_REFRESH_MS }: { refetchInterval?: number | false } = {}) {
  return useQuery({
    queryKey: queryKeys.queue(branchId ?? '', date),
    queryFn: () => apiClient.queue.list({ branchId: branchId!, date }),
    enabled: !!branchId,
    retry: false,
    refetchInterval,
    refetchIntervalInBackground: false,
  })
}

export function useCheckIn() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (body: CheckInRequest) => apiClient.queue.checkIn(body),
    onSettled: () => Promise.all([qc.invalidateQueries({ queryKey: ['queue'] }), qc.invalidateQueries({ queryKey: ['appointments'] })]),
  })
}

export function useUpdateQueueStatus() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, status }: { id: string; status: QueueStatus }) => apiClient.queue.updateStatus(id, { status }),
    onSettled: () => qc.invalidateQueries({ queryKey: ['queue'] }),
  })
}
