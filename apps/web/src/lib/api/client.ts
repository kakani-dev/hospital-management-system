import type {
  AddMemberRequest,
  AddMemberResponse,
  Appointment,
  AppointmentQuery,
  Branch,
  CancelAppointmentRequest,
  CheckInResult,
  CloseQueueDayResult,
  CreateAppointmentRequest,
  CreateBranchRequest,
  CreatePatientRequest,
  CreatePractitionerRequest,
  CreatePractitionerBranchRequest,
  CreateScheduleOverrideRequest,
  CreateScheduleRequest,
  CurrentTenant,
  CurrentUser,
  Department,
  VisitSuggestion,
  VisitType,
  DeletePatientRequest,
  DuplicateCandidate,
  DuplicateCheckRequest,
  HealthStatus,
  Invitation,
  Member,
  PagedResult,
  PatientDetail,
  PatientSearchRequest,
  PatientStats,
  RegistrationSettings,
  PatientSummary,
  SetupState,
  Practitioner,
  PractitionerBranchMembership,
  ProblemDetails,
  QueueEntry,
  QueueStatus,
  RescheduleAppointmentRequest,
  Schedule,
  ScheduleOverride,
  SchedulingSettings,
  MyDay,
  Slot,
  SwitchContextRequest,
  UpdateBranchRequest,
  UpdatePractitionerRequest,
  UpdatePractitionerBranchRequest,
  UpdateScheduleRequest,
  UpdateTenantRequest,
  UpdateMemberRequest,
  UpdatePatientRequest,
  UpdateQueueStatusRequest,
  WalkInRequest,
  ApprovalRequest,
  ApprovalSettings,
  BillDocument,
  BillListItem,
  BranchBillProfile,
  CashierSession,
  DayEndSession,
  EarningsReport,
  PatientBillingSummary,
  PaymentLink,
  PaymentAccount,
  AddPaymentAccountRequest,
  PublicBill,
  Receipt,
  AddPriceRequest,
  CopyPriceResult,
  PriceImportResult,
  PriceImportRow,
  PriceListSummary,
  CategoryDefault,
  SaveServiceItemRequest,
  ServiceItem,
  ServicePrice,
  TaxCode,
  CreateStockItemRequest,
  CreateStockStoreRequest,
  OpeningStockDocument,
  OpeningStockLine,
  StockCatalog,
  StockItem,
  StockOnHandRow,
  PharmacyQueueRow,
  PharmacyPrescription,
  DispenseRequest,
  StockStore,
  ConsentChoice,
  ConsentLink,
  ConsentList,
  PrivacyNotice,
  PublicConsent,
  RightsRequest,
  ClaimedInvite,
  CreateInviteLinkRequest,
  HospitalApproved,
  HospitalRequest,
  HospitalSignupRequest,
  InviteLink,
  InviteLinkIssued,
  InvitePreview,
  PlatformCreateTenantRequest,
  PlatformTenant,
  PlatformTenantDetail,
  Consultation,
  ConsultationPrint,
  RecordVitalsRequest,
  Vitals,
  SaveConsultationRequest,
} from './types'
import { resilience as defaultResilience, type ResilienceConfig } from '../config'
import { beginPending, type PendingHandle } from './pending'

export class ApiError extends Error {
  readonly status: number
  readonly problem: ProblemDetails | null
  /** Parsed Retry-After header (ms from now), or null when absent/invalid. */
  readonly retryAfterMs: number | null

  constructor(status: number, problem: ProblemDetails | null, message?: string, retryAfterMs: number | null = null) {
    super(message ?? problem?.title ?? `Request failed with status ${status}`)
    this.name = 'ApiError'
    this.status = status
    this.problem = problem
    this.retryAfterMs = retryAfterMs
  }
}

/**
 * The request never produced an HTTP response: the network failed (offline, DNS, CORS-less error
 * from a proxy) or the client timeout fired. For a write, the server MAY still have processed it.
 */
export class ApiTransportError extends Error {
  readonly kind: 'network' | 'timeout'

  constructor(kind: 'network' | 'timeout', message?: string, options?: { cause?: unknown }) {
    super(message ?? (kind === 'timeout' ? 'The server did not answer in time.' : 'The server could not be reached.'), options)
    this.name = 'ApiTransportError'
    this.kind = kind
  }
}

/** Status codes that mean "try again later" (cold start, proxy timeout, overload, rate limit). */
export const TRANSIENT_STATUSES: readonly number[] = [429, 502, 503, 504]

/** True for network errors, client timeouts and 429/502/503/504: worth a retry, never a sign-out. */
export function isTransientError(error: unknown): boolean {
  if (error instanceof ApiTransportError) return true
  return error instanceof ApiError && TRANSIENT_STATUSES.includes(error.status)
}

/** Retry-After as seconds or an HTTP date → ms from now (≥ 0), or null. */
export function parseRetryAfter(value: string | null | undefined, now: number = Date.now()): number | null {
  if (!value) return null
  const trimmed = value.trim()
  if (/^\d+(\.\d+)?$/.test(trimmed)) return Math.round(Number(trimmed) * 1000)
  const at = Date.parse(trimmed)
  return Number.isNaN(at) ? null : Math.max(0, at - now)
}

/**
 * Wait before retry number `attempt` (0 = first retry): the server's Retry-After when given,
 * otherwise base × factor^attempt with ±25 % jitter; always capped at `maxDelayMs`.
 */
export function retryDelayMs(
  attempt: number,
  error: unknown,
  cfg: Pick<ResilienceConfig, 'retryBaseDelayMs' | 'retryFactor' | 'retryMaxDelayMs'>,
  random: () => number = Math.random,
): number {
  const retryAfter = error instanceof ApiError ? error.retryAfterMs : null
  const computed = retryAfter ?? cfg.retryBaseDelayMs * cfg.retryFactor ** attempt * (0.75 + random() * 0.5)
  return Math.max(0, Math.min(Math.round(computed), cfg.retryMaxDelayMs))
}

export type TokenProvider = () => string | null | Promise<string | null>

/** Asked once per request after a 401: refresh the session; true = replay with the new token. */
export type UnauthorizedHandler = () => Promise<boolean>

/** Response header carrying the tenant the API resolved for the request (M3 option b). */
export const TENANT_HEADER = 'X-Hms-Tenant'

/**
 * Called with the X-Hms-Tenant value of every API response that carries one, plus when the request
 * started (performance.now()), so answers to requests sent before a cache reset can be ignored.
 */
export type ResolvedTenantListener = (tenantId: string, requestStartedAt: number) => void

const clock = () => (typeof performance !== 'undefined' ? performance.now() : Date.now())

export interface ApiClientOptions {
  baseUrl?: string
  getAccessToken?: TokenProvider
  fetchImpl?: typeof fetch
  onResolvedTenant?: ResolvedTenantListener
  onUnauthorized?: UnauthorizedHandler
  /** Timeouts/retries; defaults to lib/config.ts `resilience` (VITE_* build settings). */
  resilience?: Partial<ResilienceConfig>
  /** Jitter source (tests pin it). */
  random?: () => number
  /** Track requests for the "waking" banner (lib/api/pending.ts). Default true. */
  trackPending?: boolean
}

export interface RequestOptions extends RequestInit {
  /** Overrides the GET/write timeout for this call (ms). */
  timeoutMs?: number
  /** false = never retry this GET automatically. Writes are never retried regardless. */
  retry?: boolean
  /** false = no Authorization header and no 401 refresh (public endpoints such as warm-up). */
  auth?: boolean
  /** false = not shown as "waiting" in the waking banner (fire-and-forget calls). */
  track?: boolean
}

const READ_METHODS = ['GET', 'HEAD']

/**
 * Typed HTTP client for the HMS edge gateway.
 *
 * SECURITY: this client deliberately never sends a tenant id header. The backend derives
 * the tenant from the authenticated (signed) token claims and validates membership server-side.
 * Any tenant/branch selection in the UI is a UX hint only.
 *
 * RESILIENCE (free hosting, cold starts): every attempt has a client timeout; GETs are retried on
 * network errors, timeouts and 429/502/503/504 with backoff (honouring Retry-After); writes are
 * never retried automatically (the screen offers a Retry button). A 401 triggers one session
 * refresh and one replay. Nothing here ever signs the user out.
 */
export class ApiClient {
  private readonly baseUrl: string
  private readonly getAccessToken?: TokenProvider
  private readonly fetchImpl: typeof fetch
  private readonly onResolvedTenant?: ResolvedTenantListener
  private readonly onUnauthorized?: UnauthorizedHandler
  private readonly cfg: ResilienceConfig
  private readonly random: () => number
  private readonly trackPending: boolean

  constructor(options: ApiClientOptions = {}) {
    this.baseUrl = (options.baseUrl ?? '').replace(/\/+$/, '')
    this.getAccessToken = options.getAccessToken
    this.onResolvedTenant = options.onResolvedTenant
    this.onUnauthorized = options.onUnauthorized
    this.cfg = { ...defaultResilience, ...options.resilience }
    this.random = options.random ?? Math.random
    this.trackPending = options.trackPending ?? true
    // Resolved per call (not captured at construction) so polyfills/test stubs installed later apply.
    this.fetchImpl = options.fetchImpl ?? ((input, init) => globalThis.fetch(input, init))
  }

  async request<T>(path: string, options: RequestOptions = {}): Promise<T> {
    const method = (options.method ?? 'GET').toUpperCase()
    const isRead = READ_METHODS.includes(method)
    const maxRetries = isRead && options.retry !== false ? this.cfg.retryCount : 0
    const pending = this.trackPending && options.track !== false ? beginPending() : null
    let retries = 0
    let replayed = false
    try {
      for (;;) {
        try {
          return await this.attempt<T>(path, options, method, isRead)
        } catch (error) {
          if (options.signal?.aborted) throw error
          if (error instanceof ApiError && error.status === 401 && options.auth !== false && !replayed && this.onUnauthorized) {
            replayed = true
            let ok = false
            try {
              ok = await this.onUnauthorized()
            } catch {
              ok = false
            }
            if (ok) continue
            throw error
          }
          if (retries >= maxRetries || !isTransientError(error)) throw error
          await this.backoff(retryDelayMs(retries, error, this.cfg, this.random), options.signal, pending)
          retries++
        }
      }
    } finally {
      pending?.end()
    }
  }

  /** Waits `ms`, or less when the user presses "Retry now"; rejects if the caller aborts. */
  private backoff(ms: number, signal: AbortSignal | null | undefined, pending: PendingHandle | null): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const done = () => {
        clearTimeout(timer)
        signal?.removeEventListener('abort', onAbort)
        pending?.setKick(null)
        resolve()
      }
      const onAbort = () => {
        clearTimeout(timer)
        pending?.setKick(null)
        reject(signal?.reason ?? new DOMException('Aborted', 'AbortError'))
      }
      const timer = setTimeout(done, ms)
      signal?.addEventListener('abort', onAbort, { once: true })
      pending?.setKick(done)
    })
  }

  /** File download. Does not parse JSON. The server name comes from Content-Disposition. */
  async download(path: string, fallbackName = 'download'): Promise<{ blob: Blob; filename: string }> {
    const headers = new Headers()
    const token = await this.getAccessToken?.()
    if (token) headers.set('Authorization', `Bearer ${token}`)
    const response = await this.fetchImpl(`${this.baseUrl}${path}`, { method: 'GET', headers })
    if (!response.ok) {
      let problem: ProblemDetails | null = null
      try {
        problem = (await response.json()) as ProblemDetails
      } catch {
        problem = null
      }
      throw new ApiError(response.status, problem)
    }
    const blob = await response.blob()
    return { blob, filename: filenameFromDisposition(response.headers.get('Content-Disposition')) ?? fallbackName }
  }

  private async attempt<T>(path: string, options: RequestOptions, method: string, isRead: boolean): Promise<T> {
    const { timeoutMs, auth, signal: callerSignal, ...rest } = options
    const init: RequestInit = { ...rest }
    delete (init as RequestOptions).retry
    delete (init as RequestOptions).track
    const headers = new Headers(init.headers)
    headers.set('Accept', 'application/json')
    if (init.body !== undefined && !headers.has('Content-Type')) {
      headers.set('Content-Type', 'application/json')
    }
    if (auth !== false) {
      const token = await this.getAccessToken?.()
      if (token) headers.set('Authorization', `Bearer ${token}`)
    }

    const controller = new AbortController()
    let timedOut = false
    const timer = setTimeout(
      () => {
        timedOut = true
        controller.abort()
      },
      timeoutMs ?? (isRead ? this.cfg.getTimeoutMs : this.cfg.writeTimeoutMs),
    )
    const onCallerAbort = () => controller.abort(callerSignal?.reason)
    if (callerSignal?.aborted) controller.abort(callerSignal.reason)
    else callerSignal?.addEventListener('abort', onCallerAbort, { once: true })

    const startedAt = clock()
    try {
      let response: Response
      try {
        response = await this.fetchImpl(`${this.baseUrl}${path}`, { ...init, method, headers, signal: controller.signal })
      } catch (cause) {
        if (timedOut) throw new ApiTransportError('timeout', undefined, { cause })
        if (callerSignal?.aborted) throw cause
        throw new ApiTransportError('network', undefined, { cause })
      }
      const resolvedTenant = response.headers.get(TENANT_HEADER)?.trim()
      if (resolvedTenant) this.onResolvedTenant?.(resolvedTenant, startedAt)
      if (!response.ok) {
        let problem: ProblemDetails | null = null
        try {
          problem = (await response.json()) as ProblemDetails
        } catch {
          problem = null
        }
        if (timedOut) throw new ApiTransportError('timeout')
        throw new ApiError(response.status, problem, undefined, parseRetryAfter(response.headers.get('Retry-After')))
      }
      if (response.status === 204) return undefined as T
      let text: string
      try {
        text = await response.text()
      } catch (cause) {
        if (timedOut) throw new ApiTransportError('timeout', undefined, { cause })
        throw cause
      }
      return (text ? JSON.parse(text) : undefined) as T
    } finally {
      clearTimeout(timer)
      callerSignal?.removeEventListener('abort', onCallerAbort)
    }
  }

  /**
   * Fire-and-forget wake-up of the edge and services (CTO contract: unauthenticated
   * GET /api/v1/warmup, result ignored). Never retried, never shown in the waking banner.
   */
  warmup = async (opts: { force?: boolean } = {}): Promise<void> => {
    // #91: page-load warm-ups run at most once per tab every few minutes, so reloads don't spend the
    // edge's per-IP warm-up limit. Sign-in passes force (a deliberate, infrequent action).
    if (opts.force) claimWarmupSlot(Date.now(), true)
    else if (!claimWarmupSlot()) return
    try {
      await this.request<void>('/api/v1/warmup', { auth: false, retry: false, track: false })
    } catch {
      /* ignored by design */
    }
  }

  health = {
    live: () => this.request<HealthStatus>('/health/live'),
    ready: () => this.request<HealthStatus>('/health/ready'),
  }

  me = () => this.request<CurrentUser>('/api/v1/me')

  /** The active hospital (tenant); carries the hospital time zone on the audit/TZ API. */
  currentTenant = () => this.request<CurrentTenant>('/api/v1/tenants/current')

  /** tenant_admin: rename the hospital or change its zone (409 asks to confirm future bookings). */
  updateCurrentTenant = (body: UpdateTenantRequest) =>
    this.request<CurrentTenant>('/api/v1/tenants/current', { method: 'PATCH', body: JSON.stringify(body) })

  /** Wizard progress for the JWT tenant. Tenant admins only. */
  setup = {
    get: () => this.request<SetupState>('/api/v1/setup'),
    advance: (step: SetupState['step']) =>
      this.request<SetupState>('/api/v1/setup/step', { method: 'POST', body: JSON.stringify({ step }) }),
  }

  /** Server validates the requested tenant/branch against memberships (403 otherwise). */
  switchContext = (body: SwitchContextRequest) =>
    this.request<void>('/api/v1/me/context', { method: 'POST', body: JSON.stringify(body) })

  branches = {
    list: (params: { includeDeleted?: boolean } = {}) =>
      this.request<Branch[]>(`/api/v1/branches${qs({ includeDeleted: params.includeDeleted ? 'true' : undefined })}`),
    /** Soft delete. 409 for the last branch or one with open appointments / queue entries. */
    remove: (id: string) => this.request<void>(`/api/v1/branches/${encodeURIComponent(id)}`, { method: 'DELETE' }),
    /** Restore a soft-deleted branch (it comes back inactive). */
    restore: (id: string) => this.request<void>(`/api/v1/branches/${encodeURIComponent(id)}/restore`, { method: 'POST' }),
    create: (body: CreateBranchRequest) =>
      this.request<Branch>('/api/v1/branches', { method: 'POST', body: JSON.stringify(body) }),
    update: (id: string, body: UpdateBranchRequest) =>
      this.request<Branch>(`/api/v1/branches/${encodeURIComponent(id)}`, { method: 'PATCH', body: JSON.stringify(body) }),
  }

  /** Invitations addressed to the signed-in user; only the invitee can accept (consent). */
  invitations = {
    list: async () => {
      const result = await this.request<Invitation[] | { items?: Invitation[] } | undefined>('/api/v1/me/invitations')
      return Array.isArray(result) ? result : (result?.items ?? [])
    },
    accept: (membershipId: string) =>
      this.request<void>(`/api/v1/me/invitations/${encodeURIComponent(membershipId)}/accept`, { method: 'POST' }),
  }

  members = {
    list: () => this.request<Member[]>('/api/v1/members'),
    /** Always 202 + a generic message (no account / invited / already a member look the same). */
    add: (body: AddMemberRequest) =>
      this.request<AddMemberResponse | undefined>('/api/v1/members', { method: 'POST', body: JSON.stringify(body) }),
    update: (id: string, body: UpdateMemberRequest) =>
      this.request<Member>(`/api/v1/members/${encodeURIComponent(id)}`, { method: 'PATCH', body: JSON.stringify(body) }),
    /** Soft delete: the membership grants nothing afterwards. */
    remove: (id: string) => this.request<void>(`/api/v1/members/${encodeURIComponent(id)}`, { method: 'DELETE' }),
    inviteLinks: {
      list: () => this.request<InviteLink[]>('/api/v1/members/invite-links'),
      /** 201 with the one-time token; works whether or not the person has an account yet. */
      create: (body: CreateInviteLinkRequest) =>
        this.request<InviteLinkIssued>('/api/v1/members/invite-links', { method: 'POST', body: JSON.stringify(body) }),
      revoke: (id: string) => this.request<void>(`/api/v1/members/invite-links/${encodeURIComponent(id)}`, { method: 'DELETE' }),
    },
  }

  /** Anonymous endpoints (no Authorization header). */
  publicApi = {
    /** Always 202 when valid; creates only a pending request (no hospital, no access). 429 rate_limited. */
    submitHospitalSignup: (body: HospitalSignupRequest) =>
      this.request<{ message: string } | undefined>('/api/v1/public/hospital-signups', { method: 'POST', body: JSON.stringify(body), auth: false }),
    /** 404 when unknown, used, revoked or expired. */
    previewInvite: (token: string) => this.request<InvitePreview>(`/api/v1/public/invites/${encodeURIComponent(token)}`, { auth: false, retry: false }),
    /** 202 when a code is queued. 404 unknown invite. 429 rate_limited. 503 when email sign-in is not configured. */
    requestInviteSignInCode: (token: string) =>
      this.request<{ expiresOn: string }>(`/api/v1/public/invites/${encodeURIComponent(token)}/sign-in-code`, { method: 'POST', auth: false, retry: false }),
    /** 200 { tokenHash, verificationType }. 401 bad code. 404 unknown invite. */
    exchangeInviteSignInCode: (token: string, code: string) =>
      this.request<{ tokenHash: string; verificationType: string }>(`/api/v1/public/invites/${encodeURIComponent(token)}/sign-in`, {
        method: 'POST',
        body: JSON.stringify({ code }),
        auth: false,
        retry: false,
      }),
  }

  /** Claim an invite link as the signed-in user (email must match: 403 invite_email_mismatch). */
  claimInvite = (token: string) =>
    this.request<ClaimedInvite>('/api/v1/me/invite-links/claim', { method: 'POST', body: JSON.stringify({ token }) })

  /** Platform console (platform operators only; 403 otherwise). Tenant metadata and counts only. */
  platform = {
    tenants: (params: { search?: string; status?: string } = {}) => this.request<PlatformTenant[]>(`/api/v1/platform/tenants${qs(params)}`),
    tenant: (id: string) => this.request<PlatformTenantDetail>(`/api/v1/platform/tenants/${encodeURIComponent(id)}`),
    createTenant: (body: PlatformCreateTenantRequest) =>
      this.request<HospitalApproved>('/api/v1/platform/tenants', { method: 'POST', body: JSON.stringify(body) }),
    suspend: (id: string, reason: string) =>
      this.request<void>(`/api/v1/platform/tenants/${encodeURIComponent(id)}/suspend`, { method: 'POST', body: JSON.stringify({ reason }) }),
    reactivate: (id: string, reason: string) =>
      this.request<void>(`/api/v1/platform/tenants/${encodeURIComponent(id)}/reactivate`, { method: 'POST', body: JSON.stringify({ reason }) }),
    reissueAdminInvite: (id: string, email: string) =>
      this.request<InviteLinkIssued>(`/api/v1/platform/tenants/${encodeURIComponent(id)}/admin-invite`, { method: 'POST', body: JSON.stringify({ email }) }),
    requests: (status?: string) => this.request<HospitalRequest[]>(`/api/v1/platform/hospital-requests${qs({ status })}`),
    approve: (id: string, tenantCode: string, acknowledgeDuplicate = false) =>
      this.request<HospitalApproved>(`/api/v1/platform/hospital-requests/${encodeURIComponent(id)}/approve`, {
        method: 'POST',
        body: JSON.stringify({ tenantCode, acknowledgeDuplicate }),
      }),
    reject: (id: string, reason: string) =>
      this.request<void>(`/api/v1/platform/hospital-requests/${encodeURIComponent(id)}/reject`, { method: 'POST', body: JSON.stringify({ reason }) }),
  }

  patients = {
    /** Paging only. Search terms are PHI and must never be put in a URL: use `search`. */
    list: (params: { page?: number; pageSize?: number; sort?: 'name' | 'recent' } = {}) => {
      const query = new URLSearchParams()
      if (params.sort && params.sort !== 'name') query.set('sort', params.sort)
      if (params.page) query.set('page', String(params.page))
      if (params.pageSize) query.set('pageSize', String(params.pageSize))
      const qs = query.toString()
      return this.request<PagedResult<PatientSummary>>(`/api/v1/patients${qs ? `?${qs}` : ''}`)
    },
    /** POST /api/v1/patients/search: the term travels in the JSON body (not logged in access logs). */
    search: (body: PatientSearchRequest) =>
      this.request<PagedResult<PatientSummary>>('/api/v1/patients/search', { method: 'POST', body: JSON.stringify(body) }),
    create: (body: CreatePatientRequest) =>
      this.request<PatientSummary>('/api/v1/patients', { method: 'POST', body: JSON.stringify(body) }),
    /** 404 for another tenant's id and for soft-deleted patients (admins included). */
    get: (id: string) => this.request<PatientDetail>(`/api/v1/patients/${encodeURIComponent(id)}`),
    /** Merge-patch: absent = unchanged, null clears dateOfBirth/phone/email. */
    update: (id: string, body: UpdatePatientRequest) =>
      this.request<PatientDetail>(`/api/v1/patients/${encodeURIComponent(id)}`, { method: 'PATCH', body: JSON.stringify(body) }),
    /** Soft delete (204). 409 invalid_state while the patient has open appointments or queue entries. */
    remove: (id: string, body: DeletePatientRequest = {}) =>
      this.request<void>(`/api/v1/patients/${encodeURIComponent(id)}`, {
        method: 'DELETE',
        ...(body.reason ? { body: JSON.stringify(body) } : {}),
      }),
    /** tenant_admin only. */
    restore: (id: string) => this.request<void>(`/api/v1/patients/${encodeURIComponent(id)}/restore`, { method: 'POST' }),
    /** tenant_admin only. Moves visits and bills onto this chart and soft-deletes the duplicate. */
    merge: (survivorId: string, body: { duplicatePatientId: string; reason: string }) =>
      this.request<void>(`/api/v1/patients/${encodeURIComponent(survivorId)}/merge`, { method: 'POST', body: JSON.stringify(body) }),
    /** Counts only (no PHI); omit branchId for the whole hospital. */
    registrationSettings: () => this.request<RegistrationSettings>('/api/v1/patients/registration-settings'),
    stats: (params: { branchId?: string } = {}) => this.request<PatientStats>(`/api/v1/patients/stats${qs(params)}`),
    /** Possible duplicates (≤ 20). Identifiers are PHI: body, never URL. Email, phone and ABHA block registration. */
    duplicates: async (body: DuplicateCheckRequest) => {
      const result = await this.request<{ candidates?: DuplicateCandidate[] } | DuplicateCandidate[] | undefined>('/api/v1/patients/duplicates', {
        method: 'POST',
        body: JSON.stringify(body),
      })
      return Array.isArray(result) ? result : (result?.candidates ?? [])
    },
  }

  practitioners = {
    /** `branchId` (API v2): practitioners bookable at that branch; omitted = tenant-wide. */
    /** includeDeleted is tenant_admin only (403 otherwise). */
    list: ({ activeOnly = true, branchId, includeDeleted }: { activeOnly?: boolean; branchId?: string; includeDeleted?: boolean } = {}) =>
      this.request<Practitioner[]>(`/api/v1/practitioners${qs({ activeOnly: String(activeOnly), branchId, includeDeleted: includeDeleted ? 'true' : undefined })}`),
    create: (body: CreatePractitionerRequest) =>
      this.request<Practitioner>('/api/v1/practitioners', { method: 'POST', body: JSON.stringify(body) }),
    update: (id: string, body: UpdatePractitionerRequest) =>
      this.request<Practitioner>(`/api/v1/practitioners/${encodeURIComponent(id)}`, { method: 'PATCH', body: JSON.stringify(body) }),
    /** Soft delete; 409 while the practitioner has open appointments. */
    remove: (id: string) => this.request<void>(`/api/v1/practitioners/${encodeURIComponent(id)}`, { method: 'DELETE' }),
    restore: (id: string) => this.request<void>(`/api/v1/practitioners/${encodeURIComponent(id)}/restore`, { method: 'POST' }),
  }

  schedules = {
    /** Weekly recurring schedules (all of the branch's practitioners when practitionerId is omitted). */
    list: (params: { branchId?: string; practitionerId?: string; includeDeleted?: boolean }) =>
      this.request<Schedule[]>(`/api/v1/schedules${qs({ ...params, includeDeleted: params.includeDeleted ? 'true' : undefined })}`),
    create: (body: CreateScheduleRequest) => this.request<Schedule>('/api/v1/schedules', { method: 'POST', body: JSON.stringify(body) }),
    update: (id: string, body: UpdateScheduleRequest) =>
      this.request<Schedule>(`/api/v1/schedules/${encodeURIComponent(id)}`, { method: 'PATCH', body: JSON.stringify(body) }),
    remove: (id: string) => this.request<void>(`/api/v1/schedules/${encodeURIComponent(id)}`, { method: 'DELETE' }),
    /** 409 schedule_overlap when the restored hours overlap another active schedule. */
    restore: (id: string) => this.request<void>(`/api/v1/schedules/${encodeURIComponent(id)}/restore`, { method: 'POST' }),
  }

  practitionerBranches = {
    list: (params: { practitionerId?: string; branchId?: string } = {}) =>
      this.request<PractitionerBranchMembership[]>(`/api/v1/practitioner-branches${qs(params)}`),
    create: (body: CreatePractitionerBranchRequest) =>
      this.request<PractitionerBranchMembership>('/api/v1/practitioner-branches', { method: 'POST', body: JSON.stringify(body) }),
    update: (id: string, body: UpdatePractitionerBranchRequest) =>
      this.request<PractitionerBranchMembership>(`/api/v1/practitioner-branches/${encodeURIComponent(id)}`, { method: 'PATCH', body: JSON.stringify(body) }),
  }

  scheduleOverrides = {
    list: (params: { practitionerId?: string; branchId?: string; from?: string; to?: string } = {}) =>
      this.request<ScheduleOverride[]>(`/api/v1/schedule-overrides${qs(params)}`),
    create: (body: CreateScheduleOverrideRequest) =>
      this.request<ScheduleOverride>('/api/v1/schedule-overrides', { method: 'POST', body: JSON.stringify(body) }),
  }

  schedulingSettings = {
    get: () => this.request<SchedulingSettings>('/api/v1/scheduling-settings'),
    update: (travelBufferMinutes: number) =>
      this.request<SchedulingSettings>('/api/v1/scheduling-settings', { method: 'PUT', body: JSON.stringify({ travelBufferMinutes }) }),
  }

  myDay = (date: string) => this.request<MyDay>(`/api/v1/practitioners/me/day${qs({ date })}`)

  departments = {
    list: () => this.request<Department[]>('/api/v1/departments'),
    create: (name: string) => this.request<Department>('/api/v1/departments', { method: 'POST', body: JSON.stringify({ name }) }),
  }

  visitTypes = {
    list: (branchId?: string) => this.request<VisitType[]>(`/api/v1/visit-types${qs({ branchId })}`),
    suggestion: (params: { branchId: string; practitionerId: string; patientId: string; startsAt: string }) =>
      this.request<VisitSuggestion>(`/api/v1/visit-types/suggestion${qs(params)}`),
    update: (id: string, body: { name?: string; defaultFeePaise?: number; durationMinutes?: number; followUpValidDays?: number | null; clearFollowUpWindow?: boolean; followUpFeePaise?: number | null; clearFollowUpFee?: boolean; followUpFreeLimit?: number | null; clearFollowUpFreeLimit?: boolean; isActive?: boolean }) =>
      this.request<VisitType>(`/api/v1/visit-types/${encodeURIComponent(id)}`, { method: 'PATCH', body: JSON.stringify(body) }),
    upsertOverride: (id: string, body: { branchId: string; feePaise?: number | null; durationMinutes?: number | null; followUpValidDays?: number | null; followUpFeePaise?: number | null }) =>
      this.request<unknown>(`/api/v1/visit-types/${encodeURIComponent(id)}/overrides`, { method: 'POST', body: JSON.stringify(body) }),
  }

  /**
   * Free, future slots; `from`/`to` are branch-local dates, inclusive, ≤ 31 days. With `durationMinutes`
   * only starts where the whole visit fits the hours and no booking are returned, ending at start + duration.
   */
  slots = (params: { branchId: string; from: string; to: string; practitionerId?: string; durationMinutes?: number }) =>
    this.request<Slot[]>(`/api/v1/slots${qs(params)}`)

  appointments = {
    list: (params: AppointmentQuery) => this.request<PagedResult<Appointment>>(`/api/v1/appointments${qs(params)}`),
    /** Tenant-wide visits for one patient (no branchId). Same list endpoint, filtered by patientId. */
    visits: (params: { patientId: string; from: string; to: string; page?: number; pageSize?: number }) =>
      this.request<PagedResult<Appointment>>(`/api/v1/appointments${qs(params)}`),
    /** 201 `booked`; 409 appointment_overlap when the practitioner is already booked then. */
    create: (body: CreateAppointmentRequest) =>
      this.request<Appointment>('/api/v1/appointments', { method: 'POST', body: JSON.stringify(body) }),
    cancel: (id: string, body: CancelAppointmentRequest = {}) =>
      this.request<Appointment>(`/api/v1/appointments/${encodeURIComponent(id)}/cancel`, { method: 'POST', body: JSON.stringify(body) }),
    /** Issues the next OPD token (appointment must be today, branch-local). */
    checkIn: (id: string) => this.request<CheckInResult>(`/api/v1/appointments/${encodeURIComponent(id)}/check-in`, { method: 'POST' }),
    /** Only `booked` appointments; 409 appointment_overlap / invalid_transition. */
    reschedule: (id: string, body: RescheduleAppointmentRequest) =>
      this.request<Appointment>(`/api/v1/appointments/${encodeURIComponent(id)}/reschedule`, { method: 'POST', body: JSON.stringify(body) }),
    /** Only `booked` appointments whose start has passed; otherwise 409 invalid_transition. */
    noShow: (id: string) => this.request<Appointment>(`/api/v1/appointments/${encodeURIComponent(id)}/no-show`, { method: 'POST' }),
  }

  queue = {
    /** Branch-scoped OPD queue for a branch-local date, ordered by token number. */
    list: (params: { branchId: string; date?: string; status?: QueueStatus }) => this.request<QueueEntry[]>(`/api/v1/queue${qs(params)}`),
    /** Walk-in token without an appointment (D11). 409 already_checked_in if already waiting/in consultation today. */
    walkIn: (body: WalkInRequest) => this.request<CheckInResult>('/api/v1/queue/walk-in', { method: 'POST', body: JSON.stringify(body) }),
    /** waiting → in_consultation | cancelled; in_consultation → done | cancelled. Otherwise 409 invalid_transition. */
    updateStatus: (id: string, body: UpdateQueueStatusRequest) =>
      this.request<QueueEntry>(`/api/v1/queue/${encodeURIComponent(id)}`, { method: 'PATCH', body: JSON.stringify(body) }),
    /** Expire tokens still waiting on that branch-local day (default today). A future day is 400. */
    closeDay: (body: { branchId: string; date?: string; reason?: string }) =>
      this.request<CloseQueueDayResult>('/api/v1/queue/close-day', { method: 'POST', body: JSON.stringify(body) }),
  }

  billing = {
    openAccount: (body: { patientId: string; branchId: string; accountType?: string }) =>
      this.request<BillDocument>('/api/v1/accounts', { method: 'POST', body: JSON.stringify(body) }),
    summary: (patientId: string) =>
      this.request<PatientBillingSummary>(`/api/v1/accounts/${encodeURIComponent(patientId)}/summary`),
    bill: (id: string) => this.request<BillDocument>(`/api/v1/bills/${encodeURIComponent(id)}`),
    addLine: (id: string, body: { code?: string; serviceItemId?: string; quantity?: number; practitionerId?: string }) =>
      this.request<BillDocument>(`/api/v1/bills/${encodeURIComponent(id)}/lines`, { method: 'POST', body: JSON.stringify(body) }),
    removeLine: (billId: string, lineId: string) =>
      this.request<BillDocument>(`/api/v1/bills/${encodeURIComponent(billId)}/lines/${encodeURIComponent(lineId)}`, { method: 'DELETE' }),
    serviceItems: (params: { q?: string; includeInactive?: boolean } = {}) =>
      this.request<ServiceItem[]>(`/api/v1/service-items${qs({ q: params.q, includeInactive: params.includeInactive ? 'true' : undefined })}`),
    taxCodes: () => this.request<TaxCode[]>('/api/v1/service-items/tax-codes'),
    categoryDefaults: () => this.request<CategoryDefault[]>('/api/v1/service-items/category-defaults'),
    saveServiceItem: (body: SaveServiceItemRequest) =>
      this.request<{ id: string; code?: string }>('/api/v1/service-items', { method: 'POST', body: JSON.stringify(body) }),
    priceLists: () => this.request<PriceListSummary[]>('/api/v1/price-lists'),
    prices: (serviceItemId: string) => this.request<ServicePrice[]>(`/api/v1/price-lists/items${qs({ serviceItemId })}`),
    addPrice: (body: AddPriceRequest) =>
      this.request<{ id: string }>('/api/v1/price-lists/items', { method: 'POST', body: JSON.stringify(body) }),
    copyPriceList: (body: { sourcePriceListId: string; branchId: string; effectiveFrom: string; name?: string; dryRun?: boolean }) =>
      this.request<CopyPriceResult>('/api/v1/price-lists/copy', { method: 'POST', body: JSON.stringify(body) }),
    importPrices: (body: { dryRun: boolean; rows: PriceImportRow[] }) =>
      this.request<PriceImportResult>('/api/v1/price-lists/import', { method: 'POST', body: JSON.stringify(body) }),
    ensureDraft: (appointmentId: string) =>
      this.request<BillDocument>('/api/v1/accounts/from-appointment', { method: 'POST', body: JSON.stringify({ appointmentId }) }),
    /** Walk-in token with no appointment: opens (or returns) its consult draft. */
    ensureWalkInDraft: (queueEntryId: string) =>
      this.request<BillDocument>('/api/v1/accounts/from-queue-entry', { method: 'POST', body: JSON.stringify({ queueEntryId }) }),
    list: (params: { status?: string; branchId?: string; from?: string; to?: string } = {}) =>
      this.request<BillListItem[]>(`/api/v1/bills${qs(params)}`),
    finalize: (id: string) => this.request<BillDocument>(`/api/v1/bills/${encodeURIComponent(id)}/finalize`, { method: 'POST' }),
    placeOfSupply: (id: string, stateCode: string) =>
      this.request<BillDocument>(`/api/v1/bills/${encodeURIComponent(id)}/place-of-supply`, { method: 'PUT', body: JSON.stringify({ stateCode }) }),
    discount: (id: string, body: { kind: 'flat_paise' | 'percent_bp'; value: number; reasonCode: string }) =>
      this.request<BillDocument | { approvalId: string; status: string; amountPaise?: number }>(`/api/v1/bills/${encodeURIComponent(id)}/discounts`, { method: 'POST', body: JSON.stringify(body) }),
    refund: (paymentId: string, body: { amountPaise: number }) =>
      this.request<Receipt | { approvalId: string; status: string }>(`/api/v1/payments/${encodeURIComponent(paymentId)}/refunds`, { method: 'POST', body: JSON.stringify(body) }),
    branchProfile: (branchId: string) =>
      this.request<BranchBillProfile>(`/api/v1/price-lists/branches/${encodeURIComponent(branchId)}/profile`),
    setBranchProfile: (branchId: string, body: { gstin?: string; legalName?: string }) =>
      this.request<BranchBillProfile>(`/api/v1/price-lists/branches/${encodeURIComponent(branchId)}/profile`, { method: 'PUT', body: JSON.stringify(body) }),
    paymentAccounts: (branchId: string) =>
      this.request<PaymentAccount[]>(`/api/v1/payment-accounts?branchId=${encodeURIComponent(branchId)}`),
    addPaymentAccount: (body: AddPaymentAccountRequest) =>
      this.request<PaymentAccount>('/api/v1/payment-accounts', { method: 'POST', body: JSON.stringify(body) }),
    updatePaymentAccount: (id: string, body: { label?: string; isActive?: boolean; isDefault?: boolean }) =>
      this.request<PaymentAccount>(`/api/v1/payment-accounts/${encodeURIComponent(id)}`, { method: 'PUT', body: JSON.stringify(body) }),
    deletePaymentAccount: (id: string) =>
      this.request<PaymentAccount>(`/api/v1/payment-accounts/${encodeURIComponent(id)}`, { method: 'DELETE' }),
    paymentLink: (id: string, body: { channel: 'qr' | 'whatsapp' | 'sms' | 'link'; destination?: string; counterSessionId?: string }) =>
      this.request<PaymentLink>(`/api/v1/bills/${encodeURIComponent(id)}/payment-links`, { method: 'POST', body: JSON.stringify(body) }),
    pay: (idempotencyKey: string, body: { accountId: string; kind: 'payment'; counterSessionId?: string; tenders: { mode: string; amountPaise: number; reference?: string }[]; allocations: { billId: string; amountPaise: number }[] }) =>
      this.request<Receipt>('/api/v1/payments', {
        method: 'POST',
        body: JSON.stringify(body),
        headers: { 'Idempotency-Key': idempotencyKey },
      }),
    applyAdvance: (id: string, body: { amountPaise: number }) =>
      this.request<BillDocument>(`/api/v1/bills/${encodeURIComponent(id)}/advances`, { method: 'POST', body: JSON.stringify(body) }),
    ensureSession: (branchId: string) =>
      this.request<CashierSession>('/api/v1/counter-sessions/ensure', { method: 'POST', body: JSON.stringify({ branchId }) }),
    findSession: (branchId: string) =>
      this.request<CashierSession>(`/api/v1/counter-sessions/open${qs({ branchId })}`),
    receipt: (id: string) => this.request<Receipt>(`/api/v1/receipts/${encodeURIComponent(id)}`),
    approvals: (status?: string) => this.request<ApprovalRequest[]>(`/api/v1/approvals${qs({ status })}`),
    approvalSettings: () => this.request<ApprovalSettings>('/api/v1/approvals/settings'),
    saveApprovalSettings: (body: ApprovalSettings) =>
      this.request<ApprovalSettings>('/api/v1/approvals/settings', { method: 'PUT', body: JSON.stringify(body) }),
    decide: (id: string, body: { status: 'approved' | 'rejected'; note?: string }) =>
      this.request<BillDocument | Receipt>(`/api/v1/approvals/${encodeURIComponent(id)}/decide`, { method: 'POST', body: JSON.stringify(body) }),
    dayEnd: (branchId: string, date: string) => this.request<DayEndSession[]>(`/api/v1/billing-reports/day-end${qs({ branchId, date })}`),
    earnings: (query: Record<string, string | undefined>) =>
      this.request<EarningsReport>(`/api/v1/billing-reports/earnings${qs(query)}`),
    earningsExport: (query: Record<string, string | undefined>) =>
      this.download(`/api/v1/billing-reports/earnings/export${qs(query)}`, earningsExportName(query)),
    reconcile: (sessionId: string) =>
      this.request<{ id: string; status: string }>(`/api/v1/counter-sessions/${encodeURIComponent(sessionId)}/reconcile`, { method: 'POST' }),
    publicLink: (token: string) =>
      this.request<PublicBill>(`/api/v1/billing-public/links/${encodeURIComponent(token)}`, { auth: false, retry: false }),
  }

  inventory = {
    items: () => this.request<StockCatalog>('/api/v1/inventory/items'),
    createItem: (body: CreateStockItemRequest) =>
      this.request<StockItem>('/api/v1/inventory/items', { method: 'POST', body: JSON.stringify(body) }),
    stores: () => this.request<StockStore[]>('/api/v1/inventory/stores'),
    createStore: (body: CreateStockStoreRequest) =>
      this.request<StockStore>('/api/v1/inventory/stores', { method: 'POST', body: JSON.stringify(body) }),
    opening: (idempotencyKey: string, body: { storeId: string; lines: OpeningStockLine[] }) =>
      this.request<OpeningStockDocument>('/api/v1/inventory/opening-stock', {
        method: 'POST',
        body: JSON.stringify(body),
        headers: { 'Idempotency-Key': idempotencyKey },
      }),
    stock: (params: { storeId?: string; itemId?: string; lowStock?: boolean } = {}) =>
      this.request<StockOnHandRow[]>(
        `/api/v1/inventory/stock${qs({ storeId: params.storeId, itemId: params.itemId, lowStock: params.lowStock ? true : undefined })}`,
      ),
  }

  /** Pharmacy dispensing (#106). Tenant and branch scope are enforced by the server. */
  pharmacy = {
    queue: (params: { branchId?: string; status?: string } = {}) =>
      this.request<PharmacyQueueRow[]>(`/api/v1/inventory/pharmacy/queue${qs({ branchId: params.branchId, status: params.status })}`),
    prescription: (id: string, storeId?: string) =>
      this.request<PharmacyPrescription>(`/api/v1/inventory/pharmacy/prescriptions/${encodeURIComponent(id)}${qs({ storeId })}`),
    dispense: (idempotencyKey: string, body: DispenseRequest) =>
      this.request<PharmacyPrescription>('/api/v1/inventory/pharmacy/dispenses', {
        method: 'POST',
        body: JSON.stringify(body),
        headers: { 'Idempotency-Key': idempotencyKey },
      }),
  }

  /** Clinical v1 (scheduling service). Writes: doctor only; the tenant comes from the session. */
  consultations = {
    /** Idempotent: an open draft for the same queue entry/appointment is returned again. 409 if not checked in. */
    start: (body: { queueEntryId?: string; appointmentId?: string }) =>
      this.request<Consultation>('/api/v1/consultations', { method: 'POST', body: JSON.stringify(body) }),
    get: (id: string) => this.request<Consultation>(`/api/v1/consultations/${encodeURIComponent(id)}`),
    /** 409 when the rowVersion is stale (edited elsewhere) or the record is finalized; 400 for an invalid line. */
    save: (id: string, body: SaveConsultationRequest) =>
      this.request<Consultation>(`/api/v1/consultations/${encodeURIComponent(id)}`, { method: 'PUT', body: JSON.stringify(body) }),
    finalize: (id: string, rowVersion: number) =>
      this.request<Consultation>(`/api/v1/consultations/${encodeURIComponent(id)}/finalize`, { method: 'POST', body: JSON.stringify({ rowVersion }) }),
    /** New draft version that supersedes a finalized one. */
    revise: (id: string) => this.request<Consultation>(`/api/v1/consultations/${encodeURIComponent(id)}/revisions`, { method: 'POST' }),
    /** 409 for a draft: only finalized prescriptions print. */
    print: (id: string) => this.request<ConsultationPrint>(`/api/v1/consultations/${encodeURIComponent(id)}/print`),
    forPatient: (patientId: string) => this.request<Consultation[]>(`/api/v1/consultations${qs({ patientId })}`),
    /** #104: 400 for an impossible value, 409 for a cancelled/no-show visit, 403 without clinical.vitals. */
    recordVitals: (body: RecordVitalsRequest) =>
      this.request<Vitals>('/api/v1/consultations/vitals', { method: 'POST', body: JSON.stringify(body) }),
    /** Newest first; pass exactly one of patientId / queueEntryId. */
    vitals: (by: { patientId: string } | { queueEntryId: string }) => this.request<Vitals[]>(`/api/v1/consultations/vitals${qs(by)}`),
  }

  privacy = {
    notices: () => this.request<PrivacyNotice[]>('/api/v1/privacy/consent-notices'),
    currentNotice: (language = 'en') =>
      this.request<PrivacyNotice>(`/api/v1/privacy/consent-notices/current${qs({ language })}`),
    createNotice: (idempotencyKey: string, body: { language: string; title: string; body: string; purposes: string[] }) =>
      this.request<PrivacyNotice>('/api/v1/privacy/consent-notices', {
        method: 'POST',
        body: JSON.stringify(body),
        headers: { 'Idempotency-Key': idempotencyKey },
      }),
    publishNotice: (idempotencyKey: string, id: string) =>
      this.request<PrivacyNotice>(`/api/v1/privacy/consent-notices/${encodeURIComponent(id)}/publish`, {
        method: 'POST',
        headers: { 'Idempotency-Key': idempotencyKey },
      }),
    consents: (patientId: string) =>
      this.request<ConsentList>(`/api/v1/privacy/patients/${encodeURIComponent(patientId)}/consents`),
    recordConsents: (idempotencyKey: string, patientId: string, body: {
      noticeId: string
      channel: string
      givenBy: string
      subjectIsMinor?: boolean
      guardianName?: string
      choices: ConsentChoice[]
    }) =>
      this.request<{ events: number; receiptQueued: boolean }>(`/api/v1/privacy/patients/${encodeURIComponent(patientId)}/consents`, {
        method: 'POST',
        body: JSON.stringify(body),
        headers: { 'Idempotency-Key': idempotencyKey },
      }),
    withdraw: (idempotencyKey: string, patientId: string, purpose: string) =>
      this.request<{ withdrawn: boolean }>(`/api/v1/privacy/patients/${encodeURIComponent(patientId)}/consents/${encodeURIComponent(purpose)}/withdraw`, {
        method: 'POST',
        body: JSON.stringify({ channel: 'tablet' }),
        headers: { 'Idempotency-Key': idempotencyKey },
      }),
    consentLink: (patientId: string) =>
      this.request<ConsentLink>(`/api/v1/privacy/patients/${encodeURIComponent(patientId)}/consent-links`, { method: 'POST' }),
    requests: (status?: string) => this.request<RightsRequest[]>(`/api/v1/privacy/rights-requests${qs({ status })}`),
    createRequest: (idempotencyKey: string, body: { patientId: string; type: string; details: string; channel: string }) =>
      this.request<RightsRequest>('/api/v1/privacy/rights-requests', {
        method: 'POST',
        body: JSON.stringify(body),
        headers: { 'Idempotency-Key': idempotencyKey },
      }),
    verifyRequest: (id: string) =>
      this.request<RightsRequest>(`/api/v1/privacy/rights-requests/${encodeURIComponent(id)}/verify`, { method: 'POST' }),
    fulfilRequest: (id: string, response: string) =>
      this.request<RightsRequest>(`/api/v1/privacy/rights-requests/${encodeURIComponent(id)}/fulfil`, {
        method: 'POST',
        body: JSON.stringify({ response }),
      }),
    closeRequest: (id: string, response: string) =>
      this.request<RightsRequest>(`/api/v1/privacy/rights-requests/${encodeURIComponent(id)}/close`, {
        method: 'POST',
        body: JSON.stringify({ response }),
      }),
    approveErasure: (id: string) =>
      this.request<RightsRequest>(`/api/v1/privacy/rights-requests/${encodeURIComponent(id)}/erasure-approvals`, { method: 'POST' }),
    executeErasure: (idempotencyKey: string, id: string) =>
      this.request<RightsRequest>(`/api/v1/privacy/rights-requests/${encodeURIComponent(id)}/execute-erasure`, {
        method: 'POST',
        headers: { 'Idempotency-Key': idempotencyKey },
      }),
    publicConsent: (token: string) =>
      this.request<PublicConsent>(`/api/v1/privacy/public/consents/${encodeURIComponent(token)}`, { auth: false, retry: false }),
    submitPublicConsent: (token: string, choices: ConsentChoice[]) =>
      this.request<{ events: number; saved: boolean }>(`/api/v1/privacy/public/consents/${encodeURIComponent(token)}`, {
        method: 'POST',
        body: JSON.stringify({ choices }),
        auth: false,
        retry: false,
      }),
  }
}

/**
 * Query string from non-empty params. Only ids, dates and paging go in URLs; PHI (names, phone,
 * DOB search terms) always travels in a JSON body.
 */
function qs(params: object): string {
  const query = new URLSearchParams()
  for (const [key, value] of Object.entries(params) as [string, unknown][]) if (value !== undefined && value !== null && value !== '') query.set(key, String(value))
  const text = query.toString()
  return text ? `?${text}` : ''
}

let currentTokenProvider: TokenProvider = () => null
let currentTenantListener: ResolvedTenantListener | null = null
let currentUnauthorizedHandler: UnauthorizedHandler | null = null

/** Called by AuthProvider: the API client asks Supabase for the current access token per request. */
export function configureApiAuth(provider: TokenProvider) {
  currentTokenProvider = provider
}

/** Called by AuthProvider: every X-Hms-Tenant response header is checked against the displayed tenant. */
export function configureResolvedTenantListener(listener: ResolvedTenantListener | null) {
  currentTenantListener = listener
}

/** Called by AuthProvider: after a 401 the client refreshes the session once and replays. */
export function configureUnauthorizedHandler(handler: UnauthorizedHandler | null) {
  currentUnauthorizedHandler = handler
}

export const apiClient = new ApiClient({
  baseUrl: import.meta.env.VITE_API_BASE_URL ?? '',
  getAccessToken: () => currentTokenProvider(),
  onResolvedTenant: (tenantId, startedAt) => currentTenantListener?.(tenantId, startedAt),
  onUnauthorized: async () => (currentUnauthorizedHandler ? currentUnauthorizedHandler() : false),
})

/** Field errors from a 400 ValidationProblem, keyed by camelCase field name. */
export function fieldErrors(error: unknown): Record<string, string> {
  if (!(error instanceof ApiError) || !error.problem?.errors) return {}
  return Object.fromEntries(Object.entries(error.problem.errors).map(([k, v]) => [k, v[0] ?? 'Invalid value']))
}

/** `code` of an API problem (e.g. 'appointment_overlap'), or null. */
export function problemCode(error: unknown): string | null {
  return error instanceof ApiError ? (error.problem?.code ?? null) : null
}

export function httpStatus(error: unknown): number | null {
  return error instanceof ApiError ? error.status : null
}

/**
 * File name from a Content-Disposition header. Prefers RFC 5987 `filename*=UTF-8''…` (what ASP.NET sends
 * alongside `filename=`), then quoted or bare `filename=`. Path separators are stripped. Null when absent.
 */
export function filenameFromDisposition(header: string | null): string | null {
  if (!header) return null
  const star = /filename\*\s*=\s*([^']*)'[^']*'([^;]+)/i.exec(header)
  let name: string | null = null
  if (star?.[2]) {
    try {
      name = decodeURIComponent(star[2].trim().replace(/^"|"$/g, ''))
    } catch {
      name = null
    }
  }
  if (!name) {
    const plain = /filename\s*=\s*(?:"([^"]*)"|([^;]+))/i.exec(header)
    name = (plain?.[1] ?? plain?.[2] ?? '').trim() || null
  }
  const safe = name?.replace(/[\\/]/g, '_').trim()
  return safe ? safe : null
}

/** Same name the API sends, used when the header can't be read: earnings-{section|accounts}-{period}.{csv|xlsx}. */
export function earningsExportName(query: Record<string, string | undefined>): string {
  const format = query.format === 'xlsx' ? 'xlsx' : 'csv'
  const section = query.section ?? (format === 'xlsx' ? 'accounts' : 'report')
  const period = query.fy ? `FY${query.fy}${query.quarter ? `-Q${query.quarter}` : ''}` : [query.from, query.to].filter(Boolean).join('-')
  return `earnings-${section}${period ? `-${period}` : ''}.${format}`
}

/** #91: how long one warm-up covers a browser tab before reloads call it again. */
export const WARMUP_INTERVAL_MS = 5 * 60_000
const WARMUP_KEY = 'hms.warmupAt'

/** True when this tab has not warmed up in the last WARMUP_INTERVAL_MS (and records now). */
export function claimWarmupSlot(now: number = Date.now(), force = false): boolean {
  try {
    const last = Number(globalThis.sessionStorage?.getItem(WARMUP_KEY) ?? 0)
    if (Number.isFinite(last) && last > 0 && now - last < WARMUP_INTERVAL_MS && now >= last && !force) return false
    globalThis.sessionStorage?.setItem(WARMUP_KEY, String(now))
  } catch {
    /* storage blocked: warm up anyway */
  }
  return true
}
