import { describe, expect, it } from 'vitest'
import { branchSchema, memberSchema } from './adminSchemas'

describe('branchSchema', () => {
  it('accepts lowercase codes and IANA zones', () => {
    expect(branchSchema.safeParse({ code: 'north-2', name: 'North', timezone: 'Asia/Kolkata' }).success).toBe(true)
  })
  it.each([
    { code: 'North', name: 'N', timezone: 'UTC' },
    { code: 'n', name: 'N', timezone: 'UTC' },
    { code: 'north', name: '', timezone: 'UTC' },
    { code: 'north', name: 'N', timezone: 'Mars/Olympus' },
  ])('rejects %o', (value) => {
    expect(branchSchema.safeParse(value).success).toBe(false)
  })
})

describe('memberSchema', () => {
  it('accepts a known role with optional branch', () => {
    expect(memberSchema.safeParse({ email: 'a@b.example', role: 'nurse', branchId: '' }).success).toBe(true)
  })
  it('rejects a branch-scoped tenant admin (tenant_admin is tenant-wide)', () => {
    expect(memberSchema.safeParse({ email: 'a@b.example', role: 'tenant_admin', branchId: '' }).success).toBe(true)
    const result = memberSchema.safeParse({ email: 'a@b.example', role: 'tenant_admin', branchId: 'a1111111-0000-4000-8000-000000000001' })
    expect(result.success).toBe(false)
    expect(result.error?.issues[0]?.path).toEqual(['branchId'])
  })
  it('rejects unknown roles', () => {
    expect(memberSchema.safeParse({ email: 'a@b.example', role: 'root', branchId: '' }).success).toBe(false)
  })
})
