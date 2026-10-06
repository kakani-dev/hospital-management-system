import { describe, expect, it } from 'vitest'
import { loginSchema } from './loginSchema'

describe('loginSchema', () => {
  it('accepts a valid email and password', () => {
    expect(loginSchema.safeParse({ email: 'demo@alpha.example', password: 'longenough' }).success).toBe(true)
  })

  it('rejects invalid email and short password', () => {
    const result = loginSchema.safeParse({ email: 'nope', password: 'short' })
    expect(result.success).toBe(false)
    if (!result.success) {
      const fields = result.error.issues.map((i) => i.path[0])
      expect(fields).toEqual(expect.arrayContaining(['email', 'password']))
    }
  })
})
