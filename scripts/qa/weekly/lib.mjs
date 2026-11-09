import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'
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

/** Create a confirmed synthetic auth user (no outbound email).
 * Live box: use a pre-seeded `/home/box/.secrets/zz-qa-wiz-*` file (email=/password=)
 * created via Supabase SQL/MCP with extensions.crypt. Password is never logged.
 */
export async function createSyntheticAuthUser(localPart) {
  const seeded = [...fs.readdirSync('/home/box/.secrets')].filter(n => n.startsWith('zz-qa-wiz-')).sort().at(-1)
  if (seeded) {
    const rawSeed = fs.readFileSync('/home/box/.secrets/' + seeded, 'utf8')
    const semail = rawSeed.match(/^email=(.*)$/m)?.[1]?.trim()
    const spass = rawSeed.match(/^password=(.*)$/m)?.[1]?.trim()
    if (semail && spass) {
      track('auth_user', { email: semail, userId: null, secretPath: '/home/box/.secrets/' + seeded, seeded: true, requestedLocalPart: localPart })
      return { email: semail, password: spass, userId: null }
    }
  }
  throw new Error('No seeded zz-qa-wiz-* auth user in /home/box/.secrets. Create one via Supabase SQL (auth.users + auth.identities, email confirmed, no outbound mail).')
}

export { c, E, T }
