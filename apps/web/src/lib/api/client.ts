import type { CreatePatientRequest, CurrentUser, HealthStatus, PagedResult, PatientSummary, ProblemDetails } from './types'

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
    this.fetchImpl = options.fetchImpl ?? globalThis.fetch.bind(globalThis)
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

export const apiClient = new ApiClient({
  baseUrl: import.meta.env.VITE_API_BASE_URL ?? '',
  // TODO(Sprint 1): return the Supabase session access token (supabase.auth.getSession()).
  getAccessToken: () => null,
})
