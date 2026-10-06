// Minimal GoTrue (Supabase Auth) stand-in for LOCAL E2E TESTS ONLY.
//
// - POST /auth/v1/token?grant_type=password|refresh_token, GET /auth/v1/user, POST /auth/v1/logout
// - GET  /auth/v1/.well-known/jwks.json (ES256 key generated at start-up, never persisted)
// - Access-token claims are produced by the REAL identity.custom_access_token_hook, executed as
//   supabase_auth_admin, exactly as hosted Supabase does when the hook is enabled.
// - Only users present in auth.users can sign in, with one shared synthetic password
//   (MOCK_AUTH_PASSWORD). Never expose this server beyond localhost.
import { createServer } from 'node:http'
import { randomBytes, randomUUID } from 'node:crypto'
import { SignJWT, exportJWK, generateKeyPair } from 'jose'
import pg from 'pg'

const PORT = Number(process.env.MOCK_AUTH_PORT ?? 54321)
const HOST = process.env.MOCK_AUTH_HOST ?? '127.0.0.1'
const DB_URL = process.env.MOCK_AUTH_DB_URL ?? 'postgresql://postgres:postgres@localhost:5432/hms_e2e'
const PASSWORD = process.env.MOCK_AUTH_PASSWORD ?? 'synthetic-demo-pass'
const ISSUER = `${process.env.MOCK_AUTH_PUBLIC_URL ?? `http://localhost:${PORT}`}/auth/v1`
const TTL_SECONDS = Number(process.env.MOCK_AUTH_TTL ?? 3600)

if (!['localhost', '127.0.0.1', '::1'].includes(HOST)) {
  throw new Error('mock-auth only binds to localhost')
}

const pool = new pg.Pool({ connectionString: DB_URL, max: 4 })
const { privateKey, publicKey } = await generateKeyPair('ES256')
const kid = `mock-${randomUUID()}`
const publicJwk = { ...(await exportJWK(publicKey)), kid, alg: 'ES256', use: 'sig' }

/** refresh token -> { userId, sessionId } (in memory; restart = everyone signed out). */
const refreshTokens = new Map()

async function findUserByEmail(email) {
  const { rows } = await pool.query('select id, email, created_at from auth.users where lower(email) = lower($1)', [email])
  return rows[0] ?? null
}

async function findUserById(id) {
  const { rows } = await pool.query('select id, email, created_at from auth.users where id = $1', [id])
  return rows[0] ?? null
}

async function runHook(userId, claims) {
  const client = await pool.connect()
  try {
    await client.query('begin')
    await client.query('set local role supabase_auth_admin')
    const { rows } = await client.query('select identity.custom_access_token_hook($1::jsonb) as result', [
      JSON.stringify({ user_id: userId, claims, authentication_method: 'password' }),
    ])
    await client.query('commit')
    return rows[0].result.claims
  } catch (error) {
    await client.query('rollback').catch(() => {})
    throw error
  } finally {
    client.release()
  }
}

function userJson(user) {
  return {
    id: user.id,
    aud: 'authenticated',
    role: 'authenticated',
    email: user.email,
    email_confirmed_at: new Date(0).toISOString(),
    app_metadata: { provider: 'email', providers: ['email'] },
    user_metadata: {},
    identities: [],
    created_at: new Date(user.created_at ?? Date.now()).toISOString(),
    updated_at: new Date().toISOString(),
    is_anonymous: false,
  }
}

async function issueSession(user, sessionId = randomUUID()) {
  const now = Math.floor(Date.now() / 1000)
  const baseClaims = {
    iss: ISSUER,
    sub: user.id,
    aud: 'authenticated',
    exp: now + TTL_SECONDS,
    iat: now,
    email: user.email,
    phone: '',
    role: 'authenticated',
    aal: 'aal1',
    amr: [{ method: 'password', timestamp: now }],
    session_id: sessionId,
    is_anonymous: false,
    app_metadata: { provider: 'email', providers: ['email'] },
    user_metadata: {},
  }
  const claims = await runHook(user.id, baseClaims)
  const accessToken = await new SignJWT(claims).setProtectedHeader({ alg: 'ES256', kid, typ: 'JWT' }).sign(privateKey)
  const refreshToken = randomBytes(24).toString('base64url')
  refreshTokens.set(refreshToken, { userId: user.id, sessionId })
  return {
    access_token: accessToken,
    token_type: 'bearer',
    expires_in: TTL_SECONDS,
    expires_at: now + TTL_SECONDS,
    refresh_token: refreshToken,
    user: userJson(user),
  }
}

function send(res, status, body) {
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info, x-supabase-api-version',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  })
  res.end(body === undefined ? '' : JSON.stringify(body))
}

const authError = (res, status, code, message) => send(res, status, { code: status, error_code: code, msg: message, error: code, error_description: message })

async function readJson(req) {
  let raw = ''
  for await (const chunk of req) raw += chunk
  try {
    return raw ? JSON.parse(raw) : {}
  } catch {
    return {}
  }
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', `http://${req.headers.host}`)
  try {
    if (req.method === 'OPTIONS') return send(res, 204)
    if (req.method === 'GET' && url.pathname === '/health') return send(res, 200, { ok: true })
    if (req.method === 'GET' && url.pathname === '/auth/v1/.well-known/jwks.json') return send(res, 200, { keys: [publicJwk] })

    if (req.method === 'POST' && url.pathname === '/auth/v1/token') {
      const body = await readJson(req)
      const grant = url.searchParams.get('grant_type')
      if (grant === 'password') {
        const user = body.email ? await findUserByEmail(String(body.email)) : null
        if (!user || body.password !== PASSWORD) return authError(res, 400, 'invalid_credentials', 'Invalid login credentials')
        return send(res, 200, await issueSession(user))
      }
      if (grant === 'refresh_token') {
        const entry = refreshTokens.get(String(body.refresh_token ?? ''))
        if (!entry) return authError(res, 400, 'refresh_token_not_found', 'Invalid Refresh Token: Refresh Token Not Found')
        refreshTokens.delete(String(body.refresh_token))
        const user = await findUserById(entry.userId)
        if (!user) return authError(res, 400, 'user_not_found', 'User not found')
        return send(res, 200, await issueSession(user, entry.sessionId))
      }
      return authError(res, 400, 'unsupported_grant_type', 'Unsupported grant type')
    }

    if (req.method === 'GET' && url.pathname === '/auth/v1/user') {
      const token = (req.headers.authorization ?? '').replace(/^Bearer\s+/i, '')
      const sub = token.split('.').length === 3 ? JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString()).sub : null
      const user = sub ? await findUserById(sub) : null
      return user ? send(res, 200, userJson(user)) : authError(res, 401, 'bad_jwt', 'invalid JWT')
    }

    if (req.method === 'POST' && url.pathname === '/auth/v1/logout') return send(res, 204)

    return authError(res, 404, 'not_found', 'Not found')
  } catch (error) {
    console.error('[mock-auth]', error)
    return authError(res, 500, 'unexpected_failure', 'Mock auth failure')
  }
})

server.listen(PORT, HOST, () => console.log(`[mock-auth] listening on http://${HOST}:${PORT} (issuer ${ISSUER})`))
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => pool.end().then(() => process.exit(0))))
