import { z } from 'zod'
import { ROLES } from '../../lib/api/types'

const isIanaZone = (tz: string) => {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: tz })
    return tz.length > 0
  } catch {
    return false
  }
}

export const branchSchema = z
  .object({
    code: z
      .string()
      .trim()
      .regex(/^[a-z0-9][a-z0-9-]{1,39}$/, { error: '2-40 lowercase letters, digits or hyphens' }),
    name: z.string().trim().min(1, { error: 'Name is required' }).max(120, { error: 'Max 120 characters' }),
    /** true (the form's default): no override, the branch follows the hospital zone. */
    useHospitalZone: z.boolean().optional(),
    timezone: z.string().trim(),
  })
  .refine((v) => v.useHospitalZone === true || isIanaZone(v.timezone), {
    path: ['timezone'],
    error: 'Use an IANA time zone, e.g. Asia/Kolkata',
  })
export type BranchFormValues = z.infer<typeof branchSchema>

export const TENANT_ADMIN_BRANCH_ERROR = 'Tenant admins are hospital-wide: choose All branches'

export const memberSchema = z
  .object({
    email: z.email({ error: 'Enter a valid email address' }),
    role: z.enum(ROLES),
    branchId: z.union([z.literal(''), z.uuid()]),
  })
  // Mirrors the API (400) and DB CHECK (role <> 'tenant_admin' or branch_id is null).
  .refine((v) => v.role !== 'tenant_admin' || v.branchId === '', { path: ['branchId'], error: TENANT_ADMIN_BRANCH_ERROR })
export type MemberFormValues = z.infer<typeof memberSchema>
