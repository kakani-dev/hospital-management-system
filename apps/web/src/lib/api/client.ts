import type {
  AddMemberRequest,
  Branch,
  CreateBranchRequest,
  CreatePatientRequest,
  CurrentUser,
  HealthStatus,
  Member,
  PagedResult,
  PatientSummary,
  ProblemDetails,
  SwitchContextRequest,
  UpdateBranchRequest,
  UpdateMemberRequest,
} from './types'

export class ApiError extends Error {
  readonly status: number
  readonly problem: ProblemDetails | null

  constructor(status: number, problem: ProblemDetails | null, message?: string) {
    super(message ?? problem?.title ?? `Request failed with status ${status}`)
    this.name = 'ApiError'
    this.status = status
    this.problem = problem
  }
}

export type TokenProvider = () => string | null | Promise<string | null>

export interface ApiClientOptions {
  baseUrl?: string
  getAccessToken?: TokenProvider
  fetchImpl?: typeof fetch
}

/**
 * Typed HTTP client for the HMS gateway.
 *
 * SECURITY: this client deliberately never sends a tenant id header. The backend derives
 * the tenant from the authenticated (signed) token claims and validates membership server-side.
 * Any tenant/branch selection in the UI is a UX hint only.
 */
export class ApiClient {
  private readonly baseUrl: string
  private readonly getAccessToken?: TokenProvider
  private readonly fetchImpl: typeof fetch

  constructor(options: ApiClientOptions = {}) {
    this.baseUrl = (options.baseUrl ?? '').replace(/\/+$/, '')
    this.getAccessToken = options.getAccessToken
    // Resolved per call (not captured at construction) so polyfills/test stubs installed later apply.
    this.fetchImpl = options.fetchImpl ?? ((input, init) => globalThis.fetch(input, init))
  }

  async request<T>(path: string, init: RequestInit = {}): Promise<T> {
    const headers = new Headers(init.headers)
    headers.set('Accept', 'application/json')
    if (init.body !== undefined && !headers.has('Content-Type')) {
      headers.set('Content-Type', 'application/json')
    }
    const token = await this.getAccessToken?.()
    if (token) headers.set('Authorization', `Bearer ${token}`)

    const response = await this.fetchImpl(`${this.baseUrl}${path}`, { ...init, headers })
    if (!response.ok) {
      let problem: ProblemDetails | null = null
      try {
        problem = (await response.json()) as ProblemDetails
      } catch {
        problem = null
      }
      throw new ApiError(response.status, problem)
    }
    if (response.status === 204) return undefined as T
    return (await response.json()) as T
  }

  health = {
    live: () => this.request<HealthStatus>('/health/live'),
    ready: () => this.request<HealthStatus>('/health/ready'),
  }

  me = () => this.request<CurrentUser>('/api/v1/me')

  /** Server validates the requested tenant/branch against memberships (403 otherwise). */
  switchContext = (body: SwitchContextRequest) =>
    this.request<void>('/api/v1/me/context', { method: 'POST', body: JSON.stringify(body) })

  branches = {
    list: () => this.request<Branch[]>('/api/v1/branches'),
    create: (body: CreateBranchRequest) =>
      this.request<Branch>('/api/v1/branches', { method: 'POST', body: JSON.stringify(body) }),
    update: (id: string, body: UpdateBranchRequest) =>
      this.request<Branch>(`/api/v1/branches/${encodeURIComponent(id)}`, { method: 'PATCH', body: JSON.stringify(body) }),
  }

  members = {
    list: () => this.request<Member[]>('/api/v1/members'),
    add: (body: AddMemberRequest) => this.request<Member>('/api/v1/members', { method: 'POST', body: JSON.stringify(body) }),
    update: (id: string, body: UpdateMemberRequest) =>
      this.request<Member>(`/api/v1/members/${encodeURIComponent(id)}`, { method: 'PATCH', body: JSON.stringify(body) }),
  }

  patients = {
    list: (params: { page?: number; pageSize?: number; search?: string } = {}) => {
      const query = new URLSearchParams()
      if (params.page) query.set('page', String(params.page))
      if (params.pageSize) query.set('pageSize', String(params.pageSize))
      if (params.search) query.set('search', params.search)
      const qs = query.toString()
      return this.request<PagedResult<PatientSummary>>(`/api/v1/patients${qs ? `?${qs}` : ''}`)
    },
    create: (body: CreatePatientRequest) =>
      this.request<PatientSummary>('/api/v1/patients', { method: 'POST', body: JSON.stringify(body) }),
  }
}

let currentTokenProvider: TokenProvider = () => null

/** Called by AuthProvider: the API client asks Supabase for the current access token per request. */
export function configureApiAuth(provider: TokenProvider) {
  currentTokenProvider = provider
}

export const apiClient = new ApiClient({
  baseUrl: import.meta.env.VITE_API_BASE_URL ?? '',
  getAccessToken: () => currentTokenProvider(),
})

/** Field errors from a 400 ValidationProblem, keyed by camelCase field name. */
export function fieldErrors(error: unknown): Record<string, string> {
  if (!(error instanceof ApiError) || !error.problem?.errors) return {}
  return Object.fromEntries(Object.entries(error.problem.errors).map(([k, v]) => [k, v[0] ?? 'Invalid value']))
}
