import { codeFromName } from '../../lib/timeZones'
import type { CreateTenantValues } from '../onboarding/onboardingSchemas'

/** Branch codes are derived from names (unique per hospital), so the operator types names only. */
export function branchPayload(branches: CreateTenantValues['branches']) {
  const used = new Set<string>()
  return branches.map((b, i) => {
    let code = codeFromName(b.name).slice(0, 20).replace(/-+$/, '')
    if (code.length < 2 || used.has(code)) code = `${code.slice(0, 16) || 'br'}-${i + 1}`
    used.add(code)
    return { code, name: b.name.trim(), address: b.address.trim() || null }
  })
}
