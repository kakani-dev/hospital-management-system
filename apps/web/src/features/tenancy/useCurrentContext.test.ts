import { describe, expect, it } from 'vitest'
import { ALPHA, ALPHA_EAST, ALPHA_MAIN, BETA, meFor } from '../../test/fakes'
import { defaultBranchId } from './useCurrentContext'

const membership = (branchId: string | null, tenantId = ALPHA) => ({ tenantId, tenantName: 'Demo Alpha Hospital', branchId, branchName: null, role: 'receptionist' })

describe('defaultBranchId', () => {
  it('uses the active branch when it is accessible', () => {
    expect(defaultBranchId(meFor({ activeBranchId: ALPHA_EAST }))).toBe(ALPHA_EAST)
  })

  it('"All my branches": the primary (branch-bound membership) branch, else the first accessible one', () => {
    expect(defaultBranchId(meFor({ activeBranchId: null, memberships: [membership(null), membership(ALPHA_EAST)] }))).toBe(ALPHA_EAST)
    expect(defaultBranchId(meFor({ activeBranchId: null }))).toBe(ALPHA_MAIN)
  })

  it('the only branch, and never an inaccessible or foreign id', () => {
    const only = meFor({ activeBranchId: null, accessibleBranches: [{ id: ALPHA_EAST, name: 'Alpha East' }] })
    expect(defaultBranchId(only)).toBe(ALPHA_EAST)
    expect(defaultBranchId(meFor({ activeBranchId: 'a1111111-0000-4000-8000-0000000000ff' }))).toBe(ALPHA_MAIN)
    expect(defaultBranchId(meFor({ activeBranchId: null, memberships: [membership('b2222222-0000-4000-8000-000000000001', BETA)] }))).toBe(ALPHA_MAIN)
  })

  it('null without accessible branches (or before /me loads)', () => {
    expect(defaultBranchId(meFor({ activeBranchId: null, accessibleBranches: [] }))).toBeNull()
    expect(defaultBranchId(undefined)).toBeNull()
  })
})
