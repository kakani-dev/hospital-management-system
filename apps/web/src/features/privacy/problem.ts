import { ApiError } from '../../lib/api/client'

export function problemText(error: unknown): string {
  if (error instanceof ApiError) return error.problem?.detail ?? error.message
  return 'Something went wrong. Try again.'
}
