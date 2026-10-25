import type { CurrentTenant } from '../../lib/api/types'

export const SETUP_STEPS = ['profile', 'branch', 'staff', 'schedule', 'done'] as const
export type SetupStep = (typeof SETUP_STEPS)[number]

export function isSetupStep(value: string | null | undefined): value is SetupStep {
  return SETUP_STEPS.includes(value as SetupStep)
}

/** Same-tab "Finish later". A new browser session has an empty sessionStorage and returns to the wizard. */
export function setupLaterKey(tenantId: string) {
  return `hms.setup.later.${tenantId}`
}

/** Open when the server says so. Missing fields (older API or a failed read) mean already finished. */
export function setupIsOpen(tenant: CurrentTenant | undefined | null): tenant is CurrentTenant {
  if (!tenant?.setupStep || tenant.setupStep === 'done') return false
  return !tenant.setupCompletedOn
}

export function setupDeferred(tenantId: string) {
  try {
    return sessionStorage.getItem(setupLaterKey(tenantId)) === '1'
  } catch {
    return false
  }
}

export function deferSetup(tenantId: string) {
  sessionStorage.setItem(setupLaterKey(tenantId), '1')
}

export function clearDeferredSetup(tenantId: string) {
  sessionStorage.removeItem(setupLaterKey(tenantId))
}
