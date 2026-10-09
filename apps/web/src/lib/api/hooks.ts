import { keepPreviousData, useMutation, useMutationState, useQueries, useQuery, useQueryClient, type Query } from '@tanstack/react-query'
import { ApiError, apiClient } from './client'
import type {
  AddMemberRequest,
  Appointment,
  AppointmentQuery,
  CreateAppointmentRequest,
  CreateBranchRequest,
  CreatePatientRequest,
  PatientDetail,
  PatientRef,
  Practitioner,
  QueueEntry,
  QueueStatus,
  Slot,
  SwitchContextRequest,
  UpdateBranchRequest,
  UpdateMemberRequest,
  UpdatePatientRequest,
  WalkInRequest,
} from './types'
import { ADD_MEMBER_GENERIC_MESSAGE } from './types'

export const queryKeys = {
  health: ['health'] as const,
  me: ['me'] as const,
  invitations: ['me', 'invitations'] as const,
  patients: (criteria: PatientSearchCriteria) => ['patients', criteria] as const,
  patient: (id: string) => ['patients', 'detail', id] as const,
  practitioners: ['practitioners'] as const,
  branchPractitioners: (branchId: string) => ['practitioners', 'branch', branchId] as const,
  schedules: (branchId: string) => ['schedules', branchId] as const,
  appointments: (q: AppointmentQuery) => ['appointments', q] as const,
  slots: (branchId: string, practitionerId: string, date: string) => ['appointments', 'slots', branchId, practitionerId, date] as const,
  queue: (branchId: string, date: string) => ['queue', branchId, date] as const,
  branches: ['branches'] as const,
  members: ['members'] as const,
}

/**
 * placeholderData that keeps the previous result while a new key loads, but only when `same`
 * says the old key is comparable (e.g. same branch): never show branch A's queue under branch B.
 */
function keepPreviousIf<TData>(same: (prevKey: readonly unknown[]) => boolean) {
  return (previous: TData | undefined, previousQuery: Query<TData, Error, TData, readonly unknown[]> | undefined) =>
    previous !== undefined && previousQuery && same(previousQuery.queryKey) ? previous : undefined
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
  /** tenant_admin only. */
  includeDeleted?: boolean
}

/** The API matches phones on the last 10 digits and rejects fewer than 7 digits (400). */
export const PHONE_SEARCH_MIN_DIGITS = 7

/** Trimmed, capped criteria with empty fields dropped (so they never reach the request body or query key). */
export function normalizePatientCriteria(input: string | PatientSearchCriteria): PatientSearchCriteria {
  const raw = typeof input === 'string' ? { search: input } : input
  const out: PatientSearchCriteria = {}
  const search = raw.search?.trim().slice(0, PATIENT_SEARCH_MAX_LENGTH)
  const phone = raw.phone?.trim().slice(0, 32)
  const dateOfBirth = raw.dateOfBirth?.trim()
  if (search) out.search = search
  if (phone) out.phone = phone
  if (phone && phone.replace(/\D/g, '').length >= PHONE_SEARCH_MIN_DIGITS) out.phone = phone
  else delete out.phone
  if (dateOfBirth && /^\d{4}-\d{2}-\d{2}$/.test(dateOfBirth)) out.dateOfBirth = dateOfBirth
  if (raw.includeDeleted) out.includeDeleted = true
  return out
}

/**
 * Any criterion goes to POST /api/v1/patients/search (in the body — names, MRNs, phones and DOBs
 * are PHI and must never appear in a URL); no criteria pages through GET /api/v1/patients.
 * Callers debounce.
 */
export function usePatients(input: string | PatientSearchCriteria, { enabled = true }: { enabled?: boolean } = {}) {
  const criteria = normalizePatientCriteria(input)
  // includeDeleted alone still needs the POST search route (GET /patients never returns deleted rows).
  const hasCriteria = Object.keys(criteria).length > 0
  return useQuery({
    queryKey: queryKeys.patients(criteria),
    queryFn: () => (hasCriteria ? apiClient.patients.search({ ...criteria, pageSize: 25 }) : apiClient.patients.list({ pageSize: 25 })),
    retry: false,
    enabled,
    // Keep the last results on screen (dimmed) while the next search runs, instead of blanking.
    placeholderData: keepPreviousData,
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
    mutationFn: (reason?: string) => apiClient.patients.remove(id, { reason: reason?.trim() || undefined }),
    onSuccess: () => {
      qc.removeQueries({ queryKey: queryKeys.patient(id) })
      return qc.invalidateQueries({ queryKey: ['patients'] })
    },
  })
}

export function useRestorePatient() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => apiClient.patients.restore(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['patients'] }),
  })
}

/**
 * Patient names for ids (appointments and queue entries carry only patientId). One cached
 * GET /patients/{id} per distinct id; a 404 (deleted / other tenant) resolves to null.
 */
export function usePatientLookup(ids: readonly string[]): (id: string) => PatientDetail | null | undefined {
  const unique = [...new Set(ids)]
  const results = useQueries({
    queries: unique.map((id) => ({
      queryKey: queryKeys.patient(id),
      queryFn: () => apiClient.patients.get(id),
      retry: false,
      staleTime: 5 * 60_000,
    })),
  })
  const byId = new Map<string, PatientDetail | null | undefined>()
  unique.forEach((id, i) => byId.set(id, results[i]?.isError ? null : results[i]?.data))
  return (id) => byId.get(id)
}

/**
 * Patient summary for appointment/queue rows. API v2 embeds `patient` in the same query:
 * an object, or `null` when the patient is soft-deleted or not readable (shown as unavailable —
 * GET /patients/{id} would 404 too, so no fetch). Only rows where the field is **absent** (an
 * older API) fall back to a cached GET /patients/{id}. Result: undefined = loading, null = unavailable.
 */
export function usePatientRefs(rows: readonly { patientId: string; patient?: PatientRef | null }[]) {
  const missing = rows.filter((r) => r.patient === undefined).map((r) => r.patientId)
  const lookup = usePatientLookup(missing)
  return (row: { patientId: string; patient?: PatientRef | null }): PatientRef | null | undefined =>
    row.patient === undefined ? lookup(row.patientId) : row.patient
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

export function usePractitioners() {
  return useQuery({ queryKey: queryKeys.practitioners, queryFn: () => apiClient.practitioners.list(), retry: false, staleTime: 60_000 })
}

export interface BranchPractitioners {
  practitioners: Practitioner[]
  /** false when the API rejected `branchId` (older API): callers filter by schedules instead. */
  branchFiltered: boolean
}

/**
 * Practitioners bookable at a branch via GET /practitioners?branchId= (API v2). An API that rejects
 * the parameter with 400 gets the tenant-wide list and `branchFiltered: false`.
 */
export function useBranchPractitioners(branchId: string | null) {
  return useQuery({
    queryKey: queryKeys.branchPractitioners(branchId ?? ''),
    queryFn: async (): Promise<BranchPractitioners> => {
      try {
        return { practitioners: await apiClient.practitioners.list({ branchId: branchId! }), branchFiltered: true }
      } catch (error) {
        if (!(error instanceof ApiError) || error.status !== 400) throw error
        return { practitioners: await apiClient.practitioners.list(), branchFiltered: false }
      }
    },
    enabled: !!branchId,
    retry: false,
    staleTime: 60_000,
  })
}

export function useSchedules(branchId: string | null) {
  return useQuery({
    queryKey: queryKeys.schedules(branchId ?? ''),
    queryFn: () => apiClient.schedules.list({ branchId: branchId! }),
    enabled: !!branchId,
    retry: false,
    staleTime: 60_000,
  })
}

/** Max page size the API allows. */
const MAX_PAGE_SIZE = 100
/** Safety cap on pages fetched for one calendar range. */
const MAX_PAGES = 10

/** All appointments in [from, to) for a branch (pages through Paged<AppointmentDto>). */
export function useAppointments(query: AppointmentQuery | null, options: { refetchInterval?: number | false } = {}) {
  return useQuery({
    queryKey: queryKeys.appointments(query ?? { branchId: '', from: '', to: '' }),
    queryFn: async () => {
      const items = []
      for (let page = 1; page <= MAX_PAGES; page++) {
        const result = await apiClient.appointments.list({ ...query!, page, pageSize: MAX_PAGE_SIZE })
        items.push(...result.items)
        if (items.length >= result.totalCount || result.items.length === 0) break
      }
      return items
    },
    enabled: !!query?.branchId,
    retry: false,
    refetchInterval: options.refetchInterval,
    // Day/week steps and practitioner filters keep the old list (dimmed) until the new one lands.
    placeholderData: keepPreviousIf<Appointment[]>((prev) => (prev[1] as AppointmentQuery | undefined)?.branchId === query?.branchId),
  })
}

export function useSlots(branchId: string | null, practitionerId: string, date: string) {
  return useQuery({
    queryKey: queryKeys.slots(branchId ?? '', practitionerId, date),
    queryFn: () => apiClient.slots({ branchId: branchId!, practitionerId, from: date, to: date }),
    enabled: !!branchId && !!practitionerId && !!date,
    retry: false,
    placeholderData: keepPreviousIf<Slot[]>((prev) => prev[2] === (branchId ?? '') && prev[3] === practitionerId),
  })
}

export function useCreateAppointment() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (body: CreateAppointmentRequest) => apiClient.appointments.create(body),
    // Refetch on conflicts too: the calendar and the slot list are stale either way.
    onSettled: () => qc.invalidateQueries({ queryKey: ['appointments'] }),
  })
}

export function useCancelAppointment() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, reason }: { id: string; reason?: string }) => apiClient.appointments.cancel(id, reason ? { reason } : {}),
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
    placeholderData: keepPreviousIf<QueueEntry[]>((prev) => prev[1] === (branchId ?? '')),
    refetchInterval,
    refetchIntervalInBackground: false,
  })
}

const invalidateQueueAndAppointments = (qc: ReturnType<typeof useQueryClient>) =>
  Promise.all([qc.invalidateQueries({ queryKey: ['queue'] }), qc.invalidateQueries({ queryKey: ['appointments'] })])

export const mutationKeys = {
  checkIn: ['appointments', 'check-in'] as const,
  walkIn: ['queue', 'walk-in'] as const,
  queueStatus: ['queue', 'status'] as const,
}

/** Applies `fn` to every cached appointment list (skips other shapes under the 'appointments' prefix). */
function updateCachedAppointments(qc: ReturnType<typeof useQueryClient>, fn: (a: Appointment) => Appointment) {
  qc.setQueriesData<Appointment[]>({ queryKey: ['appointments'] }, (list) =>
    Array.isArray(list) && list.every((a) => typeof a?.id === 'string' && 'status' in a) ? list.map(fn) : list,
  )
}

/**
 * Check in a booked appointment (POST /appointments/{id}/check-in). The token is issued by the
 * server, so nothing is optimistic; on success the row flips to checked_in at once instead of
 * waiting for the next poll.
 */
export function useCheckInAppointment() {
  const qc = useQueryClient()
  return useMutation({
    mutationKey: mutationKeys.checkIn,
    mutationFn: (appointmentId: string) => apiClient.appointments.checkIn(appointmentId),
    onSuccess: (_result, appointmentId) => updateCachedAppointments(qc, (a) => (a.id === appointmentId ? { ...a, status: 'checked_in' } : a)),
    onSettled: () => invalidateQueueAndAppointments(qc),
  })
}

/** Walk-in token without an appointment (POST /queue/walk-in). */
export function useWalkIn() {
  const qc = useQueryClient()
  return useMutation({
    mutationKey: mutationKeys.walkIn,
    mutationFn: (body: WalkInRequest) => apiClient.queue.walkIn(body),
    onSettled: () => invalidateQueueAndAppointments(qc),
  })
}

export interface QueueStatusChange {
  id: string
  status: Exclude<QueueStatus, 'waiting'>
}

/**
 * Queue transition with an optimistic update: the card moves column at once, a failure (409, 403,
 * timeout…) rolls the board back, and the board is refetched either way.
 */
export function useUpdateQueueStatus() {
  const qc = useQueryClient()
  return useMutation({
    mutationKey: mutationKeys.queueStatus,
    mutationFn: ({ id, status }: QueueStatusChange) => apiClient.queue.updateStatus(id, { status }),
    onMutate: async ({ id, status }: QueueStatusChange) => {
      await qc.cancelQueries({ queryKey: ['queue'] })
      const snapshot = qc.getQueriesData<QueueEntry[]>({ queryKey: ['queue'] })
      qc.setQueriesData<QueueEntry[]>({ queryKey: ['queue'] }, (list) => (Array.isArray(list) ? list.map((e) => (e.id === id ? { ...e, status } : e)) : list))
      return { snapshot }
    },
    onError: (_error, _change, context) => context?.snapshot.forEach(([key, data]) => qc.setQueryData(key, data)),
    onSettled: () => invalidateQueueAndAppointments(qc),
  })
}

/** Ids (variables) of the pending mutations with `mutationKey`: per-row "saving" state. */
export function usePendingMutationIds<V>(mutationKey: readonly unknown[], idOf: (variables: V) => string): string[] {
  return useMutationState({
    filters: { mutationKey: [...mutationKey], status: 'pending' },
    select: (m) => idOf(m.state.variables as V),
  })
}
