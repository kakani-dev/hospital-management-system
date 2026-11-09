import fs from 'fs'
export const E = process.env.HMS_EDGE_URL || 'https://ca-hms-edge.whiteisland-88abe7bd.centralindia.azurecontainerapps.io'
const raw = JSON.parse(fs.readFileSync('/home/box/.secrets/qa-tokens.json', 'utf8'))
for (const [role, tok] of Object.entries(raw)) {
  if (!tok) throw new Error('missing token for ' + role)
}
export const T = raw
export async function c(role, m, p, body, extra = {}) {
  const h = { 'content-type': 'application/json', 'idempotency-key': crypto.randomUUID(), ...extra }
  if (role) h.authorization = 'Bearer ' + T[role]
  const r = await fetch(E + p, { method: m, headers: h, body: body === undefined ? undefined : JSON.stringify(body) })
  const t = await r.text()
  let j
  try { j = JSON.parse(t) } catch {}
  return { s: r.status, t, j }
}
export const log = (id, r, note = '') => console.log(id, r.s, note, (r.t || '').slice(0, 220).replace(/\s+/g, ' '))

/** Refuse demo.* identities; ensure active branch for every qa role. */
export async function ensureQaContext(preferredBranchName = /Hyderabad Main/i) {
  const me0 = (await c('admin', 'GET', '/api/v1/me')).j
  if (!me0?.email || /^demo\./i.test(me0.email) || me0.email === 'demo.admin@demo.medicore.test') {
    throw new Error('REFUSE: qa tokens must be qa.* logins, got ' + me0?.email)
  }
  const branches = me0.accessibleBranches || []
  const br = branches.find(b => preferredBranchName.test(b.name)) || branches[0]
  if (!br) throw new Error('no accessible branch for qa.admin')
  for (const role of Object.keys(T)) {
    const me = (await c(role, 'GET', '/api/v1/me')).j
    if (!me?.email || /^demo\./i.test(me.email)) throw new Error('REFUSE demo login for role ' + role + ': ' + me?.email)
    if (me.activeBranchId !== br.id) {
      await c(role, 'POST', '/api/v1/me/context', { branchId: br.id, tenantId: me.activeTenantId || me0.activeTenantId })
    }
  }
  return { tenantId: me0.activeTenantId, branchId: br.id, branchName: br.name, adminEmail: me0.email }
}
