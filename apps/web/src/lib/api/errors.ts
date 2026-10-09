import { ApiTransportError, isTransientError } from './client'

/**
 * Message for a failed write that was NOT retried automatically. A timeout or network error means
 * the server may still have done it, so say "check first"; a 503/502/504/429 means it did not.
 */
export function transientWriteMessage(error: unknown, action: string): string | null {
  if (!isTransientError(error)) return null
  if (error instanceof ApiTransportError) {
    return error.kind === 'timeout'
      ? `The server did not answer in time while trying to ${action}. It may still have been saved: check the screen before you retry.`
      : `The server could not be reached while trying to ${action}. Check the connection and retry.`
  }
  return `The server is waking up or busy and could not ${action}. Nothing was saved. Retry in a few seconds.`
}
