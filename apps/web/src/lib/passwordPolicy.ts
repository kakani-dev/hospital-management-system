/** Admin-set password policy (#311). The server and database enforce the same rule. */
export const PASSWORD_MIN = 10
export const PASSWORD_MAX_BYTES = 72
export const PASSWORD_POLICY_TEXT = 'Use 10-72 characters with at least one letter and one digit.'

export function isStrongEnough(password: string): boolean {
  return (
    password.length >= PASSWORD_MIN &&
    new TextEncoder().encode(password).length <= PASSWORD_MAX_BYTES &&
    /[A-Za-z]/.test(password) &&
    /[0-9]/.test(password)
  )
}

// No look-alikes (0/O, 1/l/I) so it can be read out to the person.
const LETTERS = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ'
const DIGITS = '23456789'
const ALL = LETTERS + DIGITS

/** Uniform pick: bytes at or above the largest multiple of the alphabet size are rejected (no modulo bias). */
function randomChars(chars: string, length: number): string {
  const limit = 256 - (256 % chars.length)
  let out = ''
  while (out.length < length) {
    for (const byte of crypto.getRandomValues(new Uint8Array(length * 2))) {
      if (byte < limit && out.length < length) out += chars.charAt(byte % chars.length)
    }
  }
  return out
}

/** A random 14-character password from crypto.getRandomValues that always meets the policy. */
export function generatePassword(length = 14): string {
  for (;;) {
    const out = randomChars(ALL, length)
    if (isStrongEnough(out)) return out
  }
}
