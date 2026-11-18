import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'
import { randomBytes } from 'node:crypto'
import { c, E, T } from '../h.mjs'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
export const RUN_ID = process.env.QA_RUN_ID || new Date().toLocaleString('sv-SE', { timeZone: 'Asia/Kolkata' }).replace(/[-: ]/g, '').slice(0, 12)
export const TAG = `QA Test ${RUN_ID}`
export const ENTITY_LOG = path.join(__dirname, `entities-${RUN_ID}.json`)
export const entities = { runId: RUN_ID, startedAt: new Date().toISOString(), items: [] }

export function track(kind, data) {
  entities.items.push({ kind, at: new Date().toISOString(), ...data })
  fs.writeFileSync(ENTITY_LOG, JSON.stringify(entities, null, 2))
}

export const ist = (off = 0) => {
  const d = new Date(Date.now() + off * 864e5)
  return d.toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' })
}
export const rnd = () => String(Math.floor(Math.random() * 90000) + 10000)

const rd = (f) => fs.readFileSync('/home/box/.secrets/' + f, 'utf8').trim()
const SUPABASE = 'https://gvgomzogbzbjhlcsimrx.supabase.co'
const KEY = rd('medicore-publishable-key')

export async function anon(m, p, body) {
  const h = { 'content-type': 'application/json', 'idempotency-key': crypto.randomUUID() }
  const r = await fetch(E + p, { method: m, headers: h, body: body === undefined ? undefined : JSON.stringify(body) })
  const t = await r.text()
  let j; try { j = JSON.parse(t) } catch {}
  return { s: r.status, t, j }
}

export async function withToken(token, m, p, body, extra = {}) {
  const h = { 'content-type': 'application/json', 'idempotency-key': crypto.randomUUID(), authorization: 'Bearer ' + token, ...extra }
  const r = await fetch(E + p, { method: m, headers: h, body: body === undefined ? undefined : JSON.stringify(body) })
  const t = await r.text()
  let j; try { j = JSON.parse(t) } catch {}
  return { s: r.status, t, j }
}

export async function passwordToken(email, password) {
  const r = await fetch(SUPABASE + '/auth/v1/token?grant_type=password', {
    method: 'POST', headers: { apikey: KEY, 'content-type': 'application/json' },
    body: JSON.stringify({ email, password }),
  })
  const j = await r.json()
  if (!j.access_token) throw new Error('login failed for ' + email + ' ' + (j.error_code || j.msg || r.status))
  return j.access_token
}

export async function platformToken() {
  const raw = rd('medicore-master-login')
  const email = raw.split(/\r?\n/).find(l => l.toLowerCase().startsWith('email=')).split('=').slice(1).join('=').trim()
  const password = raw.split(/\r?\n/).find(l => l.toLowerCase().startsWith('password=')).split('=').slice(1).join('=').trim()
  const tok = await passwordToken(email, password)
  const me = await withToken(tok, 'GET', '/api/v1/me')
  if (!me.j?.isPlatformAdmin) throw new Error('master login is not platform admin')
  return tok
}

const SECRETS_DIR = '/home/box/.secrets'

function genWizardPassword() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
  let pw = ''
  while (pw.length < 16) {
    const n = randomBytes(1)[0]
    if (n >= Math.floor(256 / alphabet.length) * alphabet.length) continue
    pw += alphabet[n % alphabet.length]
  }
  if (![...pw].some((c) => /[A-Za-z]/.test(c)) || ![...pw].some((c) => /\d/.test(c))) {
    return genWizardPassword()
  }
  return pw
}

function writeSecretFile(path, email, password) {
  fs.writeFileSync(path, `email=${email}\npassword=${password}\n`, { mode: 0o600 })
  fs.chmodSync(path, 0o600)
}

function redact(text, password) {
  return String(text ?? '').replace(new RegExp(password.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g'), '[redacted]')
}

/** Seed via POST /api/v1/platform/qa/wizard-auth-users (platform admin). Password never logged. */
async function seedWizardUserHttp(email, password) {
  const tok = await platformToken()
  const res = await withToken(tok, 'POST', '/api/v1/platform/qa/wizard-auth-users', { email, password })
  const userId = res.j?.userId
  if (res.s >= 300 || !userId || !/^[0-9a-f-]{36}$/i.test(String(userId))) {
    const errText = redact((res.j?.code || res.j?.detail || res.j?.title || res.t || ('HTTP ' + res.s)), password)
    throw new Error('seed endpoint returned ' + res.s + ' ' + errText.slice(0, 200))
  }
  return String(userId)
}

/** Create a confirmed synthetic auth user for this run (no outbound email).
 * Inserts via POST /api/v1/platform/qa/wizard-auth-users (platform-admin, allowlisted emails).
 * Password is written only to `/home/box/.secrets/zz-qa-wiz-<runId>` and is never logged.
 */
export async function createSyntheticAuthUser(localPart) {
  const email = `${String(localPart || '').trim().toLowerCase()}@synthetic.example`
  if (!/^(zz-qa\.wiz\.[0-9]{12}|zz-qa-wiz-[0-9]{8,14})@synthetic\.example$/.test(email)) {
    throw new Error('refusing to seed a non zz-qa wizard email')
  }
  const password = genWizardPassword()
  const secretPath = `${SECRETS_DIR}/zz-qa-wiz-${RUN_ID}`
  writeSecretFile(secretPath, email, password)
  let userId
  try {
    userId = await seedWizardUserHttp(email, password)
  } catch (e) {
    throw new Error('wizard auth seed failed: ' + redact(e?.message || e, password).slice(0, 240))
  }
  // Confirm GoTrue will issue a token before returning the password to the caller.
  await passwordToken(email, password)
  track('auth_user', { email, userId, secretPath, seeded: true, createdThisRun: true })
  return { email, password, userId }
}

export { c, E, T }
